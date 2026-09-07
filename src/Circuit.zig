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

pub const InputPin = struct {
    node: NodeId,
    port: u16,
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
    driver: ?OutputPin = null,

    // fan-out
    consumers: std.ArrayListUnmanaged(InputPin) = .empty,
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

    for (self.nets.values.items) |*net| {
        net.consumers.deinit(self.gpa);
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
    const input_count = node.input_count;
    const output_count = node.outputCount();

    for (0..input_count) |port| {
        self.disconnectInput(node_id, port);
    }

    for (0..output_count) |port| {
        self.disconnectOutput(node_id, port);
    }

    const node_after_disconnect = self.nodes.get(node_id) orelse unreachable;

    self.gpa.free(node_after_disconnect.connections);

    return self.nodes.destroy(node_id);
}

pub fn addNet(self: *Circuit) !NetId {
    return self.nets.create(self.gpa, .{});
}

pub fn removeNet(self: *Circuit, net_id: NetId) bool {
    var input_index: usize = 0;
    while (input_index < self.inputs.items.len) {
        if (self.inputs.items[input_index].net == net_id) {
            _ = self.inputs.orderedRemove(input_index);
        } else {
            input_index += 1;
        }
    }

    var output_index: usize = 0;
    while (output_index < self.outputs.items.len) {
        if (self.outputs.items[output_index].net == net_id) {
            _ = self.outputs.orderedRemove(output_index);
        } else {
            output_index += 1;
        }
    }

    const net = self.nets.get(net_id) orelse return false;

    if (net.driver) |driver| {
        const node = self.nodes.get(driver.node) orelse unreachable;
        const index = @as(usize, node.input_count) + @as(usize, driver.port);

        std.debug.assert(index < node.connections.len);
        std.debug.assert(node.connections[index].? == net_id);

        node.connections[index] = null;
    }

    for (net.consumers.items) |consumer| {
        const node = self.nodes.get(consumer.node) orelse unreachable;

        const port: usize = consumer.port;

        std.debug.assert(port < node.input_count);
        std.debug.assert(node.connections[port].? == net_id);

        node.connections[port] = null;
    }

    net.consumers.deinit(self.gpa);

    return self.nets.destroy(net_id);
}

pub fn connectInput(self: *Circuit, node_id: NodeId, port: usize, net_id: NetId) !void {
    const node = self.nodes.get(node_id) orelse return error.InvalidNode;

    if (port >= node.input_count) {
        return error.InvalidPort;
    }

    const net = self.nets.get(net_id) orelse return error.InvalidNet;

    if (node.connections[port]) |old_net_id| {
        if (old_net_id == net_id) {
            return;
        }
    }

    try net.consumers.ensureUnusedCapacity(self.gpa, 1);

    if (node.connections[port]) |old_net_id| {
        const old_net = self.nets.get(old_net_id) orelse unreachable;

        var found = false;
        for (old_net.consumers.items, 0..) |consumer, i| {
            if (consumer.node == node_id and consumer.port == port) {
                _ = old_net.consumers.swapRemove(i);
                found = true;
                break;
            }
        }

        std.debug.assert(found);
    }

    net.consumers.appendAssumeCapacity(.{
        .node = node_id,
        .port = @intCast(port),
    });

    node.connections[port] = net_id;
}

pub fn disconnectInput(self: *Circuit, node_id: NodeId, port: usize) void {
    const node = self.nodes.get(node_id) orelse return;

    if (port >= node.input_count) {
        return;
    }

    const net_id = node.connections[port] orelse return;
    const net = self.nets.get(net_id) orelse unreachable;
    var found = false;
    for (net.consumers.items, 0..) |consumer, i| {
        if (consumer.node == node_id and consumer.port == port) {
            _ = net.consumers.swapRemove(i);
            found = true;
            break;
        }
    }

    std.debug.assert(found);

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

    try std.testing.expectEqual(
        @as(usize, 2),
        circuit.nets.get(net).?
            .consumers.items.len,
    );

    try std.testing.expect(
        circuit.removeNode(a),
    );

    try std.testing.expect(
        circuit.nodes.get(a) == null,
    );

    try std.testing.expect(
        circuit.nodes.get(b) != null,
    );

    try std.testing.expectEqual(
        @as(usize, 1),
        circuit.nets.get(net).?
            .consumers.items.len,
    );

    try std.testing.expect(
        circuit.nets.get(net).?
            .consumers.items[0]
            .node == b,
    );

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
