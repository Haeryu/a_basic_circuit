const Circuit = @This();

const std = @import("std");

pub const NodeId = enum(u32) {
    invalid = std.math.maxInt(u32),
    _,

    fn index(self: NodeId) usize {
        return @intCast(@intFromEnum(self));
    }
};

pub const Kind = enum(u8) {
    input = 0,
    output = 1,
    not = 2,
    and2 = 3,
    or2 = 4,
    xor2 = 5,
    dff = 6,
    buffer = 7,
    nand2 = 8,
    nor2 = 9,
    xnor2 = 10,
    counter = 11,
    ram = 12,

    pub fn inputCount(self: Kind) usize {
        return switch (self) {
            .input => 0,
            .output, .not, .buffer => 1,
            .and2, .or2, .xor2, .dff, .nand2, .nor2, .xnor2 => 2,
            .counter => 3,
            // RAM is special-cased: address bits occupy pins 0..63, DATA is
            // pin 64, WE pin 65 and CLK pin 66.
            .ram => 67,
        };
    }
};

pub const RunResult = enum(u8) {
    settled,
    pending,
};

const Node = struct {
    kind: Kind,
    // Counter lanes use [0] for their DATA bit and [1] for the group index.
    // Shared CLK/LOAD live in CounterGroup; ordinary gate nodes stay compact.
    inputs: [2]NodeId = .{ .invalid, .invalid },
    value: bool = false,
    previous_clock: bool = false,
    alive: bool = true,
};

const CounterGroup = struct {
    first: NodeId,
    width: u8,
    clock: NodeId = .invalid,
    load: NodeId = .invalid,
    count: u64 = 0,
    previous_clock: bool = false,
    alive: bool = true,
    last_evaluated_round: u64 = 0,
};

const RamGroup = struct {
    first: NodeId,
    width: u8,
    address_width: u8,
    address: [64]NodeId = @splat(.invalid),
    write_enable: NodeId = .invalid,
    clock: NodeId = .invalid,
    base: u64 = 0,
    end: u64 = 0,
    cells: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    previous_clock: bool = false,
    cached_read: u64 = 0,
    last_evaluated_round: u64 = 0,
    alive: bool = true,
};

pub const RamCell = struct {
    address: u64,
    word: u64,
};

allocator: std.mem.Allocator,
nodes: std.ArrayListUnmanaged(Node) = .empty,
counter_groups: std.ArrayListUnmanaged(CounterGroup) = .empty,
ram_groups: std.ArrayListUnmanaged(RamGroup) = .empty,

// Rebuilt only when the graph changes. offsets/source -> consumers is CSR.
fanout_offsets: std.ArrayListUnmanaged(u32) = .empty,
fanout: std.ArrayListUnmanaged(NodeId) = .empty,

current: std.ArrayListUnmanaged(NodeId) = .empty,
next: std.ArrayListUnmanaged(NodeId) = .empty,
queued: std.ArrayListUnmanaged(bool) = .empty,

topology_dirty: bool = true,
round_serial: u64 = 0,

pub fn init(allocator: std.mem.Allocator) Circuit {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Circuit) void {
    const allocator = self.allocator;
    self.queued.deinit(allocator);
    self.next.deinit(allocator);
    self.current.deinit(allocator);
    self.fanout.deinit(allocator);
    self.fanout_offsets.deinit(allocator);
    for (self.ram_groups.items) |*group| group.cells.deinit(allocator);
    self.ram_groups.deinit(allocator);
    self.counter_groups.deinit(allocator);
    self.nodes.deinit(allocator);
    self.* = undefined;
}

pub fn addNode(self: *Circuit, kind: Kind) !NodeId {
    if (kind == .counter) return self.addCounter(1);

    // Keep one u32 value for `.invalid` and one addressable CSR sentinel at
    // fanout_offsets[node_count], including on wasm32 where usize is also u32.
    if (self.nodes.items.len >= std.math.maxInt(u32) - 1) return error.CircuitTooLarge;

    const id: NodeId = @enumFromInt(@as(u32, @intCast(self.nodes.items.len)));
    try self.nodes.append(self.allocator, .{ .kind = kind });
    self.topology_dirty = true;
    return id;
}

/// Add a native binary counter as contiguous single-bit output nodes.
/// Pins 0 (CLK) and 1 (LOAD) are shared across the group; pin 2 sets a lane's
/// DATA bit. On a rising CLK edge, LOAD selects DATA instead of incrementing.
pub fn addCounter(self: *Circuit, width: usize) !NodeId {
    if (width == 0 or width > 64) return error.InvalidWidth;

    const max_node_count: usize = std.math.maxInt(u32) - 1;
    if (self.nodes.items.len > max_node_count - width) return error.CircuitTooLarge;
    if (self.counter_groups.items.len >= max_node_count) return error.CircuitTooLarge;

    // Reserve every fallible allocation before changing either logical length.
    try self.counter_groups.ensureUnusedCapacity(self.allocator, 1);
    try self.nodes.ensureUnusedCapacity(self.allocator, width);

    const first: NodeId = @enumFromInt(@as(u32, @intCast(self.nodes.items.len)));
    const group_id: NodeId = @enumFromInt(@as(u32, @intCast(self.counter_groups.items.len)));
    self.counter_groups.appendAssumeCapacity(.{
        .first = first,
        .width = @intCast(width),
    });

    for (0..width) |_| {
        self.nodes.appendAssumeCapacity(.{
            .kind = .counter,
            .inputs = .{ .invalid, group_id },
        });
    }

    self.topology_dirty = true;
    return first;
}

/// Add sparse native RAM. Address width may be 1..64 while the mapped window
/// is configured separately; only non-zero cells occupy storage.
pub fn addRam(self: *Circuit, width: usize, address_width: usize) !NodeId {
    if (width == 0 or width > 64 or address_width == 0 or address_width > 64) return error.InvalidWidth;

    const max_node_count: usize = std.math.maxInt(u32) - 1;
    if (self.nodes.items.len > max_node_count - width) return error.CircuitTooLarge;
    if (self.ram_groups.items.len >= max_node_count) return error.CircuitTooLarge;

    try self.ram_groups.ensureUnusedCapacity(self.allocator, 1);
    try self.nodes.ensureUnusedCapacity(self.allocator, width);

    const first: NodeId = @enumFromInt(@as(u32, @intCast(self.nodes.items.len)));
    const group_id: NodeId = @enumFromInt(@as(u32, @intCast(self.ram_groups.items.len)));
    const default_end = if (address_width == 64)
        std.math.maxInt(u64)
    else
        (@as(u64, 1) << @intCast(address_width)) - 1;
    self.ram_groups.appendAssumeCapacity(.{
        .first = first,
        .width = @intCast(width),
        .address_width = @intCast(address_width),
        .end = default_end,
    });

    for (0..width) |_| self.nodes.appendAssumeCapacity(.{
        .kind = .ram,
        .inputs = .{ .invalid, group_id },
    });

    self.topology_dirty = true;
    return first;
}

pub fn configureRam(self: *Circuit, id: NodeId, base: u64, end: u64) !void {
    const lane = self.node(id) orelse return error.InvalidNode;
    if (lane.kind != .ram) return error.NotRam;
    const group_index = self.ramGroupIndex(lane) orelse return error.InvalidNode;
    const group = &self.ram_groups.items[group_index];
    if (base > end or !addressFits(group.address_width, end)) return error.ValueOutOfRange;

    // Reconfiguring a mapped window keeps overlapping contents, but discarded
    // addresses must not silently reappear if the window is expanded later.
    var stale = std.ArrayListUnmanaged(u64).empty;
    defer stale.deinit(self.allocator);
    var iterator = group.cells.keyIterator();
    while (iterator.next()) |address| {
        if (address.* < base or address.* > end) try stale.append(self.allocator, address.*);
    }
    for (stale.items) |address| _ = group.cells.remove(address);

    group.base = base;
    group.end = end;
    self.topology_dirty = true;
}

pub fn ramRead(self: *const Circuit, id: NodeId, address: u64) !u64 {
    const lane = self.nodeConst(id) orelse return error.InvalidNode;
    if (lane.kind != .ram) return error.NotRam;
    const group_index = self.ramGroupIndex(lane) orelse return error.InvalidNode;
    const group = &self.ram_groups.items[group_index];
    if (address < group.base or address > group.end) return error.AddressOutOfRange;
    return group.cells.get(address) orelse 0;
}

pub fn ramWrite(self: *Circuit, id: NodeId, address: u64, word: u64) !void {
    const lane = self.node(id) orelse return error.InvalidNode;
    if (lane.kind != .ram) return error.NotRam;
    const group_index = self.ramGroupIndex(lane) orelse return error.InvalidNode;
    const group = &self.ram_groups.items[group_index];
    if (address < group.base or address > group.end) return error.AddressOutOfRange;
    if (word & ~busMask(group.width) != 0) return error.ValueOutOfRange;
    if (word == 0) _ = group.cells.remove(address) else try group.cells.put(self.allocator, address, word);
    const current_address = self.ramAddress(group);
    if (current_address == address) {
        group.cached_read = word;
        const first = group.first.index();
        for (0..group.width) |bit| {
            const output = word & (@as(u64, 1) << @intCast(bit)) != 0;
            const output_lane = &self.nodes.items[first + bit];
            if (output_lane.value == output or self.topology_dirty) continue;
            output_lane.value = output;
            self.scheduleConsumers(&self.current, ramLane(group.first, bit));
        }
    }
}

pub fn ramCellCount(self: *const Circuit, id: NodeId) !usize {
    const lane = self.nodeConst(id) orelse return error.InvalidNode;
    if (lane.kind != .ram) return error.NotRam;
    const group_index = self.ramGroupIndex(lane) orelse return error.InvalidNode;
    return self.ram_groups.items[group_index].cells.count();
}

pub fn appendRamCells(self: *const Circuit, id: NodeId, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(RamCell)) !void {
    const lane = self.nodeConst(id) orelse return error.InvalidNode;
    if (lane.kind != .ram) return error.NotRam;
    const group_index = self.ramGroupIndex(lane) orelse return error.InvalidNode;
    const group = &self.ram_groups.items[group_index];
    try out.ensureUnusedCapacity(allocator, group.cells.count());
    var iterator = group.cells.iterator();
    while (iterator.next()) |entry| out.appendAssumeCapacity(.{
        .address = entry.key_ptr.*,
        .word = entry.value_ptr.*,
    });
}

pub fn removeNode(self: *Circuit, id: NodeId) bool {
    const removed = self.node(id) orelse return false;
    if (removed.kind == .counter) {
        const group_index = self.counterGroupIndex(removed) orelse return false;
        return self.removeCounterGroup(group_index);
    }
    if (removed.kind == .ram) {
        const group_index = self.ramGroupIndex(removed) orelse return false;
        return self.removeRamGroup(group_index);
    }

    removed.alive = false;
    removed.value = false;
    removed.inputs = .{ .invalid, .invalid };
    removed.previous_clock = false;

    // Editing is cold compared with simulation. Scanning here avoids a second
    // mutable reverse-index structure that would have to stay in sync.
    self.clearDownstreamRange(id.index(), id.index() + 1);

    self.topology_dirty = true;
    return true;
}

/// Connect one node's single-bit output directly to an input pin.
/// Fan-out is represented by several input pins referring to the same source.
pub fn connect(self: *Circuit, source_id: NodeId, target_id: NodeId, pin: usize) !void {
    _ = self.node(source_id) orelse return error.InvalidNode;
    const target = self.node(target_id) orelse return error.InvalidNode;
    if (target.kind == .ram) {
        const group_index = self.ramGroupIndex(target) orelse return error.InvalidNode;
        const group = &self.ram_groups.items[group_index];
        if (pin < 64) {
            if (pin >= group.address_width) return error.InvalidPin;
            group.address[pin] = source_id;
        } else switch (pin) {
            64 => target.inputs[0] = source_id,
            65 => group.write_enable = source_id,
            66 => group.clock = source_id,
            else => return error.InvalidPin,
        }
        self.topology_dirty = true;
        return;
    }
    if (pin >= target.kind.inputCount()) return error.InvalidPin;
    if (self.inputSource(target, pin) == source_id) return;

    if (target.kind == .counter) {
        const group_index = self.counterGroupIndex(target) orelse return error.InvalidNode;
        switch (pin) {
            0 => self.counter_groups.items[group_index].clock = source_id,
            1 => self.counter_groups.items[group_index].load = source_id,
            2 => target.inputs[0] = source_id,
            else => unreachable,
        }
    } else {
        target.inputs[pin] = source_id;
    }

    self.topology_dirty = true;
}

pub fn disconnect(self: *Circuit, target_id: NodeId, pin: usize) bool {
    const target = self.node(target_id) orelse return false;
    if (target.kind == .ram) {
        const group_index = self.ramGroupIndex(target) orelse return false;
        const group = &self.ram_groups.items[group_index];
        const source = self.inputSource(target, pin);
        if (source == .invalid) return false;
        if (pin < 64) {
            if (pin >= group.address_width) return false;
            group.address[pin] = .invalid;
        } else switch (pin) {
            64 => target.inputs[0] = .invalid,
            65 => group.write_enable = .invalid,
            66 => group.clock = .invalid,
            else => return false,
        }
        self.topology_dirty = true;
        return true;
    }
    if (pin >= target.kind.inputCount()) return false;
    if (self.inputSource(target, pin) == .invalid) return false;

    if (target.kind == .counter) {
        const group_index = self.counterGroupIndex(target) orelse return false;
        switch (pin) {
            0 => self.counter_groups.items[group_index].clock = .invalid,
            1 => self.counter_groups.items[group_index].load = .invalid,
            2 => target.inputs[0] = .invalid,
            else => unreachable,
        }
    } else {
        target.inputs[pin] = .invalid;
    }

    self.topology_dirty = true;
    return true;
}

pub fn setInput(self: *Circuit, id: NodeId, input_value: bool) !void {
    const input = self.node(id) orelse return error.InvalidNode;
    if (input.kind != .input) return error.NotInput;
    if (input.value == input_value) return;

    input.value = input_value;

    // A dirty topology will schedule every live non-input node on rebuild.
    if (!self.topology_dirty) self.scheduleConsumers(&self.current, id);
}

/// Set a counter atomically without inventing or consuming a clock edge.
pub fn setCounter(self: *Circuit, id: NodeId, count: u64) !void {
    const lane = self.node(id) orelse return error.InvalidNode;
    if (lane.kind != .counter) return error.NotCounter;
    const group_index = self.counterGroupIndex(lane) orelse return error.InvalidNode;
    const group = &self.counter_groups.items[group_index];
    if (count & ~counterMask(group.width) != 0) return error.ValueOutOfRange;
    group.count = count;
    const first = group.first.index();
    for (0..group.width) |bit| {
        const output_lane = &self.nodes.items[first + bit];
        const output = count & (@as(u64, 1) << @intCast(bit)) != 0;
        if (output_lane.value == output) continue;
        output_lane.value = output;
        if (!self.topology_dirty) self.scheduleConsumers(&self.current, counterLane(group.first, bit));
    }
}

pub fn value(self: *const Circuit, id: NodeId) !bool {
    const n = self.nodeConst(id) orelse return error.InvalidNode;
    return n.value;
}

/// Editor checkpoint: bit 0 is the output, bit 1 the sequential clock history.
pub fn state(self: *const Circuit, id: NodeId) !u2 {
    const n = self.nodeConst(id) orelse return error.InvalidNode;
    const previous_clock = if (n.kind == .counter) blk: {
        const group_index = self.counterGroupIndex(n) orelse return error.InvalidNode;
        break :blk self.counter_groups.items[group_index].previous_clock;
    } else if (n.kind == .ram) blk: {
        const group_index = self.ramGroupIndex(n) orelse return error.InvalidNode;
        break :blk self.ram_groups.items[group_index].previous_clock;
    } else n.previous_clock;
    return @as(u2, @intFromBool(n.value)) | (@as(u2, @intFromBool(previous_clock)) << 1);
}

pub fn restoreState(self: *Circuit, id: NodeId, saved: u2) !void {
    const n = self.node(id) orelse return error.InvalidNode;
    const output = saved & 1 != 0;
    n.value = output;

    if (n.kind == .counter) {
        const group_index = self.counterGroupIndex(n) orelse return error.InvalidNode;
        const group = &self.counter_groups.items[group_index];
        const bit_index = id.index() - group.first.index();
        const bit = @as(u64, 1) << @intCast(bit_index);
        if (output) {
            group.count |= bit;
        } else {
            group.count &= ~bit;
        }
        group.previous_clock = saved & 2 != 0;
    } else if (n.kind == .ram) {
        const group_index = self.ramGroupIndex(n) orelse return error.InvalidNode;
        const group = &self.ram_groups.items[group_index];
        const bit_index = id.index() - group.first.index();
        const bit = @as(u64, 1) << @intCast(bit_index);
        if (output) {
            group.cached_read |= bit;
        } else {
            group.cached_read &= ~bit;
        }
        group.previous_clock = saved & 2 != 0;
    } else {
        n.previous_clock = n.kind == .dff and saved & 2 != 0;
    }
    self.topology_dirty = true;
}

/// Execute at most `max_rounds` synchronous delta rounds.
/// `pending` means more propagation remains; it is deliberately not classified
/// as an error because the caller may resume with another `run` call.
pub fn run(self: *Circuit, max_rounds: usize) !RunResult {
    try self.rebuildIfNeeded();

    var rounds: usize = 0;
    while (self.current.items.len != 0) {
        if (rounds == max_rounds) return .pending;
        rounds += 1;
        self.beginRound();

        // The current round is no longer queued. A changed source may schedule
        // any of these nodes again for the next round.
        for (self.current.items) |id| {
            self.queued.items[id.index()] = false;
        }

        var changed_count: usize = 0;
        const work = self.current.items;
        for (work) |id| {
            const idx = id.index();
            const n = &self.nodes.items[idx];
            if (!n.alive or n.kind == .input) continue;

            const old_value = n.value;
            if (try self.evaluate(idx) != old_value) {
                work[changed_count] = id;
                changed_count += 1;
            }
        }

        // Commit after evaluating the whole round. Sequential nodes therefore
        // sample the same old outputs even when they feed one another.
        for (work[0..changed_count]) |id| {
            const idx = id.index();
            self.nodes.items[idx].value = !self.nodes.items[idx].value;
            self.scheduleConsumers(&self.next, id);
        }

        std.mem.swap(std.ArrayListUnmanaged(NodeId), &self.current, &self.next);
        self.next.clearRetainingCapacity();
    }

    return .settled;
}

fn beginRound(self: *Circuit) void {
    self.round_serial +%= 1;
    if (self.round_serial != 0) return;

    // A serial wrap must not make a dormant group look evaluated this round.
    for (self.counter_groups.items) |*group| group.last_evaluated_round = 0;
    for (self.ram_groups.items) |*group| group.last_evaluated_round = 0;
    self.round_serial = 1;
}

fn rebuildIfNeeded(self: *Circuit) !void {
    if (!self.topology_dirty) return;

    const allocator = self.allocator;
    const node_count = self.nodes.items.len;

    try self.fanout_offsets.resize(allocator, node_count + 1);
    @memset(self.fanout_offsets.items, 0);

    var edge_count: usize = 0;
    for (self.nodes.items) |n| {
        if (!n.alive) continue;
        for (0..n.kind.inputCount()) |pin| {
            const source_id = self.inputSource(&n, pin);
            _ = self.nodeConst(source_id) orelse continue;
            const source_index = source_id.index();
            if (self.fanout_offsets.items[source_index] == std.math.maxInt(u32)) {
                return error.CircuitTooLarge;
            }
            self.fanout_offsets.items[source_index] += 1;
            edge_count = std.math.add(usize, edge_count, 1) catch return error.CircuitTooLarge;
            if (edge_count > std.math.maxInt(u32)) return error.CircuitTooLarge;
        }
    }

    try self.fanout.resize(allocator, edge_count);

    // Counts -> end positions. Filling backwards decrements them into starts,
    // leaving a complete CSR offset table without a temporary cursor buffer.
    var end: u32 = 0;
    for (self.fanout_offsets.items[0..node_count]) |*offset| {
        end += offset.*;
        offset.* = end;
    }
    self.fanout_offsets.items[node_count] = end;

    var target_index = node_count;
    while (target_index != 0) {
        target_index -= 1;
        const target = self.nodes.items[target_index];
        if (!target.alive) continue;

        var pin = target.kind.inputCount();
        while (pin != 0) {
            pin -= 1;
            const source_id = self.inputSource(&target, pin);
            if (self.nodeConst(source_id) == null) continue;
            const source_index = source_id.index();
            self.fanout_offsets.items[source_index] -= 1;
            const at: usize = @intCast(self.fanout_offsets.items[source_index]);
            self.fanout.items[at] = @enumFromInt(@as(u32, @intCast(target_index)));
        }
    }

    try self.current.ensureTotalCapacity(allocator, node_count);
    try self.next.ensureTotalCapacity(allocator, node_count);
    try self.queued.resize(allocator, node_count);
    @memset(self.queued.items, false);
    self.current.clearRetainingCapacity();
    self.next.clearRetainingCapacity();

    for (self.nodes.items, 0..) |*n, i| {
        if (!n.alive) continue;
        if (n.kind == .input) continue;

        const id: NodeId = @enumFromInt(@as(u32, @intCast(i)));
        self.current.appendAssumeCapacity(id);
        self.queued.items[i] = true;
    }

    self.topology_dirty = false;
}

fn evaluate(self: *Circuit, node_index: usize) !bool {
    const n = &self.nodes.items[node_index];
    if (n.kind == .counter) return self.evaluateCounter(node_index);
    if (n.kind == .ram) return self.evaluateRam(node_index);

    const a = self.readInput(n, 0);
    return switch (n.kind) {
        .input => n.value,
        .output => a,
        .not => !a,
        .buffer => a,
        .and2 => a and self.readInput(n, 1),
        .or2 => a or self.readInput(n, 1),
        .xor2 => a != self.readInput(n, 1),
        .nand2 => !(a and self.readInput(n, 1)),
        .nor2 => !(a or self.readInput(n, 1)),
        .xnor2 => a == self.readInput(n, 1),
        .dff => blk: {
            const clock = self.readInput(n, 1);
            const rising = !n.previous_clock and clock;
            n.previous_clock = clock;
            break :blk if (rising) a else n.value;
        },
        .counter, .ram => unreachable,
    };
}

fn evaluateRam(self: *Circuit, node_index: usize) !bool {
    const n = &self.nodes.items[node_index];
    const group_index = self.ramGroupIndex(n) orelse return n.value;
    const group = &self.ram_groups.items[group_index];

    if (group.last_evaluated_round != self.round_serial) {
        group.last_evaluated_round = self.round_serial;
        const address = self.ramAddress(group);
        const clock = if (self.nodeConst(group.clock)) |source| source.value else false;
        const rising = !group.previous_clock and clock;
        group.previous_clock = clock;
        const write_enable = if (self.nodeConst(group.write_enable)) |source| source.value else false;
        if (rising and write_enable and
            address >= group.base and address <= group.end)
        {
            var write_word: u64 = 0;
            const first = group.first.index();
            for (self.nodes.items[first..][0..group.width], 0..) |lane, bit| {
                const source = self.nodeConst(lane.inputs[0]) orelse continue;
                if (source.value) write_word |= @as(u64, 1) << @intCast(bit);
            }
            if (write_word == 0) {
                _ = group.cells.remove(address);
            } else {
                try group.cells.put(self.allocator, address, write_word);
            }
        }
        group.cached_read = if (address >= group.base and address <= group.end) group.cells.get(address) orelse 0 else 0;
    }

    const bit_index = node_index - group.first.index();
    return group.cached_read & (@as(u64, 1) << @intCast(bit_index)) != 0;
}

fn evaluateCounter(self: *Circuit, node_index: usize) bool {
    const n = &self.nodes.items[node_index];
    const group_index = self.counterGroupIndex(n) orelse return n.value;

    if (self.counter_groups.items[group_index].last_evaluated_round != self.round_serial) {
        const clock = self.readInput(n, 0);
        const mutable_group = &self.counter_groups.items[group_index];
        mutable_group.last_evaluated_round = self.round_serial;
        const rising = !mutable_group.previous_clock and clock;
        mutable_group.previous_clock = clock;
        if (rising) {
            if (self.readInput(n, 1)) {
                // Read outputs before the round commits, just like DFF data.
                // Sample the whole word once, even if another counter is its
                // source or DATA/LOAD also scheduled a lane in this round.
                var loaded: u64 = 0;
                const first = mutable_group.first.index();
                for (self.nodes.items[first..][0..mutable_group.width], 0..) |lane, bit| {
                    const source = self.nodeConst(lane.inputs[0]) orelse continue;
                    if (source.value) loaded |= @as(u64, 1) << @intCast(bit);
                }
                mutable_group.count = loaded;
            } else {
                mutable_group.count +%= 1;
                mutable_group.count &= counterMask(mutable_group.width);
            }
        }
    }

    const group = &self.counter_groups.items[group_index];
    const bit_index = node_index - group.first.index();
    return group.count & (@as(u64, 1) << @intCast(bit_index)) != 0;
}

fn readInput(self: *const Circuit, n: *const Node, pin: usize) bool {
    if (pin >= n.kind.inputCount()) return false;
    const source = self.nodeConst(self.inputSource(n, pin)) orelse return false;
    return source.value;
}

fn inputSource(self: *const Circuit, n: *const Node, pin: usize) NodeId {
    if (n.kind == .counter) {
        const group_index = self.counterGroupIndex(n) orelse return .invalid;
        const group = &self.counter_groups.items[group_index];
        return switch (pin) {
            0 => group.clock,
            1 => group.load,
            2 => n.inputs[0],
            else => .invalid,
        };
    }
    if (n.kind == .ram) {
        const group_index = self.ramGroupIndex(n) orelse return .invalid;
        const group = &self.ram_groups.items[group_index];
        if (pin < 64) return if (pin < group.address_width) group.address[pin] else .invalid;
        return switch (pin) {
            64 => n.inputs[0],
            65 => group.write_enable,
            66 => group.clock,
            else => .invalid,
        };
    }
    return n.inputs[pin];
}

fn scheduleConsumers(self: *Circuit, queue: *std.ArrayListUnmanaged(NodeId), source_id: NodeId) void {
    const source = source_id.index();
    const start: usize = @intCast(self.fanout_offsets.items[source]);
    const finish: usize = @intCast(self.fanout_offsets.items[source + 1]);

    for (self.fanout.items[start..finish]) |target_id| {
        const target = target_id.index();
        if (self.queued.items[target]) continue;
        self.queued.items[target] = true;
        queue.appendAssumeCapacity(target_id);
    }
}

fn removeCounterGroup(self: *Circuit, group_index: usize) bool {
    if (group_index >= self.counter_groups.items.len) return false;
    const group = &self.counter_groups.items[group_index];
    if (!group.alive) return false;

    const first = group.first.index();
    const end = first + @as(usize, group.width);
    for (self.nodes.items[first..end]) |*lane| {
        lane.alive = false;
        lane.value = false;
        lane.inputs = .{ .invalid, .invalid };
        lane.previous_clock = false;
    }

    group.alive = false;
    group.clock = .invalid;
    group.load = .invalid;
    group.count = 0;
    group.previous_clock = false;
    group.last_evaluated_round = 0;
    self.clearDownstreamRange(first, end);
    self.topology_dirty = true;
    return true;
}

fn removeRamGroup(self: *Circuit, group_index: usize) bool {
    if (group_index >= self.ram_groups.items.len) return false;
    const group = &self.ram_groups.items[group_index];
    if (!group.alive) return false;

    const first = group.first.index();
    const end = first + @as(usize, group.width);
    for (self.nodes.items[first..end]) |*lane| {
        lane.alive = false;
        lane.value = false;
        lane.inputs = .{ .invalid, .invalid };
        lane.previous_clock = false;
    }
    group.cells.deinit(self.allocator);
    group.cells = .empty;
    group.address = @splat(.invalid);
    group.write_enable = .invalid;
    group.clock = .invalid;
    group.previous_clock = false;
    group.cached_read = 0;
    group.last_evaluated_round = 0;
    group.alive = false;
    self.clearDownstreamRange(first, end);
    self.topology_dirty = true;
    return true;
}

fn clearDownstreamRange(self: *Circuit, first: usize, end: usize) void {
    for (self.nodes.items) |*candidate| {
        if (!candidate.alive) continue;
        if (candidate.kind == .ram) {
            if (candidate.inputs[0] != .invalid) {
                const source = candidate.inputs[0].index();
                if (source >= first and source < end) candidate.inputs[0] = .invalid;
            }
            continue;
        }
        // The second counter slot is metadata, never a signal reference.
        const count = if (candidate.kind == .counter) 1 else candidate.kind.inputCount();
        for (0..count) |pin| {
            const source_id = candidate.inputs[pin];
            if (source_id == .invalid) continue;
            const source = source_id.index();
            if (source >= first and source < end) candidate.inputs[pin] = .invalid;
        }
    }
    for (self.counter_groups.items) |*group| {
        if (!group.alive) continue;
        for ([_]*NodeId{ &group.clock, &group.load }) |source_id| {
            if (source_id.* == .invalid) continue;
            const source = source_id.*.index();
            if (source >= first and source < end) source_id.* = .invalid;
        }
    }
    for (self.ram_groups.items) |*group| {
        if (!group.alive) continue;
        for (group.address[0..group.address_width]) |*source_id| {
            if (source_id.* == .invalid) continue;
            const source = source_id.*.index();
            if (source >= first and source < end) source_id.* = .invalid;
        }
        for ([_]*NodeId{ &group.write_enable, &group.clock }) |source_id| {
            if (source_id.* == .invalid) continue;
            const source = source_id.*.index();
            if (source >= first and source < end) source_id.* = .invalid;
        }
    }
}

fn counterGroupIndex(self: *const Circuit, n: *const Node) ?usize {
    if (n.kind != .counter or n.inputs[1] == .invalid) return null;
    const group_index = n.inputs[1].index();
    if (group_index >= self.counter_groups.items.len) return null;
    if (!self.counter_groups.items[group_index].alive) return null;
    return group_index;
}

fn ramGroupIndex(self: *const Circuit, n: *const Node) ?usize {
    if (n.kind != .ram or n.inputs[1] == .invalid) return null;
    const group_index = n.inputs[1].index();
    if (group_index >= self.ram_groups.items.len) return null;
    if (!self.ram_groups.items[group_index].alive) return null;
    return group_index;
}

fn counterMask(width: u8) u64 {
    if (width == 64) return std.math.maxInt(u64);
    return (@as(u64, 1) << @intCast(width)) - 1;
}

fn busMask(width: u8) u64 {
    return counterMask(width);
}

fn addressFits(width: u8, address: u64) bool {
    return width == 64 or address < (@as(u64, 1) << @intCast(width));
}

fn ramAddress(self: *const Circuit, group: *const RamGroup) u64 {
    var result: u64 = 0;
    for (group.address[0..group.address_width], 0..) |source_id, bit| {
        const source = self.nodeConst(source_id) orelse continue;
        if (source.value) result |= @as(u64, 1) << @intCast(bit);
    }
    return result;
}

fn node(self: *Circuit, id: NodeId) ?*Node {
    if (id == .invalid) return null;
    const index = id.index();
    if (index >= self.nodes.items.len) return null;
    const n = &self.nodes.items[index];
    if (!n.alive) return null;
    return n;
}

fn nodeConst(self: *const Circuit, id: NodeId) ?*const Node {
    if (id == .invalid) return null;
    const index = id.index();
    if (index >= self.nodes.items.len) return null;
    const n = &self.nodes.items[index];
    if (!n.alive) return null;
    return n;
}

fn counterLane(first: NodeId, offset: usize) NodeId {
    return @enumFromInt(@intFromEnum(first) + @as(u32, @intCast(offset)));
}

fn ramLane(first: NodeId, offset: usize) NodeId {
    return @enumFromInt(@intFromEnum(first) + @as(u32, @intCast(offset)));
}

fn expectCounterValue(circuit: *const Circuit, first: NodeId, width: usize, expected: u64) !void {
    for (0..width) |bit_index| {
        const bit = @as(u64, 1) << @intCast(bit_index);
        try std.testing.expectEqual(expected & bit != 0, try circuit.value(counterLane(first, bit_index)));
    }
}

fn expectRamValue(circuit: *const Circuit, first: NodeId, width: usize, expected: u64) !void {
    for (0..width) |bit_index| {
        const bit = @as(u64, 1) << @intCast(bit_index);
        try std.testing.expectEqual(expected & bit != 0, try circuit.value(ramLane(first, bit_index)));
    }
}

fn expectSettled(circuit: *Circuit) !void {
    try std.testing.expectEqual(RunResult.settled, try circuit.run(256));
}

fn pulseClock(circuit: *Circuit, clock: NodeId) !void {
    try circuit.setInput(clock, false);
    try expectSettled(circuit);
    try circuit.setInput(clock, true);
    try expectSettled(circuit);
}

test "fanout uses direct source-to-input connections" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    const a = try circuit.addNode(.input);
    const b = try circuit.addNode(.input);
    const and_gate = try circuit.addNode(.and2);
    const first_out = try circuit.addNode(.output);
    const second_out = try circuit.addNode(.output);

    try circuit.connect(a, and_gate, 0);
    try circuit.connect(b, and_gate, 1);
    try circuit.connect(and_gate, first_out, 0);
    try circuit.connect(and_gate, second_out, 0);

    try std.testing.expectEqual(RunResult.settled, try circuit.run(8));
    try std.testing.expectEqual(false, try circuit.value(first_out));
    try std.testing.expectEqual(false, try circuit.value(second_out));

    try circuit.setInput(a, true);
    try circuit.setInput(b, true);
    try std.testing.expectEqual(RunResult.settled, try circuit.run(8));
    try std.testing.expectEqual(true, try circuit.value(first_out));
    try std.testing.expectEqual(true, try circuit.value(second_out));
}

test "additional combinational gates evaluate expected truth table" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    const a = try circuit.addNode(.input);
    const b = try circuit.addNode(.input);
    const buffer = try circuit.addNode(.buffer);
    const nand = try circuit.addNode(.nand2);
    const nor = try circuit.addNode(.nor2);
    const xnor = try circuit.addNode(.xnor2);

    try circuit.connect(a, buffer, 0);
    for ([_]NodeId{ nand, nor, xnor }) |gate| {
        try circuit.connect(a, gate, 0);
        try circuit.connect(b, gate, 1);
    }

    const Case = struct { a: bool, b: bool, nand: bool, nor: bool, xnor: bool };
    for ([_]Case{
        .{ .a = false, .b = false, .nand = true, .nor = true, .xnor = true },
        .{ .a = false, .b = true, .nand = true, .nor = false, .xnor = false },
        .{ .a = true, .b = false, .nand = true, .nor = false, .xnor = false },
        .{ .a = true, .b = true, .nand = false, .nor = false, .xnor = true },
    }) |case| {
        try circuit.setInput(a, case.a);
        try circuit.setInput(b, case.b);
        try std.testing.expectEqual(RunResult.settled, try circuit.run(8));
        try std.testing.expectEqual(case.a, try circuit.value(buffer));
        try std.testing.expectEqual(case.nand, try circuit.value(nand));
        try std.testing.expectEqual(case.nor, try circuit.value(nor));
        try std.testing.expectEqual(case.xnor, try circuit.value(xnor));
    }
}

test "editing leaves a usable incomplete circuit" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    const source = try circuit.addNode(.input);
    const inverter = try circuit.addNode(.not);
    const out = try circuit.addNode(.output);
    try circuit.connect(source, inverter, 0);
    try circuit.connect(inverter, out, 0);

    try circuit.setInput(source, true);
    try std.testing.expectEqual(RunResult.settled, try circuit.run(8));
    try std.testing.expectEqual(false, try circuit.value(out));

    try std.testing.expect(circuit.removeNode(source));
    try std.testing.expectEqual(RunResult.settled, try circuit.run(8));
    // A disconnected input reads false, so NOT produces true while editing.
    try std.testing.expectEqual(true, try circuit.value(out));
    try std.testing.expect(!circuit.removeNode(source));
}

test "round budget reports pending and resumes" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    const input = try circuit.addNode(.input);
    const first = try circuit.addNode(.not);
    const second = try circuit.addNode(.not);
    const out = try circuit.addNode(.output);
    try circuit.connect(input, first, 0);
    try circuit.connect(first, second, 0);
    try circuit.connect(second, out, 0);

    try std.testing.expectEqual(RunResult.pending, try circuit.run(1));
    try std.testing.expectEqual(RunResult.pending, try circuit.run(1));
    try std.testing.expectEqual(RunResult.settled, try circuit.run(8));
    try std.testing.expectEqual(false, try circuit.value(out));
}

test "steady state input changes allocate nothing" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var circuit = Circuit.init(failing.allocator());
    defer circuit.deinit();

    const a = try circuit.addNode(.input);
    const b = try circuit.addNode(.input);
    const gate = try circuit.addNode(.xor2);
    try circuit.connect(a, gate, 0);
    try circuit.connect(b, gate, 1);
    try std.testing.expectEqual(RunResult.settled, try circuit.run(8));

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    try circuit.setInput(a, true);
    try std.testing.expectEqual(RunResult.settled, try circuit.run(8));
    try circuit.setInput(b, true);
    try std.testing.expectEqual(RunResult.settled, try circuit.run(8));
    try std.testing.expectEqual(false, try circuit.value(gate));
    try std.testing.expect(!failing.has_induced_failure);
}

test "dffs sample the same old state on a rising edge" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    const d = try circuit.addNode(.input);
    const clock = try circuit.addNode(.input);
    const first = try circuit.addNode(.dff);
    const second = try circuit.addNode(.dff);
    try circuit.connect(d, first, 0);
    try circuit.connect(clock, first, 1);
    try circuit.connect(first, second, 0);
    try circuit.connect(clock, second, 1);

    try std.testing.expectEqual(RunResult.settled, try circuit.run(8));
    try circuit.setInput(d, true);
    try std.testing.expectEqual(RunResult.settled, try circuit.run(8));

    try circuit.setInput(clock, true);
    try std.testing.expectEqual(RunResult.settled, try circuit.run(8));
    try std.testing.expectEqual(true, try circuit.value(first));
    try std.testing.expectEqual(false, try circuit.value(second));

    try circuit.setInput(clock, false);
    try std.testing.expectEqual(RunResult.settled, try circuit.run(8));
    try circuit.setInput(clock, true);
    try std.testing.expectEqual(RunResult.settled, try circuit.run(8));
    try std.testing.expectEqual(true, try circuit.value(second));
}

test "topology edits do not swallow a pending dff rising edge" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    const data = try circuit.addNode(.input);
    const clock = try circuit.addNode(.input);
    const dff = try circuit.addNode(.dff);
    try circuit.connect(data, dff, 0);
    try circuit.connect(clock, dff, 1);

    try std.testing.expectEqual(RunResult.settled, try circuit.run(8));
    try circuit.setInput(data, true);
    try std.testing.expectEqual(RunResult.settled, try circuit.run(8));

    try circuit.setInput(clock, true);
    _ = try circuit.addNode(.output);
    try std.testing.expectEqual(RunResult.settled, try circuit.run(8));
    try std.testing.expectEqual(true, try circuit.value(dff));
}

test "combinational oscillator remains pending" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    const inverter = try circuit.addNode(.not);
    try circuit.connect(inverter, inverter, 0);

    try std.testing.expectEqual(RunResult.pending, try circuit.run(16));
    try std.testing.expectEqual(RunResult.pending, try circuit.run(16));
}

test "node ids are simple monotonic u32 values" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    const a = try circuit.addNode(.input);
    const b = try circuit.addNode(.not);
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(a));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(b));
    try std.testing.expect(circuit.removeNode(a));

    const c = try circuit.addNode(.output);
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(c));
    try std.testing.expectError(error.InvalidNode, circuit.connect(a, c, 0));
}

test "checkpoint retains dff output and clock history without a new edge" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();
    const data = try circuit.addNode(.input);
    const clock = try circuit.addNode(.input);
    const flop = try circuit.addNode(.dff);
    try circuit.connect(data, flop, 0);
    try circuit.connect(clock, flop, 1);
    try circuit.setInput(clock, true);
    try circuit.restoreState(flop, 3);
    try std.testing.expectEqual(RunResult.settled, try circuit.run(8));
    try std.testing.expectEqual(true, try circuit.value(flop));
    try std.testing.expectEqual(@as(u2, 3), try circuit.state(flop));
    try circuit.setInput(clock, false);
    try std.testing.expectEqual(RunResult.settled, try circuit.run(8));
    try circuit.setInput(clock, true);
    try std.testing.expectEqual(RunResult.settled, try circuit.run(8));
    try std.testing.expectEqual(false, try circuit.value(flop));
    try std.testing.expectEqual(@as(u2, 2), try circuit.state(flop));
    try std.testing.expectError(error.InvalidNode, circuit.state(.invalid));
    try std.testing.expectError(error.InvalidNode, circuit.restoreState(.invalid, 0));
}

test "three bit counter rolls over and accepts clock on any lane" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    const clock = try circuit.addNode(.input);
    const counter = try circuit.addCounter(3);
    try circuit.connect(clock, counterLane(counter, 1), 0);
    try expectSettled(&circuit);

    for (1..9) |step| {
        try pulseClock(&circuit, clock);
        try expectCounterValue(&circuit, counter, 3, @intCast(step & 7));
        for (0..3) |bit_index| {
            const saved = try circuit.state(counterLane(counter, bit_index));
            try std.testing.expect(saved & 2 != 0);
        }
    }
}

test "setting counter value preserves clock history and schedules changed outputs" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();
    const clock = try circuit.addNode(.input);
    const counter = try circuit.addCounter(3);
    const out = try circuit.addNode(.output);
    try circuit.connect(clock, counter, 0);
    try circuit.connect(counterLane(counter, 2), out, 0);
    try expectSettled(&circuit);
    try circuit.setInput(clock, true);
    try expectSettled(&circuit);
    try circuit.setCounter(counterLane(counter, 1), 7);
    try expectSettled(&circuit);
    try expectCounterValue(&circuit, counter, 3, 7);
    try std.testing.expectEqual(true, try circuit.value(out));
    try std.testing.expectEqual(@as(u2, 3), try circuit.state(counter));
    try circuit.setInput(clock, false);
    try expectSettled(&circuit);
    try circuit.setInput(clock, true);
    try expectSettled(&circuit);
    try expectCounterValue(&circuit, counter, 3, 0);
    try std.testing.expectEqual(false, try circuit.value(out));
    try std.testing.expectError(error.ValueOutOfRange, circuit.setCounter(counter, 8));
    try std.testing.expectError(error.NotCounter, circuit.setCounter(clock, 0));
    try std.testing.expectError(error.InvalidNode, circuit.setCounter(.invalid, 0));
    const wide = try circuit.addCounter(64);
    try circuit.setCounter(wide, std.math.maxInt(u64));
    try expectSettled(&circuit);
    try expectCounterValue(&circuit, wide, 64, std.math.maxInt(u64));
}

test "sixty four bit counter carries and rolls over from restored state" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    const clock = try circuit.addNode(.input);
    const counter = try circuit.addCounter(64);
    try circuit.connect(clock, counterLane(counter, 63), 0);

    for (0..64) |bit_index| {
        const saved: u2 = if (bit_index < 63) 1 else 0;
        try circuit.restoreState(counterLane(counter, bit_index), saved);
    }
    try expectSettled(&circuit);
    try expectCounterValue(&circuit, counter, 64, std.math.maxInt(u64) >> 1);

    try circuit.setInput(clock, true);
    try expectSettled(&circuit);
    try expectCounterValue(&circuit, counter, 64, @as(u64, 1) << 63);

    try circuit.setInput(clock, false);
    try expectSettled(&circuit);
    for (0..64) |bit_index| {
        try circuit.restoreState(counterLane(counter, bit_index), 1);
    }
    try expectSettled(&circuit);
    try expectCounterValue(&circuit, counter, 64, std.math.maxInt(u64));

    try circuit.setInput(clock, true);
    try expectSettled(&circuit);
    try expectCounterValue(&circuit, counter, 64, 0);
}

test "held high counter clock survives topology rebuild without a new edge" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    const clock = try circuit.addNode(.input);
    const counter = try circuit.addCounter(4);
    try circuit.connect(clock, counterLane(counter, 2), 0);
    try expectSettled(&circuit);

    try circuit.setInput(clock, true);
    try expectSettled(&circuit);
    try expectCounterValue(&circuit, counter, 4, 1);

    const mirror = try circuit.addNode(.output);
    try circuit.connect(counter, mirror, 0);
    try expectSettled(&circuit);
    try expectCounterValue(&circuit, counter, 4, 1);
    try std.testing.expectEqual(true, try circuit.value(mirror));
}

test "counter and dff commit together on a shared rising edge" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    const clock = try circuit.addNode(.input);
    const counter = try circuit.addCounter(2);
    const dff = try circuit.addNode(.dff);
    try circuit.connect(clock, counter, 0);
    try circuit.connect(counter, dff, 0);
    try circuit.connect(clock, dff, 1);
    try expectSettled(&circuit);

    try circuit.setInput(clock, true);
    try expectSettled(&circuit);
    try expectCounterValue(&circuit, counter, 2, 1);
    try std.testing.expectEqual(false, try circuit.value(dff));

    try circuit.setInput(clock, false);
    try expectSettled(&circuit);
    try circuit.setInput(clock, true);
    try expectSettled(&circuit);
    try expectCounterValue(&circuit, counter, 2, 2);
    try std.testing.expectEqual(true, try circuit.value(dff));
}

test "steady state counter clock toggles allocate nothing" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var circuit = Circuit.init(failing.allocator());
    defer circuit.deinit();

    const clock = try circuit.addNode(.input);
    const counter = try circuit.addCounter(64);
    try circuit.connect(clock, counterLane(counter, 31), 0);
    try expectSettled(&circuit);

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    for (0..32) |step| {
        try circuit.setInput(clock, step & 1 == 0);
        try expectSettled(&circuit);
    }
    try std.testing.expect(!failing.has_induced_failure);
}

test "counter allocation is transactional when node reservation fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var circuit = Circuit.init(failing.allocator());
    defer circuit.deinit();

    failing.fail_index = failing.alloc_index + 1;
    try std.testing.expectError(error.OutOfMemory, circuit.addCounter(8));
    try std.testing.expectEqual(@as(usize, 0), circuit.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 0), circuit.counter_groups.items.len);
    try std.testing.expect(failing.has_induced_failure);
}

test "removing one counter lane removes the group and clears consumers" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    const initial_node_count = circuit.nodes.items.len;
    try std.testing.expectError(error.InvalidWidth, circuit.addCounter(0));
    try std.testing.expectError(error.InvalidWidth, circuit.addCounter(65));
    try std.testing.expectEqual(initial_node_count, circuit.nodes.items.len);

    const clock = try circuit.addNode(.input);
    const counter = try circuit.addCounter(3);
    const low_out = try circuit.addNode(.output);
    const high_out = try circuit.addNode(.output);
    try circuit.connect(clock, counterLane(counter, 2), 0);
    try std.testing.expect(circuit.disconnect(counter, 0));
    try std.testing.expect(!circuit.disconnect(counterLane(counter, 1), 0));
    try circuit.connect(clock, counterLane(counter, 1), 0);
    try circuit.connect(counter, low_out, 0);
    try circuit.connect(counterLane(counter, 2), high_out, 0);
    try expectSettled(&circuit);
    try pulseClock(&circuit, clock);
    try std.testing.expectEqual(true, try circuit.value(low_out));

    try std.testing.expect(circuit.removeNode(counterLane(counter, 1)));
    for (0..3) |bit_index| {
        const lane = counterLane(counter, bit_index);
        try std.testing.expectError(error.InvalidNode, circuit.value(lane));
        try std.testing.expectError(error.InvalidNode, circuit.state(lane));
        try std.testing.expectError(error.InvalidNode, circuit.restoreState(lane, 0));
    }
    try std.testing.expectError(error.InvalidNode, circuit.connect(clock, counter, 0));
    try expectSettled(&circuit);
    try std.testing.expectEqual(false, try circuit.value(low_out));
    try std.testing.expectEqual(false, try circuit.value(high_out));
    try std.testing.expect(!circuit.removeNode(counter));

    const single = try circuit.addNode(.counter);
    try std.testing.expectEqual(Kind.counter, circuit.nodes.items[single.index()].kind);
    try std.testing.expectEqual(false, try circuit.value(single));
}

test "counter loads another chip's complete word only on rising edges" {
    for ([_]usize{ 1, 3, 32, 64 }) |width| {
        var circuit = Circuit.init(std.testing.allocator);
        defer circuit.deinit();
        const clock = try circuit.addNode(.input);
        const load = try circuit.addNode(.input);
        const data = try circuit.addCounter(width);
        const counter = try circuit.addCounter(width);
        // Shared controls may be connected through any output lane.
        try circuit.connect(clock, counterLane(counter, width - 1), 0);
        try circuit.connect(load, counterLane(counter, width - 1), 1);
        for (0..width) |bit| try circuit.connect(counterLane(data, bit), counterLane(counter, bit), 2);
        const pattern = (@as(u64, 1) << @intCast(width - 1)) | 1;
        try circuit.setCounter(data, pattern);
        try circuit.setInput(load, true);
        try expectSettled(&circuit);
        try expectCounterValue(&circuit, counter, width, 0);
        try pulseClock(&circuit, clock);
        try expectCounterValue(&circuit, counter, width, pattern);

        try circuit.setCounter(data, 0);
        try expectSettled(&circuit);
        try circuit.setInput(load, false);
        try expectSettled(&circuit);
        try expectCounterValue(&circuit, counter, width, pattern);
        try pulseClock(&circuit, clock);
        try expectCounterValue(&circuit, counter, width, (pattern +% 1) & counterMask(@intCast(width)));

        try circuit.setInput(load, true);
        try expectSettled(&circuit);
        try pulseClock(&circuit, clock);
        try expectCounterValue(&circuit, counter, width, 0);
        try circuit.setCounter(data, counterMask(@intCast(width)));
        try pulseClock(&circuit, clock);
        try expectCounterValue(&circuit, counter, width, counterMask(@intCast(width)));
        try circuit.setInput(load, false);
        try pulseClock(&circuit, clock);
        try expectCounterValue(&circuit, counter, width, 0);
    }
}

test "counter loading and dff sampling use the old outputs in either creation order" {
    for ([_]bool{ false, true }) |reverse| {
        var circuit = Circuit.init(std.testing.allocator);
        defer circuit.deinit();
        const clock = try circuit.addNode(.input);
        const load = try circuit.addNode(.input);
        const first = try circuit.addCounter(3);
        const second = try circuit.addCounter(3);
        const source = if (reverse) second else first;
        const target = if (reverse) first else second;
        const flop = try circuit.addNode(.dff);
        try circuit.connect(clock, source, 0);
        try circuit.connect(clock, target, 0);
        try circuit.connect(load, target, 1);
        for (0..3) |bit| try circuit.connect(counterLane(source, bit), counterLane(target, bit), 2);
        try circuit.connect(target, flop, 0);
        try circuit.connect(clock, flop, 1);
        try circuit.setInput(load, true);
        try circuit.setCounter(source, 3);
        try expectSettled(&circuit);
        try pulseClock(&circuit, clock);
        try expectCounterValue(&circuit, source, 3, 4);
        try expectCounterValue(&circuit, target, 3, 3);
        try std.testing.expectEqual(false, try circuit.value(flop));
        try pulseClock(&circuit, clock);
        try expectCounterValue(&circuit, source, 3, 5);
        try expectCounterValue(&circuit, target, 3, 4);
        try std.testing.expectEqual(true, try circuit.value(flop));
    }
}

test "removing load or data sources preserves counter metadata and clears shared controls" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();
    // This node id intentionally equals the first counter's group index.
    const data = try circuit.addNode(.input);
    const load = try circuit.addNode(.input);
    const clock = try circuit.addNode(.input);
    const counter = try circuit.addCounter(3);
    try circuit.connect(clock, counter, 0);
    try circuit.connect(load, counterLane(counter, 2), 1);
    for (0..3) |bit| try circuit.connect(data, counterLane(counter, bit), 2);
    try circuit.setInput(data, true);
    try circuit.setInput(load, true);
    try pulseClock(&circuit, clock);
    try expectCounterValue(&circuit, counter, 3, 7);
    try std.testing.expect(circuit.removeNode(data));
    try expectSettled(&circuit);
    try expectCounterValue(&circuit, counter, 3, 7);
    try pulseClock(&circuit, clock);
    try expectCounterValue(&circuit, counter, 3, 0);
    try std.testing.expect(circuit.removeNode(load));
    try std.testing.expect(!circuit.disconnect(counter, 1));
    try pulseClock(&circuit, clock);
    try expectCounterValue(&circuit, counter, 3, 1);
    try std.testing.expect(circuit.removeNode(clock));
    try std.testing.expect(!circuit.disconnect(counterLane(counter, 2), 0));
    try expectSettled(&circuit);
    try expectCounterValue(&circuit, counter, 3, 1);
    try std.testing.expectError(error.InvalidPin, circuit.connect(counter, counter, 3));
    try std.testing.expect(!circuit.disconnect(counter, 3));
}

test "counter lane data disconnect is local and deleting a source group clears load" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();
    const source = try circuit.addCounter(2);
    const target = try circuit.addCounter(3);
    const clock = try circuit.addNode(.input);
    try circuit.connect(clock, target, 0);
    try circuit.connect(source, target, 1);
    for (0..3) |bit| try circuit.connect(source, counterLane(target, bit), 2);
    try circuit.setCounter(source, 1);
    try pulseClock(&circuit, clock);
    try expectCounterValue(&circuit, target, 3, 7);
    try std.testing.expect(circuit.disconnect(counterLane(target, 1), 2));
    try std.testing.expect(!circuit.disconnect(counterLane(target, 1), 2));
    try pulseClock(&circuit, clock);
    try expectCounterValue(&circuit, target, 3, 5);
    try std.testing.expect(circuit.removeNode(counterLane(source, 1)));
    try std.testing.expect(!circuit.disconnect(target, 1));
    try std.testing.expect(!circuit.disconnect(counterLane(target, 2), 2));
    try pulseClock(&circuit, clock);
    try expectCounterValue(&circuit, target, 3, 6);
}

test "counter load and increment reuse storage after topology preparation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var circuit = Circuit.init(failing.allocator());
    defer circuit.deinit();
    const clock = try circuit.addNode(.input);
    const load = try circuit.addNode(.input);
    const source = try circuit.addCounter(64);
    const target = try circuit.addCounter(64);
    try circuit.connect(clock, target, 0);
    try circuit.connect(load, target, 1);
    for (0..64) |bit| try circuit.connect(counterLane(source, bit), counterLane(target, bit), 2);
    try expectSettled(&circuit);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    for (0..16) |step| {
        const pattern = (@as(u64, 1) << 63) | @as(u64, @intCast(step));
        try circuit.setCounter(source, pattern);
        try circuit.setInput(load, true);
        try pulseClock(&circuit, clock);
        try expectCounterValue(&circuit, target, 64, pattern);
        try circuit.setInput(load, false);
        try pulseClock(&circuit, clock);
        try expectCounterValue(&circuit, target, 64, pattern + 1);
    }
    try std.testing.expect(!failing.has_induced_failure);
}

test "sparse sixty four bit RAM maps a high address window and writes only on rising edges" {
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();

    const ram = try circuit.addRam(64, 64);
    const base: u64 = 0x0020_0000_0000_0001;
    const last = base + 3;
    try circuit.configureRam(ram, base, last);
    try circuit.ramWrite(ram, base, 0x8000_0001_0000_0001);
    try circuit.ramWrite(ram, last, std.math.maxInt(u64));
    try std.testing.expectEqual(@as(usize, 2), try circuit.ramCellCount(ram));
    try std.testing.expectEqual(@as(u64, 0x8000_0001_0000_0001), try circuit.ramRead(ram, base));
    try std.testing.expectEqual(std.math.maxInt(u64), try circuit.ramRead(ram, last));
    try std.testing.expectError(error.AddressOutOfRange, circuit.ramRead(ram, base - 1));
    try std.testing.expectError(error.AddressOutOfRange, circuit.ramWrite(ram, last + 1, 1));

    var address: [64]NodeId = undefined;
    var data: [64]NodeId = undefined;
    for (0..64) |bit| {
        address[bit] = try circuit.addNode(.input);
        data[bit] = try circuit.addNode(.input);
        try circuit.connect(address[bit], ram, bit);
        try circuit.connect(data[bit], ramLane(ram, bit), 64);
    }
    const write_enable = try circuit.addNode(.input);
    const clock = try circuit.addNode(.input);
    try circuit.connect(write_enable, ram, 65);
    try circuit.connect(clock, ramLane(ram, 63), 66);

    const setBus = struct {
        fn apply(c: *Circuit, lanes: []const NodeId, word: u64) !void {
            for (lanes, 0..) |lane, bit| try c.setInput(lane, word & (@as(u64, 1) << @intCast(bit)) != 0);
        }
    }.apply;

    try setBus(&circuit, &address, base);
    try expectSettled(&circuit);
    try expectRamValue(&circuit, ram, 64, 0x8000_0001_0000_0001);
    try setBus(&circuit, &address, last);
    try expectSettled(&circuit);
    try expectRamValue(&circuit, ram, 64, std.math.maxInt(u64));

    const written: u64 = 0xfedc_ba98_7654_3210;
    try setBus(&circuit, &address, base + 1);
    try setBus(&circuit, &data, written);
    try circuit.setInput(write_enable, true);
    try circuit.setInput(clock, true);
    try expectSettled(&circuit);
    try std.testing.expectEqual(written, try circuit.ramRead(ram, base + 1));
    try expectRamValue(&circuit, ram, 64, written);

    // DATA changes while CLK remains high must not create another write, even
    // when an unrelated topology edit forces fanout reconstruction.
    try setBus(&circuit, &data, 0x1234);
    _ = try circuit.addNode(.output);
    try expectSettled(&circuit);
    try std.testing.expectEqual(written, try circuit.ramRead(ram, base + 1));

    // An address outside the window reads zero and a rising WE edge is ignored.
    try circuit.setInput(clock, false);
    try setBus(&circuit, &address, base - 1);
    try setBus(&circuit, &data, 0x55aa);
    try expectSettled(&circuit);
    try expectRamValue(&circuit, ram, 64, 0);
    try circuit.setInput(clock, true);
    try expectSettled(&circuit);
    try std.testing.expectEqual(@as(usize, 3), try circuit.ramCellCount(ram));

    try circuit.ramWrite(ram, base + 1, 0);
    try std.testing.expectEqual(@as(usize, 2), try circuit.ramCellCount(ram));
    try circuit.configureRam(ram, base + 1, last);
    try std.testing.expectEqual(@as(usize, 1), try circuit.ramCellCount(ram));
}

test "RAM checkpoint retains held high clock history without a phantom write" {
    var original = Circuit.init(std.testing.allocator);
    defer original.deinit();
    const ram = try original.addRam(8, 8);
    const data = try original.addNode(.input);
    const write_enable = try original.addNode(.input);
    const clock = try original.addNode(.input);
    for (0..8) |bit| try original.connect(data, ramLane(ram, bit), 64);
    try original.connect(write_enable, ram, 65);
    try original.connect(clock, ram, 66);
    try original.setInput(data, true);
    try original.setInput(write_enable, true);
    try original.setInput(clock, true);
    try expectSettled(&original);
    try std.testing.expectEqual(@as(u64, 0xff), try original.ramRead(ram, 0));
    const saved = try original.state(ram);
    try std.testing.expect(saved & 2 != 0);

    var restored = Circuit.init(std.testing.allocator);
    defer restored.deinit();
    const restored_ram = try restored.addRam(8, 8);
    const restored_data = try restored.addNode(.input);
    const restored_we = try restored.addNode(.input);
    const restored_clock = try restored.addNode(.input);
    for (0..8) |bit| try restored.connect(restored_data, ramLane(restored_ram, bit), 64);
    try restored.connect(restored_we, restored_ram, 65);
    try restored.connect(restored_clock, restored_ram, 66);
    try restored.ramWrite(restored_ram, 0, 0x3c);
    for (0..8) |bit| try restored.restoreState(ramLane(restored_ram, bit), saved & 2);
    try restored.setInput(restored_data, true);
    try restored.setInput(restored_we, true);
    try restored.setInput(restored_clock, true);
    try expectSettled(&restored);
    try std.testing.expectEqual(@as(u64, 0x3c), try restored.ramRead(restored_ram, 0));
}
