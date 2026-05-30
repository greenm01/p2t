//! Benchmark + quality report for the tessellator. Run with `zig build bench`
//! (built in ReleaseFast). Inputs are generated procedurally so the benchmark
//! is self-contained; sizes mirror the fixtures used elsewhere (a ~100-vertex
//! glyph-like shape, a ~1000-vertex wiggly contour, and a holed rectangle).

const std = @import("std");
const linux = std.os.linux;
const tess = @import("root.zig");

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

const T = tess.Tess; // f64 / u32
const Vec = T.Vec;
const Mesh = T.Mesh;
const F = tess.GpuFillTess; // f32 / u32 renderer-facing workspace
const FVec = F.Vec;
const FMesh = F.FillMesh;

fn ellipse(allocator: std.mem.Allocator, n: usize, rx: f64, ry: f64) ![]Vec {
    const pts = try allocator.alloc(Vec, n);
    for (0..n) |k| {
        const a = 2.0 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
        pts[k] = .{ .x = rx * @cos(a), .y = ry * @sin(a) };
    }
    return pts;
}

fn gear(allocator: std.mem.Allocator, teeth: usize) ![]Vec {
    const n = teeth * 2;
    const pts = try allocator.alloc(Vec, n);
    for (0..n) |k| {
        const r: f64 = if (k % 2 == 0) 100.0 else 60.0;
        const a = 2.0 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
        pts[k] = .{ .x = r * @cos(a), .y = r * @sin(a) };
    }
    return pts;
}

/// Wiggly closed contour (concave, nazca-like) with `n` vertices.
fn wiggly(allocator: std.mem.Allocator, n: usize) ![]Vec {
    const pts = try allocator.alloc(Vec, n);
    for (0..n) |k| {
        const a = 2.0 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
        const r = 100.0 + 30.0 * @sin(7.0 * a) + 15.0 * @sin(13.0 * a) + 8.0 * @sin(23.0 * a);
        pts[k] = .{ .x = r * @cos(a), .y = r * @sin(a) };
    }
    return pts;
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

const Quality = struct { minAngle: f64, meanMinAngle: f64, slivers: usize };

fn quality(m: Mesh) Quality {
    var mn: f64 = 180.0;
    var sum: f64 = 0;
    var slivers: usize = 0;
    var t: usize = 0;
    while (t < m.indices.len) : (t += 3) {
        const ang = triMinAngleDeg(m.vertices[m.indices[t]], m.vertices[m.indices[t + 1]], m.vertices[m.indices[t + 2]]);
        mn = @min(mn, ang);
        sum += ang;
        if (ang < 20.0) slivers += 1;
    }
    const cnt: f64 = @floatFromInt(m.triangleCount());
    return .{ .minAngle = mn, .meanMinAngle = sum / cnt, .slivers = slivers };
}

fn triMinAngleDegF(a: FVec, b: FVec, c: FVec) f64 {
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

fn qualityF(m: FMesh) Quality {
    var mn: f64 = 180.0;
    var sum: f64 = 0;
    var slivers: usize = 0;
    var t: usize = 0;
    while (t < m.indices.len) : (t += 3) {
        const ang = triMinAngleDegF(m.vertices[m.indices[t]], m.vertices[m.indices[t + 1]], m.vertices[m.indices[t + 2]]);
        mn = @min(mn, ang);
        sum += ang;
        if (ang < 20.0) slivers += 1;
    }
    const cnt: f64 = @floatFromInt(m.triangleCount());
    return .{ .minAngle = mn, .meanMinAngle = sum / cnt, .slivers = slivers };
}

fn ellipseF(allocator: std.mem.Allocator, n: usize, rx: f32, ry: f32) ![]FVec {
    const pts = try allocator.alloc(FVec, n);
    for (0..n) |k| {
        const a = 2.0 * std.math.pi * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
        pts[k] = .{ .x = rx * @cos(a), .y = ry * @sin(a) };
    }
    return pts;
}

fn gearF(allocator: std.mem.Allocator, teeth: usize) ![]FVec {
    const n = teeth * 2;
    const pts = try allocator.alloc(FVec, n);
    for (0..n) |k| {
        const r: f32 = if (k % 2 == 0) 100.0 else 60.0;
        const a = 2.0 * std.math.pi * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
        pts[k] = .{ .x = r * @cos(a), .y = r * @sin(a) };
    }
    return pts;
}

fn wigglyF(allocator: std.mem.Allocator, n: usize) ![]FVec {
    const pts = try allocator.alloc(FVec, n);
    for (0..n) |k| {
        const a = 2.0 * std.math.pi * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
        const r = 100.0 + 30.0 * @sin(7.0 * a) + 15.0 * @sin(13.0 * a) + 8.0 * @sin(23.0 * a);
        pts[k] = .{ .x = r * @cos(a), .y = r * @sin(a) };
    }
    return pts;
}

fn addFillContours(ft: *F, outer: []const FVec, holes: []const []const FVec) !void {
    ft.reset();
    try ft.addContour(outer, .solid);
    for (holes) |hole| try ft.addContour(hole, .hole);
}

fn benchOne(
    allocator: std.mem.Allocator,
    name: []const u8,
    outer: []const Vec,
    holes: []const []const Vec,
    iters: usize,
) !void {
    const p = std.debug.print;

    var refined = try T.triangulate(allocator, outer, holes);
    defer refined.deinit();
    const qref = quality(refined);
    var raw = try T.triangulateRaw(allocator, outer, holes);
    defer raw.deinit();
    const qraw = quality(raw);

    var bestRaw: u64 = std.math.maxInt(u64);
    var bestRef: u64 = std.math.maxInt(u64);
    for (0..iters) |_| {
        const t0 = nowNs();
        var m = try T.triangulateRaw(allocator, outer, holes);
        const dt = nowNs() - t0;
        m.deinit();
        bestRaw = @min(bestRaw, dt);
    }
    for (0..iters) |_| {
        const t0 = nowNs();
        var m = try T.triangulate(allocator, outer, holes);
        const dt = nowNs() - t0;
        m.deinit();
        bestRef = @min(bestRef, dt);
    }

    p("{s}: {d} verts -> {d} tris\n", .{ name, outer.len, refined.triangleCount() });
    p("  ear-clip only : {d:>8.3} us   minAngle {d:6.3}  meanMin {d:6.3}  slivers<20 {d}\n", .{ @as(f64, @floatFromInt(bestRaw)) / 1000.0, qraw.minAngle, qraw.meanMinAngle, qraw.slivers });
    p("  + delaunay    : {d:>8.3} us   minAngle {d:6.3}  meanMin {d:6.3}  slivers<20 {d}\n", .{ @as(f64, @floatFromInt(bestRef)) / 1000.0, qref.minAngle, qref.meanMinAngle, qref.slivers });
}

fn benchFillOne(
    allocator: std.mem.Allocator,
    name: []const u8,
    outer: []const FVec,
    holes: []const []const FVec,
    iters: usize,
) !void {
    const p = std.debug.print;

    var ft = F.init(allocator);
    defer ft.deinit();
    var total = outer.len;
    for (holes) |h| total += h.len;
    try ft.reserve(total, holes.len + 1);

    try addFillContours(&ft, outer, holes);
    var raw = try ft.tessellateFill(.{ .quality = .raw });
    defer raw.deinit();
    const qraw = qualityF(raw);

    try addFillContours(&ft, outer, holes);
    var balanced = try ft.tessellateFill(.{ .quality = .balanced });
    defer balanced.deinit();
    const qbal = qualityF(balanced);

    var bestRaw: u64 = std.math.maxInt(u64);
    var bestBal: u64 = std.math.maxInt(u64);
    for (0..iters) |_| {
        const t0 = nowNs();
        try addFillContours(&ft, outer, holes);
        var m = try ft.tessellateFill(.{ .quality = .raw });
        const dt = nowNs() - t0;
        m.deinit();
        bestRaw = @min(bestRaw, dt);
    }
    for (0..iters) |_| {
        const t0 = nowNs();
        try addFillContours(&ft, outer, holes);
        var m = try ft.tessellateFill(.{ .quality = .balanced });
        const dt = nowNs() - t0;
        m.deinit();
        bestBal = @min(bestBal, dt);
    }

    p("{s} gpu fill workspace:\n", .{name});
    p("  raw          : {d:>8.3} us   minAngle {d:6.3}  meanMin {d:6.3}  slivers<20 {d}\n", .{ @as(f64, @floatFromInt(bestRaw)) / 1000.0, qraw.minAngle, qraw.meanMinAngle, qraw.slivers });
    p("  balanced     : {d:>8.3} us   minAngle {d:6.3}  meanMin {d:6.3}  slivers<20 {d}\n", .{ @as(f64, @floatFromInt(bestBal)) / 1000.0, qbal.minAngle, qbal.meanMinAngle, qbal.slivers });
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    const el = try ellipse(allocator, 100, 200, 50);
    defer allocator.free(el);
    const gr = try gear(allocator, 32);
    defer allocator.free(gr);
    const wig = try wiggly(allocator, 1000);
    defer allocator.free(wig);
    const elf = try ellipseF(allocator, 100, 200, 50);
    defer allocator.free(elf);
    const grf = try gearF(allocator, 32);
    defer allocator.free(grf);
    const wigf = try wigglyF(allocator, 1000);
    defer allocator.free(wigf);

    // Holed rectangle: outer 0..200 square with four square holes.
    const outer = [_]Vec{ .{ .x = 0, .y = 0 }, .{ .x = 200, .y = 0 }, .{ .x = 200, .y = 200 }, .{ .x = 0, .y = 200 } };
    const outerf = [_]FVec{ .{ .x = 0, .y = 0 }, .{ .x = 200, .y = 0 }, .{ .x = 200, .y = 200 }, .{ .x = 0, .y = 200 } };
    var holeStore: [4][4]Vec = undefined;
    var holes: [4][]const Vec = undefined;
    var holeStoreF: [4][4]FVec = undefined;
    var holesF: [4][]const FVec = undefined;
    const centers = [_][2]f64{ .{ 50, 50 }, .{ 150, 50 }, .{ 50, 150 }, .{ 150, 150 } };
    for (centers, 0..) |c, i| {
        // clockwise hole
        holeStore[i] = .{
            .{ .x = c[0] - 20, .y = c[1] - 20 },
            .{ .x = c[0] - 20, .y = c[1] + 20 },
            .{ .x = c[0] + 20, .y = c[1] + 20 },
            .{ .x = c[0] + 20, .y = c[1] - 20 },
        };
        holes[i] = &holeStore[i];
        holeStoreF[i] = .{
            .{ .x = @floatCast(c[0] - 20), .y = @floatCast(c[1] - 20) },
            .{ .x = @floatCast(c[0] - 20), .y = @floatCast(c[1] + 20) },
            .{ .x = @floatCast(c[0] + 20), .y = @floatCast(c[1] + 20) },
            .{ .x = @floatCast(c[0] + 20), .y = @floatCast(c[1] - 20) },
        };
        holesF[i] = &holeStoreF[i];
    }

    try benchOne(allocator, "ellipse (convex, sliver-prone)", el, &.{}, 20000);
    try benchFillOne(allocator, "ellipse (convex, sliver-prone)", elf, &.{}, 20000);
    try benchOne(allocator, "gear (concave, 64 teeth)", gr, &.{}, 20000);
    try benchFillOne(allocator, "gear (concave, 64 teeth)", grf, &.{}, 20000);
    try benchOne(allocator, "wiggly blob (nazca-like)", wig, &.{}, 2000);
    try benchFillOne(allocator, "wiggly blob (nazca-like)", wigf, &.{}, 2000);
    try benchOne(allocator, "rect + 4 holes", &outer, &holes, 20000);
    try benchFillOne(allocator, "rect + 4 holes", &outerf, &holesF, 20000);
}
