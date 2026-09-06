const CompiledCircuit = @This();

const std = @import("std");

pub const BusIndex = enum(u32) {
    _,
};
pub const ChipIndex = enum(u32) {
    _,
};

pub const Op = enum(u8) {
    and2,
    or2,
    xor2,
    not1,
    dff,

    pub fn inputCount(self: Op) usize {
        return switch (self) {
            .and2, .or2, .xor2, .dff => 2,
            .not1 => 1,
        };
    }
};

const RunFn = *const fn (circuit: *CompiledCircuit, chip: ChipIndex) void;

const pfnRuns = [_]RunFn{
    &runAnd2,
    &runOr2,
    &runXor2,
    &runNot1,
    &runDff,
};

pub const ChipSpec = struct {
    op: Op,
    inputs: []const BusIndex,
    output: BusIndex,
};

pub const Topology = struct {
    ops: []Op,

    input_starts: []u32,
    inputs: []BusIndex,
    outputs: []BusIndex,

    consumer_offsets: []u32,
    consumers: []ChipIndex,

    pub fn init(
        allocator: std.mem.Allocator,
        bus_count: usize,
        chips: []const ChipSpec,
    ) !Topology {
        if (bus_count > std.math.maxInt(u32)) {
            return error.TopologyTooLarge;
        }

        if (chips.len > std.math.maxInt(u32)) {
            return error.TopologyTooLarge;
        }

        var input_count: usize = 0;

        for (chips) |chip| {
            if (chip.inputs.len != chip.op.inputCount()) {
                return error.InvalidArity;
            }

            if (@as(usize, @intCast(@intFromEnum(chip.output))) >= bus_count) {
                return error.InvalidBus;
            }

            for (chip.inputs) |bus_index| {
                if (@as(usize, @intCast(@intFromEnum(bus_index))) >= bus_count) {
                    return error.InvalidBus;
                }
            }

            input_count = std.math.add(usize, input_count, chip.inputs.len) catch {
                return error.TopologyTooLarge;
            };
        }

        if (input_count > std.math.maxInt(u32)) {
            return error.TopologyTooLarge;
        }

        var driven: std.bit_set.DynamicBitSetUnmanaged = try .initEmpty(allocator, bus_count);
        defer driven.deinit(allocator);

        for (chips) |chip| {
            const output: usize = @intCast(@intFromEnum(chip.output));

            if (driven.isSet(output)) {
                return error.MultipleDrivers;
            }

            driven.set(output);
        }

        const ops = try allocator.alloc(Op, chips.len);
        errdefer allocator.free(ops);

        const input_starts = try allocator.alloc(u32, chips.len);
        errdefer allocator.free(input_starts);

        const inputs = try allocator.alloc(BusIndex, input_count);
        errdefer allocator.free(inputs);

        const outputs = try allocator.alloc(BusIndex, chips.len);
        errdefer allocator.free(outputs);

        const consumer_offsets = try allocator.alloc(u32, bus_count + 1);
        errdefer allocator.free(consumer_offsets);

        const consumers = try allocator.alloc(ChipIndex, input_count);
        errdefer allocator.free(consumers);

        @memset(consumer_offsets, 0);

        var input_cursor: usize = 0;
        for (chips, 0..) |chip, chip_index| {
            ops[chip_index] = chip.op;

            input_starts[chip_index] = @intCast(input_cursor);

            outputs[chip_index] = chip.output;

            for (chip.inputs) |bus_index| {
                inputs[input_cursor] = bus_index;

                input_cursor += 1;
                const bus: usize = @intCast(@intFromEnum(bus_index));

                consumer_offsets[bus + 1] += 1;
            }
        }

        // counts -> CSR offsets
        for (0..bus_count) |bus| {
            consumer_offsets[bus + 1] += consumer_offsets[bus];
        }

        const write_offsets = try allocator.dupe(u32, consumer_offsets[0..bus_count]);
        defer allocator.free(write_offsets);

        for (chips, 0..) |chip, chip_index| {
            for (chip.inputs) |bus_index| {
                const bus: usize = @intCast(@intFromEnum(bus_index));
                const position: usize = @intCast(write_offsets[bus]);

                consumers[position] = @enumFromInt(chip_index);

                write_offsets[bus] += 1;
            }
        }

        return .{
            .ops = ops,

            .input_starts = input_starts,
            .inputs = inputs,
            .outputs = outputs,

            .consumer_offsets = consumer_offsets,
            .consumers = consumers,
        };
    }

    pub fn deinit(self: *Topology, allocator: std.mem.Allocator) void {
        allocator.free(self.consumers);
        allocator.free(self.consumer_offsets);

        allocator.free(self.outputs);
        allocator.free(self.inputs);
        allocator.free(self.input_starts);

        allocator.free(self.ops);

        self.* = undefined;
    }
};

allocator: std.mem.Allocator,

ops: []Op,

input_starts: []u32,
inputs: []BusIndex,
outputs: []BusIndex,

consumer_offsets: []u32,
consumers: []ChipIndex,

values: std.bit_set.DynamicBitSetUnmanaged,
next_values: std.bit_set.DynamicBitSetUnmanaged,
pending: std.bit_set.DynamicBitSetUnmanaged,

dirty: std.bit_set.DynamicBitSetUnmanaged,

current_dirty: []ChipIndex,
next_dirty: []ChipIndex,

current_dirty_count: usize,
next_dirty_count: usize,

dff_prev_clock: std.bit_set.DynamicBitSetUnmanaged,
dff_initialized: std.bit_set.DynamicBitSetUnmanaged,

pub fn init(allocator: std.mem.Allocator, topology: *Topology) !CompiledCircuit {
    const bus_count = topology.consumer_offsets.len - 1;
    const chip_count = topology.ops.len;

    var values: std.bit_set.DynamicBitSetUnmanaged = try .initEmpty(allocator, bus_count);
    errdefer values.deinit(allocator);

    var next_values: std.bit_set.DynamicBitSetUnmanaged = try .initEmpty(allocator, bus_count);
    errdefer next_values.deinit(allocator);

    var pending: std.bit_set.DynamicBitSetUnmanaged = try .initEmpty(allocator, bus_count);
    errdefer pending.deinit(allocator);

    var dirty: std.bit_set.DynamicBitSetUnmanaged = try .initFull(allocator, chip_count);
    errdefer dirty.deinit(allocator);

    const current_dirty = try allocator.alloc(ChipIndex, chip_count);
    errdefer allocator.free(current_dirty);

    const next_dirty = try allocator.alloc(ChipIndex, chip_count);
    errdefer allocator.free(next_dirty);

    for (current_dirty, 0..) |*slot, i| {
        slot.* = @enumFromInt(i);
    }

    var dff_prev_clock: std.bit_set.DynamicBitSetUnmanaged =
        try .initEmpty(allocator, chip_count);
    errdefer dff_prev_clock.deinit(allocator);

    var dff_initialized: std.bit_set.DynamicBitSetUnmanaged =
        try .initEmpty(allocator, chip_count);
    errdefer dff_initialized.deinit(allocator);

    defer topology.* = undefined;

    return .{
        .allocator = allocator,

        .ops = topology.ops,

        .input_starts = topology.input_starts,
        .inputs = topology.inputs,
        .outputs = topology.outputs,

        .consumer_offsets = topology.consumer_offsets,
        .consumers = topology.consumers,

        .values = values,
        .next_values = next_values,
        .pending = pending,
        .dirty = dirty,

        .current_dirty = current_dirty,
        .next_dirty = next_dirty,

        .current_dirty_count = chip_count,
        .next_dirty_count = 0,

        .dff_prev_clock = dff_prev_clock,
        .dff_initialized = dff_initialized,
    };
}

pub fn deinit(self: *CompiledCircuit) void {
    const allocator = self.allocator;

    self.dff_initialized.deinit(allocator);
    self.dff_prev_clock.deinit(allocator);

    allocator.free(self.next_dirty);
    allocator.free(self.current_dirty);

    self.dirty.deinit(allocator);

    self.pending.deinit(allocator);
    self.next_values.deinit(allocator);
    self.values.deinit(allocator);

    allocator.free(self.consumers);
    allocator.free(self.consumer_offsets);

    allocator.free(self.outputs);
    allocator.free(self.inputs);
    allocator.free(self.input_starts);

    allocator.free(self.ops);

    self.* = undefined;
}

pub fn store(self: *CompiledCircuit, bus_index: BusIndex, value: bool) !void {
    const bus: usize = @intCast(@intFromEnum(bus_index));

    if (bus >= self.values.bit_length) {
        return error.InvalidBus;
    }

    if (self.values.isSet(bus) == value) {
        return;
    }

    self.values.setValue(bus, value);

    const consumer_start: usize = @intCast(self.consumer_offsets[bus]);
    const consumer_end: usize = @intCast(self.consumer_offsets[bus + 1]);

    for (self.consumers[consumer_start..consumer_end]) |chip_index| {
        const chip: usize = @intCast(@intFromEnum(chip_index));

        if (self.dirty.isSet(chip)) {
            continue;
        }

        std.debug.assert(self.current_dirty_count < self.current_dirty.len);

        self.current_dirty[self.current_dirty_count] = chip_index;
        self.current_dirty_count += 1;

        self.dirty.set(chip);
    }
}

pub fn load(self: *const CompiledCircuit, bus_index: BusIndex) !bool {
    const bus: usize = @intCast(@intFromEnum(bus_index));

    if (bus >= self.values.bit_length) {
        return error.InvalidBus;
    }

    return self.values.isSet(bus);
}

pub fn settle(self: *CompiledCircuit, max_rounds: usize) !void {
    var rounds: usize = 0;
    while (self.current_dirty_count != 0) {
        if (rounds == max_rounds) {
            return error.UnstableCircuit;
        }

        rounds += 1;

        const work_count = self.current_dirty_count;
        for (self.current_dirty[0..work_count]) |chip_index| {
            const chip: usize = @intCast(@intFromEnum(chip_index));
            self.dirty.unset(chip);

            const op = self.ops[chip];
            pfnRuns[@intFromEnum(op)](self, chip_index);
        }

        for (self.current_dirty[0..work_count]) |chip_index| {
            const chip: usize = @intCast(@intFromEnum(chip_index));
            const bus_index = self.outputs[chip];
            const bus: usize = @intCast(@intFromEnum(bus_index));

            if (!self.pending.isSet(bus)) {
                continue;
            }

            self.pending.unset(bus);

            const old = self.values.isSet(bus);
            const new = self.next_values.isSet(bus);

            if (old == new) {
                continue;
            }

            self.values.setValue(bus, new);

            const consumer_start: usize = @intCast(self.consumer_offsets[bus]);

            const consumer_end: usize = @intCast(self.consumer_offsets[bus + 1]);

            for (self.consumers[consumer_start..consumer_end]) |consumer| {
                const consumer_chip: usize = @intCast(@intFromEnum(consumer));

                if (self.dirty.isSet(consumer_chip)) {
                    continue;
                }

                std.debug.assert(self.next_dirty_count < self.next_dirty.len);

                self.next_dirty[self.next_dirty_count] = consumer;
                self.next_dirty_count += 1;
                self.dirty.set(consumer_chip);
            }
        }

        const tmp = self.current_dirty;
        self.current_dirty = self.next_dirty;
        self.next_dirty = tmp;

        self.current_dirty_count = self.next_dirty_count;

        self.next_dirty_count = 0;
    }
}

fn runAnd2(self: *CompiledCircuit, chip_index: ChipIndex) void {
    const chip: usize = @intCast(@intFromEnum(chip_index));

    const input_start: usize = @intCast(self.input_starts[chip]);

    const a: usize = @intCast(@intFromEnum(self.inputs[input_start]));
    const b: usize = @intCast(@intFromEnum(self.inputs[input_start + 1]));
    const out: usize = @intCast(@intFromEnum(self.outputs[chip]));

    self.next_values.setValue(out, self.values.isSet(a) and self.values.isSet(b));

    self.pending.set(out);
}

fn runOr2(self: *CompiledCircuit, chip_index: ChipIndex) void {
    const chip: usize = @intCast(@intFromEnum(chip_index));

    const input_start: usize = @intCast(self.input_starts[chip]);

    const a: usize = @intCast(@intFromEnum(self.inputs[input_start]));
    const b: usize = @intCast(@intFromEnum(self.inputs[input_start + 1]));
    const out: usize = @intCast(@intFromEnum(self.outputs[chip]));

    self.next_values.setValue(out, self.values.isSet(a) or self.values.isSet(b));

    self.pending.set(out);
}

fn runXor2(self: *CompiledCircuit, chip_index: ChipIndex) void {
    const chip: usize = @intCast(@intFromEnum(chip_index));

    const input_start: usize = @intCast(self.input_starts[chip]);

    const a: usize = @intCast(@intFromEnum(self.inputs[input_start]));
    const b: usize = @intCast(@intFromEnum(self.inputs[input_start + 1]));
    const out: usize = @intCast(@intFromEnum(self.outputs[chip]));

    self.next_values.setValue(out, self.values.isSet(a) != self.values.isSet(b));

    self.pending.set(out);
}

fn runNot1(self: *CompiledCircuit, chip_index: ChipIndex) void {
    const chip: usize = @intCast(@intFromEnum(chip_index));

    const input_start: usize = @intCast(self.input_starts[chip]);

    const input: usize = @intCast(@intFromEnum(self.inputs[input_start]));
    const out: usize = @intCast(@intFromEnum(self.outputs[chip]));

    self.next_values.setValue(out, !self.values.isSet(input));

    self.pending.set(out);
}

fn runDff(self: *CompiledCircuit, chip_index: ChipIndex) void {
    const chip: usize = @intCast(@intFromEnum(chip_index));
    const input_start: usize = @intCast(self.input_starts[chip]);

    const d: usize = @intCast(@intFromEnum(self.inputs[input_start]));
    const clk: usize = @intCast(@intFromEnum(self.inputs[input_start + 1]));
    const out: usize = @intCast(@intFromEnum(self.outputs[chip]));
    const clock = self.values.isSet(clk);

    if (!self.dff_initialized.isSet(chip)) {
        self.dff_initialized.set(chip);
        self.dff_prev_clock.setValue(chip, clock);
        return;
    }

    const prev_clock = self.dff_prev_clock.isSet(chip);
    self.dff_prev_clock.setValue(chip, clock);

    if (prev_clock or !clock) {
        return;
    }

    self.next_values.setValue(out, self.values.isSet(d));

    self.pending.set(out);
}

test "compiled and" {
    // A ----\
    //        AND ---- OUT
    // B ----/
    //
    // buses:
    //
    //   0 = A
    //   1 = B
    //   2 = OUT
    //
    // chips:
    //
    //   0 = AND

    var topology = try Topology.init(
        std.testing.allocator,
        3,
        &.{
            .{
                .op = .and2,
                .inputs = &.{
                    @enumFromInt(0),
                    @enumFromInt(1),
                },
                .output = @enumFromInt(2),
            },
        },
    );
    errdefer topology.deinit(
        std.testing.allocator,
    );

    var circuit = try CompiledCircuit.init(
        std.testing.allocator,
        &topology,
    );
    defer circuit.deinit();

    const Case = struct {
        a: bool,
        b: bool,
        out: bool,
    };

    const cases = [_]Case{
        .{
            .a = false,
            .b = false,
            .out = false,
        },
        .{
            .a = false,
            .b = true,
            .out = false,
        },
        .{
            .a = true,
            .b = false,
            .out = false,
        },
        .{
            .a = true,
            .b = true,
            .out = true,
        },
    };

    for (cases) |case| {
        try circuit.store(
            @enumFromInt(0),
            case.a,
        );

        try circuit.store(
            @enumFromInt(1),
            case.b,
        );

        try circuit.settle(8);

        try std.testing.expectEqual(
            case.out,
            try circuit.load(
                @enumFromInt(2),
            ),
        );
    }
}

test "propagates across delta rounds" {
    var topology = try Topology.init(
        std.testing.allocator,
        5,
        &.{
            .{
                .op = .and2,
                .inputs = &.{
                    @enumFromInt(0), // A
                    @enumFromInt(1), // B
                },
                .output = @enumFromInt(3), // MID
            },
            .{
                .op = .and2,
                .inputs = &.{
                    @enumFromInt(3), // MID
                    @enumFromInt(2), // C
                },
                .output = @enumFromInt(4), // OUT
            },
        },
    );
    errdefer topology.deinit(std.testing.allocator);

    var circuit = try CompiledCircuit.init(
        std.testing.allocator,
        &topology,
    );
    defer circuit.deinit();

    try circuit.store(@enumFromInt(0), true);
    try circuit.store(@enumFromInt(1), true);
    try circuit.store(@enumFromInt(2), true);

    try std.testing.expectError(
        error.UnstableCircuit,
        circuit.settle(1),
    );

    // Round 1:
    // AND0 sees A=B=1 -> stages MID=1
    // AND1 still sees old MID=0.
    try std.testing.expectEqual(
        false,
        try circuit.load(@enumFromInt(4)),
    );

    // Pending work must have survived the round limit.
    try circuit.settle(1);

    try std.testing.expectEqual(
        true,
        try circuit.load(@enumFromInt(3)),
    );

    try std.testing.expectEqual(
        true,
        try circuit.load(@enumFromInt(4)),
    );
}

test "fanout wakes all consumers" {
    var topology = try Topology.init(
        std.testing.allocator,
        7,
        &.{
            .{
                .op = .and2,
                .inputs = &.{
                    @enumFromInt(0), // A
                    @enumFromInt(1), // B
                },
                .output = @enumFromInt(4), // MID
            },
            .{
                .op = .and2,
                .inputs = &.{
                    @enumFromInt(4), // MID
                    @enumFromInt(2), // C
                },
                .output = @enumFromInt(5), // OUT0
            },
            .{
                .op = .and2,
                .inputs = &.{
                    @enumFromInt(4), // MID
                    @enumFromInt(3), // D
                },
                .output = @enumFromInt(6), // OUT1
            },
        },
    );
    errdefer topology.deinit(std.testing.allocator);

    var circuit = try CompiledCircuit.init(
        std.testing.allocator,
        &topology,
    );
    defer circuit.deinit();

    try circuit.store(@enumFromInt(0), true);
    try circuit.store(@enumFromInt(1), true);
    try circuit.store(@enumFromInt(2), true);
    try circuit.store(@enumFromInt(3), true);

    try circuit.settle(8);

    try std.testing.expectEqual(
        true,
        try circuit.load(@enumFromInt(4)),
    );

    try std.testing.expectEqual(
        true,
        try circuit.load(@enumFromInt(5)),
    );

    try std.testing.expectEqual(
        true,
        try circuit.load(@enumFromInt(6)),
    );
}

test "combinational oscillator does not settle" {
    var topology = try Topology.init(
        std.testing.allocator,
        1,
        &.{
            .{
                .op = .not1,
                .inputs = &.{
                    @enumFromInt(0),
                },
                .output = @enumFromInt(0),
            },
        },
    );
    errdefer topology.deinit(std.testing.allocator);

    var circuit = try CompiledCircuit.init(
        std.testing.allocator,
        &topology,
    );
    defer circuit.deinit();

    try std.testing.expectError(
        error.UnstableCircuit,
        circuit.settle(16),
    );
}

test "dff samples only on rising edge" {
    // bus 0 = D
    // bus 1 = CLK
    // bus 2 = Q

    var topology = try Topology.init(
        std.testing.allocator,
        3,
        &.{
            .{
                .op = .dff,
                .inputs = &.{
                    @enumFromInt(0),
                    @enumFromInt(1),
                },
                .output = @enumFromInt(2),
            },
        },
    );
    errdefer topology.deinit(
        std.testing.allocator,
    );

    var circuit = try CompiledCircuit.init(
        std.testing.allocator,
        &topology,
    );
    defer circuit.deinit();

    // Initial evaluation establishes CLK=0.
    try circuit.settle(8);

    // D = 1, but clock remains low.
    try circuit.store(
        @enumFromInt(0),
        true,
    );
    try circuit.settle(8);

    try std.testing.expectEqual(
        false,
        try circuit.load(@enumFromInt(2)),
    );

    // Rising edge.
    try circuit.store(
        @enumFromInt(1),
        true,
    );
    try circuit.settle(8);

    try std.testing.expectEqual(
        true,
        try circuit.load(@enumFromInt(2)),
    );

    // Change D while CLK is still high.
    try circuit.store(
        @enumFromInt(0),
        false,
    );
    try circuit.settle(8);

    try std.testing.expectEqual(
        true,
        try circuit.load(@enumFromInt(2)),
    );

    // Falling edge.
    try circuit.store(
        @enumFromInt(1),
        false,
    );
    try circuit.settle(8);

    try std.testing.expectEqual(
        true,
        try circuit.load(@enumFromInt(2)),
    );

    // Next rising edge samples D=0.
    try circuit.store(
        @enumFromInt(1),
        true,
    );
    try circuit.settle(8);

    try std.testing.expectEqual(
        false,
        try circuit.load(@enumFromInt(2)),
    );
}

test "dffs sample old state on same rising edge" {
    var topology = try Topology.init(
        std.testing.allocator,
        4,
        &.{
            .{
                .op = .dff,
                .inputs = &.{
                    @enumFromInt(0), // D
                    @enumFromInt(1), // CLK
                },
                .output = @enumFromInt(2), // Q0
            },
            .{
                .op = .dff,
                .inputs = &.{
                    @enumFromInt(2), // Q0
                    @enumFromInt(1), // CLK
                },
                .output = @enumFromInt(3), // Q1
            },
        },
    );
    errdefer topology.deinit(std.testing.allocator);

    var circuit = try CompiledCircuit.init(
        std.testing.allocator,
        &topology,
    );
    defer circuit.deinit();

    // Establish CLK=0 for both DFFs.
    try circuit.settle(8);

    // D = 1
    try circuit.store(@enumFromInt(0), true);
    try circuit.settle(8);

    // First rising edge.
    try circuit.store(@enumFromInt(1), true);
    try circuit.settle(8);

    // Both DFFs sampled from the same old snapshot:
    //
    // DFF0 saw D=1  -> Q0=1
    // DFF1 saw Q0=0 -> Q1=0
    try std.testing.expectEqual(
        true,
        try circuit.load(@enumFromInt(2)),
    );

    try std.testing.expectEqual(
        false,
        try circuit.load(@enumFromInt(3)),
    );

    // Falling edge.
    try circuit.store(@enumFromInt(1), false);
    try circuit.settle(8);

    // Second rising edge.
    try circuit.store(@enumFromInt(1), true);
    try circuit.settle(8);

    // Now DFF1 samples the previously committed Q0=1.
    try std.testing.expectEqual(
        true,
        try circuit.load(@enumFromInt(2)),
    );

    try std.testing.expectEqual(
        true,
        try circuit.load(@enumFromInt(3)),
    );
}

test "sequential feedback toggles on rising edge" {
    var topology = try Topology.init(
        std.testing.allocator,
        3,
        &.{
            .{
                .op = .not1,
                .inputs = &.{
                    @enumFromInt(0), // Q
                },
                .output = @enumFromInt(1), // D
            },
            .{
                .op = .dff,
                .inputs = &.{
                    @enumFromInt(1), // D
                    @enumFromInt(2), // CLK
                },
                .output = @enumFromInt(0), // Q
            },
        },
    );
    errdefer topology.deinit(std.testing.allocator);

    var circuit = try CompiledCircuit.init(
        std.testing.allocator,
        &topology,
    );
    defer circuit.deinit();

    // Initial:
    //
    // Q=0
    // NOT(Q) -> D=1
    // DFF establishes CLK=0
    try circuit.settle(8);

    try std.testing.expectEqual(
        false,
        try circuit.load(@enumFromInt(0)),
    );

    try std.testing.expectEqual(
        true,
        try circuit.load(@enumFromInt(1)),
    );

    // First rising edge:
    // D=1 -> Q=1
    try circuit.store(@enumFromInt(2), true);
    try circuit.settle(8);

    try std.testing.expectEqual(
        true,
        try circuit.load(@enumFromInt(0)),
    );

    // NOT propagates Q=1 -> D=0 during settle.
    try std.testing.expectEqual(
        false,
        try circuit.load(@enumFromInt(1)),
    );

    // Falling edge.
    try circuit.store(@enumFromInt(2), false);
    try circuit.settle(8);

    // Second rising edge:
    // D=0 -> Q=0
    try circuit.store(@enumFromInt(2), true);
    try circuit.settle(8);

    try std.testing.expectEqual(
        false,
        try circuit.load(@enumFromInt(0)),
    );

    try std.testing.expectEqual(
        true,
        try circuit.load(@enumFromInt(1)),
    );
}
