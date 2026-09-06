const std = @import("std");

pub fn GenHandle(comptime Tag: type) type {
    _ = Tag;

    return packed struct(u64) {
        generation: u31,
        reserved: u1 = 0,
        index: u32,

        pub fn eql(self: @This(), other: @This()) bool {
            return self.generation == other.generation and
                self.index == other.index and
                self.reserved == other.reserved;
        }
    };
}

pub fn DenseGenPool(comptime T: type, comptime HandleType: type) type {
    return struct {
        const Self = @This();

        const end = std.math.maxInt(u32);

        const SlotState = packed struct(u32) {
            live: bool,
            generation: u31,
        };

        const Slot = packed struct(u64) {
            state: SlotState,
            index_or_next: u32,
        };

        pub const Handle = HandleType;

        slots: std.ArrayListUnmanaged(Slot),
        values: std.ArrayListUnmanaged(T),

        value_slots: std.ArrayListUnmanaged(u32),

        free_head: u32,

        pub const init: Self = .{
            .slots = .empty,
            .values = .empty,
            .value_slots = .empty,
            .free_head = end,
        };

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.value_slots.deinit(gpa);
            self.values.deinit(gpa);
            self.slots.deinit(gpa);

            self.* = undefined;
        }

        pub fn create(self: *Self, gpa: std.mem.Allocator, value: T) !Handle {
            try self.values.ensureUnusedCapacity(gpa, 1);
            try self.value_slots.ensureUnusedCapacity(gpa, 1);

            if (self.free_head == end) {
                if (self.slots.items.len >= end) {
                    return error.TooManySlots;
                }

                try self.slots.ensureUnusedCapacity(gpa, 1);
            }

            const dense_index: u32 = @intCast(self.values.items.len);

            var slot_index: u32 = undefined;
            var generation: u31 = undefined;

            if (self.free_head != end) {
                slot_index = self.free_head;

                const slot = &self.slots.items[@intCast(slot_index)];

                std.debug.assert(!slot.state.live);

                self.free_head = slot.index_or_next;

                slot.state.live = true;
                slot.index_or_next = dense_index;

                generation = slot.state.generation;
            } else {
                slot_index = @intCast(self.slots.items.len);
                generation = 0;

                self.slots.appendAssumeCapacity(.{
                    .state = .{
                        .live = true,
                        .generation = generation,
                    },
                    .index_or_next = dense_index,
                });
            }

            self.values.appendAssumeCapacity(value);
            self.value_slots.appendAssumeCapacity(slot_index);

            return .{
                .generation = generation,
                .index = slot_index,
            };
        }

        pub fn destroy(self: *Self, handle: Handle) bool {
            if (handle.reserved != 0) {
                return false;
            }

            const slot_index: usize = @intCast(handle.index);

            if (slot_index >= self.slots.items.len) {
                return false;
            }

            const slot = &self.slots.items[slot_index];

            if (!slot.state.live) {
                return false;
            }

            if (slot.state.generation != handle.generation) {
                return false;
            }

            const dense_index: usize = @intCast(slot.index_or_next);

            const last_index = self.values.items.len - 1;

            if (dense_index != last_index) {
                self.values.items[dense_index] = self.values.items[last_index];

                const moved_slot_index = self.value_slots.items[last_index];

                self.value_slots.items[dense_index] = moved_slot_index;

                self.slots.items[@intCast(moved_slot_index)].index_or_next =
                    @intCast(dense_index);
            }

            self.values.items[last_index] = undefined;
            self.values.items.len -= 1;

            self.value_slots.items[last_index] = undefined;
            self.value_slots.items.len -= 1;

            slot.state.live = false;

            if (slot.state.generation == std.math.maxInt(u31)) {
                @branchHint(.cold);
                @panic("generation overflow");
            }

            slot.state.generation += 1;
            slot.index_or_next = self.free_head;
            self.free_head = handle.index;

            return true;
        }

        pub fn get(self: *Self, handle: Handle) ?*T {
            if (handle.reserved != 0) {
                return null;
            }

            const slot_index: usize = @intCast(handle.index);

            if (slot_index >= self.slots.items.len) {
                return null;
            }

            const slot = &self.slots.items[slot_index];

            if (!slot.state.live) {
                return null;
            }

            if (slot.state.generation != handle.generation) {
                return null;
            }

            return &self.values.items[@intCast(slot.index_or_next)];
        }

        pub fn getConst(self: *const Self, handle: Handle) ?*const T {
            if (handle.reserved != 0) {
                return null;
            }

            const slot_index: usize = @intCast(handle.index);

            if (slot_index >= self.slots.items.len) {
                return null;
            }

            const slot = &self.slots.items[slot_index];

            if (!slot.state.live) {
                return null;
            }

            if (slot.state.generation != handle.generation) {
                return null;
            }

            return &self.values.items[@intCast(slot.index_or_next)];
        }

        pub fn denseIndex(self: *const Self, handle: Handle) ?usize {
            if (handle.reserved != 0) {
                return null;
            }

            const slot_index: usize = @intCast(handle.index);
            if (slot_index >= self.slots.items.len) {
                return null;
            }

            const slot = &self.slots.items[slot_index];
            if (!slot.state.live) {
                return null;
            }

            if (slot.state.generation != handle.generation) {
                return null;
            }

            return @intCast(slot.index_or_next);
        }

        pub fn handleAtDenseIndex(self: *const Self, dense_index: usize) ?Handle {
            if (dense_index >= self.values.items.len) {
                return null;
            }

            const slot_index = self.value_slots.items[dense_index];
            const slot = &self.slots.items[@intCast(slot_index)];

            std.debug.assert(slot.state.live);

            return .{
                .generation = slot.state.generation,
                .index = slot_index,
            };
        }
    };
}

test "dense gen pool keeps handles stable across swap remove" {
    const TestId = GenHandle(enum {});
    const Pool = DenseGenPool(u32, TestId);

    var pool: Pool = .init;
    defer pool.deinit(std.testing.allocator);

    const a = try pool.create(
        std.testing.allocator,
        10,
    );

    const b = try pool.create(
        std.testing.allocator,
        20,
    );

    const c = try pool.create(
        std.testing.allocator,
        30,
    );

    try std.testing.expectEqual(
        @as(usize, 3),
        pool.values.items.len,
    );

    // Remove middle dense element.
    //
    // Before:
    //
    // dense:
    // [ A ][ B ][ C ]
    //
    // After:
    //
    // [ A ][ C ]
    //
    // C moves, but its Handle must remain valid.
    try std.testing.expect(
        pool.destroy(b),
    );

    try std.testing.expectEqual(
        @as(usize, 2),
        pool.values.items.len,
    );

    try std.testing.expectEqual(
        @as(u32, 10),
        pool.get(a).?.*,
    );

    try std.testing.expectEqual(
        @as(u32, 30),
        pool.get(c).?.*,
    );

    // Old B handle is dead.
    try std.testing.expect(
        pool.get(b) == null,
    );

    try std.testing.expect(
        !pool.destroy(b),
    );

    // Reuse B's sparse slot.
    const d = try pool.create(
        std.testing.allocator,
        40,
    );

    try std.testing.expectEqual(
        b.index,
        d.index,
    );

    try std.testing.expect(
        b.generation != d.generation,
    );

    // Reusing the slot must not resurrect B.
    try std.testing.expect(
        pool.get(b) == null,
    );

    try std.testing.expectEqual(
        @as(u32, 40),
        pool.get(d).?.*,
    );

    // C still points to C even though its dense position moved.
    try std.testing.expectEqual(
        @as(u32, 30),
        pool.get(c).?.*,
    );
}
