const std = @import("std");
const mesh = @import("mesh.zig");

fn expandBits(v: u32) u64 {
    var x: u64 = v;
    x = (x | (x << 16)) & 0x0000FFFF0000FFFF;
    x = (x | (x << 8)) & 0x00FF00FF00FF00FF;
    x = (x | (x << 4)) & 0x0F0F0F0F0F0F0F0F;
    x = (x | (x << 2)) & 0x3333333333333333;
    x = (x | (x << 1)) & 0x5555555555555555;
    return x;
}

pub fn morton2D(x: u32, y: u32) u64 {
    return expandBits(x) | (expandBits(y) << 1);
}

pub fn hilbert2D(x: u32, y: u32) u64 {
    var hx: i64 = x;
    var hy: i64 = y;
    var code: u64 = 0;
    var scale: i64 = 1 << 31;

    while (scale > 0) : (scale >>= 1) {
        const rx: u64 = if ((hx & scale) != 0) 1 else 0;
        const ry: u64 = if ((hy & scale) != 0) 1 else 0;
        const scale_u: u64 = @intCast(scale);
        code += scale_u * scale_u * ((3 * rx) ^ ry);

        if (ry == 0) {
            if (rx == 1) {
                const max_coord = scale - 1;
                hx = max_coord - hx;
                hy = max_coord - hy;
            }
            std.mem.swap(i64, &hx, &hy);
        }
    }

    return code;
}

pub const BoundingBox = struct {
    min_x: f64,
    min_y: f64,
    max_x: f64,
    max_y: f64,

    pub fn fromVertices(vertices: []const mesh.Vertex) BoundingBox {
        var bounds = BoundingBox{
            .min_x = std.math.inf(f64),
            .min_y = std.math.inf(f64),
            .max_x = -std.math.inf(f64),
            .max_y = -std.math.inf(f64),
        };

        for (vertices) |v| {
            bounds.min_x = @min(bounds.min_x, v.x);
            bounds.min_y = @min(bounds.min_y, v.y);
            bounds.max_x = @max(bounds.max_x, v.x);
            bounds.max_y = @max(bounds.max_y, v.y);
        }

        return bounds;
    }
};

pub fn computeMortonCodes(allocator: std.mem.Allocator, vertices: []const mesh.Vertex) ![]u64 {
    const codes = try allocator.alloc(u64, vertices.len);
    errdefer allocator.free(codes);

    if (vertices.len == 0) return codes;

    const bounds = BoundingBox.fromVertices(vertices);
    const width = bounds.max_x - bounds.min_x;
    const height = bounds.max_y - bounds.min_y;

    const scale_x = if (width > 0.0) 4294967295.0 / width else 0.0;
    const scale_y = if (height > 0.0) 4294967295.0 / height else 0.0;

    for (vertices, 0..) |v, i| {
        const nx = @as(u32, @intFromFloat((v.x - bounds.min_x) * scale_x));
        const ny = @as(u32, @intFromFloat((v.y - bounds.min_y) * scale_y));
        codes[i] = morton2D(nx, ny);
    }

    return codes;
}

pub fn computeHilbertCodes(allocator: std.mem.Allocator, vertices: []const mesh.Vertex) ![]u64 {
    const codes = try allocator.alloc(u64, vertices.len);
    errdefer allocator.free(codes);

    if (vertices.len == 0) return codes;

    const bounds = BoundingBox.fromVertices(vertices);
    const width = bounds.max_x - bounds.min_x;
    const height = bounds.max_y - bounds.min_y;

    const scale_x = if (width > 0.0) 4294967295.0 / width else 0.0;
    const scale_y = if (height > 0.0) 4294967295.0 / height else 0.0;

    for (vertices, 0..) |v, i| {
        const nx = @as(u32, @intFromFloat((v.x - bounds.min_x) * scale_x));
        const ny = @as(u32, @intFromFloat((v.y - bounds.min_y) * scale_y));
        codes[i] = hilbert2D(nx, ny);
    }

    return codes;
}

pub fn sortVerticesByMorton(allocator: std.mem.Allocator, vertices: []const mesh.Vertex) ![]usize {
    const codes = try computeMortonCodes(allocator, vertices);
    defer allocator.free(codes);

    const indices = try allocator.alloc(usize, vertices.len);
    for (indices, 0..) |*idx, i| {
        idx.* = i;
    }

    const Context = struct {
        codes: []const u64,
        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return ctx.codes[a] < ctx.codes[b];
        }
    };

    std.mem.sortUnstable(usize, indices, Context{ .codes = codes }, Context.lessThan);
    return indices;
}

pub fn sortVerticesByHilbert(allocator: std.mem.Allocator, vertices: []const mesh.Vertex) ![]usize {
    const codes = try computeHilbertCodes(allocator, vertices);
    defer allocator.free(codes);

    const indices = try allocator.alloc(usize, vertices.len);
    for (indices, 0..) |*idx, i| {
        idx.* = i;
    }

    const Context = struct {
        codes: []const u64,
        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            if (ctx.codes[a] != ctx.codes[b]) return ctx.codes[a] < ctx.codes[b];
            return a < b;
        }
    };

    std.mem.sortUnstable(usize, indices, Context{ .codes = codes }, Context.lessThan);
    return indices;
}

fn hash64(value: u64) u64 {
    var x = value +% 0x9E3779B97F4A7C15;
    x = (x ^ (x >> 30)) *% 0xBF58476D1CE4E5B9;
    x = (x ^ (x >> 27)) *% 0x94D049BB133111EB;
    return x ^ (x >> 31);
}

fn brioRound(hash: u64) u8 {
    const nonzero = if (hash == 0) @as(u64, 1) else hash;
    const round = @ctz(nonzero);
    return @intCast(@min(round, 63));
}

pub fn brioRoundForIndex(index: usize, seed: u64) u8 {
    return brioRound(hash64(@as(u64, @intCast(index)) ^ seed));
}

pub fn sortVerticesByBrioMorton(allocator: std.mem.Allocator, vertices: []const mesh.Vertex, seed: u64) ![]usize {
    const codes = try computeMortonCodes(allocator, vertices);
    defer allocator.free(codes);

    const Item = struct {
        index: usize,
        code: u64,
        round: u8,
    };

    const items = try allocator.alloc(Item, vertices.len);
    defer allocator.free(items);
    for (items, 0..) |*item, i| {
        item.* = .{
            .index = i,
            .code = codes[i],
            .round = brioRoundForIndex(i, seed),
        };
    }

    const Context = struct {
        pub fn lessThan(_: @This(), a: Item, b: Item) bool {
            if (a.round != b.round) return a.round > b.round;
            if (a.code != b.code) return a.code < b.code;
            return a.index < b.index;
        }
    };
    std.mem.sortUnstable(Item, items, Context{}, Context.lessThan);

    const indices = try allocator.alloc(usize, vertices.len);
    for (items, 0..) |item, i| {
        indices[i] = item.index;
    }
    return indices;
}

pub fn sortVerticesByBrioHilbert(allocator: std.mem.Allocator, vertices: []const mesh.Vertex, seed: u64) ![]usize {
    const codes = try computeHilbertCodes(allocator, vertices);
    defer allocator.free(codes);

    const Item = struct {
        index: usize,
        code: u64,
        round: u8,
    };

    const items = try allocator.alloc(Item, vertices.len);
    defer allocator.free(items);
    for (items, 0..) |*item, i| {
        item.* = .{
            .index = i,
            .code = codes[i],
            .round = brioRoundForIndex(i, seed),
        };
    }

    const Context = struct {
        pub fn lessThan(_: @This(), a: Item, b: Item) bool {
            if (a.round != b.round) return a.round > b.round;
            if (a.code != b.code) return a.code < b.code;
            return a.index < b.index;
        }
    };
    std.mem.sortUnstable(Item, items, Context{}, Context.lessThan);

    const indices = try allocator.alloc(usize, vertices.len);
    for (items, 0..) |item, i| {
        indices[i] = item.index;
    }
    return indices;
}

test "morton sorting" {
    const vertices = [_]mesh.Vertex{
        .{ .x = 100.0, .y = 100.0 }, // highest morton code
        .{ .x = 0.0, .y = 0.0 }, // lowest morton code
        .{ .x = 50.0, .y = 50.0 }, // middle
    };

    const allocator = std.testing.allocator;
    const sorted_indices = try sortVerticesByMorton(allocator, &vertices);
    defer allocator.free(sorted_indices);

    try std.testing.expect(sorted_indices.len == 3);
    try std.testing.expect(sorted_indices[0] == 1); // 0.0, 0.0
    try std.testing.expect(sorted_indices[1] == 2); // 50.0, 50.0
    try std.testing.expect(sorted_indices[2] == 0); // 100.0, 100.0
}

test "hilbert 4x4 ordering" {
    const expected = [_]struct { x: u32, y: u32, code: u64 }{
        .{ .x = 0, .y = 0, .code = 0 },
        .{ .x = 1, .y = 0, .code = 1 },
        .{ .x = 1, .y = 1, .code = 2 },
        .{ .x = 0, .y = 1, .code = 3 },
        .{ .x = 0, .y = 2, .code = 4 },
        .{ .x = 0, .y = 3, .code = 5 },
        .{ .x = 1, .y = 3, .code = 6 },
        .{ .x = 1, .y = 2, .code = 7 },
        .{ .x = 2, .y = 2, .code = 8 },
        .{ .x = 2, .y = 3, .code = 9 },
        .{ .x = 3, .y = 3, .code = 10 },
        .{ .x = 3, .y = 2, .code = 11 },
        .{ .x = 3, .y = 1, .code = 12 },
        .{ .x = 2, .y = 1, .code = 13 },
        .{ .x = 2, .y = 0, .code = 14 },
        .{ .x = 3, .y = 0, .code = 15 },
    };

    for (expected) |case| {
        try std.testing.expectEqual(case.code, hilbert2D(case.x, case.y));
    }
}

test "hilbert sorting breaks equal-code ties by index" {
    const vertices = [_]mesh.Vertex{
        .{ .x = 1.0, .y = 1.0 },
        .{ .x = 1.0, .y = 1.0 },
        .{ .x = 0.0, .y = 0.0 },
    };

    const allocator = std.testing.allocator;
    const sorted_indices = try sortVerticesByHilbert(allocator, &vertices);
    defer allocator.free(sorted_indices);

    try std.testing.expectEqual(@as(usize, 3), sorted_indices.len);
    try std.testing.expectEqual(@as(usize, 2), sorted_indices[0]);
    try std.testing.expectEqual(@as(usize, 0), sorted_indices[1]);
    try std.testing.expectEqual(@as(usize, 1), sorted_indices[2]);
}
