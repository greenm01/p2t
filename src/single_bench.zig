const std = @import("std");
const p2t = @import("p2t");

const Io = std.Io;
const corridor_module = p2t.corridor;
const mesh = p2t.mesh;
const parser = p2t.parser;
const predicates = p2t.predicates;
const spatial = p2t.spatial;
const triangulate = p2t.triangulate;

const Case = struct {
    name: []const u8,
    vertices: []const mesh.Vertex,
    sorted_indices: []const usize,
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

fn readFile(allocator: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    const dir = Io.Dir.cwd();
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);

    var buf: [1024 * 1024]u8 = undefined;
    const bufs = [_][]u8{&buf};
    const bytes_read = try file.readPositional(io, &bufs, 0);

    const result = try allocator.alloc(u8, bytes_read);
    @memcpy(result, buf[0..bytes_read]);
    return result;
}

fn loadCase(allocator: std.mem.Allocator, io: Io, name: []const u8, path: []const u8, iterations: usize) !Case {
    const file_content = try readFile(allocator, io, path);
    defer allocator.free(file_content);

    const points = try parser.parseDatString(allocator, file_content);
    defer allocator.free(points);

    const vertices = try allocator.alloc(mesh.Vertex, points.len);
    for (points, 0..) |p, i| {
        vertices[i] = .{ .x = p.x, .y = p.y };
    }

    return .{
        .name = name,
        .vertices = vertices,
        .sorted_indices = try spatial.sortVerticesByMorton(allocator, vertices),
        .iterations = iterations,
    };
}

fn deinitCase(allocator: std.mem.Allocator, case: Case) void {
    allocator.free(case.sorted_indices);
    allocator.free(case.vertices);
}

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

fn runRound(
    allocator: std.mem.Allocator,
    engine: *triangulate.Engine,
    arena: *mesh.ThreadArena,
    corridor: *corridor_module.Corridor,
    mesh_ids: []i32,
    case: Case,
) !RoundTiming {
    var timing = RoundTiming{};
    predicates.resetStats();
    engine.resetStats();
    const total_start = now();

    for (0..case.iterations) |_| {
        engine.resetRetainingCapacity();
        arena.resetRetainingCapacity();

        try engine.initSuperTriangle(case.vertices);

        const insertion_start = now();
        for (case.sorted_indices) |idx| {
            mesh_ids[idx] = try engine.insertUniquePointTrusted(arena, case.vertices[idx]);
        }
        const insertion_end = now();

        for (0..case.vertices.len) |i| {
            const start_idx = mesh_ids[i];
            const end_idx = mesh_ids[(i + 1) % case.vertices.len];
            try corridor.recoverConstraintTrusted(allocator, engine, arena, start_idx, end_idx);
        }
        const constraint_end = now();

        timing.insertion_us += elapsedMicros(insertion_start, insertion_end);
        timing.constraint_us += elapsedMicros(insertion_end, constraint_end);
        timing.triangles += engine.liveTriangleCount();
    }

    timing.total_us = elapsedMicros(total_start, now());
    timing.predicate_stats = predicates.statsSnapshot();
    timing.engine_stats = engine.statsSnapshot();
    return timing;
}

fn lessTotal(_: void, a: RoundTiming, b: RoundTiming) bool {
    return a.total_us < b.total_us;
}

fn perRun(value: u64, iterations: usize) f64 {
    return @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(iterations));
}

fn printCase(case: Case, best: RoundTiming, median: RoundTiming) void {
    const other_us = if (best.total_us > best.insertion_us + best.constraint_us)
        best.total_us - best.insertion_us - best.constraint_us
    else
        0;
    const triangles_per_run = best.triangles / case.iterations;

    std.debug.print(
        "{s}: {d} vertices, {d} runs, {d} triangles/run, best {d} us ({d:>.3} us/run), median {d} us\n",
        .{
            case.name,
            case.vertices.len,
            case.iterations,
            triangles_per_run,
            best.total_us,
            perRun(best.total_us, case.iterations),
            median.total_us,
        },
    );
    std.debug.print(
        "  phase best/run: insertion {d:>.3} us, constraints {d:>.3} us, setup+other {d:>.3} us\n",
        .{
            perRun(best.insertion_us, case.iterations),
            perRun(best.constraint_us, case.iterations),
            perRun(other_us, case.iterations),
        },
    );
    if (best.predicate_stats.any()) {
        std.debug.print(
            "  predicates/run: orient {d:>.1}, incircle {d:>.1}; exact/run: orient {d:>.1}, incircle {d:>.1}\n",
            .{
                @as(f64, @floatFromInt(best.predicate_stats.orient_calls)) / @as(f64, @floatFromInt(case.iterations)),
                @as(f64, @floatFromInt(best.predicate_stats.incircle_calls)) / @as(f64, @floatFromInt(case.iterations)),
                @as(f64, @floatFromInt(best.predicate_stats.orient_exact)) / @as(f64, @floatFromInt(case.iterations)),
                @as(f64, @floatFromInt(best.predicate_stats.incircle_exact)) / @as(f64, @floatFromInt(case.iterations)),
            },
        );
    }
    if (best.engine_stats.any()) {
        const iterations_f64 = @as(f64, @floatFromInt(case.iterations));
        const inserted_f64 = @max(@as(f64, @floatFromInt(best.engine_stats.inserted_points)), 1.0);
        const traces_f64 = @max(@as(f64, @floatFromInt(best.engine_stats.corridor_traces)), 1.0);
        std.debug.print(
            "  topology/run: walks {d:>.1}, walk steps {d:>.1}, fallbacks {d:>.1}, fallback scans {d:>.1}\n",
            .{
                @as(f64, @floatFromInt(best.engine_stats.walk_calls)) / iterations_f64,
                @as(f64, @floatFromInt(best.engine_stats.walk_steps)) / iterations_f64,
                @as(f64, @floatFromInt(best.engine_stats.walk_fallbacks)) / iterations_f64,
                @as(f64, @floatFromInt(best.engine_stats.walk_fallback_scan_tris)) / iterations_f64,
            },
        );
        std.debug.print(
            "  topology/insert: cavity tris {d:>.2}, cavity edges {d:>.2}; legalization/run: tests {d:>.1}, flips {d:>.1}; corridor tris/trace {d:>.2}\n",
            .{
                @as(f64, @floatFromInt(best.engine_stats.cavity_triangles)) / inserted_f64,
                @as(f64, @floatFromInt(best.engine_stats.cavity_edges)) / inserted_f64,
                @as(f64, @floatFromInt(best.engine_stats.legalization_tests)) / iterations_f64,
                @as(f64, @floatFromInt(best.engine_stats.edge_flips)) / iterations_f64,
                @as(f64, @floatFromInt(best.engine_stats.corridor_triangles)) / traces_f64,
            },
        );
        std.debug.print(
            "  edge lookup/run: global calls {d:>.1}, scanned tris {d:>.1}; fast calls {d:>.1}, fallbacks {d:>.1}\n",
            .{
                @as(f64, @floatFromInt(best.engine_stats.find_live_edge_calls)) / iterations_f64,
                @as(f64, @floatFromInt(best.engine_stats.find_live_edge_scan_tris)) / iterations_f64,
                @as(f64, @floatFromInt(best.engine_stats.find_live_edge_fast_calls)) / iterations_f64,
                @as(f64, @floatFromInt(best.engine_stats.find_live_edge_fast_fallbacks)) / iterations_f64,
            },
        );
    }
}

fn benchCase(allocator: std.mem.Allocator, case: Case) !void {
    const rounds = 3;
    var timings: [rounds]RoundTiming = undefined;

    const mesh_ids = try allocator.alloc(i32, case.vertices.len);
    defer allocator.free(mesh_ids);

    var engine = triangulate.Engine.init(allocator);
    defer engine.deinit();
    try engine.reserveForPointCount(case.vertices.len);

    var arena = mesh.ThreadArena{};
    defer arena.deinit(allocator);

    var corridor = corridor_module.Corridor{};
    defer corridor.deinit(allocator);

    for (0..rounds) |round| {
        timings[round] = try runRound(allocator, &engine, &arena, &corridor, mesh_ids, case);
    }

    std.mem.sortUnstable(RoundTiming, &timings, {}, lessTotal);
    printCase(case, timings[0], timings[rounds / 2]);
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cases = try allocator.alloc(Case, 3);
    cases[0] = try loadCase(allocator, init.io, "dude", "tests/fixtures/dude.dat", 500);
    cases[1] = try loadCase(allocator, init.io, "nazca-monkey", "tests/fixtures/nazca_monkey.dat", 30);
    cases[2] = try loadCase(allocator, init.io, "nazca-heron", "tests/fixtures/nazca_heron.dat", 30);
    defer for (cases) |case| deinitCase(allocator, case);

    std.debug.print("Cleave larger single-mesh benchmark (ReleaseFast, validation skipped)\n", .{});
    for (cases) |case| {
        try benchCase(allocator, case);
    }
}
