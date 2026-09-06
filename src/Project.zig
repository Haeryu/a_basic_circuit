const Project = @This();

const std = @import("std");

const Circuit = @import("Circuit.zig");
const DenseGenPool = @import("dense_gen_pool.zig").DenseGenPool;
const GenHandle = @import("dense_gen_pool.zig").GenHandle;

const CircuitPool = DenseGenPool(
    Circuit,
    Circuit.Id,
);

gpa: std.mem.Allocator,
circuits: CircuitPool,

pub fn init(gpa: std.mem.Allocator) Project {
    return .{
        .gpa = gpa,
        .circuits = .init,
    };
}

pub fn deinit(self: *Project) void {
    for (self.circuits.values.items) |*circuit| {
        circuit.deinit();
    }

    self.circuits.deinit(self.gpa);

    self.* = undefined;
}

pub fn addCircuit(self: *Project) !Circuit.Id {
    return self.circuits.create(self.gpa, .init(self.gpa));
}

pub fn removeCircuit(self: *Project, id: Circuit.Id) bool {
    const circuit = self.circuits.get(id) orelse return false;
    circuit.deinit();
    return self.circuits.destroy(id);
}

pub fn get(self: *Project, id: Circuit.Id) ?*Circuit {
    return self.circuits.get(id);
}

pub fn getConst(self: *const Project, id: Circuit.Id) ?*const Circuit {
    return self.circuits.getConst(id);
}

test "project keeps circuit handles stable" {
    var project =
        Project.init(std.testing.allocator);
    defer project.deinit();

    const a = try project.addCircuit();
    const b = try project.addCircuit();
    const c = try project.addCircuit();

    try std.testing.expect(
        project.removeCircuit(b),
    );

    try std.testing.expect(
        project.get(a) != null,
    );

    try std.testing.expect(
        project.get(b) == null,
    );

    try std.testing.expect(
        project.get(c) != null,
    );

    const d = try project.addCircuit();

    try std.testing.expectEqual(
        b.index,
        d.index,
    );

    try std.testing.expect(
        b.generation != d.generation,
    );

    try std.testing.expect(
        project.get(b) == null,
    );

    try std.testing.expect(
        project.get(d) != null,
    );
}

test "circuit may contain subcircuit node" {
    var project =
        Project.init(std.testing.allocator);
    defer project.deinit();

    const child_id = try project.addCircuit();
    const parent_id = try project.addCircuit();

    const child = project.get(child_id).?;

    const child_input = try child.addNet();
    const child_output = try child.addNet();

    _ = try child.addInput(child_input);
    _ = try child.addOutput(child_output);

    const parent = project.get(parent_id).?;

    const node_id = try parent.addSubcircuitNode(
        child_id,
        child,
        .{ .x = 0, .y = 0 },
    );

    const node = parent.nodes.get(node_id).?;

    switch (node.kind) {
        .subcircuit => |id| {
            try std.testing.expect(
                id.eql(child_id),
            );
        },

        .primitive => {
            return error.UnexpectedNodeKind;
        },
    }

    try std.testing.expectEqual(
        @as(usize, 1),
        node.inputCount(),
    );

    try std.testing.expectEqual(
        @as(usize, 1),
        node.outputCount(),
    );

    try std.testing.expectEqual(
        @as(usize, 2),
        node.connections.len,
    );
}
