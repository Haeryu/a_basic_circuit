const std = @import("std");

const Circuit = @import("Circuit.zig");
const CompiledCircuit = @import("CompiledCircuit.zig");

const BusIndex = CompiledCircuit.BusIndex;
const ChipSpec = CompiledCircuit.ChipSpec;
const Topology = CompiledCircuit.Topology;

pub const Compilation = struct {
    topology: Topology,

    // Runtime index -> editor handle.
    bus_to_net: []Circuit.NetId,
    chip_to_node: []Circuit.NodeId,

    topology_owned: bool = true,

    pub fn deinit(self: *Compilation, allocator: std.mem.Allocator) void {
        if (self.topology_owned) {
            self.topology.deinit(allocator);
        }

        allocator.free(self.bus_to_net);
        allocator.free(self.chip_to_node);

        self.* = undefined;
    }

    pub fn createRuntime(self: *Compilation, allocator: std.mem.Allocator) !CompiledCircuit {
        std.debug.assert(self.topology_owned);

        const runtime: CompiledCircuit = try .init(allocator, &self.topology);
        self.topology_owned = false;

        return runtime;
    }
};

pub fn compile(allocator: std.mem.Allocator, circuit: *const Circuit) !Compilation {
    const chip_count = circuit.nodes.values.items.len;
    const bus_count = circuit.nets.values.items.len;

    var input_count: usize = 0;
    for (circuit.nodes.values.items) |node| {
        input_count = std.math.add(usize, input_count, node.op.inputCount()) catch {
            return error.TopologyTooLarge;
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

    for (bus_to_net, 0..) |*net_id, i| {
        net_id.* = circuit.nets.handleAtDenseIndex(i) orelse unreachable;
    }

    for (chip_to_node, 0..) |*node_id, i| {
        node_id.* = circuit.nodes.handleAtDenseIndex(i) orelse unreachable;
    }

    var input_cursor: usize = 0;
    for (circuit.nodes.values.items, 0..) |node, chip_index| {
        const node_input_count = node.op.inputCount();
        const node_output_count = node.op.outputCount();

        for (0..node_input_count) |port| {
            const net_id = node.connections[port] orelse return error.UnconnectedInput;
            const dense_net_index = circuit.nets.denseIndex(net_id) orelse
                return error.InvalidNet;

            inputs[input_cursor + port] = @enumFromInt(dense_net_index);
        }

        if (node_output_count != 1) {
            return error.UnsupportedOutputCount;
        }

        const output_connection_index = node_input_count;

        const output_net_id = node.connections[output_connection_index] orelse
            return error.UnconnectedOutput;

        const output_dense_index = circuit.nets.denseIndex(output_net_id) orelse
            return error.InvalidNet;

        chip_specs[chip_index] = .{
            .op = node.op,
            .inputs = inputs[input_cursor .. input_cursor + node_input_count],
            .output = @enumFromInt(
                output_dense_index,
            ),
        };

        input_cursor += node_input_count;
    }

    var topology: Topology = try .init(allocator, bus_count, chip_specs);
    errdefer topology.deinit(allocator);

    return .{
        .topology = topology,
        .bus_to_net = bus_to_net,
        .chip_to_node = chip_to_node,
    };
}

test "compile circuit and run" {
    var circuit =
        Circuit.init(std.testing.allocator);
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

    var compilation = try compile(
        std.testing.allocator,
        &circuit,
    );
    defer compilation.deinit(
        std.testing.allocator,
    );

    const a_bus: BusIndex =
        @enumFromInt(
            circuit.nets.denseIndex(a).?,
        );

    const b_bus: BusIndex =
        @enumFromInt(
            circuit.nets.denseIndex(b).?,
        );

    const out_bus: BusIndex =
        @enumFromInt(
            circuit.nets.denseIndex(out).?,
        );

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
    var circuit =
        Circuit.init(std.testing.allocator);
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

    // Stale handles must remain invalid.
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

    var compilation = try compile(
        std.testing.allocator,
        &circuit,
    );
    defer compilation.deinit(
        std.testing.allocator,
    );

    const a_bus: BusIndex =
        @enumFromInt(
            circuit.nets.denseIndex(a).?,
        );

    const b_bus: BusIndex =
        @enumFromInt(
            circuit.nets.denseIndex(b).?,
        );

    const out_bus: BusIndex =
        @enumFromInt(
            circuit.nets.denseIndex(out).?,
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
    var circuit =
        Circuit.init(std.testing.allocator);
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

    const input_bus =
        circuit.nets.denseIndex(input).?;

    const output_bus =
        circuit.nets.denseIndex(output).?;

    var compilation = try compile(
        std.testing.allocator,
        &circuit,
    );
    defer compilation.deinit(
        std.testing.allocator,
    );

    try std.testing.expect(
        compilation.chip_to_node[0]
            .eql(node),
    );

    try std.testing.expect(
        compilation.bus_to_net[input_bus]
            .eql(input),
    );

    try std.testing.expect(
        compilation.bus_to_net[output_bus]
            .eql(output),
    );

    // Mutate the editor graph after compilation.
    //
    // The compiled snapshot must not change even if the editor-side
    // dense storage changes or the original handle becomes stale.
    try std.testing.expect(
        circuit.removeNet(output),
    );

    try std.testing.expect(
        circuit.nets.get(output) == null,
    );

    try std.testing.expect(
        compilation.bus_to_net[input_bus]
            .eql(input),
    );

    try std.testing.expect(
        compilation.bus_to_net[output_bus]
            .eql(output),
    );
}
