const std = @import("std");
const p2t = @import("p2t");

const Io = std.Io;
const mesh = p2t.mesh;
const parser = p2t.parser;
const spatial = p2t.spatial;
const triangulate = p2t.triangulate;
const corridor_module = p2t.corridor;

const Case = struct {
    name: []const u8,
    vertices: []const mesh.Vertex,
    sorted_indices: []const usize,
};

const WorkerStats = struct {
    jobs: usize = 0,
    triangles: usize = 0,
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

fn loadCase(allocator: std.mem.Allocator, io: Io, name: []const u8, path: []const u8) !Case {
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
    };
}

fn deinitCase(allocator: std.mem.Allocator, case: Case) void {
    allocator.free(case.sorted_indices);
    allocator.free(case.vertices);
}

fn triangulateCase(
    allocator: std.mem.Allocator,
    engine: *triangulate.Engine,
    arena: *mesh.ThreadArena,
    corridor: *corridor_module.Corridor,
    mesh_ids: []i32,
    case: Case,
) !usize {
    engine.resetRetainingCapacity();
    arena.resetRetainingCapacity();

    try engine.initSuperTriangle(case.vertices);

    for (case.sorted_indices) |idx| {
        mesh_ids[idx] = try engine.insertUniquePointTrusted(arena, case.vertices[idx]);
    }

    for (0..case.vertices.len) |i| {
        const start_idx = mesh_ids[i];
        const end_idx = mesh_ids[(i + 1) % case.vertices.len];
        try corridor.recoverConstraintTrusted(allocator, engine, arena, start_idx, end_idx);
    }

    return engine.liveTriangleCount();
}

fn workerMain(cases: []const Case, max_vertices: usize, jobs: usize, stride: usize, offset: usize, stats: *WorkerStats) !void {
    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_allocator.deinit();
    const allocator = arena_allocator.allocator();

    var engine = triangulate.Engine.init(allocator);
    defer engine.deinit();
    try engine.reserveForPointCount(max_vertices);

    var arena = mesh.ThreadArena{};
    defer arena.deinit(allocator);

    var corridor = corridor_module.Corridor{};
    defer corridor.deinit(allocator);

    const mesh_ids = try allocator.alloc(i32, max_vertices);

    var job = offset;
    while (job < jobs) : (job += stride) {
        const case = cases[job % cases.len];
        stats.triangles += try triangulateCase(allocator, &engine, &arena, &corridor, mesh_ids[0..case.vertices.len], case);
        stats.jobs += 1;
    }
}

fn elapsedMicros(start: std.os.linux.timespec, end: std.os.linux.timespec) u64 {
    const start_ns = @as(u64, @intCast(start.sec)) * 1_000_000_000 + @as(u64, @intCast(start.nsec));
    const end_ns = @as(u64, @intCast(end.sec)) * 1_000_000_000 + @as(u64, @intCast(end.nsec));
    return @intCast((end_ns - start_ns) / 1000);
}

fn runThreadCount(allocator: std.mem.Allocator, cases: []const Case, max_vertices: usize, jobs: usize, thread_count: usize) !u64 {
    var threads = try allocator.alloc(std.Thread, thread_count);
    defer allocator.free(threads);

    var stats = try allocator.alloc(WorkerStats, thread_count);
    defer allocator.free(stats);
    @memset(stats, .{});

    var ts_start: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts_start);

    for (0..thread_count) |i| {
        threads[i] = try std.Thread.spawn(.{}, workerMain, .{ cases, max_vertices, jobs, thread_count, i, &stats[i] });
    }
    for (threads) |thread| thread.join();

    var ts_end: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts_end);

    var total_jobs: usize = 0;
    var total_triangles: usize = 0;
    for (stats) |worker_stats| {
        total_jobs += worker_stats.jobs;
        total_triangles += worker_stats.triangles;
    }
    if (total_jobs != jobs or total_triangles == 0) return error.InvalidBenchmarkRun;

    return elapsedMicros(ts_start, ts_end);
}

fn printRun(thread_count: usize, jobs: usize, elapsed_us: u64, baseline_us: u64) void {
    const per_job = @as(f64, @floatFromInt(elapsed_us)) / @as(f64, @floatFromInt(jobs));
    const speedup = @as(f64, @floatFromInt(baseline_us)) / @as(f64, @floatFromInt(elapsed_us));
    std.debug.print("{d:>3} worker(s): {d:>8} us  {d:>7.3} us/job  {d:>5.2}x\n", .{
        thread_count,
        elapsed_us,
        per_job,
        speedup,
    });
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cases = try allocator.alloc(Case, 3);
    cases[0] = try loadCase(allocator, init.io, "fixture-test", "tests/fixtures/test.dat");
    cases[1] = try loadCase(allocator, init.io, "diamond", "tests/fixtures/diamond.dat");
    cases[2] = try loadCase(allocator, init.io, "star", "tests/fixtures/star.dat");
    defer for (cases) |case| deinitCase(allocator, case);

    var max_vertices: usize = 0;
    for (cases) |case| max_vertices = @max(max_vertices, case.vertices.len);

    const jobs: usize = 20_000;
    const cpu_count = try std.Thread.getCpuCount();
    const counts = [_]usize{ 1, 2, 4, 8, cpu_count };

    std.debug.print("Cleave batch throughput ({d} independent jobs across {d} fixtures)\n", .{ jobs, cases.len });
    var baseline_us: u64 = 0;
    var last_count: usize = 0;
    for (counts) |raw_count| {
        const thread_count = @max(@as(usize, 1), @min(raw_count, cpu_count));
        if (thread_count == last_count) continue;
        last_count = thread_count;

        const elapsed_us = try runThreadCount(allocator, cases, max_vertices, jobs, thread_count);
        if (baseline_us == 0) baseline_us = elapsed_us;
        printRun(thread_count, jobs, elapsed_us, baseline_us);
    }
}
