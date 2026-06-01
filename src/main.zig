const std = @import("std");
const Io = std.Io;
const parser = @import("parser.zig");
const mesh = @import("mesh.zig");
const triangulate = @import("triangulate.zig");
const corridor_module = @import("corridor.zig");

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

    var times = try allocator.alloc(u64, iterations);
    defer allocator.free(times);

    var reportedTriangles: usize = 0;

    for (0..iterations) |round| {
        var engine = triangulate.Engine.init(allocator);
        defer engine.deinit();

        var arena = mesh.ThreadArena{};
        defer arena.deinit(allocator);

        var ts_start: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts_start);

        try engine.initSuperTriangle(vertices);

        for (vertices) |v| {
            try engine.insertPoint(&arena, v);
        }

        // Phase 5: Constraint Recovery
        var corridor = corridor_module.Corridor{};
        defer corridor.deinit(allocator);

        for (0..vertices.len) |i| {
            const start_idx = @as(i32, @intCast(i));
            const end_idx = @as(i32, @intCast((i + 1) % vertices.len));
            
            const start_pt = engine.getVertex(start_idx);
            const end_pt = engine.getVertex(end_idx);

            corridor.pierced_triangles.clearRetainingCapacity();

            // Find triangle containing start_pt to begin tracing
            const start_tri = engine.walk(engine.last_valid_tri, start_pt);
            if (start_tri >= 0) {
                try corridor.trace(allocator, &engine, start_tri, end_pt, start_pt);
                try corridor.clearAndRetriangulate(allocator, &engine, &arena, start_idx, end_idx);
            }
        }

        var ts_end: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts_end);
        
        const start_ns = @as(u64, @intCast(ts_start.sec)) * 1_000_000_000 + @as(u64, @intCast(ts_start.nsec));
        const end_ns = @as(u64, @intCast(ts_end.sec)) * 1_000_000_000 + @as(u64, @intCast(ts_end.nsec));

        const elapsed = end_ns - start_ns;
        times[round] = @intCast(elapsed / 1000); // to us
        reportedTriangles = engine.mesh.triangles.len;
    }

    std.mem.sortUnstable(u64, times, {}, std.sort.asc(u64));
    const best = times[0];
    const median = times[iterations / 2];

    std.debug.print("{s} (Zig): {d} runs, {d} triangles, best {d} us, median {d} us\n", .{ name, iterations, reportedTriangles, best, median });
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
