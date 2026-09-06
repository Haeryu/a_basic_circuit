const std = @import("std");

const Circuit = @import("Circuit.zig");
const CompiledCircuit = @import("CompiledCircuit.zig");
const Project = @import("Project.zig");

const BusIndex = CompiledCircuit.BusIndex;
const ChipSpec = CompiledCircuit.ChipSpec;
const Topology = CompiledCircuit.Topology;

pub const PinDiagnostic = struct {
    circuit: Circuit.Id,
    node: Circuit.NodeId,
    port: u16,
};

pub const NetDiagnostic = struct {
    circuit: Circuit.Id,
    net: Circuit.NetId,
};

pub const Diagnostic = union(enum) {
    unconnected_input: PinDiagnostic,
    unconnected_output: PinDiagnostic,

    undriven_net: NetDiagnostic,
    driven_input: NetDiagnostic,
};

pub const CompileFailure = struct {
    diagnostics: []Diagnostic,

    pub fn deinit(self: *CompileFailure, allocator: std.mem.Allocator) void {
        allocator.free(self.diagnostics);
        self.* = undefined;
    }
};

pub const Compilation = struct {
    topology: Topology,

    input_buses: []BusIndex,
    output_buses: []BusIndex,

    topology_owned: bool = true,

    pub fn deinit(self: *Compilation, allocator: std.mem.Allocator) void {
        if (self.topology_owned) {
            self.topology.deinit(allocator);
        }

        allocator.free(self.output_buses);
        allocator.free(self.input_buses);

        self.* = undefined;
    }

    pub fn createRuntime(self: *Compilation, allocator: std.mem.Allocator) !CompiledCircuit {
        std.debug.assert(self.topology_owned);

        const runtime: CompiledCircuit = try .init(allocator, &self.topology);

        self.topology_owned = false;

        return runtime;
    }
};

pub const CompileResult = union(enum) {
    success: Compilation,
    failure: CompileFailure,
};

pub fn compile(
    allocator: std.mem.Allocator,
    project: *const Project,
    root_id: Circuit.Id,
) !CompileResult {
    try validateHierarchy(allocator, project, root_id);

    const root = project.getConst(root_id) orelse return error.InvalidCircuit;

    var visited: std.bit_set.DynamicBitSetUnmanaged = try .initEmpty(
        allocator,
        project.circuits.slots.items.len,
    );
    defer visited.deinit(allocator);

    var diagnostics: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);

    try validateDiagnostics(allocator, project, root_id, &visited, &diagnostics);

    if (diagnostics.items.len != 0) {
        return .{
            .failure = .{
                .diagnostics = try diagnostics.toOwnedSlice(allocator),
            },
        };
    }

    const chip_count = try countPrimitiveNodes(project, root_id);
    const input_count = try countPrimitiveInputs(project, root_id);

    const chip_specs = try allocator.alloc(ChipSpec, chip_count);
    defer allocator.free(chip_specs);

    const inputs = try allocator.alloc(BusIndex, input_count);
    defer allocator.free(inputs);

    const root_bus_count = root.nets.values.items.len;

    if (root_bus_count > std.math.maxInt(u32)) {
        return error.TopologyTooLarge;
    }

    const root_bus_map = try allocator.alloc(BusIndex, root_bus_count);
    defer allocator.free(root_bus_map);

    for (root_bus_map, 0..) |*bus, i| {
        bus.* = @enumFromInt(i);
    }

    var next_bus: u32 = @intCast(root_bus_count);
    var chip_cursor: usize = 0;
    var input_cursor: usize = 0;

    try emitCircuit(
        allocator,
        project,
        root_id,
        root_bus_map,
        chip_specs,
        inputs,
        &chip_cursor,
        &input_cursor,
        &next_bus,
    );

    std.debug.assert(chip_cursor == chip_count);
    std.debug.assert(input_cursor == input_count);

    const input_buses = try allocator.alloc(BusIndex, root.inputs.items.len);
    errdefer allocator.free(input_buses);

    const output_buses = try allocator.alloc(BusIndex, root.outputs.items.len);
    errdefer allocator.free(output_buses);

    for (root.inputs.items, 0..) |port, i| {
        const dense_index = root.nets.denseIndex(port.net) orelse unreachable;

        input_buses[i] = root_bus_map[dense_index];
    }

    for (root.outputs.items, 0..) |port, i| {
        const dense_index = root.nets.denseIndex(port.net) orelse unreachable;

        output_buses[i] = root_bus_map[dense_index];
    }

    var topology: Topology = try .init(allocator, next_bus, chip_specs);
    errdefer topology.deinit(allocator);

    return .{
        .success = .{
            .topology = topology,
            .input_buses = input_buses,
            .output_buses = output_buses,
        },
    };
}

fn countPrimitiveNodes(project: *const Project, circuit_id: Circuit.Id) !usize {
    const circuit = project.getConst(circuit_id) orelse return error.InvalidCircuit;

    var count: usize = 0;
    for (circuit.nodes.values.items) |node| {
        switch (node.kind) {
            .primitive => {
                count = std.math.add(usize, count, 1) catch return error.TopologyTooLarge;
            },
            .subcircuit => |child_id| {
                const child_count = try countPrimitiveNodes(project, child_id);
                count = std.math.add(usize, count, child_count) catch
                    return error.TopologyTooLarge;
            },
        }
    }

    return count;
}

fn countPrimitiveInputs(project: *const Project, circuit_id: Circuit.Id) !usize {
    const circuit = project.getConst(circuit_id) orelse return error.InvalidCircuit;

    var count: usize = 0;
    for (circuit.nodes.values.items) |node| {
        switch (node.kind) {
            .primitive => {
                count = std.math.add(usize, count, node.inputCount()) catch
                    return error.TopologyTooLarge;
            },
            .subcircuit => |child_id| {
                const child_count = try countPrimitiveInputs(project, child_id);
                count = std.math.add(usize, count, child_count) catch
                    return error.TopologyTooLarge;
            },
        }
    }

    return count;
}

fn makeChildBusMap(
    allocator: std.mem.Allocator,
    child: *const Circuit,
    parent_node: *const Circuit.Node,
    parent: *const Circuit,
    parent_bus_map: []const BusIndex,
    next_bus: *u32,
) ![]BusIndex {
    std.debug.assert(parent_node.inputCount() == child.inputs.items.len);

    std.debug.assert(parent_node.outputCount() == child.outputs.items.len);

    const bus_map = try allocator.alloc(BusIndex, child.nets.values.items.len);
    errdefer allocator.free(bus_map);

    const invalid = std.math.maxInt(u32);
    @memset(bus_map, @enumFromInt(invalid));

    for (child.inputs.items, 0..) |port, i| {
        const child_dense = child.nets.denseIndex(port.net) orelse unreachable;
        const parent_net = parent_node.connections[i] orelse unreachable;
        const parent_dense = parent.nets.denseIndex(parent_net) orelse unreachable;

        bus_map[child_dense] = parent_bus_map[parent_dense];
    }

    const output_start = parent_node.inputCount();

    for (child.outputs.items, 0..) |port, i| {
        const child_dense = child.nets.denseIndex(port.net) orelse unreachable;
        const parent_net = parent_node.connections[output_start + i] orelse unreachable;
        const parent_dense = parent.nets.denseIndex(parent_net) orelse unreachable;
        const existing = @intFromEnum(bus_map[child_dense]);

        if (existing != invalid) {
            // Pass-through interfaces need bus aliasing.
            if (existing != @intFromEnum(parent_bus_map[parent_dense])) {
                return error.InterfaceAlias;
            }

            continue;
        }

        bus_map[child_dense] = parent_bus_map[parent_dense];
    }

    for (bus_map) |*bus| {
        if (@intFromEnum(bus.*) != invalid) {
            continue;
        }

        if (next_bus.* == std.math.maxInt(u32)) {
            return error.TopologyTooLarge;
        }

        bus.* = @enumFromInt(next_bus.*);
        next_bus.* += 1;
    }

    return bus_map;
}

fn emitCircuit(
    allocator: std.mem.Allocator,
    project: *const Project,
    circuit_id: Circuit.Id,
    bus_map: []const BusIndex,
    chip_specs: []ChipSpec,
    inputs: []BusIndex,
    chip_cursor: *usize,
    input_cursor: *usize,
    next_bus: *u32,
) !void {
    const circuit = project.getConst(circuit_id) orelse return error.InvalidCircuit;

    std.debug.assert(bus_map.len == circuit.nets.values.items.len);

    for (circuit.nodes.values.items) |node| {
        switch (node.kind) {
            .primitive => |op| {
                const input_count = node.inputCount();

                if (node.outputCount() != 1) {
                    return error.UnsupportedOutputCount;
                }

                std.debug.assert(chip_cursor.* < chip_specs.len);
                std.debug.assert(input_cursor.* + input_count <= inputs.len);

                const input_start = input_cursor.*;

                for (0..input_count) |port| {
                    const net_id = node.connections[port] orelse unreachable;
                    const dense_index = circuit.nets.denseIndex(net_id) orelse unreachable;

                    inputs[input_start + port] = bus_map[dense_index];
                }

                const output_net = node.connections[input_count] orelse unreachable;
                const output_dense = circuit.nets.denseIndex(output_net) orelse unreachable;

                chip_specs[chip_cursor.*] = .{
                    .op = op,
                    .inputs = inputs[input_start .. input_start + input_count],
                    .output = bus_map[output_dense],
                };

                chip_cursor.* += 1;
                input_cursor.* += input_count;
            },
            .subcircuit => |child_id| {
                const child = project.getConst(child_id) orelse return error.InvalidCircuit;
                const child_bus_map =
                    try makeChildBusMap(allocator, child, &node, circuit, bus_map, next_bus);
                defer allocator.free(child_bus_map);

                try emitCircuit(
                    allocator,
                    project,
                    child_id,
                    child_bus_map,
                    chip_specs,
                    inputs,
                    chip_cursor,
                    input_cursor,
                    next_bus,
                );
            },
        }
    }
}

fn validateHierarchy(
    allocator: std.mem.Allocator,
    project: *const Project,
    root_id: Circuit.Id,
) !void {
    var active: std.bit_set.DynamicBitSetUnmanaged = try .initEmpty(
        allocator,
        project.circuits.slots.items.len,
    );
    defer active.deinit(allocator);

    try validateHierarchyRecursive(project, root_id, &active);
}

fn validateHierarchyRecursive(
    project: *const Project,
    circuit_id: Circuit.Id,
    active: *std.bit_set.DynamicBitSetUnmanaged,
) !void {
    const circuit = project.getConst(circuit_id) orelse return error.InvalidCircuit;
    const slot: usize = @intCast(circuit_id.index);

    if (active.isSet(slot)) {
        return error.CircuitCycle;
    }

    active.set(slot);
    defer active.unset(slot);

    for (circuit.nodes.values.items) |node| {
        switch (node.kind) {
            .primitive => {},
            .subcircuit => |child_id| {
                const child = project.getConst(child_id) orelse return error.InvalidCircuit;

                if (node.inputCount() != child.inputs.items.len or
                    node.outputCount() != child.outputs.items.len)
                {
                    return error.SubcircuitInterfaceChanged;
                }

                try validateHierarchyRecursive(project, child_id, active);
            },
        }
    }
}

fn validateDiagnostics(
    allocator: std.mem.Allocator,
    project: *const Project,
    circuit_id: Circuit.Id,
    visited: *std.bit_set.DynamicBitSetUnmanaged,
    diagnostics: *std.ArrayListUnmanaged(Diagnostic),
) !void {
    const circuit = project.getConst(circuit_id) orelse return error.InvalidCircuit;
    const slot: usize = @intCast(circuit_id.index);

    if (visited.isSet(slot)) {
        return;
    }

    visited.set(slot);

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

    for (circuit.nodes.values.items, 0..) |node, dense_index| {
        const node_id = circuit.nodes.handleAtDenseIndex(dense_index) orelse unreachable;
        const input_count = node.inputCount();
        const output_count = node.outputCount();

        for (0..input_count) |port| {
            if (node.connections[port] != null) {
                continue;
            }

            try diagnostics.append(allocator, .{
                .unconnected_input = .{
                    .circuit = circuit_id,
                    .node = node_id,
                    .port = @intCast(port),
                },
            });
        }

        for (0..output_count) |port| {
            if (node.connections[input_count + port] != null) {
                continue;
            }

            try diagnostics.append(allocator, .{
                .unconnected_output = .{
                    .circuit = circuit_id,
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
                .driven_input = .{
                    .circuit = circuit_id,
                    .net = net_id,
                },
            });

            continue;
        }

        if (net.driver == null and !is_input and (net.consumers.items.len != 0 or is_output)) {
            try diagnostics.append(allocator, .{
                .undriven_net = .{
                    .circuit = circuit_id,
                    .net = net_id,
                },
            });
        }
    }

    for (circuit.nodes.values.items) |node| {
        switch (node.kind) {
            .primitive => {},
            .subcircuit => |child_id| {
                try validateDiagnostics(allocator, project, child_id, visited, diagnostics);
            },
        }
    }
}

fn compileSuccess(project: *const Project, root_id: Circuit.Id) !Compilation {
    const result = try compile(std.testing.allocator, project, root_id);

    return switch (result) {
        .success => |compilation| compilation,
        .failure => |value| {
            var failure = value;
            failure.deinit(std.testing.allocator);

            return error.UnexpectedCompileFailure;
        },
    };
}

test "compile primitive circuit and run" {
    var project =
        Project.init(std.testing.allocator);
    defer project.deinit();

    const root_id =
        try project.addCircuit();

    {
        const root =
            project.get(root_id).?;

        const input =
            try root.addNet();

        const output =
            try root.addNet();

        _ = try root.addInput(input);
        _ = try root.addOutput(output);

        const node =
            try root.addNode(
                .not1,
                .{ .x = 0, .y = 0 },
            );

        try root.connectInput(
            node,
            0,
            input,
        );

        try root.connectOutput(
            node,
            0,
            output,
        );
    }

    var compilation =
        try compileSuccess(
            &project,
            root_id,
        );
    defer compilation.deinit(
        std.testing.allocator,
    );

    try std.testing.expectEqual(
        @as(usize, 1),
        compilation.topology.ops.len,
    );

    try std.testing.expectEqual(
        @as(usize, 1),
        compilation.input_buses.len,
    );

    try std.testing.expectEqual(
        @as(usize, 1),
        compilation.output_buses.len,
    );

    var runtime =
        try compilation.createRuntime(
            std.testing.allocator,
        );
    defer runtime.deinit();

    const input_bus =
        compilation.input_buses[0];

    const output_bus =
        compilation.output_buses[0];

    try runtime.store(
        input_bus,
        false,
    );

    try runtime.settle(8);

    try std.testing.expectEqual(
        true,
        try runtime.load(output_bus),
    );

    try runtime.store(
        input_bus,
        true,
    );

    try runtime.settle(8);

    try std.testing.expectEqual(
        false,
        try runtime.load(output_bus),
    );
}

test "compile nested subcircuits and run" {
    var project =
        Project.init(std.testing.allocator);
    defer project.deinit();

    const leaf_id =
        try project.addCircuit();

    const middle_id =
        try project.addCircuit();

    const root_id =
        try project.addCircuit();

    {
        const leaf =
            project.get(leaf_id).?;

        const input =
            try leaf.addNet();

        const output =
            try leaf.addNet();

        _ = try leaf.addInput(input);
        _ = try leaf.addOutput(output);

        const node =
            try leaf.addNode(
                .not1,
                .{ .x = 0, .y = 0 },
            );

        try leaf.connectInput(
            node,
            0,
            input,
        );

        try leaf.connectOutput(
            node,
            0,
            output,
        );
    }

    {
        const leaf =
            project.getConst(leaf_id).?;

        const middle =
            project.get(middle_id).?;

        const input =
            try middle.addNet();

        const output =
            try middle.addNet();

        _ = try middle.addInput(input);
        _ = try middle.addOutput(output);

        const instance =
            try middle.addSubcircuitNode(
                leaf_id,
                leaf,
                .{ .x = 0, .y = 0 },
            );

        try middle.connectInput(
            instance,
            0,
            input,
        );

        try middle.connectOutput(
            instance,
            0,
            output,
        );
    }

    {
        const middle =
            project.getConst(middle_id).?;

        const root =
            project.get(root_id).?;

        const input =
            try root.addNet();

        const output =
            try root.addNet();

        _ = try root.addInput(input);
        _ = try root.addOutput(output);

        const instance =
            try root.addSubcircuitNode(
                middle_id,
                middle,
                .{ .x = 0, .y = 0 },
            );

        try root.connectInput(
            instance,
            0,
            input,
        );

        try root.connectOutput(
            instance,
            0,
            output,
        );
    }

    var compilation =
        try compileSuccess(
            &project,
            root_id,
        );
    defer compilation.deinit(
        std.testing.allocator,
    );

    try std.testing.expectEqual(
        @as(usize, 1),
        compilation.topology.ops.len,
    );

    var runtime =
        try compilation.createRuntime(
            std.testing.allocator,
        );
    defer runtime.deinit();

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
}

test "compile returns diagnostics from child circuit" {
    var project =
        Project.init(std.testing.allocator);
    defer project.deinit();

    const child_id =
        try project.addCircuit();

    const root_id =
        try project.addCircuit();

    var child_node: Circuit.NodeId =
        undefined;

    {
        const child =
            project.get(child_id).?;

        child_node =
            try child.addNode(
                .not1,
                .{ .x = 0, .y = 0 },
            );
    }

    {
        const child =
            project.getConst(child_id).?;

        const root =
            project.get(root_id).?;

        _ = try root.addSubcircuitNode(
            child_id,
            child,
            .{ .x = 0, .y = 0 },
        );
    }

    const result =
        try compile(
            std.testing.allocator,
            &project,
            root_id,
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
                @as(usize, 2),
                failure.diagnostics.len,
            );

            switch (failure.diagnostics[0]) {
                .unconnected_input => |pin| {
                    try std.testing.expect(
                        pin.circuit.eql(
                            child_id,
                        ),
                    );

                    try std.testing.expect(
                        pin.node.eql(
                            child_node,
                        ),
                    );

                    try std.testing.expectEqual(
                        @as(u16, 0),
                        pin.port,
                    );
                },

                else => return error.UnexpectedDiagnostic,
            }

            switch (failure.diagnostics[1]) {
                .unconnected_output => |pin| {
                    try std.testing.expect(
                        pin.circuit.eql(
                            child_id,
                        ),
                    );

                    try std.testing.expect(
                        pin.node.eql(
                            child_node,
                        ),
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

test "compile reports undriven net" {
    var project =
        Project.init(std.testing.allocator);
    defer project.deinit();

    const root_id =
        try project.addCircuit();

    var input_net: Circuit.NetId =
        undefined;

    {
        const root =
            project.get(root_id).?;

        input_net =
            try root.addNet();

        const output =
            try root.addNet();

        _ = try root.addOutput(output);

        const node =
            try root.addNode(
                .not1,
                .{ .x = 0, .y = 0 },
            );

        try root.connectInput(
            node,
            0,
            input_net,
        );

        try root.connectOutput(
            node,
            0,
            output,
        );
    }

    const result =
        try compile(
            std.testing.allocator,
            &project,
            root_id,
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
                .undriven_net => |diagnostic| {
                    try std.testing.expect(
                        diagnostic.circuit.eql(
                            root_id,
                        ),
                    );

                    try std.testing.expect(
                        diagnostic.net.eql(
                            input_net,
                        ),
                    );
                },

                else => return error.UnexpectedDiagnostic,
            }
        },
    }
}

test "compile reports driven input" {
    var project =
        Project.init(std.testing.allocator);
    defer project.deinit();

    const root_id =
        try project.addCircuit();

    var driven_input: Circuit.NetId =
        undefined;

    {
        const root =
            project.get(root_id).?;

        const source_input =
            try root.addNet();

        driven_input =
            try root.addNet();

        _ = try root.addInput(source_input);
        _ = try root.addInput(driven_input);

        const node =
            try root.addNode(
                .not1,
                .{ .x = 0, .y = 0 },
            );

        try root.connectInput(
            node,
            0,
            source_input,
        );

        try root.connectOutput(
            node,
            0,
            driven_input,
        );
    }

    const result =
        try compile(
            std.testing.allocator,
            &project,
            root_id,
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
                .driven_input => |diagnostic| {
                    try std.testing.expect(
                        diagnostic.circuit.eql(
                            root_id,
                        ),
                    );

                    try std.testing.expect(
                        diagnostic.net.eql(
                            driven_input,
                        ),
                    );
                },

                else => return error.UnexpectedDiagnostic,
            }
        },
    }
}

test "compile rejects circuit cycle" {
    var project =
        Project.init(std.testing.allocator);
    defer project.deinit();

    const a_id =
        try project.addCircuit();

    const b_id =
        try project.addCircuit();

    {
        const b =
            project.getConst(b_id).?;

        const a =
            project.get(a_id).?;

        _ = try a.addSubcircuitNode(
            b_id,
            b,
            .{ .x = 0, .y = 0 },
        );
    }

    {
        const a =
            project.getConst(a_id).?;

        const b =
            project.get(b_id).?;

        _ = try b.addSubcircuitNode(
            a_id,
            a,
            .{ .x = 0, .y = 0 },
        );
    }

    try std.testing.expectError(
        error.CircuitCycle,
        compile(
            std.testing.allocator,
            &project,
            a_id,
        ),
    );
}

test "compile rejects stale subcircuit id" {
    var project =
        Project.init(std.testing.allocator);
    defer project.deinit();

    const child_id =
        try project.addCircuit();

    const root_id =
        try project.addCircuit();

    {
        const child =
            project.getConst(child_id).?;

        const root =
            project.get(root_id).?;

        _ = try root.addSubcircuitNode(
            child_id,
            child,
            .{ .x = 0, .y = 0 },
        );
    }

    try std.testing.expect(
        project.removeCircuit(
            child_id,
        ),
    );

    const replacement =
        try project.addCircuit();

    try std.testing.expectEqual(
        child_id.index,
        replacement.index,
    );

    try std.testing.expect(
        child_id.generation !=
            replacement.generation,
    );

    try std.testing.expectError(
        error.InvalidCircuit,
        compile(
            std.testing.allocator,
            &project,
            root_id,
        ),
    );
}

test "compile rejects changed subcircuit interface" {
    var project =
        Project.init(std.testing.allocator);
    defer project.deinit();

    const child_id =
        try project.addCircuit();

    const root_id =
        try project.addCircuit();

    {
        const child =
            project.get(child_id).?;

        const input =
            try child.addNet();

        const output =
            try child.addNet();

        _ = try child.addInput(input);
        _ = try child.addOutput(output);
    }

    {
        const child =
            project.getConst(child_id).?;

        const root =
            project.get(root_id).?;

        _ = try root.addSubcircuitNode(
            child_id,
            child,
            .{ .x = 0, .y = 0 },
        );
    }

    {
        const child =
            project.get(child_id).?;

        const extra =
            try child.addNet();

        _ = try child.addInput(extra);
    }

    try std.testing.expectError(
        error.SubcircuitInterfaceChanged,
        compile(
            std.testing.allocator,
            &project,
            root_id,
        ),
    );
}
