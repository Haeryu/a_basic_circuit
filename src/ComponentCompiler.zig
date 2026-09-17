const std = @import("std");
const Circuit = @import("Circuit.zig");
const Semantics = @import("Semantics.zig");

pub const Scratch = struct {
    allocator: std.mem.Allocator,
    input_offsets: std.ArrayListUnmanaged(u32) = .empty,
    input_nodes: std.ArrayListUnmanaged(Circuit.NodeId) = .empty,
    output_offsets: std.ArrayListUnmanaged(u32) = .empty,
    output_nodes: std.ArrayListUnmanaged(Circuit.NodeId) = .empty,
    created: std.ArrayListUnmanaged(Circuit.NodeId) = .empty,

    pub fn init(allocator: std.mem.Allocator) Scratch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Scratch) void {
        self.created.deinit(self.allocator);
        self.output_nodes.deinit(self.allocator);
        self.output_offsets.deinit(self.allocator);
        self.input_nodes.deinit(self.allocator);
        self.input_offsets.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clearRetainingCapacity(self: *Scratch) void {
        self.input_offsets.clearRetainingCapacity();
        self.input_nodes.clearRetainingCapacity();
        self.output_offsets.clearRetainingCapacity();
        self.output_nodes.clearRetainingCapacity();
        self.created.clearRetainingCapacity();
    }

    pub fn inputCount(self: *const Scratch) usize {
        return if (self.input_offsets.items.len == 0) 0 else self.input_offsets.items.len - 1;
    }

    pub fn outputCount(self: *const Scratch) usize {
        return if (self.output_offsets.items.len == 0) 0 else self.output_offsets.items.len - 1;
    }

    pub fn inputBus(self: *const Scratch, pin: usize) ?[]const Circuit.NodeId {
        if (pin >= self.inputCount()) return null;
        const begin: usize = @intCast(self.input_offsets.items[pin]);
        const end: usize = @intCast(self.input_offsets.items[pin + 1]);
        return self.input_nodes.items[begin..end];
    }

    pub fn outputBus(self: *const Scratch, pin: usize) ?[]const Circuit.NodeId {
        if (pin >= self.outputCount()) return null;
        const begin: usize = @intCast(self.output_offsets.items[pin]);
        const end: usize = @intCast(self.output_offsets.items[pin + 1]);
        return self.output_nodes.items[begin..end];
    }
};

fn Builder(comptime budgeted: bool) type {
    return struct {
        circuit: *Circuit,
        scratch: *Scratch,
        budget: usize,

        fn add(self: *@This(), kind: Circuit.Kind) !Circuit.NodeId {
            if (budgeted and self.scratch.created.items.len >= self.budget) return error.BudgetExceeded;
            const id = try self.circuit.addNode(kind);
            try self.scratch.created.append(self.scratch.allocator, id);
            return id;
        }

        fn gate(self: *@This(), kind: Circuit.Kind, a: Circuit.NodeId, b: ?Circuit.NodeId) !Circuit.NodeId {
            const id = try self.add(kind);
            try self.circuit.connect(a, id, 0);
            if (b) |rhs| try self.circuit.connect(rhs, id, 1);
            return id;
        }

        fn mux2(self: *@This(), select: Circuit.NodeId, inverse_select: Circuit.NodeId, low: Circuit.NodeId, high: Circuit.NodeId) !Circuit.NodeId {
            const lo = try self.gate(.nand2, low, inverse_select);
            const hi = try self.gate(.nand2, high, select);
            return self.gate(.nand2, lo, hi);
        }
    };
}

fn appendInputBus(builder: anytype, width: usize) !void {
    for (0..width) |_| try builder.scratch.input_nodes.append(builder.scratch.allocator, try builder.add(.buffer));
    try builder.scratch.input_offsets.append(builder.scratch.allocator, @intCast(builder.scratch.input_nodes.items.len));
}

fn appendOutputBus(scratch: *Scratch, bus: []const Circuit.NodeId) !void {
    try scratch.output_nodes.appendSlice(scratch.allocator, bus);
    try scratch.output_offsets.append(scratch.allocator, @intCast(scratch.output_nodes.items.len));
}

pub fn scalarCount(kind: Semantics.Kind, width: u8, address_width: u8) ?usize {
    const w: usize = width;
    const a: usize = address_width;
    const lanes: usize = @as(usize, 1) << @intCast(address_width);
    return switch (kind) {
        .split, .join => w,
        .adder => 7 * w + 1,
        .register => 5 * w + 3,
        .alu => 17 * w + 7,
        .ram => (a + w + 2) + a + lanes * (a - 1) + 2 * lanes + 4 * w * lanes + 3 * w * (lanes - 1),
        .mux => a + lanes * w + a + 3 * w * (lanes - 1),
        .decoder => 2 * a + lanes * (a - 1),
        .demux => w + 2 * a + lanes * (a - 1 + w),
        else => null,
    };
}

pub fn compile(circuit: *Circuit, scratch: *Scratch, kind: Semantics.Kind, width: u8, address_width: u8, split_width: u8, budget: usize) !void {
    scratch.clearRetainingCapacity();
    switch (kind) {
        .adder, .register, .alu, .ram, .mux, .demux, .decoder, .split, .join => {},
        else => return error.InvalidKind,
    }
    if ((scalarCount(kind, width, address_width) orelse return error.InvalidKind) > budget) return error.BudgetExceeded;

    var builder = Builder(true){ .circuit = circuit, .scratch = scratch, .budget = budget };
    try scratch.input_offsets.append(scratch.allocator, 0);
    const input_count = Semantics.inputCount(kind, address_width, false);
    for (0..input_count) |pin| {
        const port = Semantics.inputPort(kind, width, address_width, split_width, false, @intCast(pin)) orelse return error.InvalidPort;
        try appendInputBus(&builder, port.width);
    }
    try scratch.output_offsets.append(scratch.allocator, 0);

    if (kind == .register) {
        const data = scratch.inputBus(0).?;
        const load = scratch.inputBus(1).?[0];
        const clock = scratch.inputBus(2).?[0];
        const inverse_load = try builder.gate(.not, load, null);
        var outputs = std.ArrayListUnmanaged(Circuit.NodeId).empty;
        defer outputs.deinit(scratch.allocator);
        try outputs.ensureTotalCapacity(scratch.allocator, width);
        for (0..width) |bit| {
            const q = try builder.add(.dff);
            const next = try builder.mux2(load, inverse_load, q, data[bit]);
            try circuit.connect(next, q, 0);
            try circuit.connect(clock, q, 1);
            outputs.appendAssumeCapacity(q);
        }
        try appendOutputBus(scratch, outputs.items);
        return;
    }

    if (kind == .alu) {
        const a_bus = scratch.inputBus(0).?;
        const b_bus = scratch.inputBus(1).?;
        const op = scratch.inputBus(2).?;
        const zero = try builder.add(.buffer);
        var carry = zero;
        var add_bus = std.ArrayListUnmanaged(Circuit.NodeId).empty;
        var and_bus = std.ArrayListUnmanaged(Circuit.NodeId).empty;
        var or_bus = std.ArrayListUnmanaged(Circuit.NodeId).empty;
        var xor_bus = std.ArrayListUnmanaged(Circuit.NodeId).empty;
        defer add_bus.deinit(scratch.allocator);
        defer and_bus.deinit(scratch.allocator);
        defer or_bus.deinit(scratch.allocator);
        defer xor_bus.deinit(scratch.allocator);
        try add_bus.ensureTotalCapacity(scratch.allocator, width);
        try and_bus.ensureTotalCapacity(scratch.allocator, width);
        try or_bus.ensureTotalCapacity(scratch.allocator, width);
        try xor_bus.ensureTotalCapacity(scratch.allocator, width);
        for (0..width) |bit| {
            const xor_ab = try builder.gate(.xor2, a_bus[bit], b_bus[bit]);
            xor_bus.appendAssumeCapacity(xor_ab);
            add_bus.appendAssumeCapacity(try builder.gate(.xor2, xor_ab, carry));
            const ab = try builder.gate(.and2, a_bus[bit], b_bus[bit]);
            and_bus.appendAssumeCapacity(ab);
            const xc = try builder.gate(.and2, xor_ab, carry);
            carry = try builder.gate(.or2, ab, xc);
            or_bus.appendAssumeCapacity(try builder.gate(.or2, a_bus[bit], b_bus[bit]));
        }
        const inverse0 = try builder.gate(.not, op[0], null);
        const inverse1 = try builder.gate(.not, op[1], null);
        var result = std.ArrayListUnmanaged(Circuit.NodeId).empty;
        defer result.deinit(scratch.allocator);
        try result.ensureTotalCapacity(scratch.allocator, width);
        for (0..width) |bit| {
            const low = try builder.mux2(op[0], inverse0, add_bus.items[bit], and_bus.items[bit]);
            const high = try builder.mux2(op[0], inverse0, or_bus.items[bit], xor_bus.items[bit]);
            result.appendAssumeCapacity(try builder.mux2(op[1], inverse1, low, high));
        }
        const add_selected_low = try builder.gate(.and2, carry, inverse0);
        const add_selected = try builder.gate(.and2, add_selected_low, inverse1);
        try appendOutputBus(scratch, result.items);
        try appendOutputBus(scratch, &.{add_selected});
        return;
    }

    if (kind == .ram) {
        const address = scratch.inputBus(0).?;
        const data = scratch.inputBus(1).?;
        const write_enable = scratch.inputBus(2).?[0];
        const clock = scratch.inputBus(3).?[0];
        var inverse_address = std.ArrayListUnmanaged(Circuit.NodeId).empty;
        defer inverse_address.deinit(scratch.allocator);
        try inverse_address.ensureTotalCapacity(scratch.allocator, address_width);
        for (address) |bit| inverse_address.appendAssumeCapacity(try builder.gate(.not, bit, null));

        const lane_count: usize = @as(usize, 1) << @intCast(address_width);
        var decoded = std.ArrayListUnmanaged(Circuit.NodeId).empty;
        defer decoded.deinit(scratch.allocator);
        try decoded.ensureTotalCapacity(scratch.allocator, lane_count);
        for (0..lane_count) |lane| {
            var selected = if ((lane & 1) != 0) address[0] else inverse_address.items[0];
            for (1..address_width) |bit| {
                const mask: usize = @as(usize, 1) << @intCast(bit);
                selected = try builder.gate(.and2, selected, if ((lane & mask) != 0) address[bit] else inverse_address.items[bit]);
            }
            decoded.appendAssumeCapacity(selected);
        }

        var words = std.ArrayListUnmanaged(Circuit.NodeId).empty;
        defer words.deinit(scratch.allocator);
        try words.ensureTotalCapacity(scratch.allocator, lane_count * width);
        for (decoded.items) |select| {
            const load = try builder.gate(.and2, select, write_enable);
            const inverse_load = try builder.gate(.not, load, null);
            for (0..width) |bit| {
                const q = try builder.add(.dff);
                const next = try builder.mux2(load, inverse_load, q, data[bit]);
                try circuit.connect(next, q, 0);
                try circuit.connect(clock, q, 1);
                words.appendAssumeCapacity(q);
            }
        }

        var level = std.ArrayListUnmanaged(Circuit.NodeId).empty;
        defer level.deinit(scratch.allocator);
        try level.appendSlice(scratch.allocator, words.items);
        var lanes = lane_count;
        for (0..address_width) |select_bit| {
            const select = address[select_bit];
            const inverse_select = inverse_address.items[select_bit];
            var next = std.ArrayListUnmanaged(Circuit.NodeId).empty;
            errdefer next.deinit(scratch.allocator);
            try next.ensureTotalCapacity(scratch.allocator, (lanes / 2) * width);
            var lane: usize = 0;
            while (lane < lanes) : (lane += 2) {
                for (0..width) |bit| next.appendAssumeCapacity(try builder.mux2(
                    select,
                    inverse_select,
                    level.items[lane * width + bit],
                    level.items[(lane + 1) * width + bit],
                ));
            }
            level.deinit(scratch.allocator);
            level = next;
            lanes /= 2;
        }
        try appendOutputBus(scratch, level.items[0..width]);
        return;
    }

    if (kind == .split) {
        const input = scratch.inputBus(0).?;
        try appendOutputBus(scratch, input[0..split_width]);
        try appendOutputBus(scratch, input[split_width..]);
        return;
    }
    if (kind == .join) {
        try appendOutputBus(scratch, scratch.inputBus(0).?);
        const first_end = scratch.output_nodes.items.len;
        try scratch.output_nodes.appendSlice(scratch.allocator, scratch.inputBus(1).?);
        scratch.output_offsets.items[scratch.output_offsets.items.len - 1] = @intCast(scratch.output_nodes.items.len);
        _ = first_end;
        return;
    }
    if (kind == .adder) {
        const a_bus = scratch.inputBus(0).?;
        const b_bus = scratch.inputBus(1).?;
        var carry = scratch.inputBus(2).?[0];
        var sum = std.ArrayListUnmanaged(Circuit.NodeId).empty;
        defer sum.deinit(scratch.allocator);
        try sum.ensureTotalCapacity(scratch.allocator, width);
        for (0..width) |bit| {
            const xor = try builder.gate(.xor2, a_bus[bit], b_bus[bit]);
            sum.appendAssumeCapacity(try builder.gate(.xor2, xor, carry));
            const ab = try builder.gate(.and2, a_bus[bit], b_bus[bit]);
            const xc = try builder.gate(.and2, xor, carry);
            carry = try builder.gate(.or2, ab, xc);
        }
        try appendOutputBus(scratch, sum.items);
        try appendOutputBus(scratch, &.{carry});
        return;
    }
    if (kind == .mux) {
        const selector = scratch.inputBus(0).?;
        var level = std.ArrayListUnmanaged(Circuit.NodeId).empty;
        defer level.deinit(scratch.allocator);
        for (1..input_count) |pin| try level.appendSlice(scratch.allocator, scratch.inputBus(pin).?);
        var lanes: usize = input_count - 1;
        for (0..address_width) |select| {
            const s = selector[select];
            const inverse = try builder.gate(.not, s, null);
            var next = std.ArrayListUnmanaged(Circuit.NodeId).empty;
            errdefer next.deinit(scratch.allocator);
            try next.ensureTotalCapacity(scratch.allocator, (lanes / 2) * width);
            var lane: usize = 0;
            while (lane < lanes) : (lane += 2) {
                for (0..width) |bit| {
                    const lo = try builder.gate(.nand2, level.items[lane * width + bit], inverse);
                    const hi = try builder.gate(.nand2, level.items[(lane + 1) * width + bit], s);
                    next.appendAssumeCapacity(try builder.gate(.nand2, lo, hi));
                }
            }
            level.deinit(scratch.allocator);
            level = next;
            lanes /= 2;
        }
        try appendOutputBus(scratch, level.items[0..width]);
        return;
    }

    const address = scratch.inputBus(if (kind == .demux) 1 else 0).?;
    var inverse = std.ArrayListUnmanaged(Circuit.NodeId).empty;
    defer inverse.deinit(scratch.allocator);
    try inverse.ensureTotalCapacity(scratch.allocator, address_width);
    for (address) |bit| inverse.appendAssumeCapacity(try builder.gate(.not, bit, null));

    var decoded = std.ArrayListUnmanaged(Circuit.NodeId).empty;
    defer decoded.deinit(scratch.allocator);
    const lane_count: usize = @as(usize, 1) << @intCast(address_width);
    try decoded.ensureTotalCapacity(scratch.allocator, lane_count);
    for (0..lane_count) |lane| {
        var result = if ((lane & 1) != 0) address[0] else inverse.items[0];
        for (1..address_width) |bit| {
            const bit_mask: usize = @as(usize, 1) << @intCast(bit);
            result = try builder.gate(.and2, result, if ((lane & bit_mask) != 0) address[bit] else inverse.items[bit]);
        }
        decoded.appendAssumeCapacity(result);
    }
    if (kind == .decoder) {
        try appendOutputBus(scratch, decoded.items);
        return;
    }
    const data = scratch.inputBus(0).?;
    for (decoded.items) |enable| {
        var lane = std.ArrayListUnmanaged(Circuit.NodeId).empty;
        defer lane.deinit(scratch.allocator);
        try lane.ensureTotalCapacity(scratch.allocator, width);
        for (data) |bit| lane.appendAssumeCapacity(try builder.gate(.and2, bit, enable));
        try appendOutputBus(scratch, lane.items);
    }
}

test "compile 4-bit selector mux keeps eight-bit output" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();
    var scratch = Scratch.init(std.testing.allocator);
    defer scratch.deinit();
    try compile(&circuit, &scratch, .mux, 8, 4, 1, 250_000);
    try std.testing.expectEqual(@as(usize, 17), scratch.inputCount());
    try std.testing.expectEqual(@as(usize, 1), scratch.outputCount());
    try std.testing.expectEqual(@as(usize, 4), scratch.inputBus(0).?.len);
    try std.testing.expectEqual(@as(usize, 8), scratch.inputBus(16).?.len);
    try std.testing.expectEqual(@as(usize, 8), scratch.outputBus(0).?.len);
}

test "register alu and ram lowering matches planned scalar counts" {
    const cases = [_]struct { kind: Semantics.Kind, width: u8, address: u8, inputs: usize, outputs: usize }{
        .{ .kind = .register, .width = 8, .address = 1, .inputs = 3, .outputs = 1 },
        .{ .kind = .alu, .width = 8, .address = 1, .inputs = 3, .outputs = 2 },
        .{ .kind = .ram, .width = 8, .address = 3, .inputs = 4, .outputs = 1 },
    };
    for (cases) |case| {
        var circuit = Circuit.init(std.testing.allocator);
        defer circuit.deinit();
        var scratch = Scratch.init(std.testing.allocator);
        defer scratch.deinit();
        const expected = scalarCount(case.kind, case.width, case.address).?;
        try compile(&circuit, &scratch, case.kind, case.width, case.address, 1, expected);
        try std.testing.expectEqual(expected, scratch.created.items.len);
        try std.testing.expectEqual(case.inputs, scratch.inputCount());
        try std.testing.expectEqual(case.outputs, scratch.outputCount());
    }
}
