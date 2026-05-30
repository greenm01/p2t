//! Unit tests for the tessellator. Kept separate from the production sources;
//! `zig build test` compiles this module against the public API in root.zig.

const std = @import("std");
const tess = @import("root.zig");

// Tests run in double precision so the area assertions are exact; the comptime
// generic means this also exercises a different instantiation than GpuTess.
const T = tess.Tess;
const Vec = T.Vec;
const Mesh = T.Mesh;

fn polygonArea(points: []const Vec) f64 {
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

fn expectValidCover(area: f64, m: Mesh) !void {
    var t: usize = 0;
    while (t < m.indices.len) : (t += 3) {
        for (0..3) |k| try std.testing.expect(m.indices[t + k] < m.vertices.len);
        const a = m.vertices[m.indices[t]];
        const b = m.vertices[m.indices[t + 1]];
        const c = m.vertices[m.indices[t + 2]];
        const area2 = @abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x));
        try std.testing.expect(area2 > 1e-9); // no zero-area slivers
    }
    try std.testing.expectApproxEqAbs(area, meshArea(m), 1e-6);
}

test "triangle" {
    const pts = [_]Vec{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 0, .y = 3 } };
    var m = try T.triangulateSimple(std.testing.allocator, &pts);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 1), m.triangleCount());
    try expectValidCover(polygonArea(&pts), m);
}

test "square" {
    const pts = [_]Vec{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 10, .y = 10 },
        .{ .x = 0, .y = 10 },
    };
    var m = try T.triangulateSimple(std.testing.allocator, &pts);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 2), m.triangleCount());
    try expectValidCover(polygonArea(&pts), m);
}

test "concave L-shape" {
    const pts = [_]Vec{
        .{ .x = 0, .y = 0 },
        .{ .x = 6, .y = 0 },
        .{ .x = 6, .y = 2 },
        .{ .x = 2, .y = 2 },
        .{ .x = 2, .y = 6 },
        .{ .x = 0, .y = 6 },
    };
    var m = try T.triangulateSimple(std.testing.allocator, &pts);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 4), m.triangleCount()); // n-2
    try expectValidCover(polygonArea(&pts), m);
}

test "star (clockwise input is normalized)" {
    var pts: [10]Vec = undefined;
    const outer = 10.0;
    const inner = 4.0;
    for (0..10) |k| {
        const r: f64 = if (k % 2 == 0) outer else inner;
        const ang = -@as(f64, @floatFromInt(k)) * std.math.pi / 5.0; // clockwise input
        pts[k] = .{ .x = r * @cos(ang), .y = r * @sin(ang) };
    }
    var m = try T.triangulateSimple(std.testing.allocator, &pts);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 8), m.triangleCount()); // n-2
    try expectValidCover(polygonArea(&pts), m);
}

test "square with square hole" {
    const outer = [_]Vec{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 10, .y = 10 },
        .{ .x = 0, .y = 10 },
    };
    // Hole given clockwise (opposite winding to the CCW outer).
    const hole = [_]Vec{
        .{ .x = 3, .y = 3 },
        .{ .x = 3, .y = 7 },
        .{ .x = 7, .y = 7 },
        .{ .x = 7, .y = 3 },
    };
    var m = try T.triangulate(std.testing.allocator, &outer, &.{&hole});
    defer m.deinit();
    // Area = 100 - 16 = 84.
    try expectValidCover(84.0, m);
    // Outer(4) + hole(4) = 8 boundary vertices -> 8 triangles for an annulus.
    try std.testing.expectEqual(@as(usize, 8), m.triangleCount());
}

test "gpu instantiation compiles and covers" {
    const G = tess.GpuTess; // f32 / u32
    const pts = [_]G.Vec{
        .{ .x = 0, .y = 0 },
        .{ .x = 8, .y = 0 },
        .{ .x = 8, .y = 5 },
        .{ .x = 0, .y = 5 },
    };
    var m = try G.triangulateSimple(std.testing.allocator, &pts);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 2), m.triangleCount());
}
