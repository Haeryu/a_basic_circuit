const std = @import("std");

const Circuit = @import("Circuit.zig");
const CompiledCircuit = @import("CompiledCircuit.zig");

const BusIndex = CompiledCircuit.BusIndex;
const ChipSpec = CompiledCircuit.ChipSpec;
const Topology = CompiledCircuit.Topology;

const ChipIndex = CompiledCircuit.ChipIndex;

const ReverseEntry = packed struct(u64) {
    generation: u31 = 0,
    valid: bool = false,
    runtime_index: u32 = 0,
};

pub const PinDiagnostic = struct {
    node: Circuit.NodeId,
    port: u16,
};

pub const Diagnostic = union(enum) {
    unconnected_input: PinDiagnostic,
    unconnected_output: PinDiagnostic,

    undriven_net: Circuit.NetId,
    driven_input: Circuit.NetId,
};

pub const CompileFailure = struct {
    diagnostics: []Diagnostic,

    pub fn deinit(
        self: *CompileFailure,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.diagnostics);
        self.* = undefined;
    }
};

pub const CompileResult = union(enum) {
    success: Compilation,
    failure: CompileFailure,
};

pub const Compilation = struct {
    topology: Topology,

    // Runtime index -> editor handle.
    bus_to_net: []Circuit.NetId,
    chip_to_node: []Circuit.NodeId,

    // Editor sparse slot -> runtime index.
    net_to_bus: []ReverseEntry,
    node_to_chip: []ReverseEntry,

    topology_owned: bool = true,

    input_buses: []BusIndex,
    output_buses: []BusIndex,

    pub fn deinit(self: *Compilation, allocator: std.mem.Allocator) void {
        if (self.topology_owned) {
            self.topology.deinit(allocator);
        }

        allocator.free(self.output_buses);
        allocator.free(self.input_buses);

        allocator.free(self.node_to_chip);
        allocator.free(self.net_to_bus);

        allocator.free(self.chip_to_node);
        allocator.free(self.bus_to_net);

        self.* = undefined;
    }

    pub fn busForNet(self: *const Compilation, net_id: Circuit.NetId) ?BusIndex {
        if (net_id.reserved != 0) {
            return null;
        }

        const slot: usize = @intCast(net_id.index);

        if (slot >= self.net_to_bus.len) {
            return null;
        }

        const entry = self.net_to_bus[slot];

        if (!entry.valid) {
            return null;
        }

        if (entry.generation != net_id.generation) {
            return null;
        }

        return @enumFromInt(entry.runtime_index);
    }

    pub fn chipForNode(self: *const Compilation, node_id: Circuit.NodeId) ?ChipIndex {
        if (node_id.reserved != 0) {
            return null;
        }

        const slot: usize = @intCast(node_id.index);

        if (slot >= self.node_to_chip.len) {
            return null;
        }

        const entry = self.node_to_chip[slot];

        if (!entry.valid) {
            return null;
        }

        if (entry.generation != node_id.generation) {
            return null;
        }

        return @enumFromInt(entry.runtime_index);
    }

    pub fn createRuntime(self: *Compilation, allocator: std.mem.Allocator) !CompiledCircuit {
        std.debug.assert(self.topology_owned);

        const runtime: CompiledCircuit = try .init(allocator, &self.topology);

        self.topology_owned = false;

        return runtime;
    }
};

pub fn compile(allocator: std.mem.Allocator, circuit: *const Circuit) !CompileResult {
    const chip_count = circuit.nodes.values.items.len;
    const bus_count = circuit.nets.values.items.len;

    const external_inputs = try allocator.alloc(bool, bus_count);
    defer allocator.free(external_inputs);

    @memset(external_inputs, false);

    const external_outputs = try allocator.alloc(bool, bus_count);
    defer allocator.free(external_outputs);

    @memset(external_outputs, false);

    for (circuit.inputs.items) |port| {
        const dense_index = circuit.nets.denseIndex(port.net) orelse unreachable;

        external_inputs[dense_index] = true;
    }

    for (circuit.outputs.items) |port| {
        const dense_index = circuit.nets.denseIndex(port.net) orelse unreachable;

        external_outputs[dense_index] = true;
    }

    var diagnostics: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);

    var input_count: usize = 0;
    for (circuit.nodes.values.items, 0..) |node, dense_index| {
        const node_id = circuit.nodes.handleAtDenseIndex(dense_index) orelse unreachable;

        const node_input_count = node.inputCount();
        const node_output_count = node.outputCount();

        input_count = std.math.add(usize, input_count, node_input_count) catch
            return error.TopologyTooLarge;

        for (0..node_input_count) |port| {
            if (node.connections[port] != null) {
                continue;
            }

            try diagnostics.append(allocator, .{
                .unconnected_input = .{
                    .node = node_id,
                    .port = @intCast(port),
                },
            });
        }

        for (0..node_output_count) |port| {
            if (node.connections[node_input_count + port] != null) {
                continue;
            }

            try diagnostics.append(allocator, .{
                .unconnected_output = .{
                    .node = node_id,
                    .port = @intCast(port),
                },
            });
        }
    }

    for (circuit.nets.values.items, 0..) |net, dense_index| {
        const net_id = circuit.nets.handleAtDenseIndex(dense_index) orelse unreachable;
        const is_input = external_inputs[dense_index];
        const is_output = external_outputs[dense_index];

        if (is_input and net.driver != null) {
            try diagnostics.append(allocator, .{
                .driven_input = net_id,
            });

            continue;
        }

        if (net.driver == null and !is_input and (net.consumers.items.len != 0 or is_output)) {
            try diagnostics.append(allocator, .{
                .undriven_net = net_id,
            });
        }
    }

    if (diagnostics.items.len != 0) {
        return .{
            .failure = .{
                .diagnostics = try diagnostics.toOwnedSlice(allocator),
            },
        };
    }

    const chip_specs = try allocator.alloc(ChipSpec, chip_count);
    defer allocator.free(chip_specs);

    const inputs = try allocator.alloc(BusIndex, input_count);
    defer allocator.free(inputs);

    const bus_to_net = try allocator.alloc(Circuit.NetId, bus_count);
    errdefer allocator.free(bus_to_net);

    const chip_to_node = try allocator.alloc(Circuit.NodeId, chip_count);
    errdefer allocator.free(chip_to_node);

    const net_to_bus = try allocator.alloc(ReverseEntry, circuit.nets.slots.items.len);
    errdefer allocator.free(net_to_bus);
    @memset(net_to_bus, .{});

    const node_to_chip = try allocator.alloc(ReverseEntry, circuit.nodes.slots.items.len);
    errdefer allocator.free(node_to_chip);
    @memset(node_to_chip, .{});

    for (bus_to_net, 0..) |*net_id, i| {
        const handle = circuit.nets.handleAtDenseIndex(i) orelse unreachable;

        net_id.* = handle;

        net_to_bus[@intCast(handle.index)] = .{
            .generation = handle.generation,
            .valid = true,
            .runtime_index = @intCast(i),
        };
    }

    for (chip_to_node, 0..) |*node_id, i| {
        const handle = circuit.nodes.handleAtDenseIndex(i) orelse unreachable;

        node_id.* = handle;

        node_to_chip[@intCast(handle.index)] = .{
            .generation = handle.generation,
            .valid = true,
            .runtime_index = @intCast(i),
        };
    }

    var input_cursor: usize = 0;
    for (circuit.nodes.values.items, 0..) |node, chip_index| {
        const node_input_count = node.inputCount();
        const node_output_count = node.outputCount();

        for (0..node_input_count) |port| {
            const net_id = node.connections[port] orelse unreachable;
            const dense_net_index = circuit.nets.denseIndex(net_id) orelse unreachable;

            inputs[input_cursor + port] = @enumFromInt(dense_net_index);
        }

        if (node_output_count != 1) {
            return error.UnsupportedOutputCount;
        }

        const output_connection_index = node_input_count;

        const output_net_id = node.connections[output_connection_index] orelse unreachable;
        const output_dense_index = circuit.nets.denseIndex(output_net_id) orelse
            return error.InvalidNet;

        const op = switch (node.kind) {
            .primitive => |op| op,
            .subcircuit => unreachable,
        };

        chip_specs[chip_index] = .{
            .op = op,
            .inputs = inputs[input_cursor .. input_cursor + node_input_count],
            .output = @enumFromInt(output_dense_index),
        };

        input_cursor += node_input_count;
    }

    const input_buses = try allocator.alloc(BusIndex, circuit.inputs.items.len);
    errdefer allocator.free(input_buses);

    const output_buses = try allocator.alloc(BusIndex, circuit.outputs.items.len);
    errdefer allocator.free(output_buses);

    for (circuit.inputs.items, 0..) |port, i| {
        const dense_index = circuit.nets.denseIndex(port.net) orelse unreachable;

        input_buses[i] = @enumFromInt(dense_index);
    }

    for (circuit.outputs.items, 0..) |port, i| {
        const dense_index = circuit.nets.denseIndex(port.net) orelse unreachable;

        output_buses[i] = @enumFromInt(dense_index);
    }

    var topology: Topology = try .init(allocator, bus_count, chip_specs);
    errdefer topology.deinit(allocator);

    return .{
        .success = .{
            .topology = topology,

            .bus_to_net = bus_to_net,
            .chip_to_node = chip_to_node,

            .net_to_bus = net_to_bus,
            .node_to_chip = node_to_chip,

            .input_buses = input_buses,
            .output_buses = output_buses,
        },
    };
}

fn compileSuccess(
    circuit: *const Circuit,
) !Compilation {
    const result = try compile(
        std.testing.allocator,
        circuit,
    );

    return switch (result) {
        .success => |compilation| compilation,

        .failure => |failure_value| {
            var failure = failure_value;
            failure.deinit(std.testing.allocator);

            return error.UnexpectedCompileFailure;
        },
    };
}

test "compile reports all unconnected pins" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    const and_node = try circuit.addNode(
        .and2,
        .{ .x = 0, .y = 0 },
    );

    const not_node = try circuit.addNode(
        .not1,
        .{ .x = 100, .y = 0 },
    );

    // AND:
    //
    // input 0  -> connected
    // input 1  -> missing
    // output 0 -> missing
    //
    // NOT:
    //
    // input 0  -> missing
    // output 0 -> missing

    const a = try circuit.addNet();
    _ = try circuit.addInput(a);

    try circuit.connectInput(
        and_node,
        0,
        a,
    );

    const result = try compile(
        std.testing.allocator,
        &circuit,
    );

    switch (result) {
        .success => |value| {
            var compilation = value;
            defer compilation.deinit(
                std.testing.allocator,
            );

            return error.ExpectedFailure;
        },

        .failure => |value| {
            var failure = value;
            defer failure.deinit(
                std.testing.allocator,
            );

            try std.testing.expectEqual(
                @as(usize, 4),
                failure.diagnostics.len,
            );

            switch (failure.diagnostics[0]) {
                .unconnected_input => |pin| {
                    try std.testing.expect(
                        pin.node.eql(and_node),
                    );

                    try std.testing.expectEqual(
                        @as(u16, 1),
                        pin.port,
                    );
                },

                else => return error.UnexpectedDiagnostic,
            }

            switch (failure.diagnostics[1]) {
                .unconnected_output => |pin| {
                    try std.testing.expect(
                        pin.node.eql(and_node),
                    );

                    try std.testing.expectEqual(
                        @as(u16, 0),
                        pin.port,
                    );
                },

                else => return error.UnexpectedDiagnostic,
            }

            switch (failure.diagnostics[2]) {
                .unconnected_input => |pin| {
                    try std.testing.expect(
                        pin.node.eql(not_node),
                    );

                    try std.testing.expectEqual(
                        @as(u16, 0),
                        pin.port,
                    );
                },

                else => return error.UnexpectedDiagnostic,
            }

            switch (failure.diagnostics[3]) {
                .unconnected_output => |pin| {
                    try std.testing.expect(
                        pin.node.eql(not_node),
                    );

                    try std.testing.expectEqual(
                        @as(u16, 0),
                        pin.port,
                    );
                },

                else => return error.UnexpectedDiagnostic,
            }
        },
    }
}

test "compile succeeds when all pins are connected" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    const node = try circuit.addNode(
        .not1,
        .{ .x = 0, .y = 0 },
    );

    const input = try circuit.addNet();
    const output = try circuit.addNet();

    _ = try circuit.addInput(input);

    try circuit.connectInput(
        node,
        0,
        input,
    );

    try circuit.connectOutput(
        node,
        0,
        output,
    );

    var compilation = try compileSuccess(
        &circuit,
    );
    defer compilation.deinit(
        std.testing.allocator,
    );

    try std.testing.expect(
        compilation.busForNet(input) != null,
    );

    try std.testing.expect(
        compilation.busForNet(output) != null,
    );

    try std.testing.expect(
        compilation.chipForNode(node) != null,
    );
}

test "compile diagnostics update after editing circuit" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    const node = try circuit.addNode(
        .and2,
        .{ .x = 0, .y = 0 },
    );

    const a = try circuit.addNet();
    const b = try circuit.addNet();
    const out = try circuit.addNet();

    _ = try circuit.addInput(a);
    _ = try circuit.addInput(b);

    try circuit.connectInput(
        node,
        0,
        a,
    );

    {
        const result = try compile(
            std.testing.allocator,
            &circuit,
        );

        switch (result) {
            .success => |value| {
                var compilation = value;
                defer compilation.deinit(
                    std.testing.allocator,
                );

                return error.ExpectedFailure;
            },

            .failure => |value| {
                var failure = value;
                defer failure.deinit(
                    std.testing.allocator,
                );

                // Missing input 1 and output 0.
                try std.testing.expectEqual(
                    @as(usize, 2),
                    failure.diagnostics.len,
                );
            },
        }
    }

    try circuit.connectInput(
        node,
        1,
        b,
    );

    {
        const result = try compile(
            std.testing.allocator,
            &circuit,
        );

        switch (result) {
            .success => |value| {
                var compilation = value;
                defer compilation.deinit(
                    std.testing.allocator,
                );

                return error.ExpectedFailure;
            },

            .failure => |value| {
                var failure = value;
                defer failure.deinit(
                    std.testing.allocator,
                );

                try std.testing.expectEqual(
                    @as(usize, 1),
                    failure.diagnostics.len,
                );

                switch (failure.diagnostics[0]) {
                    .unconnected_output => |pin| {
                        try std.testing.expect(
                            pin.node.eql(node),
                        );

                        try std.testing.expectEqual(
                            @as(u16, 0),
                            pin.port,
                        );
                    },

                    else => return error.UnexpectedDiagnostic,
                }
            },
        }
    }

    try circuit.connectOutput(
        node,
        0,
        out,
    );

    var compilation = try compileSuccess(
        &circuit,
    );
    defer compilation.deinit(
        std.testing.allocator,
    );
}

test "compile circuit and run" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    // A ----\
    //        AND ---- OUT
    // B ----/

    const and_node = try circuit.addNode(
        .and2,
        .{ .x = 0, .y = 0 },
    );

    const a = try circuit.addNet();
    const b = try circuit.addNet();
    const out = try circuit.addNet();

    _ = try circuit.addInput(a);
    _ = try circuit.addInput(b);

    try circuit.connectInput(
        and_node,
        0,
        a,
    );

    try circuit.connectInput(
        and_node,
        1,
        b,
    );

    try circuit.connectOutput(
        and_node,
        0,
        out,
    );

    var compilation = try compileSuccess(
        &circuit,
    );
    defer compilation.deinit(
        std.testing.allocator,
    );

    const a_bus =
        compilation.busForNet(a).?;

    const b_bus =
        compilation.busForNet(b).?;

    const out_bus =
        compilation.busForNet(out).?;

    var runtime = try compilation.createRuntime(
        std.testing.allocator,
    );
    defer runtime.deinit();

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
        try runtime.store(
            a_bus,
            case.a,
        );

        try runtime.store(
            b_bus,
            case.b,
        );

        try runtime.settle(8);

        try std.testing.expectEqual(
            case.out,
            try runtime.load(out_bus),
        );
    }
}

test "compile survives dense pool reordering" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    // Node dense order:
    //
    // [ junk ][ AND ]
    //
    // After removing junk:
    //
    // [ AND ]

    const junk_node = try circuit.addNode(
        .not1,
        .{ .x = -100, .y = 0 },
    );

    const and_node = try circuit.addNode(
        .and2,
        .{ .x = 0, .y = 0 },
    );

    // Net dense order:
    //
    // [ A ][ junk ][ B ][ OUT ]
    //
    // After removing junk:
    //
    // [ A ][ OUT ][ B ]

    const a = try circuit.addNet();
    const junk_net = try circuit.addNet();
    const b = try circuit.addNet();
    const out = try circuit.addNet();

    try std.testing.expect(
        circuit.removeNode(junk_node),
    );

    try std.testing.expect(
        circuit.removeNet(junk_net),
    );

    try std.testing.expect(
        circuit.nodes.get(junk_node) == null,
    );

    try std.testing.expect(
        circuit.nets.get(junk_net) == null,
    );

    try std.testing.expectEqual(
        @as(usize, 0),
        circuit.nodes.denseIndex(and_node).?,
    );

    try std.testing.expectEqual(
        @as(usize, 0),
        circuit.nets.denseIndex(a).?,
    );

    try std.testing.expectEqual(
        @as(usize, 1),
        circuit.nets.denseIndex(out).?,
    );

    try std.testing.expectEqual(
        @as(usize, 2),
        circuit.nets.denseIndex(b).?,
    );

    _ = try circuit.addInput(a);
    _ = try circuit.addInput(b);

    try circuit.connectInput(
        and_node,
        0,
        a,
    );

    try circuit.connectInput(
        and_node,
        1,
        b,
    );

    try circuit.connectOutput(
        and_node,
        0,
        out,
    );

    var compilation = try compileSuccess(
        &circuit,
    );
    defer compilation.deinit(
        std.testing.allocator,
    );

    const a_bus =
        compilation.busForNet(a).?;

    const b_bus =
        compilation.busForNet(b).?;

    const out_bus =
        compilation.busForNet(out).?;

    try std.testing.expectEqual(
        @as(u32, 0),
        @intFromEnum(
            compilation.chipForNode(and_node).?,
        ),
    );

    var runtime = try compilation.createRuntime(
        std.testing.allocator,
    );
    defer runtime.deinit();

    try runtime.store(
        a_bus,
        true,
    );

    try runtime.store(
        b_bus,
        true,
    );

    try runtime.settle(8);

    try std.testing.expectEqual(
        true,
        try runtime.load(out_bus),
    );
}

test "compilation keeps runtime identity snapshot" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    const node = try circuit.addNode(
        .not1,
        .{ .x = 0, .y = 0 },
    );

    const input = try circuit.addNet();
    const output = try circuit.addNet();

    _ = try circuit.addInput(input);

    try circuit.connectInput(
        node,
        0,
        input,
    );

    try circuit.connectOutput(
        node,
        0,
        output,
    );

    var compilation = try compileSuccess(
        &circuit,
    );
    defer compilation.deinit(
        std.testing.allocator,
    );

    const input_bus =
        compilation.busForNet(input).?;

    const output_bus =
        compilation.busForNet(output).?;

    const input_index: usize =
        @intCast(@intFromEnum(input_bus));

    const output_index: usize =
        @intCast(@intFromEnum(output_bus));

    try std.testing.expect(
        compilation.chip_to_node[0]
            .eql(node),
    );

    try std.testing.expect(
        compilation.bus_to_net[input_index]
            .eql(input),
    );

    try std.testing.expect(
        compilation.bus_to_net[output_index]
            .eql(output),
    );

    // Mutating the editor must not mutate an existing compilation snapshot.
    try std.testing.expect(
        circuit.removeNet(output),
    );

    try std.testing.expect(
        circuit.nets.get(output) == null,
    );

    try std.testing.expect(
        compilation.bus_to_net[input_index]
            .eql(input),
    );

    try std.testing.expect(
        compilation.bus_to_net[output_index]
            .eql(output),
    );
}

test "reverse compilation lookup survives editor mutation" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    const node = try circuit.addNode(
        .not1,
        .{ .x = 0, .y = 0 },
    );

    const input = try circuit.addNet();
    const output = try circuit.addNet();

    _ = try circuit.addInput(input);

    try circuit.connectInput(
        node,
        0,
        input,
    );

    try circuit.connectOutput(
        node,
        0,
        output,
    );

    var compilation = try compileSuccess(
        &circuit,
    );
    defer compilation.deinit(
        std.testing.allocator,
    );

    const input_bus =
        compilation.busForNet(input).?;

    const output_bus =
        compilation.busForNet(output).?;

    const node_chip =
        compilation.chipForNode(node).?;

    // Mutate the editor after the runtime snapshot has been created.
    try std.testing.expect(
        circuit.removeNet(output),
    );

    const replacement =
        try circuit.addNet();

    // The sparse slot is reused with a new generation.
    try std.testing.expectEqual(
        output.index,
        replacement.index,
    );

    try std.testing.expect(
        output.generation !=
            replacement.generation,
    );

    // Handles that existed in the snapshot still resolve there.
    try std.testing.expectEqual(
        input_bus,
        compilation.busForNet(input).?,
    );

    try std.testing.expectEqual(
        output_bus,
        compilation.busForNet(output).?,
    );

    try std.testing.expectEqual(
        node_chip,
        compilation.chipForNode(node).?,
    );

    // Objects created after compilation do not exist in the snapshot.
    try std.testing.expect(
        compilation.busForNet(replacement) == null,
    );
}

test "compilation exposes circuit interface" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    // A ----\
    //        AND ---- OUT
    // B ----/

    const node = try circuit.addNode(
        .and2,
        .{ .x = 0, .y = 0 },
    );

    const a = try circuit.addNet();
    const b = try circuit.addNet();
    const out = try circuit.addNet();

    try circuit.connectInput(
        node,
        0,
        a,
    );

    try circuit.connectInput(
        node,
        1,
        b,
    );

    try circuit.connectOutput(
        node,
        0,
        out,
    );

    _ = try circuit.addInput(a);
    _ = try circuit.addInput(b);
    _ = try circuit.addOutput(out);

    var compilation = try compileSuccess(
        &circuit,
    );
    defer compilation.deinit(
        std.testing.allocator,
    );

    try std.testing.expectEqual(
        @as(usize, 2),
        compilation.input_buses.len,
    );

    try std.testing.expectEqual(
        @as(usize, 1),
        compilation.output_buses.len,
    );

    try std.testing.expectEqual(
        compilation.busForNet(a).?,
        compilation.input_buses[0],
    );

    try std.testing.expectEqual(
        compilation.busForNet(b).?,
        compilation.input_buses[1],
    );

    try std.testing.expectEqual(
        compilation.busForNet(out).?,
        compilation.output_buses[0],
    );

    var runtime = try compilation.createRuntime(
        std.testing.allocator,
    );
    defer runtime.deinit();

    try runtime.store(
        compilation.input_buses[0],
        true,
    );

    try runtime.store(
        compilation.input_buses[1],
        true,
    );

    try runtime.settle(8);

    try std.testing.expectEqual(
        true,
        try runtime.load(
            compilation.output_buses[0],
        ),
    );
}

test "compile reports undriven internal net" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    const node = try circuit.addNode(
        .not1,
        .{ .x = 0, .y = 0 },
    );

    const input = try circuit.addNet();
    const output = try circuit.addNet();

    try circuit.connectInput(
        node,
        0,
        input,
    );

    try circuit.connectOutput(
        node,
        0,
        output,
    );

    _ = try circuit.addOutput(output);

    const result = try compile(
        std.testing.allocator,
        &circuit,
    );

    switch (result) {
        .success => |value| {
            var compilation = value;
            defer compilation.deinit(
                std.testing.allocator,
            );

            return error.ExpectedFailure;
        },

        .failure => |value| {
            var failure = value;
            defer failure.deinit(
                std.testing.allocator,
            );

            try std.testing.expectEqual(
                @as(usize, 1),
                failure.diagnostics.len,
            );

            switch (failure.diagnostics[0]) {
                .undriven_net => |net| {
                    try std.testing.expect(
                        net.eql(input),
                    );
                },

                else => return error.UnexpectedDiagnostic,
            }
        },
    }
}

test "external input may drive internal consumers" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    const node = try circuit.addNode(
        .not1,
        .{ .x = 0, .y = 0 },
    );

    const input = try circuit.addNet();
    const output = try circuit.addNet();

    try circuit.connectInput(
        node,
        0,
        input,
    );

    try circuit.connectOutput(
        node,
        0,
        output,
    );

    _ = try circuit.addInput(input);
    _ = try circuit.addOutput(output);

    var compilation = try compileSuccess(
        &circuit,
    );
    defer compilation.deinit(
        std.testing.allocator,
    );

    var runtime = try compilation.createRuntime(
        std.testing.allocator,
    );
    defer runtime.deinit();

    try runtime.store(
        compilation.input_buses[0],
        true,
    );

    try runtime.settle(8);

    try std.testing.expectEqual(
        false,
        try runtime.load(
            compilation.output_buses[0],
        ),
    );

    try runtime.store(
        compilation.input_buses[0],
        false,
    );

    try runtime.settle(8);

    try std.testing.expectEqual(
        true,
        try runtime.load(
            compilation.output_buses[0],
        ),
    );
}

test "circuit input may also be circuit output" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    const net = try circuit.addNet();

    _ = try circuit.addInput(net);
    _ = try circuit.addOutput(net);

    var compilation = try compileSuccess(
        &circuit,
    );
    defer compilation.deinit(
        std.testing.allocator,
    );

    try std.testing.expectEqual(
        @as(usize, 1),
        compilation.input_buses.len,
    );

    try std.testing.expectEqual(
        @as(usize, 1),
        compilation.output_buses.len,
    );

    try std.testing.expectEqual(
        compilation.input_buses[0],
        compilation.output_buses[0],
    );

    var runtime = try compilation.createRuntime(
        std.testing.allocator,
    );
    defer runtime.deinit();

    try runtime.store(
        compilation.input_buses[0],
        true,
    );

    try runtime.settle(8);

    try std.testing.expectEqual(
        true,
        try runtime.load(
            compilation.output_buses[0],
        ),
    );

    try runtime.store(
        compilation.input_buses[0],
        false,
    );

    try runtime.settle(8);

    try std.testing.expectEqual(
        false,
        try runtime.load(
            compilation.output_buses[0],
        ),
    );
}

test "compile rejects internally driven external input" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    const node = try circuit.addNode(
        .not1,
        .{ .x = 0, .y = 0 },
    );

    const source = try circuit.addNet();
    const driven = try circuit.addNet();

    try circuit.connectInput(
        node,
        0,
        source,
    );

    try circuit.connectOutput(
        node,
        0,
        driven,
    );

    _ = try circuit.addInput(source);
    _ = try circuit.addInput(driven);

    const result = try compile(
        std.testing.allocator,
        &circuit,
    );

    switch (result) {
        .success => |value| {
            var compilation = value;
            defer compilation.deinit(
                std.testing.allocator,
            );

            return error.ExpectedFailure;
        },

        .failure => |value| {
            var failure = value;
            defer failure.deinit(
                std.testing.allocator,
            );

            try std.testing.expectEqual(
                @as(usize, 1),
                failure.diagnostics.len,
            );

            switch (failure.diagnostics[0]) {
                .driven_input => |net| {
                    try std.testing.expect(
                        net.eql(driven),
                    );
                },

                else => return error.UnexpectedDiagnostic,
            }
        },
    }
}

test "primitive node stores kind and pin layout" {
    const Op = @import("op.zig").Op;

    var circuit =
        Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    const id = try circuit.addNode(
        .and2,
        .{ .x = 0, .y = 0 },
    );

    const node = circuit.nodes.get(id).?;

    switch (node.kind) {
        .primitive => |op| {
            try std.testing.expectEqual(
                Op.and2,
                op,
            );
        },

        .subcircuit => {
            return error.UnexpectedNodeKind;
        },
    }

    try std.testing.expectEqual(
        @as(usize, 2),
        node.inputCount(),
    );

    try std.testing.expectEqual(
        @as(usize, 1),
        node.outputCount(),
    );

    try std.testing.expectEqual(
        @as(usize, 3),
        node.connections.len,
    );
}
