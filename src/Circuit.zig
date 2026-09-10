const Circuit = @This();

const std = @import("std");

const DenseGenPool = @import("dense_gen_pool.zig").DenseGenPool;
const GenHandle = @import("dense_gen_pool.zig").GenHandle;
const Op = @import("op.zig").Op;

const NodeTag = struct {};
const NetTag = struct {};
const CircuitTag = struct {};

pub const NodeId = GenHandle(NodeTag);
pub const NetId = GenHandle(NetTag);
pub const Id = GenHandle(CircuitTag);

pub const Vec2 = struct {
    x: f32,
    y: f32,
};

pub const OutputPin = struct {
    node: NodeId,
    port: u16,
};

pub const NodeKind = union(enum) {
    primitive: Op,
    subcircuit: Circuit.Id,
};

pub const Node = struct {
    kind: NodeKind,
    position: Vec2,

    input_count: u16,

    // [ inputs ][ outputs ]
    connections: []?NetId,

    pub fn outputCount(self: *const Node) usize {
        return self.connections.len - self.input_count;
    }
};

pub const Net = struct {
    // Reverse index for constant-time output conflict checks. Input connections
    // live only on nodes; runtime fan-out is derived when compiling.
    driver: ?OutputPin = null,
};

pub const InterfacePort = struct {
    net: NetId,
};

const NodePool = DenseGenPool(Node, NodeId);
const NetPool = DenseGenPool(Net, NetId);

gpa: std.mem.Allocator,

nodes: NodePool,
nets: NetPool,

inputs: std.ArrayListUnmanaged(InterfacePort),
outputs: std.ArrayListUnmanaged(InterfacePort),

pub fn init(gpa: std.mem.Allocator) Circuit {
    return .{
        .gpa = gpa,
        .nodes = .init,
        .nets = .init,
        .inputs = .empty,
        .outputs = .empty,
    };
}

pub fn deinit(self: *Circuit) void {
    for (self.nodes.values.items) |node| {
        self.gpa.free(node.connections);
    }

    self.outputs.deinit(self.gpa);
    self.inputs.deinit(self.gpa);

    self.nets.deinit(self.gpa);
    self.nodes.deinit(self.gpa);

    self.* = undefined;
}

pub fn addNode(self: *Circuit, op: Op, position: Vec2) !NodeId {
    const input_count = op.inputCount();
    const output_count = op.outputCount();

    if (input_count > std.math.maxInt(u16) or output_count > std.math.maxInt(u16)) {
        return error.TooManyPins;
    }

    const total = std.math.add(usize, input_count, output_count) catch {
        return error.TooManyPins;
    };

    const connections = try self.gpa.alloc(?NetId, total);
    errdefer self.gpa.free(connections);

    @memset(connections, null);

    return self.nodes.create(self.gpa, .{
        .kind = .{
            .primitive = op,
        },
        .position = position,
        .input_count = @intCast(input_count),
        .connections = connections,
    });
}

pub fn removeNode(self: *Circuit, node_id: NodeId) bool {
    const node = self.nodes.get(node_id) orelse return false;
    for (0..node.outputCount()) |port| self.disconnectOutput(node_id, port);
    self.gpa.free(node.connections);
    return self.nodes.destroy(node_id);
}

pub fn addNet(self: *Circuit) !NetId {
    return self.nets.create(self.gpa, .{});
}

pub fn removeNet(self: *Circuit, net_id: NetId) bool {
    if (self.nets.get(net_id) == null) return false;

    for (self.nodes.values.items) |node| {
        for (node.connections) |*connection| {
            if (connection.* == net_id) connection.* = null;
        }
    }

    for ([_]*std.ArrayListUnmanaged(InterfacePort){ &self.inputs, &self.outputs }) |ports| {
        var count: usize = 0;
        for (ports.items) |port| {
            if (port.net == net_id) continue;
            ports.items[count] = port;
            count += 1;
        }
        ports.items.len = count;
    }

    return self.nets.destroy(net_id);
}

pub fn connectInput(self: *Circuit, node_id: NodeId, port: usize, net_id: NetId) !void {
    const node = self.nodes.get(node_id) orelse return error.InvalidNode;
    if (port >= node.input_count) return error.InvalidPort;
    if (self.nets.get(net_id) == null) return error.InvalidNet;
    node.connections[port] = net_id;
}

pub fn disconnectInput(self: *Circuit, node_id: NodeId, port: usize) void {
    const node = self.nodes.get(node_id) orelse return;
    if (port >= node.input_count) return;
    node.connections[port] = null;
}

pub fn connectOutput(self: *Circuit, node_id: NodeId, port: usize, net_id: NetId) !void {
    const node = self.nodes.get(node_id) orelse return error.InvalidNode;

    const input_count = node.input_count;
    const output_count = node.outputCount();

    if (port >= output_count) {
        return error.InvalidPort;
    }

    const net = self.nets.get(net_id) orelse return error.InvalidNet;

    if (net.driver) |driver| {
        if (driver.node == node_id and driver.port == port) {
            return;
        }

        return error.MultipleDrivers;
    }

    const connection_index = input_count + port;

    if (node.connections[connection_index]) |old_net_id| {
        if (old_net_id == net_id) {
            return;
        }

        const old_net = self.nets.get(old_net_id) orelse unreachable;

        std.debug.assert(old_net.driver != null);
        std.debug.assert(old_net.driver.?.node == node_id);
        std.debug.assert(old_net.driver.?.port == port);

        old_net.driver = null;
    }

    net.driver = .{
        .node = node_id,
        .port = @intCast(port),
    };

    node.connections[connection_index] = net_id;
}

pub fn disconnectOutput(self: *Circuit, node_id: NodeId, port: usize) void {
    const node = self.nodes.get(node_id) orelse return;
    const input_count = node.input_count;
    const output_count = node.outputCount();

    if (port >= output_count) {
        return;
    }

    const connection_index = input_count + port;
    const net_id = node.connections[connection_index] orelse return;

    const net = self.nets.get(net_id) orelse unreachable;

    std.debug.assert(net.driver != null);
    std.debug.assert(net.driver.?.node == node_id);
    std.debug.assert(net.driver.?.port == port);

    net.driver = null;
    node.connections[connection_index] = null;
}

pub fn addInput(self: *Circuit, net_id: NetId) !usize {
    if (self.nets.get(net_id) == null) {
        return error.InvalidNet;
    }

    for (self.inputs.items) |port| {
        if (port.net == net_id) {
            return error.AlreadyInput;
        }
    }

    const index = self.inputs.items.len;

    try self.inputs.append(self.gpa, .{ .net = net_id });

    return index;
}

pub fn addOutput(self: *Circuit, net_id: NetId) !usize {
    if (self.nets.get(net_id) == null) {
        return error.InvalidNet;
    }

    for (self.outputs.items) |port| {
        if (port.net == net_id) {
            return error.AlreadyOutput;
        }
    }

    const index = self.outputs.items.len;

    try self.outputs.append(self.gpa, .{ .net = net_id });

    return index;
}

pub fn removeInput(self: *Circuit, index: usize) bool {
    if (index >= self.inputs.items.len) {
        return false;
    }

    _ = self.inputs.orderedRemove(index);
    return true;
}

pub fn removeOutput(self: *Circuit, index: usize) bool {
    if (index >= self.outputs.items.len) {
        return false;
    }

    _ = self.outputs.orderedRemove(index);
    return true;
}

pub fn addSubcircuitNode(
    self: *Circuit,
    circuit_id: Circuit.Id,
    child: *const Circuit,
    position: Vec2,
) !NodeId {
    const input_count = child.inputs.items.len;
    const output_count = child.outputs.items.len;

    if (input_count > std.math.maxInt(u16) or output_count > std.math.maxInt(u16)) {
        return error.TooManyPins;
    }

    const connection_count = std.math.add(usize, input_count, output_count) catch
        return error.TooManyPins;

    const connections = try self.gpa.alloc(?NetId, connection_count);
    errdefer self.gpa.free(connections);

    @memset(connections, null);

    return self.nodes.create(self.gpa, .{
        .kind = .{
            .subcircuit = circuit_id,
        },
        .position = position,
        .input_count = @intCast(input_count),
        .connections = connections,
    });
}

test "circuit fanout survives node deletion" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    //
    // source.OUT ── net ─┬─> a.IN
    //                    └─> b.IN

    const source = try circuit.addNode(
        .not1,
        .{ .x = 0, .y = 0 },
    );

    const a = try circuit.addNode(
        .not1,
        .{ .x = 100, .y = -50 },
    );

    const b = try circuit.addNode(
        .not1,
        .{ .x = 100, .y = 50 },
    );

    const net = try circuit.addNet();

    try circuit.connectOutput(
        source,
        0,
        net,
    );

    try circuit.connectInput(
        a,
        0,
        net,
    );

    try circuit.connectInput(
        b,
        0,
        net,
    );

    try std.testing.expect(circuit.nodes.get(a).?.connections[0] == net);
    try std.testing.expect(circuit.nodes.get(b).?.connections[0] == net);

    try std.testing.expect(
        circuit.removeNode(a),
    );

    try std.testing.expect(
        circuit.nodes.get(a) == null,
    );

    try std.testing.expect(
        circuit.nodes.get(b) != null,
    );

    try std.testing.expect(circuit.nodes.get(b).?.connections[0] == net);
    try std.testing.expect(circuit.nets.get(net).?.driver.?.node == source);

    try std.testing.expect(
        circuit.removeNet(net),
    );

    try std.testing.expect(
        circuit.nets.get(net) == null,
    );

    // source output disconnected.
    //
    // NOT:
    // connections[0] = input
    // connections[1] = output
    try std.testing.expect(
        circuit.nodes.get(source).?
            .connections[1] == null,
    );

    // b input disconnected.
    try std.testing.expect(
        circuit.nodes.get(b).?
            .connections[0] == null,
    );
}

test "input reconnect and disconnect allocate nothing and preserve other pins" {
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var circuit = Circuit.init(counted.allocator());
    defer circuit.deinit();
    const a = try circuit.addNet();
    const b = try circuit.addNet();
    const node = try circuit.addNode(.and2, .{ .x = 0, .y = 0 });
    counted.fail_index = counted.alloc_index;
    counted.resize_fail_index = counted.resize_index;

    try circuit.connectInput(node, 0, a);
    try circuit.connectInput(node, 1, a);
    try circuit.connectInput(node, 0, b);
    try circuit.connectInput(node, 0, b);
    try std.testing.expect(circuit.nodes.get(node).?.connections[0] == b);
    try std.testing.expect(circuit.nodes.get(node).?.connections[1] == a);
    try std.testing.expectError(error.InvalidPort, circuit.connectInput(node, 2, a));
    circuit.disconnectInput(node, 0);
    circuit.disconnectInput(node, 0);
    circuit.disconnectInput(node, 2);
    try std.testing.expect(circuit.nodes.get(node).?.connections[0] == null);
    try std.testing.expect(circuit.nodes.get(node).?.connections[1] == a);
    try std.testing.expect(!counted.has_induced_failure);
}

test "output conflict leaves both drivers and connections intact" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();
    const a = try circuit.addNet();
    const b = try circuit.addNet();
    const first = try circuit.addNode(.not1, .{ .x = 0, .y = 0 });
    const second = try circuit.addNode(.not1, .{ .x = 0, .y = 0 });
    try circuit.connectOutput(first, 0, a);
    try circuit.connectOutput(second, 0, b);
    try std.testing.expectError(error.MultipleDrivers, circuit.connectOutput(first, 0, b));
    try std.testing.expect(circuit.nodes.get(first).?.connections[1] == a);
    try std.testing.expect(circuit.nodes.get(second).?.connections[1] == b);
    try std.testing.expect(circuit.nets.get(a).?.driver.?.node == first);
    try std.testing.expect(circuit.nets.get(b).?.driver.?.node == second);

    try std.testing.expect(circuit.removeNode(second));
    try std.testing.expect(circuit.nets.get(b).?.driver == null);
    try circuit.connectOutput(first, 0, b);
    try std.testing.expect(circuit.nets.get(a).?.driver == null);
    try std.testing.expect(circuit.nets.get(b).?.driver.?.node == first);
    try std.testing.expect(circuit.nodes.get(first).?.connections[1] == b);
    const replacement = try circuit.addNode(.not1, .{ .x = 0, .y = 0 });
    try std.testing.expect(replacement.index == second.index);
    try std.testing.expectError(error.InvalidNode, circuit.connectInput(second, 0, a));
}

test "net removal clears every pin and preserves interface order" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();
    const a = try circuit.addNet();
    const removed = try circuit.addNet();
    const b = try circuit.addNet();
    for ([_]NetId{ a, removed, b }) |net| {
        _ = try circuit.addInput(net);
        _ = try circuit.addOutput(net);
    }
    const node = try circuit.addNode(.and2, .{ .x = 0, .y = 0 });
    try circuit.connectInput(node, 0, removed);
    try circuit.connectInput(node, 1, removed);
    try circuit.connectOutput(node, 0, removed);
    try std.testing.expect(circuit.removeNet(removed));
    for (circuit.nodes.get(node).?.connections) |connection| try std.testing.expect(connection == null);
    for ([_][]const InterfacePort{ circuit.inputs.items, circuit.outputs.items }) |ports| {
        try std.testing.expectEqual(@as(usize, 2), ports.len);
        try std.testing.expect(ports[0].net == a);
        try std.testing.expect(ports[1].net == b);
    }
    const replacement = try circuit.addNet();
    try std.testing.expect(replacement.index == removed.index);
    try circuit.connectInput(node, 0, replacement);
    try std.testing.expectError(error.InvalidNet, circuit.connectInput(node, 0, removed));
    try std.testing.expect(!circuit.removeNet(removed));
    try std.testing.expect(circuit.nodes.get(node).?.connections[0] == replacement);
}
