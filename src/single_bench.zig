const std = @import("std");
const p2t = @import("p2t");

const build_options = p2t.build_options;
const Io = std.Io;
const corridor_module = p2t.corridor;
const mesh = p2t.mesh;
const parser = p2t.parser;
const predicates = p2t.predicates;
const polygon_seed = p2t.polygon_seed;
const quality = p2t.quality;
const spatial = p2t.spatial;
const timer = p2t.timer;
const trapezoid_dd = p2t.trapezoid_dd;
const triangulate = p2t.triangulate;

const Case = struct {
    name: []const u8,
    vertices: []const mesh.Vertex,
    morton_indices: []const usize,
    brio_indices: []const usize,
    iterations: usize,
};

const Order = struct {
    name: []const u8,
    indices: []const usize,
};

const RoundTiming = struct {
    total_us: u64 = 0,
    insertion_us: u64 = 0,
    constraint_us: u64 = 0,
    seed_us: u64 = 0,
    legalization_us: u64 = 0,
    decomposition_us: u64 = 0,
    piece_bw_us: u64 = 0,
    piece_bw_serial_us: u64 = 0,
    piece_bw_max_us: u64 = 0,
    piece_merge_us: u64 = 0,
    assembly_us: u64 = 0,
    local_legalization_us: u64 = 0,
    seam_legalization_us: u64 = 0,
    cull_us: u64 = 0,
    extraction_us: u64 = 0,
    triangles: usize = 0,
    live_triangles: usize = 0,
    dd_pieces: usize = 0,
    dd_diagonals: usize = 0,
    dd_max_piece_vertices: usize = 0,
    dd_total_piece_vertices: usize = 0,
    dd_split_candidates: u64 = 0,
    dd_midpoint_scans: u64 = 0,
    dd_edge_scans: u64 = 0,
    dd_aabb_rejects: u64 = 0,
    dd_cone_rejects: u64 = 0,
    dd_accepted_diagonals: u64 = 0,
    dd_failed_splits: u64 = 0,
    piece_bw_threads: usize = 0,
    local_legalization_tests: u64 = 0,
    local_edge_flips: u64 = 0,
    seam_legalization_tests: u64 = 0,
    seam_edge_flips: u64 = 0,
    predicate_stats: predicates.PredicateStats = .{},
    engine_stats: triangulate.EngineStats = .{},
};

fn partitionedBwMode() bool {
    return build_options.partitioned_bw_mode or build_options.partitioned_bw_parallel_mode;
}

fn partitionedBwParallelMode() bool {
    return build_options.partitioned_bw_parallel_mode;
}

const PieceBuildResult = struct {
    indices: []i32 = &.{},
    elapsed_us: u64 = 0,
    err: ?anyerror = null,

    fn deinit(self: *PieceBuildResult) void {
        if (self.indices.len != 0) std.heap.page_allocator.free(self.indices);
        self.* = .{};
    }
};

const PieceBuildStats = struct {
    wall_us: u64 = 0,
    serial_us: u64 = 0,
    max_us: u64 = 0,
    merge_us: u64 = 0,
    threads: usize = 1,
};

const PieceWorkerContext = struct {
    io: Io,
    vertices: []const mesh.Vertex,
    rings: []const i32,
    pieces: []const trapezoid_dd.Piece,
    stride: usize,
    offset: usize,
    results: []PieceBuildResult,
};

fn appendLiveLocalTrianglesAsGlobal(
    allocator: std.mem.Allocator,
    local_engine: *triangulate.Engine,
    local_to_global: []const i32,
    out_indices: *std.ArrayListUnmanaged(i32),
) !usize {
    var appended: usize = 0;
    try out_indices.ensureUnusedCapacity(allocator, local_engine.liveTriangleCount() * 3);
    for (0..local_engine.mesh.triangles.len) |tri_idx| {
        const tri = local_engine.mesh.triangles.get(tri_idx);
        if (mesh.isDeadTriangle(tri)) continue;

        const local = [_]i32{ tri.v0, tri.v1, tri.v2 };
        var global: [3]i32 = undefined;
        for (local, 0..) |vertex_id, i| {
            if (vertex_id < 0) return error.InvalidTriangleVertex;
            const slot: usize = @intCast(vertex_id);
            if (slot >= local_to_global.len or local_to_global[slot] < 0) return error.InvalidTriangleVertex;
            global[i] = local_to_global[slot];
        }
        out_indices.appendSliceAssumeCapacity(&global);
        appended += 1;
    }
    return appended;
}

fn appendPieceBowyerWatsonSeed(
    allocator: std.mem.Allocator,
    vertices: []const mesh.Vertex,
    ring: []const i32,
    out_indices: *std.ArrayListUnmanaged(i32),
) !usize {
    if (ring.len < 3) return error.InvalidTriangleVertex;

    const piece_vertices = try allocator.alloc(mesh.Vertex, ring.len);
    defer allocator.free(piece_vertices);
    for (ring, 0..) |global_idx, i| {
        if (global_idx < 0) return error.InvalidTriangleVertex;
        const slot: usize = @intCast(global_idx);
        if (slot >= vertices.len) return error.InvalidTriangleVertex;
        piece_vertices[i] = vertices[slot];
    }

    var local_engine = triangulate.Engine.init(allocator);
    defer local_engine.deinit();
    try local_engine.reserveForPointCount(piece_vertices.len);
    try local_engine.initSuperTriangle(piece_vertices);

    var local_arena = mesh.ThreadArena{};
    defer local_arena.deinit(allocator);

    const local_order = try spatial.sortVerticesByBrioMorton(allocator, piece_vertices, 0x51EEDB0B);
    defer allocator.free(local_order);

    const piece_mesh_ids = try allocator.alloc(i32, ring.len);
    defer allocator.free(piece_mesh_ids);
    for (local_order) |local_idx| {
        piece_mesh_ids[local_idx] = try local_engine.insertUniquePointTrusted(&local_arena, piece_vertices[local_idx]);
    }

    var local_corridor = corridor_module.Corridor{};
    defer local_corridor.deinit(allocator);
    for (0..ring.len) |i| {
        const start_idx = piece_mesh_ids[i];
        const end_idx = piece_mesh_ids[(i + 1) % ring.len];
        try local_corridor.recoverConstraintTrusted(allocator, &local_engine, &local_arena, start_idx, end_idx);
    }

    _ = try local_engine.cullExteriorTrianglesTrusted();

    const local_to_global = try allocator.alloc(i32, local_engine.mesh.vertices.len);
    defer allocator.free(local_to_global);
    @memset(local_to_global, -1);
    for (piece_mesh_ids, 0..) |local_vertex_id, i| {
        if (local_vertex_id < 0) return error.InvalidTriangleVertex;
        local_to_global[@as(usize, @intCast(local_vertex_id))] = ring[i];
    }

    return appendLiveLocalTrianglesAsGlobal(allocator, &local_engine, local_to_global, out_indices);
}

fn buildPieceBowyerWatsonResult(io: Io, vertices: []const mesh.Vertex, ring: []const i32) PieceBuildResult {
    const start = timer.now(io);
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var local_indices: std.ArrayListUnmanaged(i32) = .empty;
    defer local_indices.deinit(allocator);

    _ = appendPieceBowyerWatsonSeed(allocator, vertices, ring, &local_indices) catch |err| {
        return .{ .elapsed_us = timer.elapsedMicros(start, timer.now(io)), .err = err };
    };
    const owned_indices = std.heap.page_allocator.dupe(i32, local_indices.items) catch |err| {
        return .{ .elapsed_us = timer.elapsedMicros(start, timer.now(io)), .err = err };
    };
    return .{
        .indices = owned_indices,
        .elapsed_us = timer.elapsedMicros(start, timer.now(io)),
    };
}

fn partitionedBwPieceWorker(context: *PieceWorkerContext) void {
    var piece_idx = context.offset;
    while (piece_idx < context.pieces.len) : (piece_idx += context.stride) {
        const piece = context.pieces[piece_idx];
        const ring = context.rings[piece.start .. piece.start + piece.len];
        context.results[piece_idx] = buildPieceBowyerWatsonResult(context.io, context.vertices, ring);
    }
}

fn partitionedBwWorkerCount(piece_count: usize) !usize {
    if (piece_count == 0) return 1;
    const requested = build_options.partitioned_bw_threads;
    const detected = if (requested == 0) try std.Thread.getCpuCount() else requested;
    return @max(@as(usize, 1), @min(detected, piece_count));
}

fn appendPartitionedBwPiecesSerial(
    io: Io,
    allocator: std.mem.Allocator,
    vertices: []const mesh.Vertex,
    decomposition: *const trapezoid_dd.Decomposition,
    out_indices: *std.ArrayListUnmanaged(i32),
) !PieceBuildStats {
    var stats = PieceBuildStats{};
    const wall_start = timer.now(io);
    for (decomposition.pieces.items) |piece| {
        const piece_start = timer.now(io);
        const ring = decomposition.rings.items[piece.start .. piece.start + piece.len];
        _ = try appendPieceBowyerWatsonSeed(allocator, vertices, ring, out_indices);
        const piece_elapsed = timer.elapsedMicros(piece_start, timer.now(io));
        stats.serial_us += piece_elapsed;
        stats.max_us = @max(stats.max_us, piece_elapsed);
    }
    stats.wall_us = timer.elapsedMicros(wall_start, timer.now(io));
    stats.threads = 1;
    return stats;
}

fn appendPartitionedBwPiecesParallel(
    io: Io,
    allocator: std.mem.Allocator,
    vertices: []const mesh.Vertex,
    decomposition: *const trapezoid_dd.Decomposition,
    out_indices: *std.ArrayListUnmanaged(i32),
) !PieceBuildStats {
    const piece_count = decomposition.pieces.items.len;
    const thread_count = try partitionedBwWorkerCount(piece_count);
    if (thread_count == 1) {
        return appendPartitionedBwPiecesSerial(io, allocator, vertices, decomposition, out_indices);
    }

    const results = try allocator.alloc(PieceBuildResult, piece_count);
    defer allocator.free(results);
    for (results) |*result| result.* = .{};
    defer for (results) |*result| result.deinit();

    const contexts = try allocator.alloc(PieceWorkerContext, thread_count);
    defer allocator.free(contexts);
    const threads = try allocator.alloc(std.Thread, thread_count);
    defer allocator.free(threads);

    const wall_start = timer.now(io);
    var started_threads: usize = 0;
    for (0..thread_count) |i| {
        contexts[i] = .{
            .io = io,
            .vertices = vertices,
            .rings = decomposition.rings.items,
            .pieces = decomposition.pieces.items,
            .stride = thread_count,
            .offset = i,
            .results = results,
        };
        threads[i] = std.Thread.spawn(.{}, partitionedBwPieceWorker, .{&contexts[i]}) catch |err| {
            for (threads[0..started_threads]) |thread| thread.join();
            return err;
        };
        started_threads += 1;
    }
    for (threads[0..started_threads]) |thread| thread.join();
    const wall_us = timer.elapsedMicros(wall_start, timer.now(io));

    var stats = PieceBuildStats{
        .wall_us = wall_us,
        .threads = thread_count,
    };
    for (results) |result| {
        if (result.err) |err| return err;
        stats.serial_us += result.elapsed_us;
        stats.max_us = @max(stats.max_us, result.elapsed_us);
    }

    const merge_start = timer.now(io);
    for (results) |result| {
        try out_indices.appendSlice(allocator, result.indices);
    }
    stats.merge_us = timer.elapsedMicros(merge_start, timer.now(io));
    return stats;
}

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
        .morton_indices = try spatial.sortVerticesByMorton(allocator, vertices),
        .brio_indices = try spatial.sortVerticesByBrioMorton(allocator, vertices, 0xC1EAFEED),
        .iterations = iterations,
    };
}

fn deinitCase(allocator: std.mem.Allocator, case: Case) void {
    allocator.free(case.brio_indices);
    allocator.free(case.morton_indices);
    allocator.free(case.vertices);
}

fn runRound(
    io: Io,
    allocator: std.mem.Allocator,
    engine: *triangulate.Engine,
    arena: *mesh.ThreadArena,
    corridor: *corridor_module.Corridor,
    mesh_ids: []i32,
    case: Case,
    order: Order,
) !RoundTiming {
    var timing = RoundTiming{};
    var seed_indices: std.ArrayListUnmanaged(i32) = .empty;
    defer seed_indices.deinit(allocator);
    var seed_triangles: std.ArrayListUnmanaged(i32) = .empty;
    defer seed_triangles.deinit(allocator);
    var decomposition = trapezoid_dd.Decomposition{};
    defer decomposition.deinit(allocator);
    var piece_seed_indices: std.ArrayListUnmanaged(i32) = .empty;
    defer piece_seed_indices.deinit(allocator);
    var piece_ranges: std.ArrayListUnmanaged(trapezoid_dd.Piece) = .empty;
    defer piece_ranges.deinit(allocator);

    predicates.resetStats();
    engine.resetStats();
    const total_start = timer.now(io);

    for (0..case.iterations) |_| {
        engine.resetRetainingCapacity();
        arena.resetRetainingCapacity();

        var insertion_start = timer.now(io);
        var insertion_end = insertion_start;
        var constraint_end = insertion_start;
        var seed_start = insertion_start;
        var seed_end = insertion_start;
        var legalization_end = insertion_start;
        var decomposition_start = insertion_start;
        var decomposition_end = insertion_start;
        var piece_bw_wall_us: u64 = 0;
        var piece_bw_serial_us: u64 = 0;
        var piece_bw_max_us: u64 = 0;
        var piece_merge_us: u64 = 0;
        var piece_bw_threads: usize = 0;
        var assembly_start = insertion_start;
        var assembly_end = insertion_start;
        var local_legalization_end = insertion_start;
        var seam_legalization_end = insertion_start;

        if (partitionedBwMode()) {
            decomposition_start = timer.now(io);
            try trapezoid_dd.decomposeSimple(allocator, case.vertices, 256, &decomposition);
            decomposition_end = timer.now(io);

            seed_indices.clearRetainingCapacity();
            const piece_stats = if (partitionedBwParallelMode())
                try appendPartitionedBwPiecesParallel(io, allocator, case.vertices, &decomposition, &seed_indices)
            else
                try appendPartitionedBwPiecesSerial(io, allocator, case.vertices, &decomposition, &seed_indices);
            piece_bw_wall_us = piece_stats.wall_us;
            piece_bw_serial_us = piece_stats.serial_us;
            piece_bw_max_us = piece_stats.max_us;
            piece_merge_us = piece_stats.merge_us;
            piece_bw_threads = piece_stats.threads;

            assembly_start = timer.now(io);
            try engine.buildPolygonSeedMesh(case.vertices, seed_indices.items);
            try engine.setConstraintSegmentsTrusted(allocator, decomposition.diagonals.items, true, null);
            assembly_end = timer.now(io);

            seed_triangles.clearRetainingCapacity();
            try engine.setConstraintSegmentsTrusted(allocator, decomposition.diagonals.items, false, &seed_triangles);
            const seam_stats_start = engine.statsSnapshot();
            try engine.legalizeFromTriangles(allocator, seed_triangles.items);
            seam_legalization_end = timer.now(io);
            const seam_stats = engine.statsSnapshot();

            const decomp_stats = decomposition.stats();
            timing.dd_pieces += decomp_stats.pieces;
            timing.dd_diagonals += decomp_stats.diagonals;
            timing.dd_max_piece_vertices = @max(timing.dd_max_piece_vertices, decomp_stats.max_piece_vertices);
            timing.dd_total_piece_vertices += decomp_stats.total_piece_vertices;
            timing.dd_split_candidates += decomp_stats.split_candidates;
            timing.dd_midpoint_scans += decomp_stats.midpoint_scans;
            timing.dd_edge_scans += decomp_stats.edge_scans;
            timing.dd_aabb_rejects += decomp_stats.aabb_rejects;
            timing.dd_cone_rejects += decomp_stats.cone_rejects;
            timing.dd_accepted_diagonals += decomp_stats.accepted_diagonals;
            timing.dd_failed_splits += decomp_stats.failed_splits;
            timing.seam_legalization_tests += seam_stats.legalization_tests - seam_stats_start.legalization_tests;
            timing.seam_edge_flips += seam_stats.edge_flips - seam_stats_start.edge_flips;

            seed_start = decomposition_end;
            seed_end = assembly_end;
            legalization_end = seam_legalization_end;
            insertion_start = decomposition_start;
            insertion_end = assembly_start;
            constraint_end = seam_legalization_end;
            local_legalization_end = assembly_end;
        } else if (build_options.trapezoid_dd_mode) {
            decomposition_start = timer.now(io);
            try trapezoid_dd.decomposeSimple(allocator, case.vertices, 256, &decomposition);
            decomposition_end = timer.now(io);

            seed_indices.clearRetainingCapacity();
            piece_ranges.clearRetainingCapacity();
            try piece_ranges.ensureTotalCapacity(allocator, decomposition.pieces.items.len);
            for (decomposition.pieces.items) |piece| {
                const ring = decomposition.rings.items[piece.start .. piece.start + piece.len];
                piece_seed_indices.clearRetainingCapacity();
                try polygon_seed.triangulateRing(allocator, case.vertices, ring, &piece_seed_indices);
                const start_tri = seed_indices.items.len / 3;
                try seed_indices.appendSlice(allocator, piece_seed_indices.items);
                piece_ranges.appendAssumeCapacity(.{ .start = start_tri, .len = piece_seed_indices.items.len / 3 });
            }
            try engine.buildPolygonSeedMesh(case.vertices, seed_indices.items);
            try engine.setConstraintSegmentsTrusted(allocator, decomposition.diagonals.items, true, null);
            seed_end = timer.now(io);

            const local_tests_start = engine.statsSnapshot().legalization_tests;
            const local_flips_start = engine.statsSnapshot().edge_flips;
            for (piece_ranges.items) |range| {
                seed_triangles.clearRetainingCapacity();
                try seed_triangles.ensureTotalCapacity(allocator, range.len);
                for (0..range.len) |offset| {
                    seed_triangles.appendAssumeCapacity(@intCast(range.start + offset));
                }
                try engine.legalizeFromTriangles(allocator, seed_triangles.items);
            }
            local_legalization_end = timer.now(io);
            const local_stats = engine.statsSnapshot();

            seed_triangles.clearRetainingCapacity();
            try engine.setConstraintSegmentsTrusted(allocator, decomposition.diagonals.items, false, &seed_triangles);
            try engine.legalizeFromTriangles(allocator, seed_triangles.items);
            seam_legalization_end = timer.now(io);
            const seam_stats = engine.statsSnapshot();

            const decomp_stats = decomposition.stats();
            timing.dd_pieces += decomp_stats.pieces;
            timing.dd_diagonals += decomp_stats.diagonals;
            timing.dd_max_piece_vertices = @max(timing.dd_max_piece_vertices, decomp_stats.max_piece_vertices);
            timing.dd_total_piece_vertices += decomp_stats.total_piece_vertices;
            timing.dd_split_candidates += decomp_stats.split_candidates;
            timing.dd_midpoint_scans += decomp_stats.midpoint_scans;
            timing.dd_edge_scans += decomp_stats.edge_scans;
            timing.dd_aabb_rejects += decomp_stats.aabb_rejects;
            timing.dd_cone_rejects += decomp_stats.cone_rejects;
            timing.dd_accepted_diagonals += decomp_stats.accepted_diagonals;
            timing.dd_failed_splits += decomp_stats.failed_splits;
            timing.local_legalization_tests += local_stats.legalization_tests - local_tests_start;
            timing.local_edge_flips += local_stats.edge_flips - local_flips_start;
            timing.seam_legalization_tests += seam_stats.legalization_tests - local_stats.legalization_tests;
            timing.seam_edge_flips += seam_stats.edge_flips - local_stats.edge_flips;

            seed_start = decomposition_end;
            legalization_end = seam_legalization_end;
            insertion_start = decomposition_start;
            insertion_end = seed_end;
            constraint_end = seam_legalization_end;
        } else if (build_options.polygon_seed_mode) {
            seed_start = timer.now(io);
            try polygon_seed.triangulateSimple(allocator, case.vertices, &seed_indices);
            try engine.buildPolygonSeedMesh(case.vertices, seed_indices.items);
            seed_end = timer.now(io);

            seed_triangles.clearRetainingCapacity();
            try seed_triangles.ensureTotalCapacity(allocator, engine.mesh.triangles.len);
            for (0..engine.mesh.triangles.len) |tri_idx| {
                seed_triangles.appendAssumeCapacity(@intCast(tri_idx));
            }
            try engine.legalizeFromTriangles(allocator, seed_triangles.items);
            legalization_end = timer.now(io);
            insertion_start = seed_start;
            insertion_end = seed_end;
            constraint_end = legalization_end;
        } else {
            try engine.initSuperTriangle(case.vertices);

            insertion_start = timer.now(io);
            for (order.indices) |idx| {
                mesh_ids[idx] = try engine.insertUniquePointTrusted(arena, case.vertices[idx]);
            }
            insertion_end = timer.now(io);

            for (0..case.vertices.len) |i| {
                const start_idx = mesh_ids[i];
                const end_idx = mesh_ids[(i + 1) % case.vertices.len];
                try corridor.recoverConstraintTrusted(allocator, engine, arena, start_idx, end_idx);
            }
            constraint_end = timer.now(io);
        }

        const cull_start = constraint_end;
        if (build_options.polygon_output_mode and !build_options.polygon_seed_mode and !build_options.trapezoid_dd_mode and !partitionedBwMode()) {
            _ = try engine.cullExteriorTrianglesTrusted();
        }
        const cull_end = timer.now(io);

        const extraction_start = cull_end;
        const interior_triangles = if (build_options.polygon_output_mode or build_options.polygon_seed_mode or build_options.trapezoid_dd_mode or partitionedBwMode())
            engine.liveTriangleCount()
        else
            try engine.countInteriorTriangles();
        const extraction_end = timer.now(io);

        timing.insertion_us += timer.elapsedMicros(insertion_start, insertion_end);
        timing.constraint_us += timer.elapsedMicros(insertion_end, constraint_end);
        timing.seed_us += timer.elapsedMicros(seed_start, seed_end);
        timing.legalization_us += timer.elapsedMicros(seed_end, legalization_end);
        timing.decomposition_us += timer.elapsedMicros(decomposition_start, decomposition_end);
        timing.piece_bw_us += piece_bw_wall_us;
        timing.piece_bw_serial_us += piece_bw_serial_us;
        timing.piece_bw_max_us += piece_bw_max_us;
        timing.piece_merge_us += piece_merge_us;
        timing.piece_bw_threads = @max(timing.piece_bw_threads, piece_bw_threads);
        timing.assembly_us += timer.elapsedMicros(assembly_start, assembly_end);
        timing.local_legalization_us += timer.elapsedMicros(seed_end, local_legalization_end);
        timing.seam_legalization_us += timer.elapsedMicros(local_legalization_end, seam_legalization_end);
        timing.cull_us += timer.elapsedMicros(cull_start, cull_end);
        timing.extraction_us += timer.elapsedMicros(extraction_start, extraction_end);
        timing.triangles += interior_triangles;
        timing.live_triangles += engine.liveTriangleCount();
    }

    timing.total_us = timer.elapsedMicros(total_start, timer.now(io));
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

fn printCavityRelevance(case: Case, order: Order, stats: triangulate.EngineStats) void {
    if (stats.cavity_relevance_samples == 0) return;
    const classified = stats.cavity_relevance_interior + stats.cavity_relevance_exterior;
    const exterior_share = if (classified == 0)
        0.0
    else
        @as(f64, @floatFromInt(stats.cavity_relevance_exterior)) * 100.0 / @as(f64, @floatFromInt(classified));
    std.debug.print(
        "  cavity relevance {s}/{s}: {d} samples, interior {d}, exterior {d} ({d:>.1}%), unclassified {d}\n",
        .{
            case.name,
            order.name,
            stats.cavity_relevance_samples,
            stats.cavity_relevance_interior,
            stats.cavity_relevance_exterior,
            exterior_share,
            stats.cavity_relevance_unclassified,
        },
    );
}

fn printDecompositionDiagnostics(best: RoundTiming, iterations: usize) void {
    if (best.dd_split_candidates == 0 and best.dd_midpoint_scans == 0 and best.dd_edge_scans == 0) return;
    const iterations_f64 = @as(f64, @floatFromInt(iterations));
    std.debug.print(
        "  decomposition detail/run: candidates {d:>.1}, midpoint scans {d:>.1}, edge scans {d:>.1}, aabb rejects {d:>.1}, cone rejects {d:>.1}, accepted {d:>.1}, failed splits {d:>.1}\n",
        .{
            @as(f64, @floatFromInt(best.dd_split_candidates)) / iterations_f64,
            @as(f64, @floatFromInt(best.dd_midpoint_scans)) / iterations_f64,
            @as(f64, @floatFromInt(best.dd_edge_scans)) / iterations_f64,
            @as(f64, @floatFromInt(best.dd_aabb_rejects)) / iterations_f64,
            @as(f64, @floatFromInt(best.dd_cone_rejects)) / iterations_f64,
            @as(f64, @floatFromInt(best.dd_accepted_diagonals)) / iterations_f64,
            @as(f64, @floatFromInt(best.dd_failed_splits)) / iterations_f64,
        },
    );
}

fn printCase(case: Case, order: Order, best: RoundTiming, median: RoundTiming) void {
    const phase_us = if (partitionedBwMode())
        best.decomposition_us + best.piece_bw_us + best.piece_merge_us + best.assembly_us + best.seam_legalization_us + best.cull_us + best.extraction_us
    else if (build_options.trapezoid_dd_mode)
        best.decomposition_us + best.seed_us + best.local_legalization_us + best.seam_legalization_us + best.cull_us + best.extraction_us
    else if (build_options.polygon_seed_mode)
        best.seed_us + best.legalization_us + best.cull_us + best.extraction_us
    else
        best.insertion_us + best.constraint_us + best.cull_us + best.extraction_us;
    const other_us = if (best.total_us > phase_us)
        best.total_us - phase_us
    else
        0;
    const triangles_per_run = best.triangles / case.iterations;
    const live_triangles_per_run = best.live_triangles / case.iterations;

    std.debug.print(
        "{s}/{s}: {d} vertices, {d} runs, {d} interior triangles/run ({d} live mesh), best {d} us ({d:>.3} us/run), median {d} us\n",
        .{
            case.name,
            order.name,
            case.vertices.len,
            case.iterations,
            triangles_per_run,
            live_triangles_per_run,
            best.total_us,
            perRun(best.total_us, case.iterations),
            median.total_us,
        },
    );
    if (partitionedBwMode()) {
        const avg_pieces = @as(f64, @floatFromInt(best.dd_pieces)) / @as(f64, @floatFromInt(case.iterations));
        const avg_diagonals = @as(f64, @floatFromInt(best.dd_diagonals)) / @as(f64, @floatFromInt(case.iterations));
        const mean_piece_vertices = @as(f64, @floatFromInt(best.dd_total_piece_vertices)) / @max(@as(f64, @floatFromInt(best.dd_pieces)), 1.0);
        const critical_path = perRun(best.decomposition_us, case.iterations) +
            perRun(best.piece_bw_us + best.piece_merge_us, case.iterations) +
            perRun(best.assembly_us, case.iterations) +
            perRun(best.seam_legalization_us, case.iterations);
        const critical_path_without_decomp = perRun(best.piece_bw_us + best.piece_merge_us, case.iterations) +
            perRun(best.assembly_us, case.iterations) +
            perRun(best.seam_legalization_us, case.iterations);
        std.debug.print(
            "  phase best/run: decomposition {d:>.3} us, piece BW wall {d:>.3} us, piece BW serial {d:>.3} us, max piece BW {d:>.3} us, piece merge {d:>.3} us, assembly {d:>.3} us, seam legalize {d:>.3} us, extraction {d:>.3} us, setup+other {d:>.3} us\n",
            .{
                perRun(best.decomposition_us, case.iterations),
                perRun(best.piece_bw_us, case.iterations),
                perRun(best.piece_bw_serial_us, case.iterations),
                perRun(best.piece_bw_max_us, case.iterations),
                perRun(best.piece_merge_us, case.iterations),
                perRun(best.assembly_us, case.iterations),
                perRun(best.seam_legalization_us, case.iterations),
                perRun(best.extraction_us, case.iterations),
                perRun(other_us, case.iterations),
            },
        );
        std.debug.print(
            "  decomposition/run: pieces {d:>.1}, diagonals {d:>.1}, max piece {d}, mean piece vertices {d:>.1}, workers {d}; measured critical path {d:>.3} us/run ({d:>.3} us without decomp)\n",
            .{
                avg_pieces,
                avg_diagonals,
                best.dd_max_piece_vertices,
                mean_piece_vertices,
                best.piece_bw_threads,
                critical_path,
                critical_path_without_decomp,
            },
        );
        std.debug.print(
            "  seam legalization/run: tests {d:>.1}, flips {d:>.1}\n",
            .{
                @as(f64, @floatFromInt(best.seam_legalization_tests)) / @as(f64, @floatFromInt(case.iterations)),
                @as(f64, @floatFromInt(best.seam_edge_flips)) / @as(f64, @floatFromInt(case.iterations)),
            },
        );
        printDecompositionDiagnostics(best, case.iterations);
    } else if (build_options.trapezoid_dd_mode) {
        const avg_pieces = @as(f64, @floatFromInt(best.dd_pieces)) / @as(f64, @floatFromInt(case.iterations));
        const avg_diagonals = @as(f64, @floatFromInt(best.dd_diagonals)) / @as(f64, @floatFromInt(case.iterations));
        const mean_piece_vertices = @as(f64, @floatFromInt(best.dd_total_piece_vertices)) / @max(@as(f64, @floatFromInt(best.dd_pieces)), 1.0);
        const estimated_four_core = perRun(best.decomposition_us, case.iterations) +
            (perRun(best.seed_us + best.local_legalization_us, case.iterations) / 4.0) +
            perRun(best.seam_legalization_us, case.iterations);
        std.debug.print(
            "  phase best/run: decomposition {d:>.3} us, piece seed {d:>.3} us, local legalize {d:>.3} us, seam legalize {d:>.3} us, extraction {d:>.3} us, setup+other {d:>.3} us\n",
            .{
                perRun(best.decomposition_us, case.iterations),
                perRun(best.seed_us, case.iterations),
                perRun(best.local_legalization_us, case.iterations),
                perRun(best.seam_legalization_us, case.iterations),
                perRun(best.extraction_us, case.iterations),
                perRun(other_us, case.iterations),
            },
        );
        std.debug.print(
            "  decomposition/run: pieces {d:>.1}, diagonals {d:>.1}, max piece {d}, mean piece vertices {d:>.1}; est 4-core critical path {d:>.3} us/run\n",
            .{
                avg_pieces,
                avg_diagonals,
                best.dd_max_piece_vertices,
                mean_piece_vertices,
                estimated_four_core,
            },
        );
        std.debug.print(
            "  dd legalization/run: local tests {d:>.1}, flips {d:>.1}; seam tests {d:>.1}, flips {d:>.1}\n",
            .{
                @as(f64, @floatFromInt(best.local_legalization_tests)) / @as(f64, @floatFromInt(case.iterations)),
                @as(f64, @floatFromInt(best.local_edge_flips)) / @as(f64, @floatFromInt(case.iterations)),
                @as(f64, @floatFromInt(best.seam_legalization_tests)) / @as(f64, @floatFromInt(case.iterations)),
                @as(f64, @floatFromInt(best.seam_edge_flips)) / @as(f64, @floatFromInt(case.iterations)),
            },
        );
        printDecompositionDiagnostics(best, case.iterations);
    } else if (build_options.polygon_seed_mode) {
        std.debug.print(
            "  phase best/run: polygon seed {d:>.3} us, legalization {d:>.3} us, extraction {d:>.3} us, setup+other {d:>.3} us\n",
            .{
                perRun(best.seed_us, case.iterations),
                perRun(best.legalization_us, case.iterations),
                perRun(best.extraction_us, case.iterations),
                perRun(other_us, case.iterations),
            },
        );
    } else if (build_options.polygon_output_mode) {
        std.debug.print(
            "  phase best/run: insertion {d:>.3} us, constraints {d:>.3} us, polygon cull {d:>.3} us, extraction {d:>.3} us, setup+other {d:>.3} us\n",
            .{
                perRun(best.insertion_us, case.iterations),
                perRun(best.constraint_us, case.iterations),
                perRun(best.cull_us, case.iterations),
                perRun(best.extraction_us, case.iterations),
                perRun(other_us, case.iterations),
            },
        );
    } else {
        std.debug.print(
            "  phase best/run: insertion {d:>.3} us, constraints {d:>.3} us, extraction {d:>.3} us, setup+other {d:>.3} us\n",
            .{
                perRun(best.insertion_us, case.iterations),
                perRun(best.constraint_us, case.iterations),
                perRun(best.extraction_us, case.iterations),
                perRun(other_us, case.iterations),
            },
        );
    }
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
            "  insertion detail: hint hits {d:>.1}, misses {d:>.1}, max walk {d}, max cavity {d} tris/{d} edges; circle reject/fallback {d:>.1}/{d:>.1}\n",
            .{
                @as(f64, @floatFromInt(best.engine_stats.walk_hint_hits)) / iterations_f64,
                @as(f64, @floatFromInt(best.engine_stats.walk_hint_misses)) / iterations_f64,
                best.engine_stats.walk_max_steps,
                best.engine_stats.cavity_max_triangles,
                best.engine_stats.cavity_max_edges,
                @as(f64, @floatFromInt(best.engine_stats.circumcircle_filter_rejects)) / iterations_f64,
                @as(f64, @floatFromInt(best.engine_stats.circumcircle_filter_fallbacks)) / iterations_f64,
            },
        );
        std.debug.print(
            "  topology/insert: cavity tris {d:>.2}, cavity edges {d:>.2}; legalization/run: tests {d:>.1}, flips {d:>.1}; corridor tris/trace {d:>.2}, max {d}\n",
            .{
                @as(f64, @floatFromInt(best.engine_stats.cavity_triangles)) / inserted_f64,
                @as(f64, @floatFromInt(best.engine_stats.cavity_edges)) / inserted_f64,
                @as(f64, @floatFromInt(best.engine_stats.legalization_tests)) / iterations_f64,
                @as(f64, @floatFromInt(best.engine_stats.edge_flips)) / iterations_f64,
                @as(f64, @floatFromInt(best.engine_stats.corridor_triangles)) / traces_f64,
                best.engine_stats.corridor_max_triangles,
            },
        );
        if (best.engine_stats.local_cavity_attempts != 0 or best.engine_stats.corridor_augmented_traces != 0) {
            std.debug.print(
                "  corridor/local: augmented/run {d:>.1}, augmented tris/aug {d:>.2}; local attempts {d:>.1}, successes {d:>.1}, fallbacks {d:>.1}\n",
                .{
                    @as(f64, @floatFromInt(best.engine_stats.corridor_augmented_traces)) / iterations_f64,
                    @as(f64, @floatFromInt(best.engine_stats.corridor_augmented_triangles)) / @max(@as(f64, @floatFromInt(best.engine_stats.corridor_augmented_traces)), 1.0),
                    @as(f64, @floatFromInt(best.engine_stats.local_cavity_attempts)) / iterations_f64,
                    @as(f64, @floatFromInt(best.engine_stats.local_cavity_successes)) / iterations_f64,
                    @as(f64, @floatFromInt(best.engine_stats.local_cavity_invalid_fallbacks + best.engine_stats.local_cavity_nondelaunay_fallbacks + best.engine_stats.local_cavity_repeated_fallbacks)) / iterations_f64,
                },
            );
        }
        std.debug.print(
            "  edge lookup/run: global calls {d:>.1}, scanned tris {d:>.1}; fast calls {d:>.1}, fallbacks {d:>.1}\n",
            .{
                @as(f64, @floatFromInt(best.engine_stats.find_live_edge_calls)) / iterations_f64,
                @as(f64, @floatFromInt(best.engine_stats.find_live_edge_scan_tris)) / iterations_f64,
                @as(f64, @floatFromInt(best.engine_stats.find_live_edge_fast_calls)) / iterations_f64,
                @as(f64, @floatFromInt(best.engine_stats.find_live_edge_fast_fallbacks)) / iterations_f64,
            },
        );
        if (best.engine_stats.polygon_culled_triangles != 0) {
            std.debug.print(
                "  polygon output/run: culled tris {d:>.1}, detached adjacencies {d:>.1}\n",
                .{
                    @as(f64, @floatFromInt(best.engine_stats.polygon_culled_triangles)) / iterations_f64,
                    @as(f64, @floatFromInt(best.engine_stats.polygon_culled_adjacencies)) / iterations_f64,
                },
            );
        }
    }
}

fn benchCase(io: Io, allocator: std.mem.Allocator, case: Case, order: Order) !void {
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
        timings[round] = try runRound(io, allocator, &engine, &arena, &corridor, mesh_ids, case, order);
    }

    std.mem.sortUnstable(RoundTiming, &timings, {}, lessTotal);
    printCase(case, order, timings[0], timings[rounds / 2]);

    if (partitionedBwMode()) {
        for (0..case.vertices.len) |i| {
            mesh_ids[i] = @intCast(i);
        }
        try engine.validateTopology();
        try engine.validateConstraintRingFlags(mesh_ids);
        try engine.validateCdtLegality();
    }

    var interior: std.ArrayListUnmanaged(bool) = .empty;
    defer interior.deinit(allocator);
    if (build_options.polygon_seed_mode or build_options.trapezoid_dd_mode or partitionedBwMode()) {
        interior.clearRetainingCapacity();
        try interior.ensureTotalCapacity(allocator, engine.mesh.triangles.len);
        for (0..engine.mesh.triangles.len) |tri_idx| {
            const tri = engine.mesh.triangles.get(tri_idx);
            interior.appendAssumeCapacity(!mesh.isDeadTriangle(tri));
        }
    } else {
        const diagnostic_stats = try runCavityRelevanceDiagnostic(allocator, &engine, &arena, &corridor, mesh_ids, case, order, &interior);
        printCavityRelevance(case, order, diagnostic_stats);
    }

    var stats = quality.QualityStats{};
    for (0..engine.mesh.triangles.len) |i| {
        if (i >= interior.items.len or !interior.items[i]) continue;
        const tri = engine.mesh.triangles.get(i);

        stats.accumulate(
            engine.getVertex(tri.v0),
            engine.getVertex(tri.v1),
            engine.getVertex(tri.v2),
        );
    }
    stats.finalize();
    stats.print(case.name);
}

fn runCavityRelevanceDiagnostic(
    allocator: std.mem.Allocator,
    engine: *triangulate.Engine,
    arena: *mesh.ThreadArena,
    corridor: *corridor_module.Corridor,
    mesh_ids: []i32,
    case: Case,
    order: Order,
    interior: *std.ArrayListUnmanaged(bool),
) !triangulate.EngineStats {
    engine.resetRetainingCapacity();
    arena.resetRetainingCapacity();
    engine.resetStats();
    engine.beginCavityRelevanceDiagnostics();
    defer engine.endCavityRelevanceDiagnostics();

    try engine.initSuperTriangle(case.vertices);
    for (order.indices) |idx| {
        mesh_ids[idx] = try engine.insertUniquePointTrusted(arena, case.vertices[idx]);
    }

    for (0..case.vertices.len) |i| {
        const start_idx = mesh_ids[i];
        const end_idx = mesh_ids[(i + 1) % case.vertices.len];
        try corridor.recoverConstraintTrusted(allocator, engine, arena, start_idx, end_idx);
    }

    _ = try engine.markInteriorTriangles(allocator, interior);
    engine.classifyCavityRelevanceDiagnostics(interior.items);
    return engine.statsSnapshot();
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

    if (build_options.partitioned_bw_parallel_mode) {
        std.debug.print("Cleave larger single-mesh benchmark (ReleaseFast, parallel partitioned Bowyer-Watson prototype)\n", .{});
    } else if (build_options.partitioned_bw_mode) {
        std.debug.print("Cleave larger single-mesh benchmark (ReleaseFast, partitioned Bowyer-Watson prototype)\n", .{});
    } else if (build_options.trapezoid_dd_mode) {
        std.debug.print("Cleave larger single-mesh benchmark (ReleaseFast, trapezoid domain-decomposition prototype)\n", .{});
    } else if (build_options.polygon_seed_mode) {
        std.debug.print("Cleave larger single-mesh benchmark (ReleaseFast, polygon-seed prototype)\n", .{});
    } else if (build_options.polygon_output_mode) {
        std.debug.print("Cleave larger single-mesh benchmark (ReleaseFast, polygon-output cull prototype)\n", .{});
    } else {
        std.debug.print("Cleave larger single-mesh benchmark (ReleaseFast, validation skipped)\n", .{});
    }
    for (cases) |case| {
        if (build_options.partitioned_bw_parallel_mode) {
            try benchCase(init.io, allocator, case, .{ .name = "partitioned-bw-parallel", .indices = case.morton_indices });
        } else if (build_options.partitioned_bw_mode) {
            try benchCase(init.io, allocator, case, .{ .name = "partitioned-bw", .indices = case.morton_indices });
        } else if (build_options.trapezoid_dd_mode) {
            try benchCase(init.io, allocator, case, .{ .name = "trapezoid-dd", .indices = case.morton_indices });
        } else if (build_options.polygon_seed_mode) {
            try benchCase(init.io, allocator, case, .{ .name = "seed", .indices = case.morton_indices });
        } else {
            try benchCase(init.io, allocator, case, .{ .name = "morton", .indices = case.morton_indices });
            try benchCase(init.io, allocator, case, .{ .name = "brio-morton", .indices = case.brio_indices });
        }
    }
}
