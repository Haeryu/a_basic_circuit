const Circuit = @This();

const std = @import("std");

pub const NodeId = enum(u32) {
    _,
};
pub const NetId = enum(u32) {
    _,
};

pub const Vec2 = struct {
    x: f32,
    y: f32,
};

pub const OutputPin = struct {
    node: NodeId,
    port: u16,
};

pub const Node = struct {
    position: Vec2,

    inputs: []?NetId,
    outputs: []?NetId,
};

pub const Net = struct {
    driver: ?OutputPin = null,
};

allocator: std.mem.Allocator,

nodes: std.ArrayListUnmanaged(Node),
nets: std.ArrayListUnmanaged(Net),

pub fn init(allocator: std.mem.Allocator) Circuit {
    return .{
        .allocator = allocator,
        .nodes = .empty,
        .nets = .empty,
    };
}

pub fn deinit(self: *Circuit) void {
    for (self.nodes.items) |node| {
        self.allocator.free(node.outputs);
        self.allocator.free(node.inputs);
    }

    self.nodes.deinit(self.allocator);
    self.nets.deinit(self.allocator);

    self.* = undefined;
}

pub fn addNode(self: *Circuit, input_count: usize, output_count: usize, position: Vec2) !NodeId {
    if (self.nodes.items.len >= std.math.maxInt(u32)) {
        return error.TooManyNodes;
    }

    const inputs = try self.allocator.alloc(?NetId, input_count);
    errdefer self.allocator.free(inputs);

    const outputs = try self.allocator.alloc(?NetId, output_count);
    errdefer self.allocator.free(outputs);

    @memset(inputs, null);
    @memset(outputs, null);

    const id: NodeId = @enumFromInt(self.nodes.items.len);

    try self.nodes.append(self.allocator, .{
        .position = position,
        .inputs = inputs,
        .outputs = outputs,
    });

    return id;
}

pub fn addNet(self: *Circuit) !NetId {
    if (self.nets.items.len >= std.math.maxInt(u32)) {
        return error.TooManyNets;
    }

    const id: NetId = @enumFromInt(self.nets.items.len);
    try self.nets.append(self.allocator, .{});

    return id;
}

pub fn connectOutput(self: *Circuit, node_id: NodeId, port: usize, net_id: NetId) !void {
    const node_index: usize = @intCast(@intFromEnum(node_id));

    const net_index: usize = @intCast(@intFromEnum(net_id));

    if (node_index >= self.nodes.items.len) {
        return error.InvalidNode;
    }

    if (net_index >= self.nets.items.len) {
        return error.InvalidNet;
    }

    const node = &self.nodes.items[node_index];

    if (port >= node.outputs.len) {
        return error.InvalidPort;
    }

    const net = &self.nets.items[net_index];

    if (net.driver != null) {
        return error.MultipleDrivers;
    }

    node.outputs[port] = net_id;

    net.driver = .{
        .node = node_id,
        .port = @intCast(port),
    };
}

pub fn connectInput(self: *Circuit, node_id: NodeId, port: usize, net_id: NetId) !void {
    const node_index: usize = @intCast(@intFromEnum(node_id));
    const net_index: usize = @intCast(@intFromEnum(net_id));

    if (node_index >= self.nodes.items.len) {
        return error.InvalidNode;
    }

    if (net_index >= self.nets.items.len) {
        return error.InvalidNet;
    }

    const node = &self.nodes.items[node_index];

    if (port >= node.inputs.len) {
        return error.InvalidPort;
    }

    node.inputs[port] = net_id;
}
