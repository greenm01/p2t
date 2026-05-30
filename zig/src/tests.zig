//! Unit tests for the tessellator. Kept separate from the production sources;
//! `zig build test` compiles this module against the public API in root.zig.

const std = @import("std");
const tess = @import("root.zig");

const Vec2 = tess.Vec2;
const Mesh = tess.Mesh;

fn polygonArea(points: []const Vec2) f64 {
    var sum: f64 = 0;
    var j = points.len - 1;
    for (0..points.len) |i| {
        sum += points[j].x * points[i].y - points[i].x * points[j].y;
        j = i;
    }
    return @abs(sum) * 0.5;
}

fn meshArea(m: Mesh) f64 {
    var sum: f64 = 0;
    var t: usize = 0;
    while (t < m.indices.len) : (t += 3) {
        const a = m.vertices[m.indices[t]];
        const b = m.vertices[m.indices[t + 1]];
        const c = m.vertices[m.indices[t + 2]];
        sum += @abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) * 0.5;
    }
    return sum;
}

fn expectValidCover(points: []const Vec2, m: Mesh) !void {
    var t: usize = 0;
    while (t < m.indices.len) : (t += 3) {
        for (0..3) |k| try std.testing.expect(m.indices[t + k] < m.vertices.len);
        const a = m.vertices[m.indices[t]];
        const b = m.vertices[m.indices[t + 1]];
        const c = m.vertices[m.indices[t + 2]];
        const area2 = @abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x));
        try std.testing.expect(area2 > 1e-9); // no zero-area slivers
    }
    try std.testing.expectApproxEqAbs(polygonArea(points), meshArea(m), 1e-6);
}

test "triangle" {
    const pts = [_]Vec2{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 0, .y = 3 } };
    var m = try tess.triangulateSimple(std.testing.allocator, &pts);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 1), m.triangleCount());
    try expectValidCover(&pts, m);
}

test "square" {
    const pts = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 10, .y = 10 },
        .{ .x = 0, .y = 10 },
    };
    var m = try tess.triangulateSimple(std.testing.allocator, &pts);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 2), m.triangleCount());
    try expectValidCover(&pts, m);
}

test "concave L-shape" {
    const pts = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 6, .y = 0 },
        .{ .x = 6, .y = 2 },
        .{ .x = 2, .y = 2 },
        .{ .x = 2, .y = 6 },
        .{ .x = 0, .y = 6 },
    };
    var m = try tess.triangulateSimple(std.testing.allocator, &pts);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 4), m.triangleCount()); // n-2
    try expectValidCover(&pts, m);
}

test "star (clockwise input is normalized)" {
    var pts: [10]Vec2 = undefined;
    const outer = 10.0;
    const inner = 4.0;
    for (0..10) |k| {
        const r: f64 = if (k % 2 == 0) outer else inner;
        const ang = -@as(f64, @floatFromInt(k)) * std.math.pi / 5.0; // clockwise input
        pts[k] = .{ .x = r * @cos(ang), .y = r * @sin(ang) };
    }
    var m = try tess.triangulateSimple(std.testing.allocator, &pts);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 8), m.triangleCount()); // n-2
    try expectValidCover(&pts, m);
}
