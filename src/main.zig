const std = @import("std");
const Io = std.Io;
const parser = @import("parser.zig");
const mesh = @import("mesh.zig");
const triangulate = @import("triangulate.zig");
const corridor_module = @import("corridor.zig");
const spatial = @import("spatial.zig");
const quality = @import("quality.zig");

pub fn readFile(allocator: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
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

pub fn bench(allocator: std.mem.Allocator, io: Io, name: []const u8, file_path: []const u8, iterations: usize) !void {
    const file_content = try readFile(allocator, io, file_path);
    defer allocator.free(file_content);

    const points = try parser.parseDatString(allocator, file_content);
    defer allocator.free(points);

    // Prepare vertices
    const vertices = try allocator.alloc(mesh.Vertex, points.len);
    defer allocator.free(vertices);
    for (points, 0..) |p, i| {
        vertices[i] = .{ .x = p.x, .y = p.y };
    }

    const BENCH_ROUNDS = 5;
    var times = try allocator.alloc(u64, BENCH_ROUNDS);
    defer allocator.free(times);

    var reportedTriangles: usize = 0;

    for (0..BENCH_ROUNDS) |round| {
        var ts_start: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts_start);

        var total_triangles: usize = 0;

        for (0..iterations) |_| {
            var engine = triangulate.Engine.init(allocator);
            defer engine.deinit();

            var arena = mesh.ThreadArena{};
            defer arena.deinit(allocator);

            try engine.initSuperTriangle(vertices);

            const sorted_indices = try spatial.sortVerticesByMorton(allocator, vertices);
            defer allocator.free(sorted_indices);
            const mesh_ids = try allocator.alloc(i32, vertices.len);
            defer allocator.free(mesh_ids);

            for (sorted_indices) |idx| {
                mesh_ids[idx] = try engine.insertPoint(&arena, vertices[idx]);
            }
            try engine.validateTopology();

            var corridor = corridor_module.Corridor{};
            defer corridor.deinit(allocator);

            for (0..vertices.len) |i| {
                const start_idx = mesh_ids[i];
                const end_idx = mesh_ids[(i + 1) % vertices.len];

                const start_pt = engine.getVertex(start_idx);
                const end_pt = engine.getVertex(end_idx);

                corridor.pierced_triangles.clearRetainingCapacity();

                const start_tri = engine.walk(engine.last_valid_tri, start_pt);
                if (start_tri >= 0) {
                    try corridor.trace(allocator, &engine, start_tri, end_pt, start_pt);
                    try corridor.clearAndRetriangulate(allocator, &engine, &arena, start_idx, end_idx);
                }
            }

            try engine.validateTopology();
            try engine.validateConstraintRing(mesh_ids);
            total_triangles += engine.liveTriangleCount();
        }

        var ts_end: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts_end);

        const start_ns = @as(u64, @intCast(ts_start.sec)) * 1_000_000_000 + @as(u64, @intCast(ts_start.nsec));
        const end_ns = @as(u64, @intCast(ts_end.sec)) * 1_000_000_000 + @as(u64, @intCast(ts_end.nsec));

        const elapsed = end_ns - start_ns;
        times[round] = @intCast(elapsed / 1000); // to us
        reportedTriangles = total_triangles;
    }

    std.mem.sortUnstable(u64, times, {}, std.sort.asc(u64));
    const best = times[0];
    const median = times[BENCH_ROUNDS / 2];

    std.debug.print("{s}: {d} runs, {d} triangles, best {d} us, median {d} us\n", .{ name, iterations, reportedTriangles, best, median });

    // Calculate quality for the last run
    if (iterations > 0) {
        // We will just do a final run to measure quality so we don't skew the timing loop
        var engine = triangulate.Engine.init(allocator);
        defer engine.deinit();

        var arena = mesh.ThreadArena{};
        defer arena.deinit(allocator);

        engine.initSuperTriangle(vertices) catch unreachable;

        const sorted_indices = spatial.sortVerticesByMorton(allocator, vertices) catch unreachable;
        defer allocator.free(sorted_indices);
        const mesh_ids = allocator.alloc(i32, vertices.len) catch unreachable;
        defer allocator.free(mesh_ids);

        for (sorted_indices) |idx| {
            mesh_ids[idx] = engine.insertPoint(&arena, vertices[idx]) catch unreachable;
        }

        var corridor = corridor_module.Corridor{};
        defer corridor.deinit(allocator);

        for (0..vertices.len) |i| {
            const start_idx = mesh_ids[i];
            const end_idx = mesh_ids[(i + 1) % vertices.len];

            const start_pt = engine.getVertex(start_idx);
            const end_pt = engine.getVertex(end_idx);

            corridor.pierced_triangles.clearRetainingCapacity();

            const start_tri = engine.walk(engine.last_valid_tri, start_pt);
            if (start_tri >= 0) {
                corridor.trace(allocator, &engine, start_tri, end_pt, start_pt) catch unreachable;
                corridor.clearAndRetriangulate(allocator, &engine, &arena, start_idx, end_idx) catch unreachable;
            }
        }

        engine.validateTopology() catch unreachable;
        engine.validateConstraintRing(mesh_ids) catch unreachable;

        var stats = quality.QualityStats{};
        for (0..engine.mesh.triangles.len) |i| {
            const tri = engine.mesh.triangles.get(i);
            if (mesh.isDeadTriangle(tri)) continue;
            // Ignore super-triangle vertices (indices 0, 1, 2)
            if (tri.v0 < 3 or tri.v1 < 3 or tri.v2 < 3) continue;

            const a = engine.getVertex(tri.v0);
            const b = engine.getVertex(tri.v1);
            const c = engine.getVertex(tri.v2);

            stats.accumulate(a, b, c);
        }
        stats.finalize();
        stats.print(name);
    }
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("Starting Zig Benchmarks (Raw Point Insertion)...\n", .{});

    try bench(allocator, init.io, "fixture-test", "tests/fixtures/test.dat", 10000);
    try bench(allocator, init.io, "diamond", "tests/fixtures/diamond.dat", 10000);
    try bench(allocator, init.io, "star", "tests/fixtures/star.dat", 10000);
    try bench(allocator, init.io, "dude", "tests/fixtures/dude.dat", 1000);
    try bench(allocator, init.io, "nazca_heron", "tests/fixtures/nazca_heron.dat", 1000);
}
