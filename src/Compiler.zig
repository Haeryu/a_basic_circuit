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

pub const InstancePathEntry = struct {
    circuit: Circuit.Id,
    node: Circuit.NodeId,
};

pub const ChipOrigin = struct {
    path_start: u32,
    path_len: u32,

    circuit: Circuit.Id,
    node: Circuit.NodeId,
};

pub const NetOrigin = struct {
    path_start: u32,
    path_len: u32,

    circuit: Circuit.Id,
    net: Circuit.NetId,

    bus: BusIndex,
};

pub const Compilation = struct {
    runtime: CompiledCircuit,

    input_buses: []BusIndex,
    output_buses: []BusIndex,

    chip_origins: []ChipOrigin,
    net_origins: []NetOrigin,
    origin_path: []InstancePathEntry,

    pub fn deinit(self: *Compilation, allocator: std.mem.Allocator) void {
        self.runtime.deinit();

        allocator.free(self.origin_path);
        allocator.free(self.net_origins);
        allocator.free(self.chip_origins);

        allocator.free(self.output_buses);
        allocator.free(self.input_buses);

        self.* = undefined;
    }
};

pub const CompileResult = union(enum) {
    success: Compilation,
    failure: CompileFailure,
};

const BusAliases = struct {
    parents: std.ArrayListUnmanaged(u32) = .empty,

    fn add(self: *BusAliases, allocator: std.mem.Allocator) !BusIndex {
        if (self.parents.items.len >= std.math.maxInt(u32)) {
            return error.TopologyTooLarge;
        }

        const index: u32 = @intCast(self.parents.items.len);

        try self.parents.append(allocator, index);

        return @enumFromInt(index);
    }

    fn find(self: *BusAliases, bus: BusIndex) BusIndex {
        var index: u32 = @intFromEnum(bus);
        var root = index;

        while (self.parents.items[@intCast(root)] != root) {
            root = self.parents.items[@intCast(root)];
        }

        while (index != root) {
            const i: usize = @intCast(index);
            const parent = self.parents.items[i];

            self.parents.items[i] = root;
            index = parent;
        }

        return @enumFromInt(root);
    }

    fn merge(self: *BusAliases, a: BusIndex, b: BusIndex) void {
        const a_root = self.find(a);
        const b_root = self.find(b);

        if (a_root == b_root) {
            return;
        }

        self.parents.items[@intCast(@intFromEnum(b_root))] = @intFromEnum(a_root);
    }
};

pub fn compile(
    allocator: std.mem.Allocator,
    project: *const Project,
    root_id: Circuit.Id,
) !CompileResult {
    var build: Build = .{
        .allocator = allocator,
        .project = project,
        .scratch = .init(allocator),
    };
    defer build.deinit();
    const scratch = build.scratch.allocator();

    const counts = try validateHierarchy(scratch, project, root_id);
    const root = project.getConst(root_id) orelse return error.InvalidCircuit;
    var visited: std.bit_set.DynamicBitSetUnmanaged = try .initEmpty(
        scratch,
        project.circuits.slots.items.len,
    );
    var diagnostics: std.ArrayListUnmanaged(Diagnostic) = .empty;
    try validateDiagnostics(scratch, project, root_id, &visited, &diagnostics);

    if (diagnostics.items.len != 0) {
        return .{ .failure = .{
            .diagnostics = try allocator.dupe(Diagnostic, diagnostics.items),
        } };
    }

    try build.chips.ensureTotalCapacityPrecise(allocator, counts.chips);
    try build.inputs.ensureTotalCapacityPrecise(allocator, counts.inputs);
    try build.chip_origins.ensureTotalCapacityPrecise(allocator, counts.chips);
    try build.net_origins.ensureTotalCapacityPrecise(allocator, counts.nets);

    const root_bus_count = root.nets.values.items.len;
    if (root_bus_count > std.math.maxInt(u32)) return error.TopologyTooLarge;
    const root_bus_map = try scratch.alloc(BusIndex, root_bus_count);
    for (root_bus_map) |*bus| bus.* = try build.aliases.add(allocator);

    try build.emitCircuit(root_id, root_bus_map);
    return .{ .success = try build.finish(root, root_bus_map) };
}

// Scratch holds validation data and temporary bus maps. Output lists transfer
// ownership to Compilation. Inputs are reserved once before emission and only
// appended within that capacity, so ChipSpec input slices remain valid.
const Build = struct {
    allocator: std.mem.Allocator,
    project: *const Project,
    scratch: std.heap.ArenaAllocator,
    chips: std.ArrayListUnmanaged(ChipSpec) = .empty,
    inputs: std.ArrayListUnmanaged(BusIndex) = .empty,
    aliases: BusAliases = .{},
    path: std.ArrayListUnmanaged(InstancePathEntry) = .empty,

    chip_origins: std.ArrayListUnmanaged(ChipOrigin) = .empty,
    net_origins: std.ArrayListUnmanaged(NetOrigin) = .empty,
    origin_path: std.ArrayListUnmanaged(InstancePathEntry) = .empty,

    fn deinit(self: *Build) void {
        self.origin_path.deinit(self.allocator);
        self.net_origins.deinit(self.allocator);
        self.chip_origins.deinit(self.allocator);
        self.path.deinit(self.allocator);
        self.aliases.parents.deinit(self.allocator);
        self.inputs.deinit(self.allocator);
        self.chips.deinit(self.allocator);
        self.scratch.deinit();
        self.* = undefined;
    }

    fn emitCircuit(self: *Build, circuit_id: Circuit.Id, bus_map: []const BusIndex) !void {
        const circuit = self.project.getConst(circuit_id) orelse return error.InvalidCircuit;
        const scratch = self.scratch.allocator();
        std.debug.assert(bus_map.len == circuit.nets.values.items.len);

        // Every net and primitive in this instance uses the same path.
        const path_end = std.math.add(usize, self.origin_path.items.len, self.path.items.len) catch
            return error.TopologyTooLarge;
        if (path_end > std.math.maxInt(u32)) return error.TopologyTooLarge;
        const path_start: u32 = @intCast(self.origin_path.items.len);
        const path_len: u32 = @intCast(self.path.items.len);
        try self.origin_path.appendSlice(self.allocator, self.path.items);

        for (circuit.nets.values.items, 0..) |_, dense_index| {
            self.net_origins.appendAssumeCapacity(.{
                .path_start = path_start,
                .path_len = path_len,
                .circuit = circuit_id,
                .net = circuit.nets.handleAtDenseIndex(dense_index) orelse unreachable,
                .bus = bus_map[dense_index],
            });
        }

        for (circuit.nodes.values.items, 0..) |node, dense_index| {
            const node_id = circuit.nodes.handleAtDenseIndex(dense_index) orelse unreachable;
            switch (node.kind) {
                .primitive => |op| {
                    if (node.outputCount() != 1) return error.UnsupportedOutputCount;
                    if (node.input_count != op.inputCount()) return error.InvalidArity;
                    const input_end = std.math.add(usize, self.inputs.items.len, node.input_count) catch
                        return error.TopologyTooLarge;
                    if (input_end > std.math.maxInt(u32) or self.chips.items.len >= std.math.maxInt(u32))
                        return error.TopologyTooLarge;
                    const input_start: u32 = @intCast(self.inputs.items.len);
                    for (node.connections[0..node.input_count]) |connection| {
                        const dense_net = circuit.nets.denseIndex(connection.?) orelse unreachable;
                        self.inputs.appendAssumeCapacity(bus_map[dense_net]);
                    }
                    const output_dense = circuit.nets.denseIndex(node.connections[node.input_count].?) orelse unreachable;
                    self.chips.appendAssumeCapacity(.{
                        .op = op,
                        .inputs = self.inputs.items[input_start..input_end],
                        .output = bus_map[output_dense],
                    });
                    self.chip_origins.appendAssumeCapacity(.{
                        .path_start = path_start,
                        .path_len = path_len,
                        .circuit = circuit_id,
                        .node = node_id,
                    });
                },
                .subcircuit => |child_id| {
                    const child = self.project.getConst(child_id) orelse return error.InvalidCircuit;
                    const child_bus_map = try self.makeChildBusMap(child, &node, circuit, bus_map);
                    defer scratch.free(child_bus_map);
                    try self.path.append(self.allocator, .{ .circuit = circuit_id, .node = node_id });
                    defer self.path.items.len -= 1;
                    try self.emitCircuit(child_id, child_bus_map);
                },
            }
        }
    }

    fn makeChildBusMap(
        self: *Build,
        child: *const Circuit,
        parent_node: *const Circuit.Node,
        parent: *const Circuit,
        parent_bus_map: []const BusIndex,
    ) ![]BusIndex {
        const scratch = self.scratch.allocator();
        const bus_map = try scratch.alloc(BusIndex, child.nets.values.items.len);
        const invalid = std.math.maxInt(u32);
        @memset(bus_map, @enumFromInt(invalid));

        for (child.inputs.items, 0..) |port, i| {
            const child_dense = child.nets.denseIndex(port.net) orelse unreachable;
            const parent_dense = parent.nets.denseIndex(parent_node.connections[i].?) orelse unreachable;
            bus_map[child_dense] = parent_bus_map[parent_dense];
        }
        for (child.outputs.items, 0..) |port, i| {
            const child_dense = child.nets.denseIndex(port.net) orelse unreachable;
            const parent_dense = parent.nets.denseIndex(parent_node.connections[@as(usize, parent_node.input_count) + i].?) orelse unreachable;
            if (@intFromEnum(bus_map[child_dense]) != invalid) {
                self.aliases.merge(bus_map[child_dense], parent_bus_map[parent_dense]);
            } else {
                bus_map[child_dense] = parent_bus_map[parent_dense];
            }
        }
        for (bus_map) |*bus| {
            if (@intFromEnum(bus.*) == invalid) bus.* = try self.aliases.add(self.allocator);
        }
        return bus_map;
    }

    fn finish(self: *Build, root: *const Circuit, root_bus_map: []const BusIndex) !Compilation {
        const allocator = self.allocator;
        for (self.inputs.items) |*input| input.* = self.aliases.find(input.*);
        for (self.net_origins.items) |*origin| origin.bus = self.aliases.find(origin.bus);

        for (self.chips.items) |*chip| chip.output = self.aliases.find(chip.output);

        const input_buses = try allocator.alloc(BusIndex, root.inputs.items.len);
        errdefer allocator.free(input_buses);
        const output_buses = try allocator.alloc(BusIndex, root.outputs.items.len);
        errdefer allocator.free(output_buses);
        for (root.inputs.items, input_buses) |port, *bus| {
            bus.* = self.aliases.find(root_bus_map[root.nets.denseIndex(port.net).?]);
        }
        for (root.outputs.items, output_buses) |port, *bus| {
            bus.* = self.aliases.find(root_bus_map[root.nets.denseIndex(port.net).?]);
        }

        const chip_origins = try self.chip_origins.toOwnedSlice(allocator);
        errdefer allocator.free(chip_origins);
        const net_origins = try self.net_origins.toOwnedSlice(allocator);
        errdefer allocator.free(net_origins);
        const origin_path = try self.origin_path.toOwnedSlice(allocator);
        errdefer allocator.free(origin_path);

        var topology = try Topology.init(allocator, self.aliases.parents.items.len, self.chips.items);
        errdefer topology.deinit(allocator);
        const runtime = try CompiledCircuit.init(allocator, &topology);
        return .{
            .runtime = runtime,
            .input_buses = input_buses,
            .output_buses = output_buses,
            .chip_origins = chip_origins,
            .net_origins = net_origins,
            .origin_path = origin_path,
        };
    }
};

const Counts = struct {
    chips: usize = 0,
    inputs: usize = 0,
    nets: usize = 0,

    fn add(self: *Counts, other: Counts) !void {
        self.chips = std.math.add(usize, self.chips, other.chips) catch return error.TopologyTooLarge;
        self.inputs = std.math.add(usize, self.inputs, other.inputs) catch return error.TopologyTooLarge;
        self.nets = std.math.add(usize, self.nets, other.nets) catch return error.TopologyTooLarge;
        if (self.chips > std.math.maxInt(u32) or self.inputs > std.math.maxInt(u32))
            return error.TopologyTooLarge;
    }
};

const Definition = struct {
    state: enum { unseen, active, complete } = .unseen,
    counts: Counts = .{},
};

fn validateHierarchy(
    allocator: std.mem.Allocator,
    project: *const Project,
    root_id: Circuit.Id,
) !Counts {
    const definitions = try allocator.alloc(Definition, project.circuits.slots.items.len);
    defer allocator.free(definitions);
    @memset(definitions, .{});
    return validateHierarchyRecursive(project, root_id, definitions);
}

fn validateHierarchyRecursive(
    project: *const Project,
    circuit_id: Circuit.Id,
    definitions: []Definition,
) !Counts {
    const circuit = project.getConst(circuit_id) orelse return error.InvalidCircuit;
    const definition = &definitions[@intCast(circuit_id.index)];
    switch (definition.state) {
        .active => return error.CircuitCycle,
        .complete => return definition.counts,
        .unseen => {},
    }
    definition.state = .active;
    var counts: Counts = .{ .nets = circuit.nets.values.items.len };
    for (circuit.nodes.values.items) |node| {
        switch (node.kind) {
            .primitive => try counts.add(.{ .chips = 1, .inputs = node.input_count }),
            .subcircuit => |child_id| {
                const child = project.getConst(child_id) orelse return error.InvalidCircuit;
                // Check each instance, including references to a cached definition.
                if (node.input_count != child.inputs.items.len or
                    node.outputCount() != child.outputs.items.len)
                    return error.SubcircuitInterfaceChanged;
                try counts.add(try validateHierarchyRecursive(project, child_id, definitions));
            },
        }
    }
    definition.* = .{ .state = .complete, .counts = counts };
    return counts;
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

    const NetUse = packed struct {
        is_input: bool = false,
        is_output: bool = false,
        consumed: bool = false,
    };
    const uses = try allocator.alloc(NetUse, bus_count);
    defer allocator.free(uses);
    @memset(uses, .{});

    for (circuit.inputs.items) |port| {
        const dense_index = circuit.nets.denseIndex(port.net) orelse unreachable;

        uses[dense_index].is_input = true;
    }

    for (circuit.outputs.items) |port| {
        const dense_index = circuit.nets.denseIndex(port.net) orelse unreachable;

        uses[dense_index].is_output = true;
    }

    for (circuit.nodes.values.items, 0..) |node, dense_index| {
        const node_id = circuit.nodes.handleAtDenseIndex(dense_index) orelse unreachable;
        const input_count = node.input_count;
        const output_count = node.outputCount();

        for (0..input_count) |port| {
            if (node.connections[port]) |net_id| {
                uses[circuit.nets.denseIndex(net_id).?].consumed = true;
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
        const is_input = uses[dense_index].is_input;
        const is_output = uses[dense_index].is_output;

        if (is_input and net.driver != null) {
            try diagnostics.append(allocator, .{
                .driven_input = .{
                    .circuit = circuit_id,
                    .net = net_id,
                },
            });

            continue;
        }

        if (net.driver == null and !is_input and (uses[dense_index].consumed or is_output)) {
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
        compilation.runtime.topology.ops.len,
    );

    try std.testing.expectEqual(
        @as(usize, 1),
        compilation.input_buses.len,
    );

    try std.testing.expectEqual(
        @as(usize, 1),
        compilation.output_buses.len,
    );

    const runtime = &compilation.runtime;

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
        compilation.runtime.topology.ops.len,
    );

    const runtime = &compilation.runtime;

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
                        pin.circuit ==
                            child_id,
                    );

                    try std.testing.expect(
                        pin.node ==
                            child_node,
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
                        pin.circuit ==
                            child_id,
                    );

                    try std.testing.expect(
                        pin.node ==
                            child_node,
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
                        diagnostic.circuit ==
                            root_id,
                    );

                    try std.testing.expect(
                        diagnostic.net ==
                            input_net,
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
                        diagnostic.circuit ==
                            root_id,
                    );

                    try std.testing.expect(
                        diagnostic.net ==
                            driven_input,
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

test "subcircuit instances have independent internal buses" {
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

        const middle =
            try child.addNet();

        const output =
            try child.addNet();

        _ = try child.addInput(input);
        _ = try child.addOutput(output);

        const first =
            try child.addNode(
                .not1,
                .{ .x = 0, .y = 0 },
            );

        const second =
            try child.addNode(
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
    }

    {
        const child =
            project.getConst(child_id).?;

        const root =
            project.get(root_id).?;

        const a =
            try root.addNet();

        const b =
            try root.addNet();

        const x =
            try root.addNet();

        const y =
            try root.addNet();

        _ = try root.addInput(a);
        _ = try root.addInput(b);

        _ = try root.addOutput(x);
        _ = try root.addOutput(y);

        const first =
            try root.addSubcircuitNode(
                child_id,
                child,
                .{ .x = 0, .y = 0 },
            );

        const second =
            try root.addSubcircuitNode(
                child_id,
                child,
                .{ .x = 0, .y = 100 },
            );

        try root.connectInput(
            first,
            0,
            a,
        );

        try root.connectOutput(
            first,
            0,
            x,
        );

        try root.connectInput(
            second,
            0,
            b,
        );

        try root.connectOutput(
            second,
            0,
            y,
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

    // Each child contains two primitive NOT gates.
    try std.testing.expectEqual(
        @as(usize, 4),
        compilation.runtime.topology.ops.len,
    );

    // Root has four buses and each child instance
    // contributes one independent internal bus.
    try std.testing.expectEqual(
        @as(usize, 6),
        compilation.runtime.topology.consumer_offsets.len - 1,
    );

    const runtime = &compilation.runtime;

    const a =
        compilation.input_buses[0];

    const b =
        compilation.input_buses[1];

    const x =
        compilation.output_buses[0];

    const y =
        compilation.output_buses[1];

    try runtime.store(a, false);
    try runtime.store(b, true);

    try runtime.settle(8);

    try std.testing.expectEqual(
        false,
        try runtime.load(x),
    );

    try std.testing.expectEqual(
        true,
        try runtime.load(y),
    );

    try runtime.store(a, true);
    try runtime.store(b, false);

    try runtime.settle(8);

    try std.testing.expectEqual(
        true,
        try runtime.load(x),
    );

    try std.testing.expectEqual(
        false,
        try runtime.load(y),
    );
}

test "pass-through subcircuit aliases input and output" {
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

        const io =
            try child.addNet();

        _ = try child.addInput(io);
        _ = try child.addOutput(io);
    }

    {
        const child =
            project.getConst(child_id).?;

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
                child_id,
                child,
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
        @as(usize, 0),
        compilation.runtime.topology.ops.len,
    );

    try std.testing.expectEqual(
        compilation.input_buses[0],
        compilation.output_buses[0],
    );

    const runtime = &compilation.runtime;

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

    var aliased_count: usize = 0;

    for (compilation.net_origins) |origin| {
        if (origin.bus == compilation.input_buses[0]) {
            aliased_count += 1;
        }
    }

    try std.testing.expect(
        aliased_count >= 3,
    );
}

test "pass-through aliases primitive buses" {
    var project =
        Project.init(std.testing.allocator);
    defer project.deinit();

    const wire_id =
        try project.addCircuit();

    const root_id =
        try project.addCircuit();

    {
        const wire =
            project.get(wire_id).?;

        const io =
            try wire.addNet();

        _ = try wire.addInput(io);
        _ = try wire.addOutput(io);
    }

    {
        const wire =
            project.getConst(wire_id).?;

        const root =
            project.get(root_id).?;

        const input =
            try root.addNet();

        const before_not =
            try root.addNet();

        const after_not =
            try root.addNet();

        const output =
            try root.addNet();

        _ = try root.addInput(input);
        _ = try root.addOutput(output);

        const first =
            try root.addSubcircuitNode(
                wire_id,
                wire,
                .{ .x = 0, .y = 0 },
            );

        const not =
            try root.addNode(
                .not1,
                .{ .x = 100, .y = 0 },
            );

        const second =
            try root.addSubcircuitNode(
                wire_id,
                wire,
                .{ .x = 200, .y = 0 },
            );

        try root.connectInput(
            first,
            0,
            input,
        );

        try root.connectOutput(
            first,
            0,
            before_not,
        );

        try root.connectInput(
            not,
            0,
            before_not,
        );

        try root.connectOutput(
            not,
            0,
            after_not,
        );

        try root.connectInput(
            second,
            0,
            after_not,
        );

        try root.connectOutput(
            second,
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
        compilation.runtime.topology.ops.len,
    );

    const runtime = &compilation.runtime;

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

test "chip origins distinguish repeated nested instances" {
    var project =
        Project.init(std.testing.allocator);
    defer project.deinit();

    const leaf_id =
        try project.addCircuit();

    const middle_id =
        try project.addCircuit();

    const root_id =
        try project.addCircuit();

    var leaf_node: Circuit.NodeId = undefined;

    {
        const leaf =
            project.get(leaf_id).?;

        const input =
            try leaf.addNet();

        const output =
            try leaf.addNet();

        _ = try leaf.addInput(input);
        _ = try leaf.addOutput(output);

        leaf_node =
            try leaf.addNode(
                .not1,
                .{ .x = 0, .y = 0 },
            );

        try leaf.connectInput(
            leaf_node,
            0,
            input,
        );

        try leaf.connectOutput(
            leaf_node,
            0,
            output,
        );
    }

    var leaf_instance: Circuit.NodeId = undefined;

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

        leaf_instance =
            try middle.addSubcircuitNode(
                leaf_id,
                leaf,
                .{ .x = 0, .y = 0 },
            );

        try middle.connectInput(
            leaf_instance,
            0,
            input,
        );

        try middle.connectOutput(
            leaf_instance,
            0,
            output,
        );
    }

    var first_instance: Circuit.NodeId = undefined;
    var second_instance: Circuit.NodeId = undefined;

    {
        const middle =
            project.getConst(middle_id).?;

        const root =
            project.get(root_id).?;

        const a =
            try root.addNet();

        const b =
            try root.addNet();

        const x =
            try root.addNet();

        const y =
            try root.addNet();

        _ = try root.addInput(a);
        _ = try root.addInput(b);

        _ = try root.addOutput(x);
        _ = try root.addOutput(y);

        first_instance =
            try root.addSubcircuitNode(
                middle_id,
                middle,
                .{ .x = 0, .y = 0 },
            );

        second_instance =
            try root.addSubcircuitNode(
                middle_id,
                middle,
                .{ .x = 0, .y = 100 },
            );

        try root.connectInput(
            first_instance,
            0,
            a,
        );

        try root.connectOutput(
            first_instance,
            0,
            x,
        );

        try root.connectInput(
            second_instance,
            0,
            b,
        );

        try root.connectOutput(
            second_instance,
            0,
            y,
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
        @as(usize, 2),
        compilation.chip_origins.len,
    );

    const first =
        compilation.chip_origins[0];

    const second =
        compilation.chip_origins[1];

    try std.testing.expect(
        first.circuit == leaf_id,
    );

    try std.testing.expect(
        second.circuit == leaf_id,
    );

    try std.testing.expect(
        first.node == leaf_node,
    );

    try std.testing.expect(
        second.node == leaf_node,
    );

    try std.testing.expectEqual(
        @as(u32, 2),
        first.path_len,
    );

    try std.testing.expectEqual(
        @as(u32, 2),
        second.path_len,
    );

    const first_start: usize =
        @intCast(first.path_start);

    const second_start: usize =
        @intCast(second.path_start);

    const first_path =
        compilation.origin_path[first_start .. first_start + first.path_len];

    const second_path =
        compilation.origin_path[second_start .. second_start + second.path_len];

    try std.testing.expect(
        first_path[0].circuit == root_id,
    );

    try std.testing.expect(
        first_path[0].node == first_instance,
    );

    try std.testing.expect(
        first_path[1].circuit == middle_id,
    );

    try std.testing.expect(
        first_path[1].node == leaf_instance,
    );

    try std.testing.expect(
        second_path[0].circuit == root_id,
    );

    try std.testing.expect(
        second_path[0].node == second_instance,
    );

    try std.testing.expect(
        second_path[1].circuit == middle_id,
    );

    try std.testing.expect(
        second_path[1].node == leaf_instance,
    );
}

test "net origins distinguish repeated subcircuit instances" {
    var project =
        Project.init(std.testing.allocator);
    defer project.deinit();

    const child_id =
        try project.addCircuit();

    const root_id =
        try project.addCircuit();

    var middle_net: Circuit.NetId = undefined;

    {
        const child =
            project.get(child_id).?;

        const input =
            try child.addNet();

        middle_net =
            try child.addNet();

        const output =
            try child.addNet();

        _ = try child.addInput(input);
        _ = try child.addOutput(output);

        const first =
            try child.addNode(
                .not1,
                .{ .x = 0, .y = 0 },
            );

        const second =
            try child.addNode(
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
            middle_net,
        );

        try child.connectInput(
            second,
            0,
            middle_net,
        );

        try child.connectOutput(
            second,
            0,
            output,
        );
    }

    var first_instance: Circuit.NodeId = undefined;
    var second_instance: Circuit.NodeId = undefined;

    {
        const child =
            project.getConst(child_id).?;

        const root =
            project.get(root_id).?;

        const a =
            try root.addNet();

        const b =
            try root.addNet();

        const x =
            try root.addNet();

        const y =
            try root.addNet();

        _ = try root.addInput(a);
        _ = try root.addInput(b);

        _ = try root.addOutput(x);
        _ = try root.addOutput(y);

        first_instance =
            try root.addSubcircuitNode(
                child_id,
                child,
                .{ .x = 0, .y = 0 },
            );

        second_instance =
            try root.addSubcircuitNode(
                child_id,
                child,
                .{ .x = 0, .y = 100 },
            );

        try root.connectInput(
            first_instance,
            0,
            a,
        );

        try root.connectOutput(
            first_instance,
            0,
            x,
        );

        try root.connectInput(
            second_instance,
            0,
            b,
        );

        try root.connectOutput(
            second_instance,
            0,
            y,
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

    var found: [2]NetOrigin = undefined;
    var found_count: usize = 0;

    for (compilation.net_origins) |origin| {
        if (!(origin.circuit == child_id)) {
            continue;
        }

        if (!(origin.net == middle_net)) {
            continue;
        }

        try std.testing.expect(
            found_count < found.len,
        );

        found[found_count] = origin;
        found_count += 1;
    }

    try std.testing.expectEqual(
        @as(usize, 2),
        found_count,
    );

    try std.testing.expect(
        found[0].bus != found[1].bus,
    );

    try std.testing.expectEqual(
        @as(u32, 1),
        found[0].path_len,
    );

    try std.testing.expectEqual(
        @as(u32, 1),
        found[1].path_len,
    );

    const first_start: usize =
        @intCast(found[0].path_start);

    const second_start: usize =
        @intCast(found[1].path_start);

    const first_path =
        compilation.origin_path[first_start .. first_start + 1];

    const second_path =
        compilation.origin_path[second_start .. second_start + 1];

    try std.testing.expect(
        first_path[0].circuit == root_id,
    );

    try std.testing.expect(
        second_path[0].circuit == root_id,
    );

    const first_is_first =
        first_path[0].node == first_instance;

    const first_is_second =
        first_path[0].node == second_instance;

    try std.testing.expect(
        first_is_first or first_is_second,
    );

    if (first_is_first) {
        try std.testing.expect(
            second_path[0].node == second_instance,
        );
    } else {
        try std.testing.expect(
            second_path[0].node == first_instance,
        );
    }
}

fn makeTestHierarchy(project: *Project, chain_length: usize) !struct { root: Circuit.Id, child: Circuit.Id } {
    const child_id = try project.addCircuit();
    {
        const child = project.get(child_id).?;
        var previous = try child.addNet();
        _ = try child.addInput(previous);
        for (0..chain_length) |_| {
            const output = try child.addNet();
            const node = try child.addNode(.not1, .{ .x = 0, .y = 0 });
            try child.connectInput(node, 0, previous);
            try child.connectOutput(node, 0, output);
            previous = output;
        }
        _ = try child.addOutput(previous);
    }
    const root_id = try project.addCircuit();
    const root = project.get(root_id).?;
    for (0..2) |_| {
        const input = try root.addNet();
        const output = try root.addNet();
        _ = try root.addInput(input);
        _ = try root.addOutput(output);
        const node = try root.addSubcircuitNode(child_id, project.getConst(child_id).?, .{ .x = 0, .y = 0 });
        try root.connectInput(node, 0, input);
        try root.connectOutput(node, 0, output);
    }
    return .{ .root = root_id, .child = child_id };
}

test "compilation owns its runtime after source edits and destruction" {
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = counted.allocator();
    var compilation: Compilation = blk: {
        var project = Project.init(std.testing.allocator);
        defer project.deinit();
        const fixture = try makeTestHierarchy(&project, 129);
        const root = project.get(fixture.root).?;
        const removed = try root.addNode(.not1, .{ .x = 0, .y = 0 });
        const discarded_output = try root.addNet();
        try root.connectInput(removed, 0, root.inputs.items[0].net);
        try root.connectOutput(removed, 0, discarded_output);
        try std.testing.expect(root.removeNode(removed));

        var result = try compile(allocator, &project, fixture.root);
        switch (result) {
            .failure => |*failure| {
                failure.deinit(allocator);
                return error.UnexpectedDiagnostics;
            },
            .success => |success| {
                const child = project.get(fixture.child).?;
                _ = child.removeNet(child.inputs.items[0].net);
                break :blk success;
            },
        }
    };
    defer compilation.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 258), compilation.chip_origins.len);
    try std.testing.expectEqual(@as(usize, 2), compilation.origin_path.len);
    for (compilation.chip_origins, 0..) |origin, i| {
        try std.testing.expectEqual(@as(u32, 1), origin.path_len);
        try std.testing.expectEqual(@as(u32, @intCast(i / 129)), origin.path_start);
    }
    for (compilation.net_origins) |origin| {
        if (origin.path_len != 0) {
            try std.testing.expect(origin.path_start < compilation.origin_path.len);
            try std.testing.expectEqual(@as(u32, 1), origin.path_len);
        }
    }

    // All runtime state is already allocated, even for hundreds of delta rounds.
    counted.fail_index = counted.alloc_index;
    counted.resize_fail_index = counted.resize_index;
    try compilation.runtime.store(compilation.input_buses[0], true);
    try compilation.runtime.settle(132);
    try std.testing.expectEqual(false, try compilation.runtime.load(compilation.output_buses[0]));
    try std.testing.expectEqual(true, try compilation.runtime.load(compilation.output_buses[1]));
    try compilation.runtime.store(compilation.input_buses[0], false);
    try compilation.runtime.store(compilation.input_buses[1], true);
    try compilation.runtime.settle(132);
    try std.testing.expectEqual(true, try compilation.runtime.load(compilation.output_buses[0]));
    try std.testing.expectEqual(false, try compilation.runtime.load(compilation.output_buses[1]));
    try std.testing.expect(!counted.has_induced_failure);
}

fn checkCompileAllocationCleanup(
    allocator: std.mem.Allocator,
    project: *const Project,
    root: Circuit.Id,
    expect_success: bool,
) !void {
    var result = try compile(allocator, project, root);
    switch (result) {
        .success => |*compilation| {
            defer compilation.deinit(allocator);
            try std.testing.expect(expect_success);
        },
        .failure => |*failure| {
            defer failure.deinit(allocator);
            try std.testing.expect(!expect_success);
        },
    }
}

test "compile releases every allocation on success and diagnostic allocation failures" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();
    const fixture = try makeTestHierarchy(&project, 17);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkCompileAllocationCleanup, .{ &project, fixture.root, true });

    const child = project.get(fixture.child).?;
    const first = child.nodes.handleAtDenseIndex(0).?;
    child.disconnectInput(first, 0);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkCompileAllocationCleanup, .{ &project, fixture.root, false });
}

test "cached hierarchy validation still checks every instance interface" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();
    const fixture = try makeTestHierarchy(&project, 1);
    project.get(fixture.root).?.nodes.values.items[1].input_count = 0;
    try std.testing.expectError(error.SubcircuitInterfaceChanged, compile(std.testing.allocator, &project, fixture.root));
}

test "empty compilation owns a usable empty runtime" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();
    const root = try project.addCircuit();
    var compilation = try compileSuccess(&project, root);
    defer compilation.deinit(std.testing.allocator);
    try compilation.runtime.settle(0);
    try std.testing.expectEqual(@as(usize, 0), compilation.chip_origins.len);
    try std.testing.expectEqual(@as(usize, 0), compilation.net_origins.len);
    try std.testing.expectError(error.InvalidBus, compilation.runtime.load(@enumFromInt(0)));
}
