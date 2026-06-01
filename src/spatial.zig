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
            .round = brioRound(hash64(@as(u64, @intCast(i)) ^ seed)),
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
