//! Apples-to-apples tessellation comparison against local libtess2 and NanoVG.
//! Run with `zig build bench-compare`.

const std = @import("std");
const linux = std.os.linux;
const opts = @import("build_options");
const tess = @import("root.zig");

const F = tess.GpuFillTess;
const Vec = F.Vec;
const FillMesh = F.FillMesh;

const libtess = if (opts.has_libtess2) @cImport({
    @cInclude("tesselator.h");
}) else struct {};

const nanovg = if (opts.has_nanovg) @cImport({
    @cInclude("nanovg.h");
}) else struct {};

const Contours = struct {
    outer: []const Vec,
    holes: []const []const Vec = &.{},
};

const QualityStats = struct {
    triangles: usize = 0,
    vertices: usize = 0,
    indices: usize = 0,
    area: f64 = 0,
    min_angle: f64 = 180,
    max_angle: f64 = 0,
    mean_min_angle: f64 = 0,
    slivers10: usize = 0,
    slivers20: usize = 0,
    slivers30: usize = 0,
    max_aspect: f64 = 0,
    mean_aspect: f64 = 0,
};

const BenchResult = struct {
    name: []const u8,
    best_ns: u64 = std.math.maxInt(u64),
    mean_ns: u64 = 0,
    quality: ?QualityStats = null,
    nano: ?NanoStats = null,
    skipped: bool = false,
    failed: ?[]const u8 = null,
};

const NanoStats = struct {
    render_fill_calls: usize = 0,
    paths: usize = 0,
    fill_vertices: usize = 0,
    fringe_vertices: usize = 0,
    fan_triangles: usize = 0,
};

const FlatContour = struct {
    xy: []f32,
};

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const io = init.io;

    std.debug.print("tessellation backend comparison\n", .{});
    std.debug.print("  libtess2: {s}\n", .{if (opts.has_libtess2) opts.libtess2_dir else "skipped"});
    std.debug.print("  NanoVG  : {s}\n", .{if (opts.has_nanovg) opts.nanovg_dir else "skipped"});
    std.debug.print("  fixtures: {s}\n\n", .{opts.fixture_dir});

    try runProceduralCases(allocator);
    try runFixtureCases(allocator, io);
}

fn runProceduralCases(allocator: std.mem.Allocator) !void {
    const ellipse_pts = try ellipse(allocator, 100, 200, 50);
    defer allocator.free(ellipse_pts);
    try runCase(allocator, "ellipse-100", .{ .outer = ellipse_pts }, 20_000);

    const gear_pts = try gear(allocator, 32);
    defer allocator.free(gear_pts);
    try runCase(allocator, "gear-64", .{ .outer = gear_pts }, 20_000);

    const wiggly_pts = try wiggly(allocator, 1000);
    defer allocator.free(wiggly_pts);
    try runCase(allocator, "wiggly-1000", .{ .outer = wiggly_pts }, 2_000);

    const outer = [_]Vec{
        .{ .x = 0, .y = 0 },
        .{ .x = 200, .y = 0 },
        .{ .x = 200, .y = 200 },
        .{ .x = 0, .y = 200 },
    };
    var hole_store: [4][4]Vec = undefined;
    var holes: [4][]const Vec = undefined;
    const centers = [_][2]f32{ .{ 50, 50 }, .{ 150, 50 }, .{ 50, 150 }, .{ 150, 150 } };
    for (centers, 0..) |c, i| {
        hole_store[i] = .{
            .{ .x = c[0] - 20, .y = c[1] - 20 },
            .{ .x = c[0] - 20, .y = c[1] + 20 },
            .{ .x = c[0] + 20, .y = c[1] + 20 },
            .{ .x = c[0] + 20, .y = c[1] - 20 },
        };
        holes[i] = &hole_store[i];
    }
    try runCase(allocator, "rect-4-holes", .{ .outer = &outer, .holes = &holes }, 20_000);
}

fn runFixtureCases(allocator: std.mem.Allocator, io: std.Io) !void {
    const small = [_][]const u8{ "diamond.dat", "star.dat", "strange.dat", "test.dat", "stalactite.dat" };
    for (small) |name| {
        const pts = readFixture(allocator, io, name) catch |err| {
            std.debug.print("{s}: skipped fixture read failure ({s})\n", .{ name, @errorName(err) });
            continue;
        };
        defer allocator.free(pts);
        try runCase(allocator, name, .{ .outer = pts }, 10_000);
    }

    const dude = try readFixture(allocator, io, "dude.dat");
    defer allocator.free(dude);
    const dude_hole_a = [_]Vec{
        .{ .x = 325, .y = 437 },
        .{ .x = 320, .y = 423 },
        .{ .x = 329, .y = 413 },
        .{ .x = 332, .y = 423 },
    };
    const dude_hole_b = [_]Vec{
        .{ .x = 320.72342, .y = 480 },
        .{ .x = 338.90617, .y = 465.96863 },
        .{ .x = 347.99754, .y = 480.61584 },
        .{ .x = 329.8148, .y = 510.41534 },
        .{ .x = 339.91632, .y = 480.11077 },
        .{ .x = 334.86556, .y = 478.09046 },
    };
    const dude_holes = [_][]const Vec{ &dude_hole_a, &dude_hole_b };
    try runCase(allocator, "dude.dat+holes", .{ .outer = dude, .holes = &dude_holes }, 1_000);

    const monkey = try readFixture(allocator, io, "nazca_monkey.dat");
    defer allocator.free(monkey);
    try runCase(allocator, "nazca_monkey.dat", .{ .outer = monkey }, 500);

    const heron = try readFixture(allocator, io, "nazca_heron.dat");
    defer allocator.free(heron);
    try runCase(allocator, "nazca_heron.dat", .{ .outer = heron }, 500);
}

fn runCase(allocator: std.mem.Allocator, name: []const u8, input: Contours, iterations: usize) !void {
    const expected = polygonAreaAbs(input.outer) - holesAreaAbs(input.holes);
    const total_points = input.outer.len + countHolePoints(input.holes);

    std.debug.print("{s}: {d} points, {d} holes, area {d:.3}, {d} runs\n", .{
        name,
        total_points,
        input.holes.len,
        expected,
        iterations,
    });
    printHeader();

    const raw = benchZig(allocator, "zig raw", input, .raw, iterations) catch errorResult("zig raw", "failed");
    printResult(raw, expected);
    const balanced = benchZig(allocator, "zig balanced", input, .balanced, iterations) catch errorResult("zig balanced", "failed");
    printResult(balanced, expected);
    const strict = benchZig(allocator, "zig strict", input, .strict_cdt, iterations) catch errorResult("zig strict", "failed");
    printResult(strict, expected);

    const lib = if (opts.has_libtess2)
        benchLibtess2(allocator, input, iterations) catch errorResult("libtess2 cdt", "failed")
    else
        BenchResult{ .name = "libtess2 cdt", .skipped = true };
    printResult(lib, expected);

    const nano = if (opts.has_nanovg)
        benchNanoVG(input, iterations) catch errorResult("nanovg fill", "failed")
    else
        BenchResult{ .name = "nanovg fill", .skipped = true };
    printResult(nano, expected);
    std.debug.print("\n", .{});
}

fn printHeader() void {
    std.debug.print("  backend        best us  mean us  tris  verts  minA  meanA  sl<20  aspMax  areaErr  gpuProxy / notes\n", .{});
}

fn printResult(result: BenchResult, expected_area: f64) void {
    if (result.skipped) {
        std.debug.print("  {s:<13} skipped\n", .{result.name});
        return;
    }
    if (result.failed) |reason| {
        std.debug.print("  {s:<13} {s}\n", .{ result.name, reason });
        return;
    }

    const best_us = @as(f64, @floatFromInt(result.best_ns)) / 1000.0;
    const mean_us = @as(f64, @floatFromInt(result.mean_ns)) / 1000.0;
    if (result.quality) |q| {
        const area_err = if (expected_area > 0) @abs(q.area - expected_area) / expected_area else 0;
        std.debug.print("  {s:<13} {d:7.2} {d:8.2} {d:5} {d:6} {d:5.2} {d:6.2} {d:6} {d:7.2} {d:8.4} {d:8.1}\n", .{
            result.name,
            best_us,
            mean_us,
            q.triangles,
            q.vertices,
            q.min_angle,
            q.mean_min_angle,
            q.slivers20,
            q.max_aspect,
            area_err,
            gpuProxyScore(q),
        });
    } else if (result.nano) |n| {
        std.debug.print("  {s:<13} {d:7.2} {d:8.2} {d:5} {d:6}     -      -      -       -        -  stencil/fill verts {d}+{d}, calls {d}\n", .{
            result.name,
            best_us,
            mean_us,
            n.fan_triangles,
            n.fill_vertices + n.fringe_vertices,
            n.fill_vertices,
            n.fringe_vertices,
            n.render_fill_calls,
        });
    }
}

fn errorResult(name: []const u8, reason: []const u8) BenchResult {
    return .{ .name = name, .failed = reason };
}

fn benchZig(
    allocator: std.mem.Allocator,
    name: []const u8,
    input: Contours,
    quality_mode: F.Quality,
    iterations: usize,
) !BenchResult {
    var ft = F.init(allocator);
    defer ft.deinit();
    try ft.reserve(input.outer.len + countHolePoints(input.holes), input.holes.len + 1);

    try addFillContours(&ft, input);
    var first = try ft.tessellateFill(.{ .quality = quality_mode });
    defer first.deinit();
    const quality = qualityFromFill(first);

    var total_ns: u128 = 0;
    var best: u64 = std.math.maxInt(u64);
    for (0..iterations) |_| {
        const t0 = nowNs();
        try addFillContours(&ft, input);
        var mesh = try ft.tessellateFill(.{ .quality = quality_mode });
        const dt = nowNs() - t0;
        mesh.deinit();
        total_ns += dt;
        best = @min(best, dt);
    }

    return .{
        .name = name,
        .best_ns = best,
        .mean_ns = @intCast(total_ns / iterations),
        .quality = quality,
    };
}

fn addFillContours(ft: *F, input: Contours) !void {
    ft.reset();
    try ft.addContour(input.outer, .solid);
    for (input.holes) |hole| try ft.addContour(hole, .hole);
}

fn benchLibtess2(allocator: std.mem.Allocator, input: Contours, iterations: usize) !BenchResult {
    if (!opts.has_libtess2) return .{ .name = "libtess2 cdt", .skipped = true };

    const buffers = try makeFlatContours(allocator, input);
    defer freeFlatContours(allocator, buffers);

    const quality = try libtess2Quality(buffers);
    var total_ns: u128 = 0;
    var best: u64 = std.math.maxInt(u64);
    for (0..iterations) |_| {
        const t0 = nowNs();
        const tris = try runLibtess2(buffers, false);
        std.mem.doNotOptimizeAway(tris);
        const dt = nowNs() - t0;
        total_ns += dt;
        best = @min(best, dt);
    }

    return .{
        .name = "libtess2 cdt",
        .best_ns = best,
        .mean_ns = @intCast(total_ns / iterations),
        .quality = quality,
    };
}

fn makeFlatContours(allocator: std.mem.Allocator, input: Contours) ![]FlatContour {
    const out = try allocator.alloc(FlatContour, input.holes.len + 1);
    errdefer allocator.free(out);
    out[0] = .{ .xy = try flattenContour(allocator, input.outer) };
    errdefer allocator.free(out[0].xy);
    for (input.holes, 0..) |hole, i| {
        out[i + 1] = .{ .xy = try flattenContour(allocator, hole) };
    }
    return out;
}

fn freeFlatContours(allocator: std.mem.Allocator, buffers: []FlatContour) void {
    for (buffers) |buffer| allocator.free(buffer.xy);
    allocator.free(buffers);
}

fn flattenContour(allocator: std.mem.Allocator, points: []const Vec) ![]f32 {
    const xy = try allocator.alloc(f32, points.len * 2);
    for (points, 0..) |point, i| {
        xy[i * 2] = point.x;
        xy[i * 2 + 1] = point.y;
    }
    return xy;
}

fn runLibtess2(buffers: []const FlatContour, collect_quality: bool) !usize {
    _ = collect_quality;
    const t = libtess.tessNewTess(null) orelse return error.Libtess2AllocFailed;
    defer libtess.tessDeleteTess(t);

    for (buffers) |buffer| {
        libtess.tessAddContour(t, 2, buffer.xy.ptr, @intCast(2 * @sizeOf(f32)), @intCast(buffer.xy.len / 2));
    }
    libtess.tessSetOption(t, libtess.TESS_CONSTRAINED_DELAUNAY_TRIANGULATION, 1);
    if (libtess.tessTesselate(t, libtess.TESS_WINDING_ODD, libtess.TESS_POLYGONS, 3, 2, null) != 1) return error.Libtess2Failed;
    if (libtess.tessGetStatus(t) != libtess.TESS_STATUS_OK) return error.Libtess2Failed;
    return @intCast(libtess.tessGetElementCount(t));
}

fn libtess2Quality(buffers: []const FlatContour) !QualityStats {
    const t = libtess.tessNewTess(null) orelse return error.Libtess2AllocFailed;
    defer libtess.tessDeleteTess(t);

    var input_vertices: usize = 0;
    for (buffers) |buffer| {
        input_vertices += buffer.xy.len / 2;
        libtess.tessAddContour(t, 2, buffer.xy.ptr, @intCast(2 * @sizeOf(f32)), @intCast(buffer.xy.len / 2));
    }
    libtess.tessSetOption(t, libtess.TESS_CONSTRAINED_DELAUNAY_TRIANGULATION, 1);
    if (libtess.tessTesselate(t, libtess.TESS_WINDING_ODD, libtess.TESS_POLYGONS, 3, 2, null) != 1) return error.Libtess2Failed;
    if (libtess.tessGetStatus(t) != libtess.TESS_STATUS_OK) return error.Libtess2Failed;

    const verts = libtess.tessGetVertices(t);
    const elems = libtess.tessGetElements(t);
    const count: usize = @intCast(libtess.tessGetElementCount(t));
    var acc = QualityAccumulator.init();
    const undef = @as(libtess.TESSindex, @bitCast(@as(c_int, -1)));
    for (0..count) |i| {
        const ia = elems[i * 3];
        const ib = elems[i * 3 + 1];
        const ic = elems[i * 3 + 2];
        if (ia == undef or ib == undef or ic == undef) continue;
        const a = readLibtessVertex(verts, ia);
        const b = readLibtessVertex(verts, ib);
        const c = readLibtessVertex(verts, ic);
        acc.add(a, b, c);
    }
    var quality = acc.finish();
    quality.vertices = input_vertices;
    quality.indices = quality.triangles * 3;
    return quality;
}

fn readLibtessVertex(vertices: [*c]const libtess.TESSreal, index: libtess.TESSindex) Vec {
    const i: usize = @intCast(index);
    return .{
        .x = @floatCast(vertices[i * 2]),
        .y = @floatCast(vertices[i * 2 + 1]),
    };
}

const NanoState = struct {
    stats: NanoStats = .{},
    next_image: c_int = 1,
};

fn benchNanoVG(input: Contours, iterations: usize) !BenchResult {
    if (!opts.has_nanovg) return .{ .name = "nanovg fill", .skipped = true };

    var state = NanoState{};
    var params = std.mem.zeroes(nanovg.NVGparams);
    params.userPtr = &state;
    params.edgeAntiAlias = 1;
    params.renderCreate = nanoRenderCreate;
    params.renderCreateTexture = nanoRenderCreateTexture;
    params.renderDeleteTexture = nanoRenderDeleteTexture;
    params.renderUpdateTexture = nanoRenderUpdateTexture;
    params.renderGetTextureSize = nanoRenderGetTextureSize;
    params.renderViewport = nanoRenderViewport;
    params.renderCancel = nanoRenderCancel;
    params.renderFlush = nanoRenderFlush;
    params.renderFill = nanoRenderFill;
    params.renderStroke = nanoRenderStroke;
    params.renderTriangles = nanoRenderTriangles;
    params.renderDelete = nanoRenderDelete;

    const ctx = nanovg.nvgCreateInternal(&params) orelse return error.NanoVGCreateFailed;
    defer nanovg.nvgDeleteInternal(ctx);

    state.stats = .{};
    drawNanoVG(ctx, input);
    const first = state.stats;

    var total_ns: u128 = 0;
    var best: u64 = std.math.maxInt(u64);
    for (0..iterations) |_| {
        state.stats = .{};
        const t0 = nowNs();
        drawNanoVG(ctx, input);
        const dt = nowNs() - t0;
        total_ns += dt;
        best = @min(best, dt);
    }

    return .{
        .name = "nanovg fill",
        .best_ns = best,
        .mean_ns = @intCast(total_ns / iterations),
        .nano = first,
    };
}

fn drawNanoVG(ctx: *nanovg.NVGcontext, input: Contours) void {
    nanovg.nvgBeginFrame(ctx, 1024, 1024, 1);
    nanovg.nvgBeginPath(ctx);
    emitNanoContour(ctx, input.outer, nanovg.NVG_SOLID);
    for (input.holes) |hole| emitNanoContour(ctx, hole, nanovg.NVG_HOLE);
    nanovg.nvgFill(ctx);
    nanovg.nvgEndFrame(ctx);
}

fn emitNanoContour(ctx: *nanovg.NVGcontext, points: []const Vec, winding: c_int) void {
    if (points.len == 0) return;
    nanovg.nvgMoveTo(ctx, points[0].x, points[0].y);
    for (points[1..]) |point| nanovg.nvgLineTo(ctx, point.x, point.y);
    nanovg.nvgClosePath(ctx);
    nanovg.nvgPathWinding(ctx, winding);
}

fn nanoRenderCreate(uptr: ?*anyopaque) callconv(.c) c_int {
    _ = uptr;
    return 1;
}

fn nanoRenderCreateTexture(uptr: ?*anyopaque, tex_type: c_int, w: c_int, h: c_int, image_flags: c_int, data: [*c]const u8) callconv(.c) c_int {
    _ = tex_type;
    _ = w;
    _ = h;
    _ = image_flags;
    _ = data;
    const state: *NanoState = @ptrCast(@alignCast(uptr.?));
    defer state.next_image += 1;
    return state.next_image;
}

fn nanoRenderDeleteTexture(uptr: ?*anyopaque, image: c_int) callconv(.c) c_int {
    _ = uptr;
    _ = image;
    return 1;
}

fn nanoRenderUpdateTexture(uptr: ?*anyopaque, image: c_int, x: c_int, y: c_int, w: c_int, h: c_int, data: [*c]const u8) callconv(.c) c_int {
    _ = uptr;
    _ = image;
    _ = x;
    _ = y;
    _ = w;
    _ = h;
    _ = data;
    return 1;
}

fn nanoRenderGetTextureSize(uptr: ?*anyopaque, image: c_int, w: [*c]c_int, h: [*c]c_int) callconv(.c) c_int {
    _ = uptr;
    _ = image;
    w.* = 0;
    h.* = 0;
    return 1;
}

fn nanoRenderViewport(uptr: ?*anyopaque, width: f32, height: f32, device_pixel_ratio: f32) callconv(.c) void {
    _ = uptr;
    _ = width;
    _ = height;
    _ = device_pixel_ratio;
}

fn nanoRenderCancel(uptr: ?*anyopaque) callconv(.c) void {
    _ = uptr;
}

fn nanoRenderFlush(uptr: ?*anyopaque) callconv(.c) void {
    _ = uptr;
}

fn nanoRenderFill(
    uptr: ?*anyopaque,
    paint: [*c]nanovg.NVGpaint,
    composite: nanovg.NVGcompositeOperationState,
    scissor: [*c]nanovg.NVGscissor,
    fringe: f32,
    bounds: [*c]const f32,
    paths: [*c]const nanovg.NVGpath,
    npaths: c_int,
) callconv(.c) void {
    _ = paint;
    _ = composite;
    _ = scissor;
    _ = fringe;
    _ = bounds;
    const state: *NanoState = @ptrCast(@alignCast(uptr.?));
    state.stats.render_fill_calls += 1;
    const count: usize = @intCast(npaths);
    state.stats.paths += count;
    for (0..count) |i| {
        const path = paths[i];
        if (path.nfill > 0) state.stats.fill_vertices += @intCast(path.nfill);
        if (path.nstroke > 0) state.stats.fringe_vertices += @intCast(path.nstroke);
        if (path.nfill >= 3) state.stats.fan_triangles += @intCast(path.nfill - 2);
    }
}

fn nanoRenderStroke(
    uptr: ?*anyopaque,
    paint: [*c]nanovg.NVGpaint,
    composite: nanovg.NVGcompositeOperationState,
    scissor: [*c]nanovg.NVGscissor,
    fringe: f32,
    stroke_width: f32,
    paths: [*c]const nanovg.NVGpath,
    npaths: c_int,
) callconv(.c) void {
    _ = uptr;
    _ = paint;
    _ = composite;
    _ = scissor;
    _ = fringe;
    _ = stroke_width;
    _ = paths;
    _ = npaths;
}

fn nanoRenderTriangles(
    uptr: ?*anyopaque,
    paint: [*c]nanovg.NVGpaint,
    composite: nanovg.NVGcompositeOperationState,
    scissor: [*c]nanovg.NVGscissor,
    verts: [*c]const nanovg.NVGvertex,
    nverts: c_int,
    fringe: f32,
) callconv(.c) void {
    _ = uptr;
    _ = paint;
    _ = composite;
    _ = scissor;
    _ = verts;
    _ = nverts;
    _ = fringe;
}

fn nanoRenderDelete(uptr: ?*anyopaque) callconv(.c) void {
    _ = uptr;
}

fn qualityFromFill(mesh: FillMesh) QualityStats {
    var acc = QualityAccumulator.init();
    var i: usize = 0;
    while (i < mesh.indices.len) : (i += 3) {
        acc.add(
            mesh.vertices[mesh.indices[i]],
            mesh.vertices[mesh.indices[i + 1]],
            mesh.vertices[mesh.indices[i + 2]],
        );
    }
    var quality = acc.finish();
    quality.vertices = mesh.vertices.len;
    quality.indices = mesh.indices.len;
    return quality;
}

const QualityAccumulator = struct {
    stats: QualityStats,
    sum_min_angle: f64 = 0,
    sum_aspect: f64 = 0,

    fn init() QualityAccumulator {
        return .{ .stats = .{} };
    }

    fn add(self: *QualityAccumulator, a: Vec, b: Vec, c: Vec) void {
        const area = @abs(orient(a, b, c)) * 0.5;
        if (area <= 0) return;
        const angles = triAngles(a, b, c);
        const aspect = triAspect(a, b, c);
        self.stats.triangles += 1;
        self.stats.area += area;
        self.stats.min_angle = @min(self.stats.min_angle, angles.lo);
        self.stats.max_angle = @max(self.stats.max_angle, angles.hi);
        self.sum_min_angle += angles.lo;
        if (angles.lo < 10) self.stats.slivers10 += 1;
        if (angles.lo < 20) self.stats.slivers20 += 1;
        if (angles.lo < 30) self.stats.slivers30 += 1;
        self.stats.max_aspect = @max(self.stats.max_aspect, aspect);
        self.sum_aspect += aspect;
    }

    fn finish(self: QualityAccumulator) QualityStats {
        var out = self.stats;
        if (out.triangles > 0) {
            const n: f64 = @floatFromInt(out.triangles);
            out.mean_min_angle = self.sum_min_angle / n;
            out.mean_aspect = self.sum_aspect / n;
        }
        return out;
    }
};

fn triAngles(a: Vec, b: Vec, c: Vec) struct { lo: f64, hi: f64 } {
    const la = @sqrt(dist2(b, c));
    const lb = @sqrt(dist2(a, c));
    const lc = @sqrt(dist2(a, b));
    if (la <= 0 or lb <= 0 or lc <= 0) return .{ .lo = 0, .hi = 180 };
    const aa = std.math.acos(std.math.clamp((lb * lb + lc * lc - la * la) / (2 * lb * lc), -1.0, 1.0)) * 180.0 / std.math.pi;
    const ab = std.math.acos(std.math.clamp((la * la + lc * lc - lb * lb) / (2 * la * lc), -1.0, 1.0)) * 180.0 / std.math.pi;
    const ac = 180.0 - aa - ab;
    return .{
        .lo = @min(aa, @min(ab, ac)),
        .hi = @max(aa, @max(ab, ac)),
    };
}

fn triAspect(a: Vec, b: Vec, c: Vec) f64 {
    const ab = @sqrt(dist2(a, b));
    const bc = @sqrt(dist2(b, c));
    const ca = @sqrt(dist2(c, a));
    return @max(ab, @max(bc, ca)) / @max(@min(ab, @min(bc, ca)), 1e-30);
}

fn gpuProxyScore(q: QualityStats) f64 {
    return @as(f64, @floatFromInt(q.triangles)) +
        0.5 * @as(f64, @floatFromInt(q.vertices)) +
        4.0 * @as(f64, @floatFromInt(q.slivers20)) +
        0.05 * q.max_aspect;
}

fn polygonAreaAbs(points: []const Vec) f64 {
    if (points.len < 3) return 0;
    var sum: f64 = 0;
    var j = points.len - 1;
    for (points, 0..) |p, i| {
        const q = points[j];
        sum += @as(f64, q.x) * @as(f64, p.y) - @as(f64, p.x) * @as(f64, q.y);
        j = i;
    }
    return @abs(sum) * 0.5;
}

fn holesAreaAbs(holes: []const []const Vec) f64 {
    var area: f64 = 0;
    for (holes) |hole| area += polygonAreaAbs(hole);
    return area;
}

fn countHolePoints(holes: []const []const Vec) usize {
    var count: usize = 0;
    for (holes) |hole| count += hole.len;
    return count;
}

fn orient(a: Vec, b: Vec, c: Vec) f64 {
    return (@as(f64, a.x) - @as(f64, c.x)) * (@as(f64, b.y) - @as(f64, c.y)) -
        (@as(f64, a.y) - @as(f64, c.y)) * (@as(f64, b.x) - @as(f64, c.x));
}

fn dist2(a: Vec, b: Vec) f64 {
    const dx = @as(f64, a.x) - @as(f64, b.x);
    const dy = @as(f64, a.y) - @as(f64, b.y);
    return dx * dx + dy * dy;
}

fn ellipse(allocator: std.mem.Allocator, n: usize, rx: f32, ry: f32) ![]Vec {
    const pts = try allocator.alloc(Vec, n);
    for (0..n) |k| {
        const a = 2.0 * std.math.pi * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
        pts[k] = .{ .x = rx * @cos(a), .y = ry * @sin(a) };
    }
    return pts;
}

fn gear(allocator: std.mem.Allocator, teeth: usize) ![]Vec {
    const n = teeth * 2;
    const pts = try allocator.alloc(Vec, n);
    for (0..n) |k| {
        const r: f32 = if (k % 2 == 0) 100.0 else 60.0;
        const a = 2.0 * std.math.pi * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
        pts[k] = .{ .x = r * @cos(a), .y = r * @sin(a) };
    }
    return pts;
}

fn wiggly(allocator: std.mem.Allocator, n: usize) ![]Vec {
    const pts = try allocator.alloc(Vec, n);
    for (0..n) |k| {
        const a = 2.0 * std.math.pi * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
        const r = 100.0 + 30.0 * @sin(7.0 * a) + 15.0 * @sin(13.0 * a) + 8.0 * @sin(23.0 * a);
        pts[k] = .{ .x = r * @cos(a), .y = r * @sin(a) };
    }
    return pts;
}

fn readFixture(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]Vec {
    const path = try std.fs.path.join(allocator, &.{ opts.fixture_dir, name });
    defer allocator.free(path);
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(data);

    var points: std.ArrayList(Vec) = .empty;
    errdefer points.deinit(allocator);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) break;
        var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
        const xs = parts.next() orelse continue;
        const ys = parts.next() orelse continue;
        try points.append(allocator, .{
            .x = try std.fmt.parseFloat(f32, xs),
            .y = try std.fmt.parseFloat(f32, ys),
        });
    }
    return points.toOwnedSlice(allocator);
}
