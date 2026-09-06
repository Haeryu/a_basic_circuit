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
