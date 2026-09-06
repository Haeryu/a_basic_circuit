const std = @import("std");

const Circuit = @import("Circuit.zig");
const CompiledCircuit = @import("CompiledCircuit.zig");

const BusIndex = CompiledCircuit.BusIndex;
const ChipSpec = CompiledCircuit.ChipSpec;
const Topology = CompiledCircuit.Topology;

pub fn compile(gpa: std.mem.Allocator, circuit: *const Circuit) !Topology {
    const chip_count = circuit.nodes.values.items.len;
    const bus_count = circuit.nets.values.items.len;

    var input_count: usize = 0;
    for (circuit.nodes.values.items) |node| {
        input_count = std.math.add(usize, input_count, node.op.inputCount()) catch {
            return error.TopologyTooLarge;
        };
    }

    const chip_specs = try gpa.alloc(ChipSpec, chip_count);
    defer gpa.free(chip_specs);

    const inputs = try gpa.alloc(BusIndex, input_count);
    defer gpa.free(inputs);

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

    return .init(gpa, bus_count, chip_specs);
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

    var topology = try compile(
        std.testing.allocator,
        &circuit,
    );
    errdefer topology.deinit(
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

    var runtime = try CompiledCircuit.init(
        std.testing.allocator,
        &topology,
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
        try runtime.store(a_bus, case.a);
        try runtime.store(b_bus, case.b);

        try runtime.settle(8);

        try std.testing.expectEqual(
            case.out,
            try runtime.load(out_bus),
        );
    }
}
