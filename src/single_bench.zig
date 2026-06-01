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
    hilbert_indices: []const usize,
    brio_hilbert_indices: []const usize,
    morton_order_us: u64,
    brio_order_us: u64,
    hilbert_order_us: u64,
    brio_hilbert_order_us: u64,
    iterations: usize,
};

const Order = struct {
    name: []const u8,
    indices: []const usize,
};

const bench_brio_seed = 0xC1EAFEED;

fn brioParallelMode() bool {
    return build_options.brio_parallel_mode;
}

fn brioPlanWindow() usize {
    return build_options.brio_plan_window;
}

fn lfqtDiagnosticMode() bool {
    return build_options.lfqt_diagnostic_mode;
}

fn lfqtBinVertices() usize {
    return @max(@as(usize, 1), build_options.lfqt_bin_vertices);
}

fn decompositionMaxPieceVertices() usize {
    return @max(@as(usize, 3), build_options.decomposition_max_piece_vertices);
}

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
    piece_dispatch_us: u64 = 0,
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
    brio_parallel_threads: usize = 0,
    brio_parallel_buckets: usize = 0,
    brio_parallel_windows: usize = 0,
    brio_parallel_inserted: usize = 0,
    brio_parallel_lock_wait_us: u64 = 0,
    brio_parallel_lock_hold_us: u64 = 0,
    brio_parallel_dispatch_us: u64 = 0,
    brio_parallel_plan_us: u64 = 0,
    brio_parallel_commit_us: u64 = 0,
    brio_parallel_planned: usize = 0,
    brio_parallel_committed: usize = 0,
    brio_parallel_invalidated: usize = 0,
    brio_parallel_serial_fallbacks: usize = 0,
    predicate_stats: predicates.PredicateStats = .{},
    engine_stats: triangulate.EngineStats = .{},
};

fn pcdtMode() bool {
    return build_options.partitioned_cdt_mode or build_options.partitioned_cdt_parallel_mode;
}

fn pcdtParallelMode() bool {
    return build_options.partitioned_cdt_parallel_mode;
}

fn pcdtPieceOrderName() []const u8 {
    return switch (build_options.partitioned_cdt_piece_order) {
        .brio => "brio",
        .morton => "morton",
        .ring => "ring",
    };
}

const BrioParallelStats = struct {
    threads: usize = 1,
    buckets: usize = 0,
    windows: usize = 0,
    inserted: usize = 0,
    lock_wait_us: u64 = 0,
    lock_hold_us: u64 = 0,
    dispatch_us: u64 = 0,
    plan_us: u64 = 0,
    commit_us: u64 = 0,
    planned: usize = 0,
    committed: usize = 0,
    invalidated: usize = 0,
    serial_fallbacks: usize = 0,
};

const BrioWorkerStats = struct {
    planned: usize = 0,
    plan_errors: usize = 0,
};

const BrioWorkerContext = struct {
    executor: *BrioParallelExecutor,
    index: usize,
    arena: mesh.ThreadArena = .{},
    stats: BrioWorkerStats = .{},
};

fn brioConfiguredWorkerCount() !usize {
    const requested = build_options.brio_threads;
    const detected = if (requested == 0) try std.Thread.getCpuCount() else requested;
    return @max(@as(usize, 1), detected);
}

fn brioExecutorWorkerMain(context: *BrioWorkerContext) void {
    context.executor.workerLoop(context);
}

const BrioParallelExecutor = struct {
    io: Io = undefined,
    allocator: std.mem.Allocator = undefined,
    thread_count: usize = 0,
    threads: []std.Thread = &.{},
    contexts: []BrioWorkerContext = &.{},
    mutex: Io.Mutex = .init,
    ready: Io.Condition = .init,
    done: Io.Condition = .init,
    shutdown: bool = false,
    generation: usize = 0,
    active_workers: usize = 0,
    pending_workers: usize = 0,
    start_order_pos: usize = 0,
    end_order_pos: usize = 0,
    engine: *triangulate.Engine = undefined,
    vertices: []const mesh.Vertex = &.{},
    order: []const usize = &.{},
    plans: []triangulate.InsertionPlan = &.{},

    fn init(self: *BrioParallelExecutor, io: Io, allocator: std.mem.Allocator, thread_count: usize) !void {
        self.* = .{
            .io = io,
            .allocator = allocator,
            .thread_count = thread_count,
        };
        self.threads = try allocator.alloc(std.Thread, thread_count);
        errdefer {
            allocator.free(self.threads);
            self.threads = &.{};
        }
        self.contexts = try allocator.alloc(BrioWorkerContext, thread_count);
        errdefer {
            for (self.contexts) |*context| context.arena.deinit(allocator);
            allocator.free(self.contexts);
            self.contexts = &.{};
        }

        var started_threads: usize = 0;
        for (0..thread_count) |i| {
            self.contexts[i] = .{
                .executor = self,
                .index = i,
            };
            self.threads[i] = std.Thread.spawn(.{}, brioExecutorWorkerMain, .{&self.contexts[i]}) catch |err| {
                self.requestShutdown();
                for (self.threads[0..started_threads]) |thread| thread.join();
                return err;
            };
            started_threads += 1;
        }
    }

    fn deinit(self: *BrioParallelExecutor) void {
        if (self.threads.len == 0) return;
        self.requestShutdown();
        for (self.threads) |thread| thread.join();
        for (self.contexts) |*context| context.arena.deinit(self.allocator);
        self.allocator.free(self.contexts);
        self.allocator.free(self.threads);
        self.* = .{};
    }

    fn requestShutdown(self: *BrioParallelExecutor) void {
        self.mutex.lockUncancelable(self.io);
        self.shutdown = true;
        self.generation +%= 1;
        self.ready.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    fn runBucket(
        self: *BrioParallelExecutor,
        engine: *triangulate.Engine,
        arena: *mesh.ThreadArena,
        vertices: []const mesh.Vertex,
        order: []const usize,
        mesh_ids: []i32,
        start_order_pos: usize,
        end_order_pos: usize,
    ) !BrioParallelStats {
        const item_count = end_order_pos - start_order_pos;
        if (item_count == 0) return .{};

        const configured_window = brioPlanWindow();
        const window_size = if (configured_window == 0) item_count else @max(@as(usize, 1), configured_window);

        var stats = BrioParallelStats{ .buckets = 1 };
        var window_start = start_order_pos;
        while (window_start < end_order_pos) {
            const window_end = @min(end_order_pos, window_start + window_size);
            const window_stats = try self.runWindow(engine, arena, vertices, order, mesh_ids, window_start, window_end);
            stats.threads = @max(stats.threads, window_stats.threads);
            stats.windows += window_stats.windows;
            stats.inserted += window_stats.inserted;
            stats.lock_wait_us += window_stats.lock_wait_us;
            stats.lock_hold_us += window_stats.lock_hold_us;
            stats.dispatch_us += window_stats.dispatch_us;
            stats.plan_us += window_stats.plan_us;
            stats.commit_us += window_stats.commit_us;
            stats.planned += window_stats.planned;
            stats.committed += window_stats.committed;
            stats.invalidated += window_stats.invalidated;
            stats.serial_fallbacks += window_stats.serial_fallbacks;
            window_start = window_end;
        }
        return stats;
    }

    fn runWindow(
        self: *BrioParallelExecutor,
        engine: *triangulate.Engine,
        arena: *mesh.ThreadArena,
        vertices: []const mesh.Vertex,
        order: []const usize,
        mesh_ids: []i32,
        start_order_pos: usize,
        end_order_pos: usize,
    ) !BrioParallelStats {
        const item_count = end_order_pos - start_order_pos;
        if (item_count == 0) return .{};
        const active_workers = @min(self.thread_count, item_count);
        if (active_workers <= 1) {
            var stats = BrioParallelStats{ .threads = 1, .windows = 1 };
            for (order[start_order_pos..end_order_pos]) |vertex_idx| {
                mesh_ids[vertex_idx] = try engine.insertUniquePointTrusted(arena, vertices[vertex_idx]);
                stats.inserted += 1;
                stats.serial_fallbacks += 1;
            }
            return stats;
        }

        const plans = try self.allocator.alloc(triangulate.InsertionPlan, item_count);
        defer self.allocator.free(plans);
        for (plans) |*plan| plan.* = .{};

        for (self.contexts) |*context| context.stats = .{};
        const dispatch_start = timer.now(self.io);
        self.mutex.lockUncancelable(self.io);
        self.engine = engine;
        self.vertices = vertices;
        self.order = order;
        self.plans = plans;
        self.start_order_pos = start_order_pos;
        self.end_order_pos = end_order_pos;
        self.active_workers = active_workers;
        self.pending_workers = active_workers;
        self.generation +%= 1;
        self.ready.broadcast(self.io);
        while (self.pending_workers != 0) {
            self.done.waitUncancelable(self.io, &self.mutex);
        }
        self.vertices = &.{};
        self.order = &.{};
        self.plans = &.{};
        self.mutex.unlock(self.io);
        const plan_us = timer.elapsedMicros(dispatch_start, timer.now(self.io));

        var stats = BrioParallelStats{
            .threads = active_workers,
            .windows = 1,
            .dispatch_us = plan_us,
            .plan_us = plan_us,
        };
        for (self.contexts[0..active_workers]) |context| {
            stats.planned += context.stats.planned;
            stats.invalidated += context.stats.plan_errors;
        }

        const commit_start = timer.now(self.io);
        var serial_remainder = false;
        for (plans, 0..) |*plan, plan_i| {
            const vertex_idx = order[start_order_pos + plan_i];
            const planned_insert = if (!serial_remainder)
                try engine.commitInsertionPlan(self.allocator, arena, vertices[vertex_idx], plan)
            else
                null;
            if (planned_insert) |inserted| {
                mesh_ids[vertex_idx] = inserted;
                stats.inserted += 1;
                stats.committed += 1;
            } else {
                if (plan.err == null) stats.invalidated += 1;
                serial_remainder = true;
                mesh_ids[vertex_idx] = try engine.insertUniquePointTrusted(arena, vertices[vertex_idx]);
                stats.inserted += 1;
                stats.serial_fallbacks += 1;
            }
        }
        stats.commit_us = timer.elapsedMicros(commit_start, timer.now(self.io));
        return stats;
    }

    fn workerLoop(self: *BrioParallelExecutor, context: *BrioWorkerContext) void {
        var seen_generation: usize = 0;
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (!self.shutdown and self.generation == seen_generation) {
                self.ready.waitUncancelable(self.io, &self.mutex);
            }
            if (self.shutdown) {
                self.mutex.unlock(self.io);
                return;
            }
            seen_generation = self.generation;
            if (context.index >= self.active_workers) {
                self.mutex.unlock(self.io);
                continue;
            }

            const bucket_len = self.end_order_pos - self.start_order_pos;
            const local_start = self.start_order_pos + (bucket_len * context.index) / self.active_workers;
            const local_end = self.start_order_pos + (bucket_len * (context.index + 1)) / self.active_workers;
            const order = self.order;
            const vertices = self.vertices;
            const plans = self.plans;
            self.mutex.unlock(self.io);

            if (local_start < local_end) {
                const plan_allocator = context.arena.resetScratch(self.allocator);
                for (local_start..local_end) |order_pos| {
                    const vertex_idx = order[order_pos];
                    const plan_index = order_pos - self.start_order_pos;
                    var plan = &plans[plan_index];
                    self.engine.buildInsertionPlan(plan_allocator, vertices[vertex_idx], plan) catch |err| {
                        plan.err = err;
                        context.stats.plan_errors += 1;
                    };
                    context.stats.planned += 1;
                }
            }

            self.mutex.lockUncancelable(self.io);
            self.pending_workers -= 1;
            if (self.pending_workers == 0) self.done.signal(self.io);
            self.mutex.unlock(self.io);
        }
    }
};

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
    dispatch_us: u64 = 0,
    merge_us: u64 = 0,
    threads: usize = 1,
};

const LfqtBin = struct {
    start: usize,
    len: usize,
    depth: usize,
};

const LfqtBuildStats = struct {
    sort_us: u64 = 0,
    split_us: u64 = 0,
    local_serial_us: u64 = 0,
    local_max_us: u64 = 0,
    est_2_us: u64 = 0,
    est_4_us: u64 = 0,
    est_8_us: u64 = 0,
    bins: usize = 0,
    max_bin_vertices: usize = 0,
    total_bin_vertices: usize = 0,
    max_depth: usize = 0,
};

const PcdtWorkerContext = struct {
    executor: *PcdtExecutor,
    index: usize,
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

fn collectSegmentSeedTriangles(
    allocator: std.mem.Allocator,
    engine: *triangulate.Engine,
    segments: []const polygon_seed.Segment,
    seed_triangles: *std.ArrayListUnmanaged(i32),
) !void {
    for (segments) |segment| {
        const found = engine.findLiveEdge(segment.a, segment.b) orelse return error.MissingConstraintEdge;
        try seed_triangles.append(allocator, found.tri);
        if (found.neighbor != -1) try seed_triangles.append(allocator, found.neighbor);
    }
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

    const piece_mesh_ids = try allocator.alloc(i32, ring.len);
    defer allocator.free(piece_mesh_ids);
    switch (build_options.partitioned_cdt_piece_order) {
        .brio, .morton => {
            const local_order = switch (build_options.partitioned_cdt_piece_order) {
                .brio => try spatial.sortVerticesByBrioMorton(allocator, piece_vertices, 0x51EEDB0B),
                .morton => try spatial.sortVerticesByMorton(allocator, piece_vertices),
                .ring => unreachable,
            };
            defer allocator.free(local_order);
            for (local_order) |local_idx| {
                piece_mesh_ids[local_idx] = try local_engine.insertUniquePointTrusted(&local_arena, piece_vertices[local_idx]);
            }
        },
        .ring => {
            for (piece_vertices, 0..) |vertex, local_idx| {
                piece_mesh_ids[local_idx] = try local_engine.insertUniquePointTrusted(&local_arena, vertex);
            }
        },
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

fn pcdtConfiguredWorkerCount() !usize {
    const requested = build_options.partitioned_cdt_threads;
    const detected = if (requested == 0) try std.Thread.getCpuCount() else requested;
    return @max(@as(usize, 1), detected);
}

fn pcdtExecutorWorkerMain(context: *PcdtWorkerContext) void {
    context.executor.workerLoop(context.index);
}

const PcdtExecutor = struct {
    io: Io = undefined,
    allocator: std.mem.Allocator = undefined,
    thread_count: usize = 0,
    threads: []std.Thread = &.{},
    contexts: []PcdtWorkerContext = &.{},
    mutex: Io.Mutex = .init,
    ready: Io.Condition = .init,
    done: Io.Condition = .init,
    shutdown: bool = false,
    generation: usize = 0,
    active_workers: usize = 0,
    pending_workers: usize = 0,
    next_piece: usize = 0,
    vertices: []const mesh.Vertex = &.{},
    rings: []const i32 = &.{},
    pieces: []const trapezoid_dd.Piece = &.{},
    results: []PieceBuildResult = &.{},

    fn init(self: *PcdtExecutor, io: Io, allocator: std.mem.Allocator, thread_count: usize) !void {
        self.* = .{
            .io = io,
            .allocator = allocator,
            .thread_count = thread_count,
        };
        self.threads = try allocator.alloc(std.Thread, thread_count);
        errdefer {
            allocator.free(self.threads);
            self.threads = &.{};
        }
        self.contexts = try allocator.alloc(PcdtWorkerContext, thread_count);
        errdefer {
            allocator.free(self.contexts);
            self.contexts = &.{};
        }

        var started_threads: usize = 0;
        for (0..thread_count) |i| {
            self.contexts[i] = .{
                .executor = self,
                .index = i,
            };
            self.threads[i] = std.Thread.spawn(.{}, pcdtExecutorWorkerMain, .{&self.contexts[i]}) catch |err| {
                self.requestShutdown();
                for (self.threads[0..started_threads]) |thread| thread.join();
                return err;
            };
            started_threads += 1;
        }
    }

    fn deinit(self: *PcdtExecutor) void {
        if (self.threads.len == 0) return;
        self.requestShutdown();
        for (self.threads) |thread| thread.join();
        self.allocator.free(self.contexts);
        self.allocator.free(self.threads);
        self.* = .{};
    }

    fn requestShutdown(self: *PcdtExecutor) void {
        self.mutex.lockUncancelable(self.io);
        self.shutdown = true;
        self.generation +%= 1;
        self.ready.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    fn run(
        self: *PcdtExecutor,
        vertices: []const mesh.Vertex,
        rings: []const i32,
        pieces: []const trapezoid_dd.Piece,
        results: []PieceBuildResult,
    ) !PieceBuildStats {
        const piece_count = pieces.len;
        const active_workers = @min(self.thread_count, piece_count);
        if (active_workers <= 1) return error.SerialPcdtRequired;

        const wall_start = timer.now(self.io);
        self.mutex.lockUncancelable(self.io);
        self.vertices = vertices;
        self.rings = rings;
        self.pieces = pieces;
        self.results = results;
        self.next_piece = 0;
        self.active_workers = active_workers;
        self.pending_workers = active_workers;
        self.generation +%= 1;
        self.ready.broadcast(self.io);
        while (self.pending_workers != 0) {
            self.done.waitUncancelable(self.io, &self.mutex);
        }
        self.vertices = &.{};
        self.rings = &.{};
        self.pieces = &.{};
        self.results = &.{};
        self.mutex.unlock(self.io);

        return .{
            .wall_us = timer.elapsedMicros(wall_start, timer.now(self.io)),
            .threads = active_workers,
        };
    }

    fn workerLoop(self: *PcdtExecutor, worker_index: usize) void {
        var seen_generation: usize = 0;
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (!self.shutdown and self.generation == seen_generation) {
                self.ready.waitUncancelable(self.io, &self.mutex);
            }
            if (self.shutdown) {
                self.mutex.unlock(self.io);
                return;
            }
            seen_generation = self.generation;
            if (worker_index >= self.active_workers) {
                self.mutex.unlock(self.io);
                continue;
            }

            while (true) {
                if (self.next_piece >= self.pieces.len) {
                    self.pending_workers -= 1;
                    if (self.pending_workers == 0) self.done.signal(self.io);
                    self.mutex.unlock(self.io);
                    break;
                }

                const piece_idx = self.next_piece;
                self.next_piece += 1;
                const piece = self.pieces[piece_idx];
                const ring = self.rings[piece.start .. piece.start + piece.len];
                const vertices = self.vertices;
                const results = self.results;
                self.mutex.unlock(self.io);

                results[piece_idx] = buildPieceBowyerWatsonResult(self.io, vertices, ring);

                self.mutex.lockUncancelable(self.io);
            }
        }
    }
};

fn appendPcdtPiecesSerial(
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

fn appendPcdtPiecesParallel(
    allocator: std.mem.Allocator,
    vertices: []const mesh.Vertex,
    decomposition: *const trapezoid_dd.Decomposition,
    out_indices: *std.ArrayListUnmanaged(i32),
    executor: *PcdtExecutor,
) !PieceBuildStats {
    const piece_count = decomposition.pieces.items.len;
    if (piece_count <= 1 or executor.thread_count <= 1) {
        return appendPcdtPiecesSerial(executor.io, allocator, vertices, decomposition, out_indices);
    }

    const results = try allocator.alloc(PieceBuildResult, piece_count);
    defer allocator.free(results);
    for (results) |*result| result.* = .{};
    defer for (results) |*result| result.deinit();

    var stats = try executor.run(vertices, decomposition.rings.items, decomposition.pieces.items, results);
    for (results) |result| {
        if (result.err) |err| return err;
        stats.serial_us += result.elapsed_us;
        stats.max_us = @max(stats.max_us, result.elapsed_us);
    }
    stats.dispatch_us = if (stats.wall_us > stats.max_us) stats.wall_us - stats.max_us else 0;

    const merge_start = timer.now(executor.io);
    for (results) |result| {
        try out_indices.appendSlice(allocator, result.indices);
    }
    stats.merge_us = timer.elapsedMicros(merge_start, timer.now(executor.io));
    return stats;
}

fn appendLfqtBins(
    allocator: std.mem.Allocator,
    codes: []const u128,
    start: usize,
    end: usize,
    target_bin_vertices: usize,
    depth: usize,
    bins: *std.ArrayListUnmanaged(LfqtBin),
    stats: *LfqtBuildStats,
) !void {
    const len = end - start;
    if (len == 0) return;
    if (len <= target_bin_vertices or codes[start] == codes[end - 1]) {
        try bins.append(allocator, .{ .start = start, .len = len, .depth = depth });
        stats.bins += 1;
        stats.total_bin_vertices += len;
        stats.max_bin_vertices = @max(stats.max_bin_vertices, len);
        stats.max_depth = @max(stats.max_depth, depth);
        return;
    }

    const diff = codes[start] ^ codes[end - 1];
    const level: u7 = @intCast(127 - @clz(diff));
    const mask = @as(u128, 1) << level;

    var lo = start + 1;
    var hi = end - 1;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if ((codes[mid] & mask) == 0) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    const split = lo;
    if (split <= start or split >= end) {
        try bins.append(allocator, .{ .start = start, .len = len, .depth = depth });
        stats.bins += 1;
        stats.total_bin_vertices += len;
        stats.max_bin_vertices = @max(stats.max_bin_vertices, len);
        stats.max_depth = @max(stats.max_depth, depth);
        return;
    }

    try appendLfqtBins(allocator, codes, start, split, target_bin_vertices, depth + 1, bins, stats);
    try appendLfqtBins(allocator, codes, split, end, target_bin_vertices, depth + 1, bins, stats);
}

fn runLfqtBin(
    io: Io,
    allocator: std.mem.Allocator,
    vertices: []const mesh.Vertex,
    order: spatial.FloatingMortonOrder,
    bin: LfqtBin,
) !u64 {
    const start = timer.now(io);
    const local_vertices = try allocator.alloc(mesh.Vertex, bin.len);
    defer allocator.free(local_vertices);

    for (local_vertices, 0..) |*vertex, i| {
        vertex.* = vertices[order.indices[bin.start + i]];
    }

    var local_engine = triangulate.Engine.init(allocator);
    defer local_engine.deinit();
    try local_engine.reserveForPointCount(local_vertices.len);
    try local_engine.initSuperTriangle(local_vertices);

    var local_arena = mesh.ThreadArena{};
    defer local_arena.deinit(allocator);
    for (local_vertices) |vertex| {
        _ = try local_engine.insertUniquePointTrusted(&local_arena, vertex);
    }

    return timer.elapsedMicros(start, timer.now(io));
}

fn greaterU64(_: void, a: u64, b: u64) bool {
    return a > b;
}

fn estimateLfqtCriticalPath(allocator: std.mem.Allocator, times: []const u64, worker_count: usize) !u64 {
    if (times.len == 0) return 0;
    const workers = @max(@as(usize, 1), worker_count);
    const sorted = try allocator.dupe(u64, times);
    defer allocator.free(sorted);
    std.mem.sortUnstable(u64, sorted, {}, greaterU64);

    var loads = try allocator.alloc(u64, workers);
    defer allocator.free(loads);
    @memset(loads, 0);

    for (sorted) |elapsed| {
        var min_worker: usize = 0;
        for (loads[1..], 1..) |load, i| {
            if (load < loads[min_worker]) min_worker = i;
        }
        loads[min_worker] += elapsed;
    }

    var max_load: u64 = 0;
    for (loads) |load| max_load = @max(max_load, load);
    return max_load;
}

fn runLfqtDiagnostic(io: Io, allocator: std.mem.Allocator, case: Case) !LfqtBuildStats {
    var stats = LfqtBuildStats{};
    const sort_start = timer.now(io);
    const order = try spatial.sortVerticesByFloatingMorton(allocator, case.vertices);
    defer order.deinit(allocator);
    stats.sort_us = timer.elapsedMicros(sort_start, timer.now(io));

    var bins: std.ArrayListUnmanaged(LfqtBin) = .empty;
    defer bins.deinit(allocator);
    const split_start = timer.now(io);
    try appendLfqtBins(allocator, order.codes, 0, order.codes.len, lfqtBinVertices(), 0, &bins, &stats);
    stats.split_us = timer.elapsedMicros(split_start, timer.now(io));

    const bin_times = try allocator.alloc(u64, bins.items.len);
    defer allocator.free(bin_times);
    for (bins.items, 0..) |bin, i| {
        const elapsed = try runLfqtBin(io, allocator, case.vertices, order, bin);
        bin_times[i] = elapsed;
        stats.local_serial_us += elapsed;
        stats.local_max_us = @max(stats.local_max_us, elapsed);
    }

    stats.est_2_us = stats.sort_us + stats.split_us + try estimateLfqtCriticalPath(allocator, bin_times, 2);
    stats.est_4_us = stats.sort_us + stats.split_us + try estimateLfqtCriticalPath(allocator, bin_times, 4);
    stats.est_8_us = stats.sort_us + stats.split_us + try estimateLfqtCriticalPath(allocator, bin_times, 8);
    return stats;
}

fn printLfqtDiagnostic(case: Case, stats: LfqtBuildStats) void {
    const mean_bin = if (stats.bins == 0)
        0.0
    else
        @as(f64, @floatFromInt(stats.total_bin_vertices)) / @as(f64, @floatFromInt(stats.bins));
    std.debug.print(
        "{s}/lfqt-{d}: {d} vertices, bins {d}, max bin {d}, mean bin {d:>.1}, max depth {d}\n",
        .{
            case.name,
            lfqtBinVertices(),
            case.vertices.len,
            stats.bins,
            stats.max_bin_vertices,
            mean_bin,
            stats.max_depth,
        },
    );
    std.debug.print(
        "  lfqt timing: sort {d} us, split {d} us, local serial {d} us, local max {d} us\n",
        .{ stats.sort_us, stats.split_us, stats.local_serial_us, stats.local_max_us },
    );
    std.debug.print(
        "  lfqt estimated wall: 2 workers {d} us, 4 workers {d} us, 8 workers {d} us\n",
        .{ stats.est_2_us, stats.est_4_us, stats.est_8_us },
    );
}

fn runBrioParallelInsertion(
    executor: *BrioParallelExecutor,
    engine: *triangulate.Engine,
    arena: *mesh.ThreadArena,
    vertices: []const mesh.Vertex,
    order: []const usize,
    mesh_ids: []i32,
) !BrioParallelStats {
    var stats = BrioParallelStats{};
    var start: usize = 0;
    while (start < order.len) {
        const round = spatial.brioRoundForIndex(order[start], bench_brio_seed);
        var end = start + 1;
        while (end < order.len and spatial.brioRoundForIndex(order[end], bench_brio_seed) == round) : (end += 1) {}

        const bucket_stats = try executor.runBucket(engine, arena, vertices, order, mesh_ids, start, end);
        stats.threads = @max(stats.threads, bucket_stats.threads);
        stats.buckets += bucket_stats.buckets;
        stats.windows += bucket_stats.windows;
        stats.inserted += bucket_stats.inserted;
        stats.lock_wait_us += bucket_stats.lock_wait_us;
        stats.lock_hold_us += bucket_stats.lock_hold_us;
        stats.dispatch_us += bucket_stats.dispatch_us;
        stats.plan_us += bucket_stats.plan_us;
        stats.commit_us += bucket_stats.commit_us;
        stats.planned += bucket_stats.planned;
        stats.committed += bucket_stats.committed;
        stats.invalidated += bucket_stats.invalidated;
        stats.serial_fallbacks += bucket_stats.serial_fallbacks;
        start = end;
    }
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

    const morton_start = timer.now(io);
    const morton_indices = try spatial.sortVerticesByMorton(allocator, vertices);
    errdefer allocator.free(morton_indices);
    const morton_end = timer.now(io);

    const brio_start = timer.now(io);
    const brio_indices = try spatial.sortVerticesByBrioMorton(allocator, vertices, bench_brio_seed);
    errdefer allocator.free(brio_indices);
    const brio_end = timer.now(io);

    const hilbert_start = timer.now(io);
    const hilbert_indices = try spatial.sortVerticesByHilbert(allocator, vertices);
    errdefer allocator.free(hilbert_indices);
    const hilbert_end = timer.now(io);

    const brio_hilbert_start = timer.now(io);
    const brio_hilbert_indices = try spatial.sortVerticesByBrioHilbert(allocator, vertices, bench_brio_seed);
    errdefer allocator.free(brio_hilbert_indices);
    const brio_hilbert_end = timer.now(io);

    return .{
        .name = name,
        .vertices = vertices,
        .morton_indices = morton_indices,
        .brio_indices = brio_indices,
        .hilbert_indices = hilbert_indices,
        .brio_hilbert_indices = brio_hilbert_indices,
        .morton_order_us = timer.elapsedMicros(morton_start, morton_end),
        .brio_order_us = timer.elapsedMicros(brio_start, brio_end),
        .hilbert_order_us = timer.elapsedMicros(hilbert_start, hilbert_end),
        .brio_hilbert_order_us = timer.elapsedMicros(brio_hilbert_start, brio_hilbert_end),
        .iterations = iterations,
    };
}

fn deinitCase(allocator: std.mem.Allocator, case: Case) void {
    allocator.free(case.brio_hilbert_indices);
    allocator.free(case.hilbert_indices);
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
    pcdt_executor: ?*PcdtExecutor,
    brio_executor: ?*BrioParallelExecutor,
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
        var piece_dispatch_us: u64 = 0;
        var piece_merge_us: u64 = 0;
        var piece_bw_threads: usize = 0;
        var assembly_start = insertion_start;
        var assembly_end = insertion_start;
        var local_legalization_end = insertion_start;
        var seam_legalization_end = insertion_start;

        if (pcdtMode()) {
            decomposition_start = timer.now(io);
            try trapezoid_dd.decomposeSimple(allocator, case.vertices, decompositionMaxPieceVertices(), &decomposition);
            decomposition_end = timer.now(io);

            seed_indices.clearRetainingCapacity();
            const piece_stats = if (pcdtParallelMode() and pcdt_executor != null)
                try appendPcdtPiecesParallel(allocator, case.vertices, &decomposition, &seed_indices, pcdt_executor.?)
            else
                try appendPcdtPiecesSerial(io, allocator, case.vertices, &decomposition, &seed_indices);
            piece_bw_wall_us = piece_stats.wall_us;
            piece_bw_serial_us = piece_stats.serial_us;
            piece_bw_max_us = piece_stats.max_us;
            piece_dispatch_us = piece_stats.dispatch_us;
            piece_merge_us = piece_stats.merge_us;
            piece_bw_threads = piece_stats.threads;

            assembly_start = timer.now(io);
            try engine.buildPolygonSeedMesh(case.vertices, seed_indices.items);
            assembly_end = timer.now(io);

            seed_triangles.clearRetainingCapacity();
            try collectSegmentSeedTriangles(allocator, engine, decomposition.diagonals.items, &seed_triangles);
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
            try trapezoid_dd.decomposeSimple(allocator, case.vertices, decompositionMaxPieceVertices(), &decomposition);
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
            if (brioParallelMode() and brio_executor != null) {
                const parallel_stats = try runBrioParallelInsertion(brio_executor.?, engine, arena, case.vertices, order.indices, mesh_ids);
                timing.brio_parallel_threads = @max(timing.brio_parallel_threads, parallel_stats.threads);
                timing.brio_parallel_buckets += parallel_stats.buckets;
                timing.brio_parallel_windows += parallel_stats.windows;
                timing.brio_parallel_inserted += parallel_stats.inserted;
                timing.brio_parallel_lock_wait_us += parallel_stats.lock_wait_us;
                timing.brio_parallel_lock_hold_us += parallel_stats.lock_hold_us;
                timing.brio_parallel_dispatch_us += parallel_stats.dispatch_us;
                timing.brio_parallel_plan_us += parallel_stats.plan_us;
                timing.brio_parallel_commit_us += parallel_stats.commit_us;
                timing.brio_parallel_planned += parallel_stats.planned;
                timing.brio_parallel_committed += parallel_stats.committed;
                timing.brio_parallel_invalidated += parallel_stats.invalidated;
                timing.brio_parallel_serial_fallbacks += parallel_stats.serial_fallbacks;
            } else {
                for (order.indices) |idx| {
                    mesh_ids[idx] = try engine.insertUniquePointTrusted(arena, case.vertices[idx]);
                }
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
        if (build_options.polygon_output_mode and !build_options.polygon_seed_mode and !build_options.trapezoid_dd_mode and !pcdtMode()) {
            _ = try engine.cullExteriorTrianglesTrusted();
        }
        const cull_end = timer.now(io);

        const extraction_start = cull_end;
        const interior_triangles = if (build_options.polygon_output_mode or build_options.polygon_seed_mode or build_options.trapezoid_dd_mode or pcdtMode())
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
        timing.piece_dispatch_us += piece_dispatch_us;
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

fn orderBuildMicros(case: Case, order: Order) u64 {
    if (std.mem.eql(u8, order.name, "morton")) return case.morton_order_us;
    if (std.mem.eql(u8, order.name, "brio-morton")) return case.brio_order_us;
    if (std.mem.eql(u8, order.name, "hilbert")) return case.hilbert_order_us;
    if (std.mem.eql(u8, order.name, "brio-hilbert")) return case.brio_hilbert_order_us;
    return 0;
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
    const phase_us = if (pcdtMode())
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
    const order_us = orderBuildMicros(case, order);
    if (order_us > 0) {
        std.debug.print("  order build: {d} us\n", .{order_us});
    }
    if (pcdtMode()) {
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
            "  phase best/run: decomposition {d:>.3} us, piece CDT wall {d:>.3} us, piece CDT serial {d:>.3} us, max piece CDT {d:>.3} us, dispatch/wait {d:>.3} us, piece merge {d:>.3} us, assembly {d:>.3} us, seam legalize {d:>.3} us, extraction {d:>.3} us, setup+other {d:>.3} us\n",
            .{
                perRun(best.decomposition_us, case.iterations),
                perRun(best.piece_bw_us, case.iterations),
                perRun(best.piece_bw_serial_us, case.iterations),
                perRun(best.piece_bw_max_us, case.iterations),
                perRun(best.piece_dispatch_us, case.iterations),
                perRun(best.piece_merge_us, case.iterations),
                perRun(best.assembly_us, case.iterations),
                perRun(best.seam_legalization_us, case.iterations),
                perRun(best.extraction_us, case.iterations),
                perRun(other_us, case.iterations),
            },
        );
        std.debug.print(
            "  decomposition/run: target max {d}, pieces {d:>.1}, diagonals {d:>.1}, max piece {d}, mean piece vertices {d:>.1}, workers {d}, piece order {s}; measured critical path {d:>.3} us/run ({d:>.3} us without decomp)\n",
            .{
                decompositionMaxPieceVertices(),
                avg_pieces,
                avg_diagonals,
                best.dd_max_piece_vertices,
                mean_piece_vertices,
                best.piece_bw_threads,
                pcdtPieceOrderName(),
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
    } else if (brioParallelMode()) {
        const iterations_f64 = @as(f64, @floatFromInt(case.iterations));
        std.debug.print(
            "  phase best/run: parallel insertion {d:>.3} us, constraints {d:>.3} us, extraction {d:>.3} us, setup+other {d:>.3} us\n",
            .{
                perRun(best.insertion_us, case.iterations),
                perRun(best.constraint_us, case.iterations),
                perRun(best.extraction_us, case.iterations),
                perRun(other_us, case.iterations),
            },
        );
        std.debug.print(
            "  brio parallel/run: workers {d}, buckets {d:>.1}, windows {d:>.1}, inserted {d:>.1}, planned {d:>.1}, committed {d:>.1}, invalidated {d:>.1}, serial fallback {d:>.1}, commit rate {d:>.1}%\n",
            .{
                best.brio_parallel_threads,
                @as(f64, @floatFromInt(best.brio_parallel_buckets)) / iterations_f64,
                @as(f64, @floatFromInt(best.brio_parallel_windows)) / iterations_f64,
                @as(f64, @floatFromInt(best.brio_parallel_inserted)) / iterations_f64,
                @as(f64, @floatFromInt(best.brio_parallel_planned)) / iterations_f64,
                @as(f64, @floatFromInt(best.brio_parallel_committed)) / iterations_f64,
                @as(f64, @floatFromInt(best.brio_parallel_invalidated)) / iterations_f64,
                @as(f64, @floatFromInt(best.brio_parallel_serial_fallbacks)) / iterations_f64,
                if (best.brio_parallel_planned == 0) 0.0 else @as(f64, @floatFromInt(best.brio_parallel_committed)) * 100.0 / @as(f64, @floatFromInt(best.brio_parallel_planned)),
            },
        );
        std.debug.print(
            "  brio timing/run: plan {d:>.3} us, commit+fallback {d:>.3} us, old lock wait {d:>.3} us, old lock hold {d:>.3} us\n",
            .{
                perRun(best.brio_parallel_plan_us, case.iterations),
                perRun(best.brio_parallel_commit_us, case.iterations),
                perRun(best.brio_parallel_lock_wait_us, case.iterations),
                perRun(best.brio_parallel_lock_hold_us, case.iterations),
            },
        );
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
            "  decomposition/run: target max {d}, pieces {d:>.1}, diagonals {d:>.1}, max piece {d}, mean piece vertices {d:>.1}; est 4-core critical path {d:>.3} us/run\n",
            .{
                decompositionMaxPieceVertices(),
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
        if (best.engine_stats.transaction_retries != 0 or best.engine_stats.transaction_conflicts != 0) {
            std.debug.print(
                "  transactions/run: retries {d:>.1}, conflicts {d:>.1}\n",
                .{
                    @as(f64, @floatFromInt(best.engine_stats.transaction_retries)) / iterations_f64,
                    @as(f64, @floatFromInt(best.engine_stats.transaction_conflicts)) / iterations_f64,
                },
            );
        }
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

    var pcdt_executor = PcdtExecutor{};
    defer pcdt_executor.deinit();
    var pcdt_executor_ptr: ?*PcdtExecutor = null;
    if (pcdtParallelMode()) {
        try pcdt_executor.init(io, allocator, try pcdtConfiguredWorkerCount());
        pcdt_executor_ptr = &pcdt_executor;
    }

    var brio_executor = BrioParallelExecutor{};
    defer brio_executor.deinit();
    var brio_executor_ptr: ?*BrioParallelExecutor = null;
    if (brioParallelMode()) {
        try brio_executor.init(io, allocator, try brioConfiguredWorkerCount());
        brio_executor_ptr = &brio_executor;
    }

    for (0..rounds) |round| {
        timings[round] = try runRound(io, allocator, &engine, &arena, &corridor, mesh_ids, case, order, pcdt_executor_ptr, brio_executor_ptr);
    }

    std.mem.sortUnstable(RoundTiming, &timings, {}, lessTotal);
    printCase(case, order, timings[0], timings[rounds / 2]);

    if (pcdtMode() or brioParallelMode()) {
        if (pcdtMode()) {
            for (0..case.vertices.len) |i| {
                mesh_ids[i] = @intCast(i);
            }
        }
        try engine.validateTopology();
        try engine.validateConstraintRingFlags(mesh_ids);
        try engine.validateCdtLegality();
    }

    var interior: std.ArrayListUnmanaged(bool) = .empty;
    defer interior.deinit(allocator);
    if (build_options.polygon_seed_mode or build_options.trapezoid_dd_mode or pcdtMode()) {
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

    if (lfqtDiagnosticMode()) {
        std.debug.print("Cleave LFQT diagnostic benchmark (ReleaseFast, no merge)\n", .{});
    } else if (build_options.brio_parallel_mode) {
        std.debug.print("Cleave larger single-mesh benchmark (ReleaseFast, parallel BRIO prototype)\n", .{});
    } else if (build_options.partitioned_cdt_parallel_mode) {
        std.debug.print("Cleave larger single-mesh benchmark (ReleaseFast, parallel PCDT prototype)\n", .{});
    } else if (build_options.partitioned_cdt_mode) {
        std.debug.print("Cleave larger single-mesh benchmark (ReleaseFast, PCDT prototype)\n", .{});
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
        if (lfqtDiagnosticMode()) {
            const stats = try runLfqtDiagnostic(init.io, allocator, case);
            printLfqtDiagnostic(case, stats);
        } else if (build_options.brio_parallel_mode) {
            try benchCase(init.io, allocator, case, .{ .name = "brio-parallel", .indices = case.brio_indices });
        } else if (build_options.partitioned_cdt_parallel_mode) {
            try benchCase(init.io, allocator, case, .{ .name = "pcdt-parallel", .indices = case.morton_indices });
        } else if (build_options.partitioned_cdt_mode) {
            try benchCase(init.io, allocator, case, .{ .name = "pcdt", .indices = case.morton_indices });
        } else if (build_options.trapezoid_dd_mode) {
            try benchCase(init.io, allocator, case, .{ .name = "trapezoid-dd", .indices = case.morton_indices });
        } else if (build_options.polygon_seed_mode) {
            try benchCase(init.io, allocator, case, .{ .name = "seed", .indices = case.morton_indices });
        } else {
            try benchCase(init.io, allocator, case, .{ .name = "morton", .indices = case.morton_indices });
            try benchCase(init.io, allocator, case, .{ .name = "brio-morton", .indices = case.brio_indices });
            try benchCase(init.io, allocator, case, .{ .name = "hilbert", .indices = case.hilbert_indices });
            try benchCase(init.io, allocator, case, .{ .name = "brio-hilbert", .indices = case.brio_hilbert_indices });
        }
    }
}
