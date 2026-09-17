const std = @import("std");
const Circuit = @import("Circuit.zig");
const Semantics = @import("Semantics.zig");

pub const Target = struct {
    node: Circuit.NodeId,
    pin: u8,
    source_bit: u8,
};

pub const Scratch = struct {
    allocator: std.mem.Allocator,
    created: std.ArrayListUnmanaged(Circuit.NodeId) = .empty,
    input_widths: std.ArrayListUnmanaged(u8) = .empty,
    input_offsets: std.ArrayListUnmanaged(u32) = .empty,
    input_targets: std.ArrayListUnmanaged(Target) = .empty,
    output_offsets: std.ArrayListUnmanaged(u32) = .empty,
    output_nodes: std.ArrayListUnmanaged(Circuit.NodeId) = .empty,

    pub fn init(allocator: std.mem.Allocator) Scratch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Scratch) void {
        self.output_nodes.deinit(self.allocator);
        self.output_offsets.deinit(self.allocator);
        self.input_targets.deinit(self.allocator);
        self.input_offsets.deinit(self.allocator);
        self.input_widths.deinit(self.allocator);
        self.created.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clearRetainingCapacity(self: *Scratch) void {
        self.created.clearRetainingCapacity();
        self.input_widths.clearRetainingCapacity();
        self.input_offsets.clearRetainingCapacity();
        self.input_targets.clearRetainingCapacity();
        self.output_offsets.clearRetainingCapacity();
        self.output_nodes.clearRetainingCapacity();
    }

    pub fn inputCount(self: *const Scratch) usize {
        return self.input_widths.items.len;
    }

    pub fn inputTargets(self: *const Scratch, pin: usize) ?[]const Target {
        if (pin >= self.inputCount()) return null;
        const begin: usize = @intCast(self.input_offsets.items[pin]);
        const end: usize = @intCast(self.input_offsets.items[pin + 1]);
        return self.input_targets.items[begin..end];
    }

    pub fn outputCount(self: *const Scratch) usize {
        return if (self.output_offsets.items.len == 0) 0 else self.output_offsets.items.len - 1;
    }

    pub fn outputBus(self: *const Scratch, pin: usize) ?[]const Circuit.NodeId {
        if (pin >= self.outputCount()) return null;
        const begin: usize = @intCast(self.output_offsets.items[pin]);
        const end: usize = @intCast(self.output_offsets.items[pin + 1]);
        return self.output_nodes.items[begin..end];
    }
};

fn circuitKind(kind: Semantics.Kind, interface_input: bool) ?Circuit.Kind {
    if (interface_input) return if (kind == .input) .buffer else null;
    return switch (kind) {
        .input, .oscillator => .input,
        .output => .output,
        .not => .not,
        .and2 => .and2,
        .or2 => .or2,
        .xor2 => .xor2,
        .dff => .dff,
        .buffer => .buffer,
        .nand2 => .nand2,
        .nor2 => .nor2,
        .xnor2 => .xnor2,
        else => null,
    };
}

fn appendPort(scratch: *Scratch, width: u8, targets: []const Target) !void {
    try scratch.input_widths.append(scratch.allocator, width);
    try scratch.input_targets.appendSlice(scratch.allocator, targets);
    try scratch.input_offsets.append(scratch.allocator, @intCast(scratch.input_targets.items.len));
}

fn appendOutput(scratch: *Scratch, nodes: []const Circuit.NodeId) !void {
    try scratch.output_nodes.appendSlice(scratch.allocator, nodes);
    try scratch.output_offsets.append(scratch.allocator, @intCast(scratch.output_nodes.items.len));
}

pub fn compile(
    circuit: *Circuit,
    scratch: *Scratch,
    kind: Semantics.Kind,
    width: u8,
    address_width: u8,
    split_width: u8,
    interface_input: bool,
    budget: usize,
) !void {
    scratch.clearRetainingCapacity();
    if (width == 0 or width > Semantics.max_width or budget < width) return error.BudgetExceeded;
    if (address_width == 0 or address_width > Semantics.max_address_width) return error.InvalidShape;
    if ((kind == .split or kind == .join) and (split_width == 0 or split_width >= width)) return error.InvalidShape;
    if (kind == .display or kind == .mux or kind == .demux or kind == .decoder or kind == .adder or kind == .split or kind == .join) {
        return error.InvalidKind;
    }
    if (interface_input and kind != .input) return error.InvalidKind;

    try scratch.input_offsets.append(scratch.allocator, 0);
    try scratch.output_offsets.append(scratch.allocator, 0);

    if (kind == .clock) {
        const first = try circuit.addCounter(width);
        var ids = std.ArrayListUnmanaged(Circuit.NodeId).empty;
        defer ids.deinit(scratch.allocator);
        try ids.ensureTotalCapacity(scratch.allocator, width);
        const first_raw: u32 = @intFromEnum(first);
        for (0..width) |bit| {
            const id: Circuit.NodeId = @enumFromInt(first_raw + @as(u32, @intCast(bit)));
            ids.appendAssumeCapacity(id);
            try scratch.created.append(scratch.allocator, id);
        }
        const clock_target = [_]Target{.{ .node = first, .pin = 0, .source_bit = 0 }};
        const load_target = [_]Target{.{ .node = first, .pin = 1, .source_bit = 0 }};
        try appendPort(scratch, 1, &clock_target);
        try appendPort(scratch, 1, &load_target);
        var data_targets = std.ArrayListUnmanaged(Target).empty;
        defer data_targets.deinit(scratch.allocator);
        try data_targets.ensureTotalCapacity(scratch.allocator, width);
        for (ids.items, 0..) |id, bit| data_targets.appendAssumeCapacity(.{
            .node = id,
            .pin = 2,
            .source_bit = @intCast(bit),
        });
        try appendPort(scratch, width, data_targets.items);
        try appendOutput(scratch, ids.items);
        return;
    }

    const native_kind = circuitKind(kind, interface_input) orelse return error.InvalidKind;
    var ids = std.ArrayListUnmanaged(Circuit.NodeId).empty;
    defer ids.deinit(scratch.allocator);
    try ids.ensureTotalCapacity(scratch.allocator, width);
    for (0..width) |_| {
        const id = try circuit.addNode(native_kind);
        ids.appendAssumeCapacity(id);
        try scratch.created.append(scratch.allocator, id);
    }

    if (interface_input) {
        var targets = std.ArrayListUnmanaged(Target).empty;
        defer targets.deinit(scratch.allocator);
        try targets.ensureTotalCapacity(scratch.allocator, width);
        for (ids.items, 0..) |id, bit| targets.appendAssumeCapacity(.{ .node = id, .pin = 0, .source_bit = @intCast(bit) });
        try appendPort(scratch, width, targets.items);
    } else {
        const input_count = Semantics.inputCount(kind, address_width, false);
        for (0..input_count) |pin| {
            const port = Semantics.inputPort(kind, width, address_width, split_width, false, @intCast(pin)) orelse return error.InvalidPort;
            var targets = std.ArrayListUnmanaged(Target).empty;
            defer targets.deinit(scratch.allocator);
            if (port.width == width) {
                try targets.ensureTotalCapacity(scratch.allocator, width);
                for (ids.items, 0..) |id, bit| targets.appendAssumeCapacity(.{
                    .node = id,
                    .pin = @intCast(pin),
                    .source_bit = @intCast(bit),
                });
            } else if (port.width == 1) {
                try targets.ensureTotalCapacity(scratch.allocator, width);
                for (ids.items) |id| targets.appendAssumeCapacity(.{
                    .node = id,
                    .pin = @intCast(pin),
                    .source_bit = 0,
                });
            } else return error.InvalidPort;
            try appendPort(scratch, port.width, targets.items);
        }
    }
    try appendOutput(scratch, ids.items);
}

test "DFF clock primitive fans one input bit across every lane" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();
    var scratch = Scratch.init(std.testing.allocator);
    defer scratch.deinit();
    try compile(&circuit, &scratch, .dff, 8, 1, 1, false, 100);
    try std.testing.expectEqual(@as(usize, 2), scratch.inputCount());
    try std.testing.expectEqual(@as(u8, 8), scratch.input_widths.items[0]);
    try std.testing.expectEqual(@as(u8, 1), scratch.input_widths.items[1]);
    try std.testing.expectEqual(@as(usize, 8), scratch.inputTargets(1).?.len);
    for (scratch.inputTargets(1).?) |target| {
        try std.testing.expectEqual(@as(u8, 1), target.pin);
        try std.testing.expectEqual(@as(u8, 0), target.source_bit);
    }
}

test "clock primitive exposes shared control targets and lane-local data" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();
    var scratch = Scratch.init(std.testing.allocator);
    defer scratch.deinit();
    try compile(&circuit, &scratch, .clock, 64, 1, 1, false, 64);
    try std.testing.expectEqual(@as(usize, 3), scratch.inputCount());
    try std.testing.expectEqual(@as(usize, 1), scratch.inputTargets(0).?.len);
    try std.testing.expectEqual(@as(usize, 1), scratch.inputTargets(1).?.len);
    try std.testing.expectEqual(@as(usize, 64), scratch.inputTargets(2).?.len);
    try std.testing.expectEqual(@as(u8, 63), scratch.inputTargets(2).?[63].source_bit);
    try std.testing.expectEqual(@as(usize, 64), scratch.outputBus(0).?.len);
}
