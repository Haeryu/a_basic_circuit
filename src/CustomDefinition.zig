const std = @import("std");
const Semantics = @import("Semantics.zig");

pub const invalid_index = std.math.maxInt(u32);

pub const NodeSpec = struct {
    kind: Semantics.Kind,
    width: u8,
    address_width: u8,
    split_width: u8,
};

pub const Wire = struct {
    target: u32,
    pin: u32,
    source: u32,
    source_port: u32,
};

pub const Group = struct {
    value: u8,
    min: u8,
    max: u8,
    exposed_count: u32 = 0,
    dependent: bool = false,
};

pub const Relation = union(enum) {
    sum: struct { total: u32, low: u32, high: u32 },
    pow: struct { address: u32, out: u32 },
};

const field_count = @intFromEnum(Semantics.Field.two) + 1;
const Bindings = [field_count]u32;

const Variable = struct {
    value: u8,
    min: u8,
    max: u8,
    parent: u32,
};

const PendingRelation = union(enum) {
    sum: struct { total: u32, low: u32, high: u32 },
    pow: struct { address: u32, out: u32 },
};

pub const CompileError = error{
    InvalidNode,
    InvalidShape,
    InvalidWire,
    WidthMismatch,
    InconsistentWidths,
    OutOfMemory,
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(NodeSpec) = .empty,
    wires: std.ArrayListUnmanaged(Wire) = .empty,
    groups: std.ArrayListUnmanaged(Group) = .empty,
    bindings: std.ArrayListUnmanaged(Bindings) = .empty,
    relations: std.ArrayListUnmanaged(Relation) = .empty,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Builder) void {
        self.relations.deinit(self.allocator);
        self.bindings.deinit(self.allocator);
        self.groups.deinit(self.allocator);
        self.wires.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn reset(self: *Builder) void {
        self.nodes.clearRetainingCapacity();
        self.wires.clearRetainingCapacity();
        self.groups.clearRetainingCapacity();
        self.bindings.clearRetainingCapacity();
        self.relations.clearRetainingCapacity();
    }

    pub fn addNode(self: *Builder, spec: NodeSpec) !u32 {
        if (!validNode(spec)) return error.InvalidShape;
        const index: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, spec);
        return index;
    }

    pub fn addWire(self: *Builder, wire: Wire) !void {
        if (wire.target >= self.nodes.items.len or wire.source >= self.nodes.items.len) return error.InvalidWire;
        try self.wires.append(self.allocator, wire);
    }

    pub fn binding(self: *const Builder, node: u32, field: Semantics.Field) ?u32 {
        if (node >= self.bindings.items.len) return null;
        const index = self.bindings.items[node][@intFromEnum(field)];
        return if (index == invalid_index) null else index;
    }

    pub fn compile(self: *Builder) CompileError!void {
        self.groups.clearRetainingCapacity();
        self.bindings.clearRetainingCapacity();
        self.relations.clearRetainingCapacity();
        if (self.nodes.items.len == 0) return error.InvalidNode;

        var has_input = false;
        var has_output = false;
        for (self.nodes.items) |node| {
            if (!validNode(node)) return error.InvalidShape;
            if (node.kind == .display or node.kind == .oscillator) return error.InvalidNode;
            has_input = has_input or node.kind == .input;
            has_output = has_output or node.kind == .output;
        }
        if (!has_input or !has_output) return error.InvalidNode;

        var variables = std.ArrayListUnmanaged(Variable).empty;
        defer variables.deinit(self.allocator);
        var variable_bindings = std.ArrayListUnmanaged(Bindings).empty;
        defer variable_bindings.deinit(self.allocator);
        var pending = std.ArrayListUnmanaged(PendingRelation).empty;
        defer pending.deinit(self.allocator);

        const one = try addVariable(self.allocator, &variables, 1, 1, 1);
        const two = try addVariable(self.allocator, &variables, 2, 2, 2);
        for (self.nodes.items) |node| {
            var fields: [field_count]u32 = @splat(invalid_index);
            fields[@intFromEnum(Semantics.Field.one)] = one;
            fields[@intFromEnum(Semantics.Field.two)] = two;
            fields[@intFromEnum(Semantics.Field.width)] = try addVariable(
                self.allocator,
                &variables,
                node.width,
                if (node.kind == .split or node.kind == .join) 2 else 1,
                Semantics.max_width,
            );
            if (node.kind == .mux or node.kind == .demux or node.kind == .decoder or node.kind == .ram) {
                fields[@intFromEnum(Semantics.Field.address_width)] = try addVariable(
                    self.allocator,
                    &variables,
                    node.address_width,
                    1,
                    Semantics.max_address_width,
                );
            }
            if (node.kind == .split or node.kind == .join) {
                const low = try addVariable(self.allocator, &variables, node.split_width, 1, 63);
                const high = try addVariable(self.allocator, &variables, node.width - node.split_width, 1, 63);
                fields[@intFromEnum(Semantics.Field.split_width)] = low;
                fields[@intFromEnum(Semantics.Field.high_width)] = high;
                try pending.append(self.allocator, .{ .sum = .{
                    .total = fields[@intFromEnum(Semantics.Field.width)],
                    .low = low,
                    .high = high,
                } });
            }
            if (node.kind == .decoder) {
                const decoded = try addVariable(
                    self.allocator,
                    &variables,
                    @as(u8, 1) << @intCast(node.address_width),
                    1,
                    Semantics.max_width,
                );
                fields[@intFromEnum(Semantics.Field.decoded_width)] = decoded;
                try pending.append(self.allocator, .{ .pow = .{
                    .address = fields[@intFromEnum(Semantics.Field.address_width)],
                    .out = decoded,
                } });
            }
            try variable_bindings.append(self.allocator, fields);
        }

        for (self.wires.items) |wire| {
            if (wire.target >= self.nodes.items.len or wire.source >= self.nodes.items.len) return error.InvalidWire;
            const target = self.nodes.items[wire.target];
            const source = self.nodes.items[wire.source];
            const input = Semantics.inputPort(target.kind, target.width, target.address_width, target.split_width, false, wire.pin) orelse return error.InvalidWire;
            const output = Semantics.outputPort(source.kind, source.width, source.address_width, source.split_width, wire.source_port) orelse return error.InvalidWire;
            if (input.width != output.width) return error.WidthMismatch;
            const input_var = fieldVariable(variable_bindings.items[wire.target], input.field) orelse return error.InvalidWire;
            const output_var = fieldVariable(variable_bindings.items[wire.source], output.field) orelse return error.InvalidWire;
            unionVariables(variables.items, input_var, output_var);
        }

        const root_groups = try self.allocator.alloc(u32, variables.items.len);
        defer self.allocator.free(root_groups);
        @memset(root_groups, invalid_index);
        const variable_groups = try self.allocator.alloc(u32, variables.items.len);
        defer self.allocator.free(variable_groups);

        for (variables.items, 0..) |variable, index| {
            const root = findRoot(variables.items, @intCast(index));
            if (root_groups[root] == invalid_index) {
                root_groups[root] = @intCast(self.groups.items.len);
                try self.groups.append(self.allocator, .{
                    .value = variable.value,
                    .min = 1,
                    .max = Semantics.max_width,
                });
            }
            const group_index = root_groups[root];
            variable_groups[index] = group_index;
            const group = &self.groups.items[group_index];
            group.min = @max(group.min, variable.min);
            group.max = @min(group.max, variable.max);
            if (group.min > group.max or group.value != variable.value) return error.InconsistentWidths;
        }

        for (variable_bindings.items, self.nodes.items) |variables_for_node, node| {
            var result = [_]u32{invalid_index} ** field_count;
            for (variables_for_node, 0..) |variable, field_index| {
                if (variable != invalid_index) result[field_index] = variable_groups[variable];
            }
            try self.bindings.append(self.allocator, result);
            if (node.kind == .input or node.kind == .output) {
                self.groups.items[result[@intFromEnum(Semantics.Field.width)]].exposed_count += 1;
            }
        }

        for (pending.items) |relation| switch (relation) {
            .sum => |r| try self.relations.append(self.allocator, .{ .sum = .{
                .total = variable_groups[r.total],
                .low = variable_groups[r.low],
                .high = variable_groups[r.high],
            } }),
            .pow => |r| try self.relations.append(self.allocator, .{ .pow = .{
                .address = variable_groups[r.address],
                .out = variable_groups[r.out],
            } }),
        };
        chooseDependencies(self.groups.items, self.relations.items);
    }
};

fn validNode(node: NodeSpec) bool {
    return Semantics.validShape(node.kind, node.width, node.address_width, node.split_width);
}

fn addVariable(allocator: std.mem.Allocator, variables: *std.ArrayListUnmanaged(Variable), value: u8, min: u8, max: u8) !u32 {
    const index: u32 = @intCast(variables.items.len);
    try variables.append(allocator, .{ .value = value, .min = min, .max = max, .parent = index });
    return index;
}

fn fieldVariable(bindings: Bindings, field: Semantics.Field) ?u32 {
    const result = bindings[@intFromEnum(field)];
    return if (result == invalid_index) null else result;
}

fn findRoot(variables: []Variable, start: u32) u32 {
    var root = start;
    while (variables[root].parent != root) root = variables[root].parent;
    var current = start;
    while (variables[current].parent != current) {
        const next = variables[current].parent;
        variables[current].parent = root;
        current = next;
    }
    return root;
}

fn unionVariables(variables: []Variable, a: u32, b: u32) void {
    const left = findRoot(variables, a);
    const right = findRoot(variables, b);
    if (left != right) variables[right].parent = left;
}

fn relationEqual(a: Relation, b: Relation) bool {
    return switch (a) {
        .pow => |left| switch (b) {
            .pow => |right| left.address == right.address and left.out == right.out,
            else => false,
        },
        .sum => |left| switch (b) {
            .sum => |right| left.total == right.total and
                @min(left.low, left.high) == @min(right.low, right.high) and
                @max(left.low, left.high) == @max(right.low, right.high),
            else => false,
        },
    };
}

fn seenEarlier(relations: []const Relation, index: usize) bool {
    for (relations[0..index]) |previous| if (relationEqual(previous, relations[index])) return true;
    return false;
}

fn candidate(groups: []Group, choices: []const u32) ?u32 {
    var result: ?u32 = null;
    var result_exposed: u32 = std.math.maxInt(u32);
    for (choices) |index| {
        const group = groups[index];
        if (group.min == group.max or group.dependent) continue;
        if (result == null or group.exposed_count < result_exposed) {
            result = index;
            result_exposed = group.exposed_count;
        }
    }
    return result;
}

fn chooseDependencies(groups: []Group, relations: []const Relation) void {
    for (groups) |*group| group.dependent = false;
    inline for (.{ .pow, .sum }) |wanted| {
        for (relations, 0..) |relation, index| {
            if (std.meta.activeTag(relation) != wanted or seenEarlier(relations, index)) continue;
            const chosen = switch (relation) {
                .pow => |r| candidate(groups, &.{ r.out, r.address }),
                .sum => |r| if (r.low == r.high)
                    candidate(groups, &.{ r.total, r.low })
                else
                    candidate(groups, &.{ r.high, r.total, r.low }),
            };
            if (chosen) |group| groups[group].dependent = true;
        }
    }
}

test "custom definition groups keep data and selector widths independent" {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();
    _ = try builder.addNode(.{ .kind = .input, .width = 3, .address_width = 1, .split_width = 1 });
    _ = try builder.addNode(.{ .kind = .input, .width = 8, .address_width = 1, .split_width = 1 });
    _ = try builder.addNode(.{ .kind = .mux, .width = 8, .address_width = 3, .split_width = 1 });
    _ = try builder.addNode(.{ .kind = .output, .width = 8, .address_width = 1, .split_width = 1 });
    try builder.addWire(.{ .source = 0, .source_port = 0, .target = 2, .pin = 0 });
    try builder.addWire(.{ .source = 1, .source_port = 0, .target = 2, .pin = 1 });
    try builder.addWire(.{ .source = 2, .source_port = 0, .target = 3, .pin = 0 });
    try builder.compile();
    const selector = builder.binding(0, .width).?;
    const data = builder.binding(1, .width).?;
    try std.testing.expect(selector != data);
    try std.testing.expectEqual(selector, builder.binding(2, .address_width).?);
    try std.testing.expectEqual(data, builder.binding(2, .width).?);
    try std.testing.expectEqual(data, builder.binding(3, .width).?);
}

test "decoder into join derives decoded bus before exposed parameters" {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();
    _ = try builder.addNode(.{ .kind = .input, .width = 5, .address_width = 1, .split_width = 1 });
    _ = try builder.addNode(.{ .kind = .input, .width = 3, .address_width = 1, .split_width = 1 });
    _ = try builder.addNode(.{ .kind = .decoder, .width = 1, .address_width = 5, .split_width = 1 });
    _ = try builder.addNode(.{ .kind = .join, .width = 35, .address_width = 1, .split_width = 3 });
    _ = try builder.addNode(.{ .kind = .output, .width = 35, .address_width = 1, .split_width = 1 });
    try builder.addWire(.{ .source = 0, .source_port = 0, .target = 2, .pin = 0 });
    try builder.addWire(.{ .source = 1, .source_port = 0, .target = 3, .pin = 0 });
    try builder.addWire(.{ .source = 2, .source_port = 0, .target = 3, .pin = 1 });
    try builder.addWire(.{ .source = 3, .source_port = 0, .target = 4, .pin = 0 });
    try builder.compile();
    const decoded = builder.binding(2, .decoded_width).?;
    const total = builder.binding(3, .width).?;
    try std.testing.expect(builder.groups.items[decoded].dependent);
    try std.testing.expect(builder.groups.items[total].dependent);
    try std.testing.expect(!builder.groups.items[builder.binding(0, .width).?].dependent);
    try std.testing.expect(!builder.groups.items[builder.binding(1, .width).?].dependent);
}
