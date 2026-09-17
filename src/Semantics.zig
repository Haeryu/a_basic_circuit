const std = @import("std");

pub const max_width: u8 = 64;
pub const max_address_width: u8 = 6;
pub const max_ram_address_width: u8 = 64;

pub const Kind = enum(u8) {
    input,
    output,
    not,
    and2,
    or2,
    xor2,
    dff,
    buffer,
    nand2,
    nor2,
    xnor2,
    oscillator,
    clock,
    mux,
    demux,
    decoder,
    adder,
    split,
    join,
    display,
    register,
    alu,
    ram,
};

pub const Field = enum(u8) {
    none = 0,
    width = 1,
    one = 2,
    address_width = 3,
    split_width = 4,
    high_width = 5,
    decoded_width = 6,
    two = 7,
};

pub const Port = struct { width: u8, field: Field };

pub const ConnectionStatus = enum(u8) {
    ok = 0,
    missing_source = 1,
    inactive_output = 2,
    inactive_input = 3,
    width_mismatch = 4,
};

pub fn connectionStatus(source_present: bool, source: ?Port, target: ?Port) ConnectionStatus {
    if (!source_present) return .missing_source;
    const output = source orelse return .inactive_output;
    const input = target orelse return .inactive_input;
    return if (output.width == input.width) .ok else .width_mismatch;
}

pub fn kind(raw: u32) ?Kind {
    if (raw > @intFromEnum(Kind.ram)) return null;
    return @enumFromInt(@as(u8, @intCast(raw)));
}

pub fn validShape(k: Kind, width: u32, address_width: u32, split_width: u32) bool {
    if (width == 0 or width > max_width) return false;
    const address_max: u32 = if (k == .ram) max_ram_address_width else max_address_width;
    if (address_width == 0 or address_width > address_max) return false;
    if (split_width == 0 or split_width > max_width) return false;
    if (k == .oscillator and width != 1) return false;
    if ((k == .split or k == .join) and (width < 2 or split_width >= width)) return false;
    return true;
}

pub fn inputCount(k: Kind, address_width: u8, rgb: bool) u32 {
    return switch (k) {
        .input, .oscillator => 0,
        .clock => 3,
        .register => 3,
        .alu => 3,
        .ram => 4,
        .output, .not, .buffer, .split, .decoder => 1,
        .and2, .or2, .xor2, .nand2, .nor2, .xnor2, .dff, .demux, .join => 2,
        .adder => 3,
        .mux => 1 + (@as(u32, 1) << @intCast(address_width)),
        .display => if (rgb) 3 else 1,
    };
}

pub fn outputCount(k: Kind, address_width: u8) u32 {
    return switch (k) {
        .output, .display => 0,
        .demux => @as(u32, 1) << @intCast(address_width),
        .adder, .split, .alu => 2,
        else => 1,
    };
}

pub fn inputPort(k: Kind, width: u8, address_width: u8, split_width: u8, rgb: bool, pin: u32) ?Port {
    if (pin >= inputCount(k, address_width, rgb)) return null;
    return switch (k) {
        .clock => if (pin < 2) .{ .width = 1, .field = .one } else .{ .width = width, .field = .width },
        .register => if (pin == 0) .{ .width = width, .field = .width } else .{ .width = 1, .field = .one },
        .alu => if (pin < 2) .{ .width = width, .field = .width } else .{ .width = 2, .field = .two },
        .ram => switch (pin) {
            0 => .{ .width = address_width, .field = .address_width },
            1 => .{ .width = width, .field = .width },
            else => .{ .width = 1, .field = .one },
        },
        .display => .{ .width = width, .field = .width },
        .mux => if (pin == 0) .{ .width = address_width, .field = .address_width } else .{ .width = width, .field = .width },
        .demux => if (pin == 0) .{ .width = width, .field = .width } else .{ .width = address_width, .field = .address_width },
        .decoder => .{ .width = address_width, .field = .address_width },
        .adder => if (pin == 2) .{ .width = 1, .field = .one } else .{ .width = width, .field = .width },
        .join => if (pin == 0) .{ .width = split_width, .field = .split_width } else .{ .width = width - split_width, .field = .high_width },
        .dff => if (pin == 1) .{ .width = 1, .field = .one } else .{ .width = width, .field = .width },
        else => .{ .width = width, .field = .width },
    };
}

pub fn outputPort(k: Kind, width: u8, address_width: u8, split_width: u8, pin: u32) ?Port {
    if (pin >= outputCount(k, address_width)) return null;
    return switch (k) {
        .oscillator => .{ .width = 1, .field = .one },
        .decoder => .{ .width = @as(u8, 1) << @intCast(address_width), .field = .decoded_width },
        .adder => if (pin == 0) .{ .width = width, .field = .width } else .{ .width = 1, .field = .one },
        .alu => if (pin == 0) .{ .width = width, .field = .width } else .{ .width = 1, .field = .one },
        .split => if (pin == 0) .{ .width = split_width, .field = .split_width } else .{ .width = width - split_width, .field = .high_width },
        else => .{ .width = width, .field = .width },
    };
}

pub const WidthGroup = struct {
    min: u8,
    max: u8,
    preferred: u8,
    dependent: bool,
    override: u8 = 0,
};

pub const Relation = union(enum) {
    sum: struct { total: u16, low: u16, high: u16 },
    pow: struct { address: u16, out: u16 },
};

fn maskRange(min: u8, max: u8) u64 {
    var result: u64 = 0;
    var value = min;
    while (value <= max) : (value += 1) result |= @as(u64, 1) << @intCast(value - 1);
    return result;
}

fn contains(domain: u64, value: u8) bool {
    return domain & (@as(u64, 1) << @intCast(value - 1)) != 0;
}

fn singleton(value: u8) u64 {
    return @as(u64, 1) << @intCast(value - 1);
}

fn firstValue(domain: u64) u8 {
    return @intCast(@ctz(domain) + 1);
}

fn reduce(domains: []u64, relations: []const Relation) bool {
    var changed = true;
    while (changed) {
        changed = false;
        for (relations) |relation| switch (relation) {
            .sum => |r| {
                if (r.total >= domains.len or r.low >= domains.len or r.high >= domains.len) return false;
                var allow_total: u64 = 0;
                var allow_low: u64 = 0;
                var allow_high: u64 = 0;
                var low: u8 = 1;
                while (low <= max_width) : (low += 1) if (contains(domains[r.low], low)) {
                    var high: u8 = 1;
                    while (high <= max_width) : (high += 1) if (contains(domains[r.high], high)) {
                        const total: u16 = @as(u16, low) + @as(u16, high);
                        if (total <= max_width and contains(domains[r.total], @intCast(total))) {
                            allow_low |= singleton(low);
                            allow_high |= singleton(high);
                            allow_total |= singleton(@intCast(total));
                        }
                    };
                };
                const next = [3]u64{ domains[r.total] & allow_total, domains[r.low] & allow_low, domains[r.high] & allow_high };
                if (next[0] == 0 or next[1] == 0 or next[2] == 0) return false;
                if (next[0] != domains[r.total]) {
                    domains[r.total] = next[0];
                    changed = true;
                }
                if (next[1] != domains[r.low]) {
                    domains[r.low] = next[1];
                    changed = true;
                }
                if (next[2] != domains[r.high]) {
                    domains[r.high] = next[2];
                    changed = true;
                }
            },
            .pow => |r| {
                if (r.address >= domains.len or r.out >= domains.len) return false;
                var allow_address: u64 = 0;
                var allow_out: u64 = 0;
                var address: u8 = 1;
                while (address <= max_address_width) : (address += 1) if (contains(domains[r.address], address)) {
                    const out: u8 = @as(u8, 1) << @intCast(address);
                    if (contains(domains[r.out], out)) {
                        allow_address |= singleton(address);
                        allow_out |= singleton(out);
                    }
                };
                const next_address = domains[r.address] & allow_address;
                const next_out = domains[r.out] & allow_out;
                if (next_address == 0 or next_out == 0) return false;
                if (next_address != domains[r.address]) {
                    domains[r.address] = next_address;
                    changed = true;
                }
                if (next_out != domains[r.out]) {
                    domains[r.out] = next_out;
                    changed = true;
                }
            },
        };
    }
    return true;
}

fn search(allocator: std.mem.Allocator, groups: []const WidthGroup, relations: []const Relation, domains: []u64, attempts: *u32) !bool {
    attempts.* += 1;
    if (attempts.* > 4096 or !reduce(domains, relations)) return false;
    var branch: ?usize = null;
    var branch_count: u7 = 65;
    for (domains, 0..) |domain, index| {
        const count: u7 = @intCast(@popCount(domain));
        if (count > 1 and count < branch_count) {
            branch = index;
            branch_count = count;
        }
    }
    const index = branch orelse return true;
    const preferred = groups[index].preferred;
    if (contains(domains[index], preferred)) {
        const copy = try allocator.dupe(u64, domains);
        defer allocator.free(copy);
        copy[index] = singleton(preferred);
        if (try search(allocator, groups, relations, copy, attempts)) {
            @memcpy(domains, copy);
            return true;
        }
    }
    var value: u8 = 1;
    while (value <= max_width) : (value += 1) {
        if (value == preferred or !contains(domains[index], value)) continue;
        const copy = try allocator.dupe(u64, domains);
        defer allocator.free(copy);
        copy[index] = singleton(value);
        if (try search(allocator, groups, relations, copy, attempts)) {
            @memcpy(domains, copy);
            return true;
        }
    }
    return false;
}

pub fn solveWidths(allocator: std.mem.Allocator, groups: []const WidthGroup, relations: []const Relation, result: []u8) !bool {
    if (result.len != groups.len) return error.InvalidResultLength;
    const domains = try allocator.alloc(u64, groups.len);
    defer allocator.free(domains);
    for (groups, 0..) |group, i| {
        if (group.min == 0 or group.min > group.max or group.max > max_width or group.preferred < group.min or group.preferred > group.max) return false;
        const chosen = if (group.override != 0) group.override else group.preferred;
        if (chosen < group.min or chosen > group.max) return false;
        domains[i] = if (group.dependent and group.override == 0) maskRange(group.min, group.max) else singleton(chosen);
    }
    var attempts: u32 = 0;
    if (!try search(allocator, groups, relations, domains, &attempts)) return false;
    for (domains, result) |domain, *out| out.* = firstValue(domain);
    return true;
}

test "port semantics keep independent selector and data widths" {
    try std.testing.expectEqual(@as(u32, 17), inputCount(.mux, 4, false));
    try std.testing.expectEqual(@as(u8, 4), inputPort(.mux, 8, 4, 1, false, 0).?.width);
    try std.testing.expectEqual(@as(u8, 8), inputPort(.mux, 8, 4, 1, false, 16).?.width);
    try std.testing.expectEqual(@as(u8, 8), outputPort(.mux, 8, 4, 1, 0).?.width);
}

test "register alu and ram expose fixed controls without coupling data width" {
    try std.testing.expectEqual(@as(u32, 3), inputCount(.register, 1, false));
    try std.testing.expectEqual(@as(u8, 8), inputPort(.register, 8, 1, 1, false, 0).?.width);
    try std.testing.expectEqual(@as(u8, 1), inputPort(.register, 8, 1, 1, false, 1).?.width);
    try std.testing.expectEqual(@as(u8, 1), inputPort(.register, 8, 1, 1, false, 2).?.width);
    try std.testing.expectEqual(@as(u8, 2), inputPort(.alu, 8, 1, 1, false, 2).?.width);
    try std.testing.expectEqual(Field.two, inputPort(.alu, 8, 1, 1, false, 2).?.field);
    try std.testing.expectEqual(@as(u8, 4), inputPort(.ram, 8, 4, 1, false, 0).?.width);
    try std.testing.expectEqual(@as(u8, 8), inputPort(.ram, 8, 4, 1, false, 1).?.width);
    try std.testing.expectEqual(@as(u8, 1), inputPort(.ram, 8, 4, 1, false, 2).?.width);
    try std.testing.expectEqual(@as(u32, 2), outputCount(.alu, 1));
}

test "width solver derives split and decoder dimensions" {
    const groups = [_]WidthGroup{
        .{ .min = 1, .max = 64, .preferred = 5, .dependent = false },
        .{ .min = 1, .max = 64, .preferred = 32, .dependent = true },
        .{ .min = 1, .max = 64, .preferred = 35, .dependent = true },
        .{ .min = 1, .max = 64, .preferred = 3, .dependent = false },
    };
    const relations = [_]Relation{
        .{ .pow = .{ .address = 0, .out = 1 } },
        .{ .sum = .{ .total = 2, .low = 1, .high = 3 } },
    };
    var result: [4]u8 = undefined;
    try std.testing.expect(try solveWidths(std.testing.allocator, &groups, &relations, &result));
    try std.testing.expectEqualSlices(u8, &.{ 5, 32, 35, 3 }, &result);
}
