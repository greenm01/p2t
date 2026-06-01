const std = @import("std");
const p2t = @import("p2t");

const corridor_module = p2t.corridor;
const mesh = p2t.mesh;
const predicates = p2t.predicates;
const spatial = p2t.spatial;
const triangulate = p2t.triangulate;

const Case = struct {
    name: []const u8,
    width: usize,
    height: usize,
    start_grid: struct { x: usize, y: usize },
    end_grid: struct { x: usize, y: usize },
    jitter: f64,
    iterations: usize,
};

const RoundTiming = struct {
    total_us: u64 = 0,
    insertion_us: u64 = 0,
    constraint_us: u64 = 0,
    triangles: usize = 0,
    predicate_stats: predicates.PredicateStats = .{},
    engine_stats: triangulate.EngineStats = .{},
};

fn now() std.os.linux.timespec {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    return ts;
}

fn elapsedMicros(start: std.os.linux.timespec, end: std.os.linux.timespec) u64 {
    const start_ns = @as(u64, @intCast(start.sec)) * 1_000_000_000 + @as(u64, @intCast(start.nsec));
    const end_ns = @as(u64, @intCast(end.sec)) * 1_000_000_000 + @as(u64, @intCast(end.nsec));
    return @intCast((end_ns - start_ns) / 1000);
}

fn gridIndex(case: Case, x: usize, y: usize) usize {
    return y * case.width + x;
}

fn jitterCoord(seed: usize, amount: f64) f64 {
    var x = @as(u64, @intCast(seed)) +% 0x9E3779B97F4A7C15;
    x = (x ^ (x >> 30)) *% 0xBF58476D1CE4E5B9;
    x = (x ^ (x >> 27)) *% 0x94D049BB133111EB;
    x = x ^ (x >> 31);
    const low: u32 = @truncate(x);
    const unit = @as(f64, @floatFromInt(low)) / @as(f64, @floatFromInt(std.math.maxInt(u32)));
    return (unit - 0.5) * amount;
}

fn makeGrid(allocator: std.mem.Allocator, case: Case) ![]mesh.Vertex {
    const vertices = try allocator.alloc(mesh.Vertex, case.width * case.height);
    for (0..case.height) |y| {
        for (0..case.width) |x| {
            const idx = gridIndex(case, x, y);
            vertices[idx] = .{
                .x = @as(f64, @floatFromInt(x)) + jitterCoord(idx * 2 + 1, case.jitter),
                .y = @as(f64, @floatFromInt(y)) + jitterCoord(idx * 2 + 2, case.jitter),
            };
        }
    }
    return vertices;
}

fn runRound(allocator: std.mem.Allocator, case: Case, vertices: []const mesh.Vertex, sorted_indices: []const usize) !RoundTiming {
    var timing = RoundTiming{};
    predicates.resetStats();

    var engine = triangulate.Engine.init(allocator);
    defer engine.deinit();
    try engine.reserveForPointCount(vertices.len);

    var arena = mesh.ThreadArena{};
    defer arena.deinit(allocator);

    var corridor = corridor_module.Corridor{};
    defer corridor.deinit(allocator);

    const mesh_ids = try allocator.alloc(i32, vertices.len);
    defer allocator.free(mesh_ids);

    const total_start = now();
    for (0..case.iterations) |_| {
        engine.resetRetainingCapacity();
        arena.resetRetainingCapacity();
        engine.resetStats();

        try engine.initSuperTriangle(vertices);

        const insertion_start = now();
        for (sorted_indices) |idx| {
            mesh_ids[idx] = try engine.insertUniquePointTrusted(&arena, vertices[idx]);
        }
        const insertion_end = now();

        const start_idx = mesh_ids[gridIndex(case, case.start_grid.x, case.start_grid.y)];
        const end_idx = mesh_ids[gridIndex(case, case.end_grid.x, case.end_grid.y)];
        try corridor.recoverConstraintTrusted(allocator, &engine, &arena, start_idx, end_idx);
        const constraint_end = now();

        try engine.validateTopology();
        try engine.validateConstraintFlags();
        try engine.validateCdtLegality();

        timing.insertion_us += elapsedMicros(insertion_start, insertion_end);
        timing.constraint_us += elapsedMicros(insertion_end, constraint_end);
        timing.triangles += engine.liveTriangleCount();
        timing.engine_stats = addStats(timing.engine_stats, engine.statsSnapshot());
    }
    timing.total_us = elapsedMicros(total_start, now());
    timing.predicate_stats = predicates.statsSnapshot();
    return timing;
}

fn addStats(a: triangulate.EngineStats, b: triangulate.EngineStats) triangulate.EngineStats {
    var out = a;
    out.walk_calls += b.walk_calls;
    out.walk_steps += b.walk_steps;
    out.walk_fallbacks += b.walk_fallbacks;
    out.walk_fallback_scan_tris += b.walk_fallback_scan_tris;
    out.inserted_points += b.inserted_points;
    out.cavity_triangles += b.cavity_triangles;
    out.cavity_edges += b.cavity_edges;
    out.legalization_tests += b.legalization_tests;
    out.edge_flips += b.edge_flips;
    out.corridor_traces += b.corridor_traces;
    out.corridor_triangles += b.corridor_triangles;
    out.corridor_max_triangles = @max(out.corridor_max_triangles, b.corridor_max_triangles);
    out.corridor_augmented_traces += b.corridor_augmented_traces;
    out.corridor_augmented_triangles += b.corridor_augmented_triangles;
    out.local_cavity_attempts += b.local_cavity_attempts;
    out.local_cavity_successes += b.local_cavity_successes;
    out.local_cavity_invalid_fallbacks += b.local_cavity_invalid_fallbacks;
    out.local_cavity_nondelaunay_fallbacks += b.local_cavity_nondelaunay_fallbacks;
    out.local_cavity_repeated_fallbacks += b.local_cavity_repeated_fallbacks;
    out.find_live_edge_calls += b.find_live_edge_calls;
    out.find_live_edge_scan_tris += b.find_live_edge_scan_tris;
    out.find_live_edge_fast_calls += b.find_live_edge_fast_calls;
    out.find_live_edge_fast_fallbacks += b.find_live_edge_fast_fallbacks;
    return out;
}

fn perRun(value: u64, iterations: usize) f64 {
    return @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(iterations));
}

fn printCase(case: Case, timing: RoundTiming) void {
    const iterations_f64 = @as(f64, @floatFromInt(case.iterations));
    const traces_f64 = @max(@as(f64, @floatFromInt(timing.engine_stats.corridor_traces)), 1.0);
    std.debug.print(
        "{s}: {d} vertices, {d} runs, {d} triangles/run, total {d} us ({d:>.3} us/run)\n",
        .{
            case.name,
            case.width * case.height,
            case.iterations,
            timing.triangles / case.iterations,
            timing.total_us,
            perRun(timing.total_us, case.iterations),
        },
    );
    std.debug.print(
        "  phase/run: insertion {d:>.3} us, constraint {d:>.3} us\n",
        .{ perRun(timing.insertion_us, case.iterations), perRun(timing.constraint_us, case.iterations) },
    );
    if (timing.predicate_stats.any()) {
        std.debug.print(
            "  predicates/run: orient {d:>.1}, incircle {d:>.1}; exact/run: orient {d:>.1}, incircle {d:>.1}\n",
            .{
                @as(f64, @floatFromInt(timing.predicate_stats.orient_calls)) / iterations_f64,
                @as(f64, @floatFromInt(timing.predicate_stats.incircle_calls)) / iterations_f64,
                @as(f64, @floatFromInt(timing.predicate_stats.orient_exact)) / iterations_f64,
                @as(f64, @floatFromInt(timing.predicate_stats.incircle_exact)) / iterations_f64,
            },
        );
    }
    if (timing.engine_stats.any()) {
        std.debug.print(
            "  corridor: traces/run {d:>.1}, traced tris/trace {d:>.2}, augmented/run {d:>.1}, augmented tris/aug {d:>.2}, max tris {d}\n",
            .{
                @as(f64, @floatFromInt(timing.engine_stats.corridor_traces)) / iterations_f64,
                @as(f64, @floatFromInt(timing.engine_stats.corridor_triangles)) / traces_f64,
                @as(f64, @floatFromInt(timing.engine_stats.corridor_augmented_traces)) / iterations_f64,
                @as(f64, @floatFromInt(timing.engine_stats.corridor_augmented_triangles)) / @max(@as(f64, @floatFromInt(timing.engine_stats.corridor_augmented_traces)), 1.0),
                timing.engine_stats.corridor_max_triangles,
            },
        );
        std.debug.print(
            "  local cavity/run: attempts {d:>.1}, successes {d:>.1}, invalid {d:>.1}, nondelaunay {d:>.1}, repeated {d:>.1}\n",
            .{
                @as(f64, @floatFromInt(timing.engine_stats.local_cavity_attempts)) / iterations_f64,
                @as(f64, @floatFromInt(timing.engine_stats.local_cavity_successes)) / iterations_f64,
                @as(f64, @floatFromInt(timing.engine_stats.local_cavity_invalid_fallbacks)) / iterations_f64,
                @as(f64, @floatFromInt(timing.engine_stats.local_cavity_nondelaunay_fallbacks)) / iterations_f64,
                @as(f64, @floatFromInt(timing.engine_stats.local_cavity_repeated_fallbacks)) / iterations_f64,
            },
        );
    }
}

pub fn main(_: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cases = [_]Case{
        .{ .name = "grid32-diagonal", .width = 32, .height = 32, .start_grid = .{ .x = 0, .y = 0 }, .end_grid = .{ .x = 31, .y = 31 }, .jitter = 0.18, .iterations = 20 },
        .{ .name = "grid48-opposite-chord", .width = 48, .height = 48, .start_grid = .{ .x = 0, .y = 9 }, .end_grid = .{ .x = 47, .y = 38 }, .jitter = 0.16, .iterations = 10 },
        .{ .name = "thin64-near-horizontal", .width = 64, .height = 16, .start_grid = .{ .x = 0, .y = 7 }, .end_grid = .{ .x = 63, .y = 8 }, .jitter = 0.08, .iterations = 20 },
    };

    std.debug.print("Cleave long-segment corridor benchmark (ReleaseFast, validation after timed constraint)\n", .{});
    for (cases) |case| {
        const vertices = try makeGrid(allocator, case);
        defer allocator.free(vertices);

        const sorted_indices = try spatial.sortVerticesByMorton(allocator, vertices);
        defer allocator.free(sorted_indices);

        const timing = try runRound(allocator, case, vertices, sorted_indices);
        printCase(case, timing);
    }
}
