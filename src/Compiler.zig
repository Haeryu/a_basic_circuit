const std = @import("std");

const Circuit = @import("Circuit.zig");
const CompiledCircuit = @import("CompiledCircuit.zig");
const Project = @import("Project.zig");

const BusIndex = CompiledCircuit.BusIndex;
const ChipSpec = CompiledCircuit.ChipSpec;
const Topology = CompiledCircuit.Topology;

const ChipIndex = CompiledCircuit.ChipIndex;

const ReverseEntry = packed struct(u64) {
    generation: u31 = 0,
    valid: bool = false,
    runtime_index: u32 = 0,
};

pub const FlatCompilation = struct {
    topology: Topology,

    input_buses: []BusIndex,
    output_buses: []BusIndex,

    topology_owned: bool = true,

    pub fn deinit(self: *FlatCompilation, allocator: std.mem.Allocator) void {
        if (self.topology_owned) {
            self.topology.deinit(allocator);
        }

        allocator.free(self.output_buses);
        allocator.free(self.input_buses);

        self.* = undefined;
    }

    pub fn createRuntime(self: *FlatCompilation, allocator: std.mem.Allocator) !CompiledCircuit {
        std.debug.assert(self.topology_owned);

        const runtime: CompiledCircuit = try .init(allocator, &self.topology);
        self.topology_owned = false;

        return runtime;
    }
};

const HierarchyPinDiagnostic = struct {
    circuit: Circuit.Id,
    node: Circuit.NodeId,
    port: u16,
};

const HierarchyNetDiagnostic = struct {
    circuit: Circuit.Id,
    net: Circuit.NetId,
};

const HierarchyDiagnostic = union(enum) {
    unconnected_input: HierarchyPinDiagnostic,
    unconnected_output: HierarchyPinDiagnostic,

    undriven_net: HierarchyNetDiagnostic,
    driven_input: HierarchyNetDiagnostic,
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

pub fn compileProject(
    allocator: std.mem.Allocator,
    project: *const Project,
    root_id: Circuit.Id,
) !FlatCompilation {
    try validateHierarchy(allocator, project, root_id);

    const root = project.getConst(root_id) orelse return error.InvalidCircuit;
    const chip_count = try countPrimitiveNodes(project, root_id);
    const input_count = try countPrimitiveInputs(project, root_id);
    const chip_specs = try allocator.alloc(ChipSpec, chip_count);
    defer allocator.free(chip_specs);

    const inputs = try allocator.alloc(BusIndex, input_count);
    defer allocator.free(inputs);

    const root_bus_map = try allocator.alloc(BusIndex, root.nets.values.items.len);
    defer allocator.free(root_bus_map);

    for (root_bus_map, 0..) |*bus, i| {
        if (i > std.math.maxInt(u32)) {
            return error.TopologyTooLarge;
        }

        bus.* = @enumFromInt(i);
    }

    if (root_bus_map.len > std.math.maxInt(u32)) {
        return error.TopologyTooLarge;
    }

    var next_bus: u32 = @intCast(root_bus_map.len);
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
        .topology = topology,
        .input_buses = input_buses,
        .output_buses = output_buses,
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

    for (bus_map) |*bus| {
        bus.* = @enumFromInt(invalid);
    }

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

fn emitPrimitiveNodes(
    circuit: *const Circuit,
    bus_map: []const BusIndex,
    chip_specs: []ChipSpec,
    inputs: []BusIndex,
    chip_cursor: *usize,
    input_cursor: *usize,
) !void {
    std.debug.assert(bus_map.len == circuit.nets.values.items.len);

    for (circuit.nodes.values.items) |node| {
        const op = switch (node.kind) {
            .primitive => |op| op,
            .subcircuit => return error.NestedSubcircuit,
        };

        const node_input_count = node.inputCount();
        const node_output_count = node.outputCount();

        if (node_output_count != 1) {
            return error.UnsupportedOutputCount;
        }

        std.debug.assert(chip_cursor.* < chip_specs.len);
        std.debug.assert(input_cursor.* + node_input_count <= inputs.len);

        const input_start = input_cursor.*;

        for (0..node_input_count) |port| {
            const net_id = node.connections[port] orelse unreachable;
            const dense_index = circuit.nets.denseIndex(net_id) orelse unreachable;

            inputs[input_start + port] = bus_map[dense_index];
        }

        const output_net = node.connections[node_input_count] orelse unreachable;
        const output_dense_index = circuit.nets.denseIndex(output_net) orelse unreachable;

        chip_specs[chip_cursor.*] = .{
            .op = op,
            .inputs = inputs[input_start .. input_start + node_input_count],
            .output = bus_map[output_dense_index],
        };

        chip_cursor.* += 1;
        input_cursor.* += node_input_count;
    }
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
                const child_bus_map = try makeChildBusMap(
                    allocator,
                    child,
                    &node,
                    circuit,
                    bus_map,
                    next_bus,
                );
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

fn validateHierarchyDiagnostics(
    allocator: std.mem.Allocator,
    project: *const Project,
    circuit_id: Circuit.Id,
    visited: *std.bit_set.DynamicBitSetUnmanaged,
    diagnostics: *std.ArrayListUnmanaged(HierarchyDiagnostic),
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
                try validateHierarchyDiagnostics(
                    allocator,
                    project,
                    child_id,
                    visited,
                    diagnostics,
                );
            },
        }
    }
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

test "compiler counts primitive nodes through hierarchy" {
    var project =
        Project.init(std.testing.allocator);
    defer project.deinit();

    const child_id = try project.addCircuit();
    const parent_id = try project.addCircuit();

    {
        const child = project.get(child_id).?;

        _ = try child.addNode(
            .not1,
            .{ .x = 0, .y = 0 },
        );

        _ = try child.addNode(
            .and2,
            .{ .x = 100, .y = 0 },
        );
    }

    {
        const child = project.getConst(child_id).?;
        const parent = project.get(parent_id).?;

        _ = try parent.addNode(
            .xor2,
            .{ .x = 0, .y = 0 },
        );

        _ = try parent.addSubcircuitNode(
            child_id,
            child,
            .{ .x = 100, .y = 0 },
        );
    }

    try std.testing.expectEqual(
        @as(usize, 3),
        try countPrimitiveNodes(
            &project,
            parent_id,
        ),
    );
}

test "subcircuit interface maps onto parent buses" {
    var project =
        Project.init(std.testing.allocator);
    defer project.deinit();

    const child_id = try project.addCircuit();
    const parent_id = try project.addCircuit();

    const child = project.get(child_id).?;

    const child_in = try child.addNet();
    const child_mid = try child.addNet();
    const child_out = try child.addNet();

    _ = try child.addInput(child_in);
    _ = try child.addOutput(child_out);

    const first = try child.addNode(
        .not1,
        .{ .x = 0, .y = 0 },
    );

    const second = try child.addNode(
        .not1,
        .{ .x = 100, .y = 0 },
    );

    try child.connectInput(
        first,
        0,
        child_in,
    );

    try child.connectOutput(
        first,
        0,
        child_mid,
    );

    try child.connectInput(
        second,
        0,
        child_mid,
    );

    try child.connectOutput(
        second,
        0,
        child_out,
    );

    const parent = project.get(parent_id).?;

    const a = try parent.addNet();
    const b = try parent.addNet();

    const instance = try parent.addSubcircuitNode(
        child_id,
        child,
        .{ .x = 0, .y = 0 },
    );

    try parent.connectInput(
        instance,
        0,
        a,
    );

    try parent.connectOutput(
        instance,
        0,
        b,
    );

    const parent_bus_map = [_]BusIndex{
        @enumFromInt(0),
        @enumFromInt(1),
    };

    var next_bus: u32 = 2;

    const instance_node =
        parent.nodes.get(instance).?;

    const child_bus_map =
        try makeChildBusMap(
            std.testing.allocator,
            child,
            instance_node,
            parent,
            &parent_bus_map,
            &next_bus,
        );

    defer std.testing.allocator.free(
        child_bus_map,
    );

    const child_in_dense =
        child.nets.denseIndex(child_in).?;

    const child_mid_dense =
        child.nets.denseIndex(child_mid).?;

    const child_out_dense =
        child.nets.denseIndex(child_out).?;

    try std.testing.expectEqual(
        @as(u32, 0),
        @intFromEnum(
            child_bus_map[child_in_dense],
        ),
    );

    try std.testing.expectEqual(
        @as(u32, 1),
        @intFromEnum(
            child_bus_map[child_out_dense],
        ),
    );

    try std.testing.expectEqual(
        @as(u32, 2),
        @intFromEnum(
            child_bus_map[child_mid_dense],
        ),
    );

    try std.testing.expectEqual(
        @as(u32, 3),
        next_bus,
    );
}

test "primitive nodes emit through remapped buses" {
    var child =
        Circuit.init(std.testing.allocator);
    defer child.deinit();

    const input = try child.addNet();
    const middle = try child.addNet();
    const output = try child.addNet();

    const first = try child.addNode(
        .not1,
        .{ .x = 0, .y = 0 },
    );

    const second = try child.addNode(
        .not1,
        .{ .x = 100, .y = 0 },
    );

    try child.connectInput(
        first,
        0,
        input,
    );

    try child.connectOutput(
        first,
        0,
        middle,
    );

    try child.connectInput(
        second,
        0,
        middle,
    );

    try child.connectOutput(
        second,
        0,
        output,
    );

    // Flat buses:
    //
    // parent input  = 0
    // parent output = 1
    // child middle  = 2

    var bus_map =
        try std.testing.allocator.alloc(
            BusIndex,
            child.nets.values.items.len,
        );
    defer std.testing.allocator.free(
        bus_map,
    );

    bus_map[
        child.nets.denseIndex(input).?
    ] = @enumFromInt(0);

    bus_map[
        child.nets.denseIndex(middle).?
    ] = @enumFromInt(2);

    bus_map[
        child.nets.denseIndex(output).?
    ] = @enumFromInt(1);

    var chip_specs: [2]ChipSpec = undefined;
    var inputs: [2]BusIndex = undefined;

    var chip_cursor: usize = 0;
    var input_cursor: usize = 0;

    try emitPrimitiveNodes(
        &child,
        bus_map,
        &chip_specs,
        &inputs,
        &chip_cursor,
        &input_cursor,
    );

    try std.testing.expectEqual(
        @as(usize, 2),
        chip_cursor,
    );

    try std.testing.expectEqual(
        @as(usize, 2),
        input_cursor,
    );

    try std.testing.expectEqual(
        @as(u32, 0),
        @intFromEnum(
            chip_specs[0].inputs[0],
        ),
    );

    try std.testing.expectEqual(
        @as(u32, 2),
        @intFromEnum(
            chip_specs[0].output,
        ),
    );

    try std.testing.expectEqual(
        @as(u32, 2),
        @intFromEnum(
            chip_specs[1].inputs[0],
        ),
    );

    try std.testing.expectEqual(
        @as(u32, 1),
        @intFromEnum(
            chip_specs[1].output,
        ),
    );
}

test "one level subcircuit flatten runs" {
    var project =
        Project.init(std.testing.allocator);
    defer project.deinit();

    const child_id = try project.addCircuit();
    const parent_id = try project.addCircuit();

    // Child:
    //
    // IN -> NOT -> MIDDLE -> NOT -> OUT

    const child = project.get(child_id).?;

    const child_input = try child.addNet();
    const child_middle = try child.addNet();
    const child_output = try child.addNet();

    _ = try child.addInput(child_input);
    _ = try child.addOutput(child_output);

    const first = try child.addNode(
        .not1,
        .{ .x = 0, .y = 0 },
    );

    const second = try child.addNode(
        .not1,
        .{ .x = 100, .y = 0 },
    );

    try child.connectInput(
        first,
        0,
        child_input,
    );

    try child.connectOutput(
        first,
        0,
        child_middle,
    );

    try child.connectInput(
        second,
        0,
        child_middle,
    );

    try child.connectOutput(
        second,
        0,
        child_output,
    );

    // Parent:
    //
    // A -> [ child ] -> B

    const parent = project.get(parent_id).?;

    const a = try parent.addNet();
    const b = try parent.addNet();

    _ = try parent.addInput(a);
    _ = try parent.addOutput(b);

    const instance = try parent.addSubcircuitNode(
        child_id,
        child,
        .{ .x = 0, .y = 0 },
    );

    try parent.connectInput(
        instance,
        0,
        a,
    );

    try parent.connectOutput(
        instance,
        0,
        b,
    );

    // Root buses are assigned first.
    const parent_bus_map = [_]BusIndex{
        @enumFromInt(0),
        @enumFromInt(1),
    };

    var next_bus: u32 = 2;

    const instance_node =
        parent.nodes.get(instance).?;

    const child_bus_map =
        try makeChildBusMap(
            std.testing.allocator,
            child,
            instance_node,
            parent,
            &parent_bus_map,
            &next_bus,
        );
    defer std.testing.allocator.free(
        child_bus_map,
    );

    // Flatten result:
    //
    // A          = bus 0
    // B          = bus 1
    // child mid  = bus 2

    try std.testing.expectEqual(
        @as(u32, 3),
        next_bus,
    );

    var chip_specs: [2]ChipSpec =
        undefined;

    var inputs: [2]BusIndex =
        undefined;

    var chip_cursor: usize = 0;
    var input_cursor: usize = 0;

    try emitPrimitiveNodes(
        child,
        child_bus_map,
        &chip_specs,
        &inputs,
        &chip_cursor,
        &input_cursor,
    );

    try std.testing.expectEqual(
        @as(usize, 2),
        chip_cursor,
    );

    var topology = try Topology.init(
        std.testing.allocator,
        next_bus,
        &chip_specs,
    );
    errdefer topology.deinit(
        std.testing.allocator,
    );

    var runtime = try CompiledCircuit.init(
        std.testing.allocator,
        &topology,
    );
    defer runtime.deinit();

    const input_bus: BusIndex =
        @enumFromInt(0);

    const output_bus: BusIndex =
        @enumFromInt(1);

    try runtime.store(
        input_bus,
        false,
    );

    try runtime.settle(8);

    try std.testing.expectEqual(
        false,
        try runtime.load(output_bus),
    );

    try runtime.store(
        input_bus,
        true,
    );

    try runtime.settle(8);

    try std.testing.expectEqual(
        true,
        try runtime.load(output_bus),
    );

    try runtime.store(
        input_bus,
        false,
    );

    try runtime.settle(8);

    try std.testing.expectEqual(
        false,
        try runtime.load(output_bus),
    );
}

test "recursive subcircuit flatten runs" {
    var project =
        Project.init(std.testing.allocator);
    defer project.deinit();

    const leaf_id =
        try project.addCircuit();

    const middle_id =
        try project.addCircuit();

    const root_id =
        try project.addCircuit();

    // Leaf:
    //
    // IN -> NOT -> OUT

    const leaf = project.get(leaf_id).?;

    const leaf_in = try leaf.addNet();
    const leaf_out = try leaf.addNet();

    _ = try leaf.addInput(leaf_in);
    _ = try leaf.addOutput(leaf_out);

    const not_node = try leaf.addNode(
        .not1,
        .{ .x = 0, .y = 0 },
    );

    try leaf.connectInput(
        not_node,
        0,
        leaf_in,
    );

    try leaf.connectOutput(
        not_node,
        0,
        leaf_out,
    );

    // Middle:
    //
    // IN -> [leaf] -> X -> [leaf] -> OUT

    const middle = project.get(middle_id).?;

    const middle_in = try middle.addNet();
    const middle_x = try middle.addNet();
    const middle_out = try middle.addNet();

    _ = try middle.addInput(middle_in);
    _ = try middle.addOutput(middle_out);

    const first = try middle.addSubcircuitNode(
        leaf_id,
        leaf,
        .{ .x = 0, .y = 0 },
    );

    const second = try middle.addSubcircuitNode(
        leaf_id,
        leaf,
        .{ .x = 100, .y = 0 },
    );

    try middle.connectInput(
        first,
        0,
        middle_in,
    );

    try middle.connectOutput(
        first,
        0,
        middle_x,
    );

    try middle.connectInput(
        second,
        0,
        middle_x,
    );

    try middle.connectOutput(
        second,
        0,
        middle_out,
    );

    // Root:
    //
    // A -> [middle] -> B

    const root = project.get(root_id).?;

    const a = try root.addNet();
    const b = try root.addNet();

    _ = try root.addInput(a);
    _ = try root.addOutput(b);

    const instance =
        try root.addSubcircuitNode(
            middle_id,
            middle,
            .{ .x = 0, .y = 0 },
        );

    try root.connectInput(
        instance,
        0,
        a,
    );

    try root.connectOutput(
        instance,
        0,
        b,
    );

    const chip_count =
        try countPrimitiveNodes(
            &project,
            root_id,
        );

    const input_count =
        try countPrimitiveInputs(
            &project,
            root_id,
        );

    try std.testing.expectEqual(
        @as(usize, 2),
        chip_count,
    );

    try std.testing.expectEqual(
        @as(usize, 2),
        input_count,
    );

    const chip_specs =
        try std.testing.allocator.alloc(
            ChipSpec,
            chip_count,
        );
    defer std.testing.allocator.free(
        chip_specs,
    );

    const inputs =
        try std.testing.allocator.alloc(
            BusIndex,
            input_count,
        );
    defer std.testing.allocator.free(
        inputs,
    );

    const root_bus_map =
        try std.testing.allocator.alloc(
            BusIndex,
            root.nets.values.items.len,
        );
    defer std.testing.allocator.free(
        root_bus_map,
    );

    for (root_bus_map, 0..) |*bus, i| {
        bus.* = @enumFromInt(i);
    }

    var next_bus: u32 =
        @intCast(root_bus_map.len);

    var chip_cursor: usize = 0;
    var input_cursor: usize = 0;

    try emitCircuit(
        std.testing.allocator,
        &project,
        root_id,
        root_bus_map,
        chip_specs,
        inputs,
        &chip_cursor,
        &input_cursor,
        &next_bus,
    );

    try std.testing.expectEqual(
        @as(usize, 2),
        chip_cursor,
    );

    // Root A/B plus middle's internal X.
    try std.testing.expectEqual(
        @as(u32, 3),
        next_bus,
    );

    try std.testing.expectEqual(
        @as(u32, 0),
        @intFromEnum(
            chip_specs[0].inputs[0],
        ),
    );

    try std.testing.expectEqual(
        @as(u32, 2),
        @intFromEnum(
            chip_specs[0].output,
        ),
    );

    try std.testing.expectEqual(
        @as(u32, 2),
        @intFromEnum(
            chip_specs[1].inputs[0],
        ),
    );

    try std.testing.expectEqual(
        @as(u32, 1),
        @intFromEnum(
            chip_specs[1].output,
        ),
    );

    var topology = try Topology.init(
        std.testing.allocator,
        next_bus,
        chip_specs,
    );
    errdefer topology.deinit(
        std.testing.allocator,
    );

    var runtime = try CompiledCircuit.init(
        std.testing.allocator,
        &topology,
    );
    defer runtime.deinit();

    const a_bus: BusIndex =
        @enumFromInt(0);

    const b_bus: BusIndex =
        @enumFromInt(1);

    try runtime.store(
        a_bus,
        false,
    );

    try runtime.settle(8);

    try std.testing.expectEqual(
        false,
        try runtime.load(b_bus),
    );

    try runtime.store(
        a_bus,
        true,
    );

    try runtime.settle(8);

    try std.testing.expectEqual(
        true,
        try runtime.load(b_bus),
    );
}

test "compile project flattens nested subcircuits and runs" {
    var project =
        Project.init(std.testing.allocator);
    defer project.deinit();

    const leaf_id = try project.addCircuit();
    const middle_id = try project.addCircuit();
    const root_id = try project.addCircuit();

    // Leaf:
    //
    // IN -> NOT -> OUT

    {
        const leaf = project.get(leaf_id).?;

        const input = try leaf.addNet();
        const output = try leaf.addNet();

        _ = try leaf.addInput(input);
        _ = try leaf.addOutput(output);

        const node = try leaf.addNode(
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

    // Middle:
    //
    // IN -> [leaf] -> OUT

    {
        const leaf =
            project.getConst(leaf_id).?;

        const middle =
            project.get(middle_id).?;

        const input = try middle.addNet();
        const output = try middle.addNet();

        _ = try middle.addInput(input);
        _ = try middle.addOutput(output);

        const node =
            try middle.addSubcircuitNode(
                leaf_id,
                leaf,
                .{ .x = 0, .y = 0 },
            );

        try middle.connectInput(
            node,
            0,
            input,
        );

        try middle.connectOutput(
            node,
            0,
            output,
        );
    }

    // Root:
    //
    // A -> [middle] -> B

    {
        const middle =
            project.getConst(middle_id).?;

        const root =
            project.get(root_id).?;

        const a = try root.addNet();
        const b = try root.addNet();

        _ = try root.addInput(a);
        _ = try root.addOutput(b);

        const node =
            try root.addSubcircuitNode(
                middle_id,
                middle,
                .{ .x = 0, .y = 0 },
            );

        try root.connectInput(
            node,
            0,
            a,
        );

        try root.connectOutput(
            node,
            0,
            b,
        );
    }

    var compilation =
        try compileProject(
            std.testing.allocator,
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

    try runtime.store(
        input_bus,
        false,
    );

    try runtime.settle(8);

    try std.testing.expectEqual(
        true,
        try runtime.load(output_bus),
    );
}

test "compile project rejects subcircuit cycle" {
    var project =
        Project.init(std.testing.allocator);
    defer project.deinit();

    const a_id = try project.addCircuit();
    const b_id = try project.addCircuit();

    {
        const b = project.getConst(b_id).?;
        const a = project.get(a_id).?;

        _ = try a.addSubcircuitNode(
            b_id,
            b,
            .{ .x = 0, .y = 0 },
        );
    }

    {
        const a = project.getConst(a_id).?;
        const b = project.get(b_id).?;

        _ = try b.addSubcircuitNode(
            a_id,
            a,
            .{ .x = 0, .y = 0 },
        );
    }

    try std.testing.expectError(
        error.CircuitCycle,
        compileProject(
            std.testing.allocator,
            &project,
            a_id,
        ),
    );
}

test "compile project rejects stale subcircuit id" {
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
        project.removeCircuit(child_id),
    );

    try std.testing.expect(
        project.get(child_id) == null,
    );

    // Reuse the sparse slot with a new generation.
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
        compileProject(
            std.testing.allocator,
            &project,
            root_id,
        ),
    );
}

test "compile project rejects changed subcircuit interface" {
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

        const input = try child.addNet();
        const output = try child.addNet();

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

    // Mutate the child interface after the instance was created.
    {
        const child =
            project.get(child_id).?;

        const extra = try child.addNet();

        _ = try child.addInput(extra);
    }

    try std.testing.expectError(
        error.SubcircuitInterfaceChanged,
        compileProject(
            std.testing.allocator,
            &project,
            root_id,
        ),
    );
}

test "hierarchy validation finds unconnected pin in child" {
    var project =
        Project.init(std.testing.allocator);
    defer project.deinit();

    const child_id =
        try project.addCircuit();

    const root_id =
        try project.addCircuit();

    const child_node = blk: {
        const child =
            project.get(child_id).?;

        const node = try child.addNode(
            .not1,
            .{ .x = 0, .y = 0 },
        );

        break :blk node;
    };

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

    var visited =
        try std.bit_set.DynamicBitSetUnmanaged.initEmpty(
            std.testing.allocator,
            project.circuits.slots.items.len,
        );
    defer visited.deinit(
        std.testing.allocator,
    );

    var diagnostics: std.ArrayListUnmanaged(HierarchyDiagnostic) =
        .empty;
    defer diagnostics.deinit(
        std.testing.allocator,
    );

    try validateHierarchyDiagnostics(
        std.testing.allocator,
        &project,
        root_id,
        &visited,
        &diagnostics,
    );

    try std.testing.expectEqual(
        @as(usize, 2),
        diagnostics.items.len,
    );

    switch (diagnostics.items[0]) {
        .unconnected_input => |pin| {
            try std.testing.expect(
                pin.circuit.eql(child_id),
            );

            try std.testing.expect(
                pin.node.eql(child_node),
            );

            try std.testing.expectEqual(
                @as(u16, 0),
                pin.port,
            );
        },

        else => return error.UnexpectedDiagnostic,
    }

    switch (diagnostics.items[1]) {
        .unconnected_output => |pin| {
            try std.testing.expect(
                pin.circuit.eql(child_id),
            );

            try std.testing.expect(
                pin.node.eql(child_node),
            );

            try std.testing.expectEqual(
                @as(u16, 0),
                pin.port,
            );
        },

        else => return error.UnexpectedDiagnostic,
    }
}

test "hierarchy validation finds undriven net in child" {
    var project =
        Project.init(std.testing.allocator);
    defer project.deinit();

    const child_id =
        try project.addCircuit();

    const root_id =
        try project.addCircuit();

    var input_net: Circuit.NetId =
        undefined;

    {
        const child =
            project.get(child_id).?;

        input_net = try child.addNet();
        const output = try child.addNet();

        const node = try child.addNode(
            .not1,
            .{ .x = 0, .y = 0 },
        );

        try child.connectInput(
            node,
            0,
            input_net,
        );

        try child.connectOutput(
            node,
            0,
            output,
        );

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

    var visited =
        try std.bit_set.DynamicBitSetUnmanaged.initEmpty(
            std.testing.allocator,
            project.circuits.slots.items.len,
        );
    defer visited.deinit(
        std.testing.allocator,
    );

    var diagnostics: std.ArrayListUnmanaged(HierarchyDiagnostic) =
        .empty;
    defer diagnostics.deinit(
        std.testing.allocator,
    );

    try validateHierarchyDiagnostics(
        std.testing.allocator,
        &project,
        root_id,
        &visited,
        &diagnostics,
    );

    try std.testing.expectEqual(
        @as(usize, 2),
        diagnostics.items.len,
    );

    // Root instance has one unconnected output.
    // Child contributes one undriven net.

    switch (diagnostics.items[1]) {
        .undriven_net => |diagnostic| {
            try std.testing.expect(
                diagnostic.circuit.eql(
                    child_id,
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
}
