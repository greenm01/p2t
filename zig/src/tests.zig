//! Unit tests for the tessellator. Kept separate from the production sources;
//! `zig build test` compiles this module against the public API in root.zig.

const std = @import("std");
const mutable = @import("mutable_mesh.zig");
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

fn meshArea(m: anytype) f64 {
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

fn expectValidCover(area: f64, m: anytype) !void {
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

test "fist earcut raw covers polygon with hole" {
    const E = tess.FistEarcut(Vec, u32);
    const outer = [_]Vec{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 10, .y = 10 },
        .{ .x = 0, .y = 10 },
    };
    const hole = [_]Vec{
        .{ .x = 3, .y = 3 },
        .{ .x = 3, .y = 7 },
        .{ .x = 7, .y = 7 },
        .{ .x = 7, .y = 3 },
    };

    var m = try E.triangulateRaw(std.testing.allocator, &outer, &.{&hole});
    defer m.deinit();

    try expectValidCover(84.0, m);
    try std.testing.expectEqual(@as(usize, 8), m.triangleCount());
}

test "fist earcut z-order path covers large concave contour" {
    const E = tess.FistEarcut(Vec, u32);
    const n = 128;
    var pts: [n]Vec = undefined;
    for (0..n) |k| {
        const a = 2.0 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, n);
        const r = 100.0 + 25.0 * @sin(5.0 * a) + 10.0 * @sin(17.0 * a);
        pts[k] = .{ .x = r * @cos(a), .y = r * @sin(a) };
    }

    var m = try E.triangulateRaw(std.testing.allocator, &pts, &.{});
    defer m.deinit();

    try expectValidCover(polygonArea(&pts), m);
    try std.testing.expectEqual(@as(usize, n - 2), m.triangleCount());
}

fn triMinAngleDeg(a: Vec, b: Vec, c: Vec) f64 {
    const la = @sqrt((b.x - c.x) * (b.x - c.x) + (b.y - c.y) * (b.y - c.y));
    const lb = @sqrt((a.x - c.x) * (a.x - c.x) + (a.y - c.y) * (a.y - c.y));
    const lc = @sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
    const angA = std.math.acos(std.math.clamp((lb * lb + lc * lc - la * la) / (2 * lb * lc), -1.0, 1.0));
    const angB = std.math.acos(std.math.clamp((la * la + lc * lc - lb * lb) / (2 * la * lc), -1.0, 1.0));
    const angC = std.math.pi - angA - angB;
    return @min(angA, @min(angB, angC)) * 180.0 / std.math.pi;
}

fn meshMinAngle(m: Mesh) f64 {
    var mn: f64 = 180.0;
    var t: usize = 0;
    while (t < m.indices.len) : (t += 3) {
        const ang = triMinAngleDeg(m.vertices[m.indices[t]], m.vertices[m.indices[t + 1]], m.vertices[m.indices[t + 2]]);
        mn = @min(mn, ang);
    }
    return mn;
}

fn inCircle(verts: []const Vec, a: u32, b: u32, c: u32, d: u32) f64 {
    const adx = verts[a].x - verts[d].x;
    const ady = verts[a].y - verts[d].y;
    const bdx = verts[b].x - verts[d].x;
    const bdy = verts[b].y - verts[d].y;
    const cdx = verts[c].x - verts[d].x;
    const cdy = verts[c].y - verts[d].y;
    const ad = adx * adx + ady * ady;
    const bd = bdx * bdx + bdy * bdy;
    const cd = cdx * cdx + cdy * cdy;
    return adx * (bdy * cd - bd * cdy) - ady * (bdx * cd - bd * cdx) + ad * (bdx * cdy - bdy * cdx);
}

/// Independent check that every interior, non-boundary edge of a simple
/// polygon's mesh satisfies the local Delaunay (empty-circumcircle) property.
fn assertSimplePolygonDelaunay(n: usize, m: Mesh) !void {
    const HalfEdge = struct { tri: usize, apex: u32, e1: u32, e2: u32 };
    var map = std.AutoHashMap(u64, HalfEdge).init(std.testing.allocator);
    defer map.deinit();

    var t: usize = 0;
    while (t < m.indices.len) : (t += 3) {
        const tri = t / 3;
        for (0..3) |e| {
            const apex = m.indices[t + e];
            const e1 = m.indices[t + (e + 1) % 3];
            const e2 = m.indices[t + (e + 2) % 3];
            const lo: u64 = @min(e1, e2);
            const hi: u64 = @max(e1, e2);
            const key = (hi << 32) | lo;

            // boundary edge of a simple polygon: endpoints consecutive mod n
            const da = if (e1 > e2) e1 - e2 else e2 - e1;
            const boundary = (da == 1) or (da == n - 1);
            if (boundary) continue;

            if (map.fetchRemove(key)) |kv| {
                const o = kv.value;
                // (apex, e1, e2) is CCW within its triangle; o.apex is the
                // opposite vertex. Locally Delaunay => o.apex not inside.
                try std.testing.expect(inCircle(m.vertices, apex, e1, e2, o.apex) <= 1e-6);
            } else {
                try map.put(key, .{ .tri = tri, .apex = apex, .e1 = e1, .e2 = e2 });
            }
        }
    }
}

test "delaunay flip improves quality and is locally Delaunay" {
    // Squashed ellipse, convex: ear clipping yields a sliver fan; the flip pass
    // should turn it into a proper Delaunay mesh with a much larger min angle.
    const n = 24;
    var pts: [n]Vec = undefined;
    for (0..n) |k| {
        const ang = 2.0 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, n);
        pts[k] = .{ .x = 50.0 * @cos(ang), .y = 12.0 * @sin(ang) };
    }

    var raw = try T.triangulateRaw(std.testing.allocator, &pts, &.{});
    defer raw.deinit();
    var ref = try T.triangulate(std.testing.allocator, &pts, &.{});
    defer ref.deinit();

    // Same valid cover and triangle count; flips never change either.
    try expectValidCover(polygonArea(&pts), raw);
    try expectValidCover(polygonArea(&pts), ref);
    try std.testing.expectEqual(raw.triangleCount(), ref.triangleCount());

    // Quality strictly improves, and the refined mesh is Delaunay.
    try std.testing.expect(meshMinAngle(ref) > meshMinAngle(raw) + 1.0);
    try assertSimplePolygonDelaunay(n, ref);
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

test "fill tess fast triangle and boundary metadata" {
    const F = tess.GpuFillTess;
    var ft = F.init(std.testing.allocator);
    defer ft.deinit();

    const pts = [_]F.Vec{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 0, .y = 3 } };
    try ft.addContour(&pts, .solid);

    var m = try ft.tessellateFill(.{ .keep_boundary_edges = true });
    defer m.deinit();

    try std.testing.expect(m.diagnostics.used_fast_path);
    try std.testing.expectEqual(@as(usize, 1), m.triangleCount());
    try std.testing.expectEqual(@as(usize, 3), m.vertices.len);
    try std.testing.expectEqual(@as(usize, 3), m.boundary_edges.len);
}

test "fill tess quad fast path chooses valid two-triangle mesh" {
    const F = tess.GpuFillTess;
    var ft = F.init(std.testing.allocator);
    defer ft.deinit();

    const pts = [_]F.Vec{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 10, .y = 8 },
        .{ .x = 0, .y = 8 },
    };
    try ft.addContour(&pts, .solid);

    var m = try ft.tessellateFill(.{});
    defer m.deinit();

    try std.testing.expect(m.diagnostics.used_fast_path);
    try std.testing.expectEqual(@as(usize, 2), m.triangleCount());
    try std.testing.expectEqual(@as(usize, 4), m.vertices.len);
}

test "fill tess hole falls back to complex triangulator" {
    const F = tess.GpuFillTess;
    var ft = F.init(std.testing.allocator);
    defer ft.deinit();

    const outer = [_]F.Vec{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 10, .y = 10 },
        .{ .x = 0, .y = 10 },
    };
    const hole = [_]F.Vec{
        .{ .x = 3, .y = 3 },
        .{ .x = 3, .y = 7 },
        .{ .x = 7, .y = 7 },
        .{ .x = 7, .y = 3 },
    };
    try ft.addContour(&outer, .solid);
    try ft.addContour(&hole, .hole);

    var m = try ft.tessellateFill(.{ .keep_boundary_edges = true });
    defer m.deinit();

    try std.testing.expect(!m.diagnostics.used_fast_path);
    try std.testing.expectEqual(@as(usize, 8), m.triangleCount());
    try std.testing.expectEqual(@as(usize, 8), m.boundary_edges.len);
}

test "fill tess supports multiple solid contours" {
    const F = tess.GpuFillTess;
    var ft = F.init(std.testing.allocator);
    defer ft.deinit();

    const left = [_]F.Vec{
        .{ .x = 0, .y = 0 },
        .{ .x = 2, .y = 0 },
        .{ .x = 2, .y = 2 },
        .{ .x = 0, .y = 2 },
    };
    const right = [_]F.Vec{
        .{ .x = 4, .y = 0 },
        .{ .x = 6, .y = 0 },
        .{ .x = 6, .y = 2 },
        .{ .x = 4, .y = 2 },
    };
    try ft.addContour(&left, .solid);
    try ft.addContour(&right, .solid);

    var m = try ft.tessellateFill(.{ .keep_boundary_edges = true });
    defer m.deinit();

    try std.testing.expect(m.diagnostics.used_fast_path);
    try std.testing.expectEqual(@as(usize, 4), m.triangleCount());
    try std.testing.expectEqual(@as(usize, 8), m.vertices.len);
    try std.testing.expectEqual(@as(usize, 8), m.boundary_edges.len);
}

test "fill tess basic validation catches holes before solids" {
    const F = tess.GpuFillTess;
    var ft = F.init(std.testing.allocator);
    defer ft.deinit();

    const pts = [_]F.Vec{ .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 1, .y = 2 } };
    try ft.addContour(&pts, .hole);
    try std.testing.expectError(F.Error.HoleWithoutSolid, ft.tessellateFill(.{ .validation = .basic }));
}

test "fill tess reset reuses workspace for immediate mode" {
    const F = tess.GpuFillTess;
    var ft = F.init(std.testing.allocator);
    defer ft.deinit();
    try ft.reserve(16, 4);

    const tri_pts = [_]F.Vec{ .{ .x = 0, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 0, .y = 2 } };
    try ft.addContour(&tri_pts, .solid);
    var first = try ft.tessellateFill(.{});
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 1), first.triangleCount());

    ft.reset();
    const quad_pts = [_]F.Vec{
        .{ .x = 0, .y = 0 },
        .{ .x = 2, .y = 0 },
        .{ .x = 2, .y = 2 },
        .{ .x = 0, .y = 2 },
    };
    try ft.addContour(&quad_pts, .solid);
    var second = try ft.tessellateFill(.{});
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 2), second.triangleCount());
}

test "fill tess strategy classifier keeps auto on stable backends" {
    const F = tess.GpuFillTess;
    const pts = [_]F.Vec{
        .{ .x = 0, .y = 0 },
        .{ .x = 5, .y = 0 },
        .{ .x = 6, .y = 3 },
        .{ .x = 3, .y = 5 },
        .{ .x = 0, .y = 3 },
    };

    var ft = F.init(std.testing.allocator);
    defer ft.deinit();

    try ft.addContour(&pts, .solid);
    var raw = try ft.tessellateFill(.{ .quality = .raw });
    defer raw.deinit();
    try std.testing.expectEqual(F.TriangleStrategy.stable_raw, raw.diagnostics.triangle_strategy);
    try std.testing.expectEqual(F.SeedBackend.stable_earcut, raw.diagnostics.seed_backend);
    try std.testing.expect(!raw.diagnostics.experimental_used);

    ft.reset();
    try ft.addContour(&pts, .solid);
    var balanced = try ft.tessellateFill(.{ .quality = .balanced });
    defer balanced.deinit();
    try std.testing.expectEqual(F.TriangleStrategy.stable_balanced, balanced.diagnostics.triangle_strategy);
    try std.testing.expectEqual(F.SeedBackend.stable_earcut, balanced.diagnostics.seed_backend);

    ft.reset();
    try ft.addContour(&pts, .solid);
    var strict = try ft.tessellateFill(.{ .quality = .raw, .strategy = .strict });
    defer strict.deinit();
    try std.testing.expectEqual(F.TriangleStrategy.strict_cdt, strict.diagnostics.triangle_strategy);
}

test "fill tess experimental fist strategy is explicit and large-contour only" {
    const F = tess.GpuFillTess;
    const n = 96;
    var pts: [n]F.Vec = undefined;
    for (0..n) |k| {
        const a = 2.0 * std.math.pi * @as(f32, @floatFromInt(k)) / @as(f32, n);
        pts[k] = .{ .x = 80.0 * @cos(a), .y = 40.0 * @sin(a) };
    }

    var ft = F.init(std.testing.allocator);
    defer ft.deinit();

    try ft.addContour(&pts, .solid);
    var stable = try ft.tessellateFill(.{ .quality = .raw });
    defer stable.deinit();
    try std.testing.expectEqual(F.TriangleStrategy.stable_raw, stable.diagnostics.triangle_strategy);
    try std.testing.expect(!stable.diagnostics.experimental_used);

    ft.reset();
    try ft.addContour(&pts, .solid);
    var experimental = try ft.tessellateFill(.{ .quality = .raw, .strategy = .experimental_fist });
    defer experimental.deinit();
    try std.testing.expectEqual(F.TriangleStrategy.fist_earcut_raw, experimental.diagnostics.triangle_strategy);
    try std.testing.expectEqual(F.SeedBackend.fist_earcut, experimental.diagnostics.seed_backend);
    try std.testing.expect(experimental.diagnostics.experimental_used);
    try std.testing.expect(!experimental.diagnostics.fallback_used);
    try std.testing.expect(experimental.diagnostics.area_error <= 1e-5);
}

fn fillTriMinAngleDeg(a: tess.GpuFillTess.Vec, b: tess.GpuFillTess.Vec, c: tess.GpuFillTess.Vec) f64 {
    const ax: f64 = a.x;
    const ay: f64 = a.y;
    const bx: f64 = b.x;
    const by: f64 = b.y;
    const cx: f64 = c.x;
    const cy: f64 = c.y;
    const la = @sqrt((bx - cx) * (bx - cx) + (by - cy) * (by - cy));
    const lb = @sqrt((ax - cx) * (ax - cx) + (ay - cy) * (ay - cy));
    const lc = @sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by));
    const angA = std.math.acos(std.math.clamp((lb * lb + lc * lc - la * la) / (2 * lb * lc), -1.0, 1.0));
    const angB = std.math.acos(std.math.clamp((la * la + lc * lc - lb * lb) / (2 * la * lc), -1.0, 1.0));
    const angC = std.math.pi - angA - angB;
    return @min(angA, @min(angB, angC)) * 180.0 / std.math.pi;
}

const FillQuality = struct {
    mean_min_angle: f64,
    slivers20: usize,
};

fn fillQuality(m: tess.GpuFillTess.FillMesh) FillQuality {
    var sum: f64 = 0;
    var slivers: usize = 0;
    var t: usize = 0;
    while (t < m.indices.len) : (t += 3) {
        const angle = fillTriMinAngleDeg(m.vertices[m.indices[t]], m.vertices[m.indices[t + 1]], m.vertices[m.indices[t + 2]]);
        sum += angle;
        if (angle < 20.0) slivers += 1;
    }
    return .{ .mean_min_angle = sum / @as(f64, @floatFromInt(m.triangleCount())), .slivers20 = slivers };
}

test "fill tess balanced improves ellipse quality with bounded swaps" {
    const F = tess.GpuFillTess;
    const n = 24;
    var pts: [n]F.Vec = undefined;
    for (0..n) |k| {
        const ang = 2.0 * std.math.pi * @as(f32, @floatFromInt(k)) / @as(f32, n);
        pts[k] = .{ .x = 50.0 * @cos(ang), .y = 12.0 * @sin(ang) };
    }

    var ft = F.init(std.testing.allocator);
    defer ft.deinit();
    try ft.addContour(&pts, .solid);
    var raw = try ft.tessellateFill(.{ .quality = .raw });
    defer raw.deinit();

    ft.reset();
    try ft.addContour(&pts, .solid);
    var balanced = try ft.tessellateFill(.{ .quality = .balanced });
    defer balanced.deinit();

    const qr = fillQuality(raw);
    const qb = fillQuality(balanced);
    try std.testing.expectEqual(raw.triangleCount(), balanced.triangleCount());
    try std.testing.expect(balanced.diagnostics.quality_flips > 0);
    try std.testing.expectEqual(@as(usize, 0), balanced.diagnostics.constraint_failures);
    try std.testing.expect(!balanced.diagnostics.fallback_used);
    try std.testing.expect(qb.mean_min_angle > qr.mean_min_angle);
    try std.testing.expect(qb.slivers20 <= qr.slivers20);
}

test "mutable mesh inserts missing constraint by edge swap" {
    const F = tess.GpuFillTess;
    const R = mutable.Refiner(F.Vec, u32);
    const pts = [_]F.Vec{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = 1, .y = 1 },
        .{ .x = 0, .y = 1 },
    };
    var indices = [_]u32{ 0, 1, 3, 1, 2, 3 };
    const constraints = [_]R.Edge{.{ 0, 2 }};

    const stats = try R.refine(std.testing.allocator, &pts, &indices, &constraints, 0);
    try std.testing.expectEqual(@as(usize, 0), stats.missing_constraints);
    try std.testing.expectEqual(@as(usize, 1), stats.constraint_flips);

    var has_constraint = false;
    var t: usize = 0;
    while (t < indices.len) : (t += 3) {
        const tri = indices[t .. t + 3];
        for (0..3) |slot| {
            const a = tri[(slot + 1) % 3];
            const b = tri[(slot + 2) % 3];
            if ((a == 0 and b == 2) or (a == 2 and b == 0)) has_constraint = true;
        }
    }
    try std.testing.expect(has_constraint);
}
