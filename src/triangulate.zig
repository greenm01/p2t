const std = @import("std");
const build_options = @import("build_options");
const mesh = @import("mesh.zig");
const spatial = @import("spatial.zig");
const predicates = @import("predicates.zig");

pub const Edge = struct {
    adj_tri: i32,
    v1: i32,
    v2: i32,
    old_tri: i32,
};

const EdgeVertices = struct {
    v1: i32,
    v2: i32,
};

const LegalizeEdge = struct {
    tri: i32,
    side: usize,
};

pub const MutationMode = enum { transactional, trusted };

pub const LiveEdge = struct {
    tri: i32,
    side: usize,
    neighbor: i32 = -1,
    neighbor_side: usize = 0,
};

pub const max_transaction_attempts = 8;

pub fn isRetryableTransactionError(err: anyerror) bool {
    return switch (err) {
        error.TransactionConflict,
        error.TransactionFootprintExpansionRequired,
        => true,
        else => false,
    };
}

pub const TriangleVersionSnapshot = struct {
    tri: i32,
    version: u32,
};

pub const TriangleTransaction = struct {
    locked: std.ArrayListUnmanaged(i32) = .empty,
    versions: std.ArrayListUnmanaged(TriangleVersionSnapshot) = .empty,

    pub fn deinit(self: *TriangleTransaction, allocator: std.mem.Allocator) void {
        self.locked.deinit(allocator);
        self.versions.deinit(allocator);
    }
};

pub const EngineStats = struct {
    walk_calls: u64 = 0,
    walk_steps: u64 = 0,
    walk_fallbacks: u64 = 0,
    walk_fallback_scan_tris: u64 = 0,
    inserted_points: u64 = 0,
    cavity_triangles: u64 = 0,
    cavity_edges: u64 = 0,
    legalization_tests: u64 = 0,
    edge_flips: u64 = 0,
    corridor_traces: u64 = 0,
    corridor_triangles: u64 = 0,
    corridor_max_triangles: u64 = 0,
    corridor_augmented_traces: u64 = 0,
    corridor_augmented_triangles: u64 = 0,
    local_cavity_attempts: u64 = 0,
    local_cavity_successes: u64 = 0,
    local_cavity_invalid_fallbacks: u64 = 0,
    local_cavity_nondelaunay_fallbacks: u64 = 0,
    local_cavity_repeated_fallbacks: u64 = 0,
    find_live_edge_calls: u64 = 0,
    find_live_edge_scan_tris: u64 = 0,
    find_live_edge_fast_calls: u64 = 0,
    find_live_edge_fast_fallbacks: u64 = 0,
    walk_hint_hits: u64 = 0,
    walk_hint_misses: u64 = 0,
    walk_max_steps: u64 = 0,
    cavity_max_triangles: u64 = 0,
    cavity_max_edges: u64 = 0,
    circumcircle_filter_rejects: u64 = 0,
    circumcircle_filter_fallbacks: u64 = 0,

    pub fn any(self: EngineStats) bool {
        return self.walk_calls != 0 or self.inserted_points != 0 or self.corridor_traces != 0 or self.find_live_edge_calls != 0;
    }
};

const CavityEdgeBucket = struct {
    generation: u32 = 0,
    entry_index: i32 = -1,
};

const CavityEdgeEntry = struct {
    next: i32,
    a: i32,
    b: i32,
    count: u8,
    edge: Edge,
};

const CavityEdgeCounter = struct {
    buckets: std.ArrayListUnmanaged(CavityEdgeBucket) = .empty,
    entries: std.ArrayListUnmanaged(CavityEdgeEntry) = .empty,
    generation: u32 = 1,

    fn deinit(self: *CavityEdgeCounter, allocator: std.mem.Allocator) void {
        self.buckets.deinit(allocator);
        self.entries.deinit(allocator);
    }

    fn reset(self: *CavityEdgeCounter, allocator: std.mem.Allocator, max_edges: usize) !void {
        try self.ensureBuckets(allocator, max_edges * 2 + 1);
        self.entries.clearRetainingCapacity();

        self.generation +%= 1;
        if (self.generation == 0) {
            for (self.buckets.items) |*bucket| bucket.generation = 0;
            self.generation = 1;
        }
    }

    fn ensureBuckets(self: *CavityEdgeCounter, allocator: std.mem.Allocator, min_count: usize) !void {
        const target = @max(min_count, 16);
        if (self.buckets.items.len >= target) return;

        self.buckets.clearRetainingCapacity();
        try self.buckets.ensureTotalCapacity(allocator, target);
        while (self.buckets.items.len < target) {
            try self.buckets.append(allocator, .{});
        }
        self.generation = 1;
    }

    fn bucketIndex(self: *const CavityEdgeCounter, a: i32, b: i32) usize {
        const au: u64 = @intCast(a);
        const bu: u64 = @intCast(b);
        const hash = (au *% 0x9E3779B185EBCA87) ^ (bu *% 0xC2B2AE3D27D4EB4F);
        return @intCast(hash % self.buckets.items.len);
    }

    fn add(self: *CavityEdgeCounter, allocator: std.mem.Allocator, edge: Edge) !void {
        const a = @min(edge.v1, edge.v2);
        const b = @max(edge.v1, edge.v2);
        const bucket_index = self.bucketIndex(a, b);
        var bucket = &self.buckets.items[bucket_index];

        if (bucket.generation != self.generation) {
            bucket.generation = self.generation;
            bucket.entry_index = -1;
        } else {
            var entry_index = bucket.entry_index;
            while (entry_index >= 0) {
                const entry_usize: usize = @intCast(entry_index);
                if (self.entries.items[entry_usize].a == a and self.entries.items[entry_usize].b == b) {
                    if (self.entries.items[entry_usize].count == std.math.maxInt(u8)) {
                        return error.NonManifoldCavity;
                    }
                    self.entries.items[entry_usize].count += 1;
                    return;
                }
                entry_index = self.entries.items[entry_usize].next;
            }
        }

        try self.entries.append(allocator, .{
            .next = bucket.entry_index,
            .a = a,
            .b = b,
            .count = 1,
            .edge = edge,
        });
        bucket.entry_index = @as(i32, @intCast(self.entries.items.len - 1));
    }

    fn appendBoundaryTo(self: *const CavityEdgeCounter, allocator: std.mem.Allocator, edges: *std.ArrayListUnmanaged(Edge)) !void {
        edges.clearRetainingCapacity();
        for (self.entries.items) |entry| {
            switch (entry.count) {
                1 => try edges.append(allocator, entry.edge),
                2 => {},
                else => {
                    std.debug.print("NonManifoldCavity: edge ({d},{d}) appears {d} times in cavity\n", .{ entry.a, entry.b, entry.count });
                    return error.NonManifoldCavity;
                },
            }
        }
    }
};

pub const Engine = struct {
    mesh: mesh.GlobalMesh,
    allocator: std.mem.Allocator,
    last_valid_tri: i32,
    cavity_edge_counter: CavityEdgeCounter,
    trusted_cavity: std.ArrayListUnmanaged(i32),
    trusted_edges: std.ArrayListUnmanaged(Edge),
    trusted_new_tri_indices: std.ArrayListUnmanaged(i32),
    boundary_vertex_marks: std.ArrayListUnmanaged(u32),
    boundary_vertex_counts: std.ArrayListUnmanaged(u8),
    boundary_vertex_generation: u32,
    trusted_spoke_marks: std.ArrayListUnmanaged(u32),
    trusted_spoke_tris: std.ArrayListUnmanaged(i32),
    trusted_spoke_sides: std.ArrayListUnmanaged(u8),
    trusted_spoke_generation: u32,
    cavity_triangle_marks: std.ArrayListUnmanaged(u32),
    cavity_triangle_generation: u32,
    interior_triangle_marks: std.ArrayListUnmanaged(u32),
    interior_triangle_queue: std.ArrayListUnmanaged(i32),
    interior_triangle_generation: u32,
    vertex_hint_tri: std.ArrayListUnmanaged(i32),
    hint_grid: std.ArrayListUnmanaged(i32),
    hint_grid_side: usize,
    hint_min_x: f64,
    hint_min_y: f64,
    hint_scale_x: f64,
    hint_scale_y: f64,
    stats: EngineStats,

    pub fn init(allocator: std.mem.Allocator) Engine {
        return .{
            .mesh = mesh.GlobalMesh{},
            .allocator = allocator,
            .last_valid_tri = 0,
            .cavity_edge_counter = .{},
            .trusted_cavity = .empty,
            .trusted_edges = .empty,
            .trusted_new_tri_indices = .empty,
            .boundary_vertex_marks = .empty,
            .boundary_vertex_counts = .empty,
            .boundary_vertex_generation = 1,
            .trusted_spoke_marks = .empty,
            .trusted_spoke_tris = .empty,
            .trusted_spoke_sides = .empty,
            .trusted_spoke_generation = 1,
            .cavity_triangle_marks = .empty,
            .cavity_triangle_generation = 1,
            .interior_triangle_marks = .empty,
            .interior_triangle_queue = .empty,
            .interior_triangle_generation = 1,
            .vertex_hint_tri = .empty,
            .hint_grid = .empty,
            .hint_grid_side = 0,
            .hint_min_x = 0.0,
            .hint_min_y = 0.0,
            .hint_scale_x = 0.0,
            .hint_scale_y = 0.0,
            .stats = .{},
        };
    }

    pub fn deinit(self: *Engine) void {
        self.hint_grid.deinit(self.allocator);
        self.vertex_hint_tri.deinit(self.allocator);
        self.interior_triangle_queue.deinit(self.allocator);
        self.interior_triangle_marks.deinit(self.allocator);
        self.cavity_triangle_marks.deinit(self.allocator);
        self.trusted_spoke_sides.deinit(self.allocator);
        self.trusted_spoke_tris.deinit(self.allocator);
        self.trusted_spoke_marks.deinit(self.allocator);
        self.boundary_vertex_counts.deinit(self.allocator);
        self.boundary_vertex_marks.deinit(self.allocator);
        self.trusted_new_tri_indices.deinit(self.allocator);
        self.trusted_edges.deinit(self.allocator);
        self.trusted_cavity.deinit(self.allocator);
        self.cavity_edge_counter.deinit(self.allocator);
        self.mesh.deinit(self.allocator);
    }

    pub fn resetRetainingCapacity(self: *Engine) void {
        self.mesh.clearRetainingCapacity();
        self.trusted_cavity.clearRetainingCapacity();
        self.trusted_edges.clearRetainingCapacity();
        self.trusted_new_tri_indices.clearRetainingCapacity();
        self.last_valid_tri = 0;
        if (build_options.spatial_hints and self.hint_grid.items.len != 0) @memset(self.hint_grid.items, -1);
    }

    pub inline fn statInc(self: *Engine, comptime field: []const u8) void {
        if (build_options.instrument_mesh_stats) {
            @field(self.stats, field) += 1;
        }
    }

    pub inline fn statAdd(self: *Engine, comptime field: []const u8, value: u64) void {
        if (build_options.instrument_mesh_stats) {
            @field(self.stats, field) += value;
        }
    }

    pub inline fn statMax(self: *Engine, comptime field: []const u8, value: u64) void {
        if (build_options.instrument_mesh_stats and value > @field(self.stats, field)) {
            @field(self.stats, field) = value;
        }
    }

    pub fn resetStats(self: *Engine) void {
        if (build_options.instrument_mesh_stats) {
            self.stats = .{};
        }
    }

    pub fn statsSnapshot(self: *const Engine) EngineStats {
        if (build_options.instrument_mesh_stats) {
            return self.stats;
        }
        return .{};
    }

    pub fn reserveForPointCount(self: *Engine, point_count: usize) !void {
        try self.mesh.reserve(self.allocator, point_count + 3, point_count * 3 + 8);
        try self.ensureVertexMetadataCapacity(point_count + 3);
        try self.trusted_cavity.ensureTotalCapacity(self.allocator, 32);
        try self.trusted_edges.ensureTotalCapacity(self.allocator, 48);
        try self.trusted_new_tri_indices.ensureTotalCapacity(self.allocator, 48);
        try self.cavity_edge_counter.reset(self.allocator, 48);
        if (build_options.spatial_hints) try self.ensureHintGridCapacity(point_count);
    }

    fn hintGridSideForPointCount(point_count: usize) usize {
        var side: usize = 8;
        const target = @max(point_count / 4, 64);
        while (side * side < target and side < 64) : (side *= 2) {}
        return side;
    }

    fn ensureHintGridCapacity(self: *Engine, point_count: usize) !void {
        const side = hintGridSideForPointCount(point_count);
        const count = side * side;
        if (self.hint_grid.items.len == count) {
            self.hint_grid_side = side;
            return;
        }

        self.hint_grid.clearRetainingCapacity();
        try self.hint_grid.ensureTotalCapacity(self.allocator, count);
        while (self.hint_grid.items.len < count) {
            try self.hint_grid.append(self.allocator, -1);
        }
        self.hint_grid_side = side;
    }

    fn resetHintGridForBounds(self: *Engine, bounds: spatial.BoundingBox, point_count: usize) !void {
        if (!build_options.spatial_hints) return;
        try self.ensureHintGridCapacity(point_count);
        @memset(self.hint_grid.items, -1);
        self.hint_min_x = bounds.min_x;
        self.hint_min_y = bounds.min_y;
        const width = bounds.max_x - bounds.min_x;
        const height = bounds.max_y - bounds.min_y;
        const max_cell = if (self.hint_grid_side > 1) @as(f64, @floatFromInt(self.hint_grid_side - 1)) else 0.0;
        self.hint_scale_x = if (width > 0.0) max_cell / width else 0.0;
        self.hint_scale_y = if (height > 0.0) max_cell / height else 0.0;
    }

    fn hintCellUnchecked(self: *const Engine, pt: mesh.Vertex) struct { x: usize, y: usize } {
        if (self.hint_grid_side == 0) return .{ .x = 0, .y = 0 };
        const max_cell = self.hint_grid_side - 1;
        const raw_x = if (self.hint_scale_x > 0.0) @as(isize, @intFromFloat((pt.x - self.hint_min_x) * self.hint_scale_x)) else 0;
        const raw_y = if (self.hint_scale_y > 0.0) @as(isize, @intFromFloat((pt.y - self.hint_min_y) * self.hint_scale_y)) else 0;
        return .{
            .x = @intCast(@min(@max(raw_x, 0), @as(isize, @intCast(max_cell)))),
            .y = @intCast(@min(@max(raw_y, 0), @as(isize, @intCast(max_cell)))),
        };
    }

    fn hintIndex(self: *const Engine, x: usize, y: usize) usize {
        return y * self.hint_grid_side + x;
    }

    fn isValidStartTriangle(self: *const Engine, tri_idx: i32) bool {
        if (tri_idx < 0) return false;
        const slot: usize = @intCast(tri_idx);
        return slot < self.mesh.triangles.len and !mesh.isDeadTriangle(self.mesh.triangles.get(slot));
    }

    fn hintedStartTriangle(self: *Engine, pt: mesh.Vertex) i32 {
        if (!build_options.spatial_hints) return self.last_valid_tri;
        if (self.hint_grid.items.len == 0) {
            self.statInc("walk_hint_misses");
            return self.last_valid_tri;
        }
        const cell = self.hintCellUnchecked(pt);
        const direct = self.hint_grid.items[self.hintIndex(cell.x, cell.y)];
        if (self.isValidStartTriangle(direct)) {
            self.statInc("walk_hint_hits");
            return direct;
        }

        const min_x = if (cell.x == 0) 0 else cell.x - 1;
        const min_y = if (cell.y == 0) 0 else cell.y - 1;
        const max_x = @min(cell.x + 1, self.hint_grid_side - 1);
        const max_y = @min(cell.y + 1, self.hint_grid_side - 1);
        var y = min_y;
        while (y <= max_y) : (y += 1) {
            var x = min_x;
            while (x <= max_x) : (x += 1) {
                const candidate = self.hint_grid.items[self.hintIndex(x, y)];
                if (self.isValidStartTriangle(candidate)) {
                    self.statInc("walk_hint_hits");
                    return candidate;
                }
            }
        }

        self.statInc("walk_hint_misses");
        return self.last_valid_tri;
    }

    fn updateHintForPoint(self: *Engine, pt: mesh.Vertex, tri_idx: i32) void {
        if (!build_options.spatial_hints) return;
        if (self.hint_grid.items.len == 0 or !self.isValidStartTriangle(tri_idx)) return;
        const cell = self.hintCellUnchecked(pt);
        const min_x = if (cell.x == 0) 0 else cell.x - 1;
        const min_y = if (cell.y == 0) 0 else cell.y - 1;
        const max_x = @min(cell.x + 1, self.hint_grid_side - 1);
        const max_y = @min(cell.y + 1, self.hint_grid_side - 1);
        var y = min_y;
        while (y <= max_y) : (y += 1) {
            var x = min_x;
            while (x <= max_x) : (x += 1) {
                self.hint_grid.items[self.hintIndex(x, y)] = tri_idx;
            }
        }
    }

    fn ensureVertexMetadataCapacity(self: *Engine, vertex_count: usize) !void {
        try self.ensureBoundaryVertexCounters(vertex_count);
        try self.ensureTrustedSpokeCapacity(vertex_count);
        if (self.vertex_hint_tri.items.len >= vertex_count) return;

        try self.vertex_hint_tri.ensureTotalCapacity(self.allocator, vertex_count);
        while (self.vertex_hint_tri.items.len < vertex_count) {
            try self.vertex_hint_tri.append(self.allocator, -1);
        }
    }

    pub fn noteLiveTriangleHint(self: *Engine, tri_idx: i32, tri: mesh.Triangle) void {
        if (mesh.isDeadTriangle(tri)) return;
        const vertices = [_]i32{ tri.v0, tri.v1, tri.v2 };
        for (vertices) |vertex| {
            if (vertex < 0) continue;
            const slot: usize = @intCast(vertex);
            if (slot < self.vertex_hint_tri.items.len) {
                self.vertex_hint_tri.items[slot] = tri_idx;
            }
        }
    }

    pub fn initSuperTriangle(self: *Engine, vertices: []const mesh.Vertex) !void {
        const bounds = spatial.BoundingBox.fromVertices(vertices);
        try self.resetHintGridForBounds(bounds, vertices.len);
        const dx = bounds.max_x - bounds.min_x;
        const dy = bounds.max_y - bounds.min_y;
        const dmax = @max(dx, dy);
        const midx = (bounds.min_x + bounds.max_x) * 0.5;
        const midy = (bounds.min_y + bounds.max_y) * 0.5;

        // Print bounds for debug
        // std.debug.print("Bounds: dx={d}, dy={d}, dmax={d}, mid={d},{d}\n", .{dx, dy, dmax, midx, midy});

        const v0 = mesh.Vertex{ .x = midx - 20.0 * dmax, .y = midy - 10.0 * dmax };
        const v1 = mesh.Vertex{ .x = midx, .y = midy + 20.0 * dmax };
        const v2 = mesh.Vertex{ .x = midx + 20.0 * dmax, .y = midy - 10.0 * dmax };

        try self.ensureVertexMetadataCapacity(3);
        try self.mesh.vertices.append(self.allocator, v0);
        try self.mesh.vertices.append(self.allocator, v1);
        try self.mesh.vertices.append(self.allocator, v2);

        const super_tri = mesh.Triangle{
            .v0 = 0,
            .v1 = 2,
            .v2 = 1,
            .adj0 = -1,
            .adj1 = -1,
            .adj2 = -1,
        };
        try self.mesh.appendTriangle(self.allocator, super_tri);
        self.updateTriangleCircumcircle(0, super_tri);
        self.noteLiveTriangleHint(0, super_tri);
        self.last_valid_tri = 0;
        self.updateHintForPoint(.{ .x = midx, .y = midy }, 0);
    }

    pub fn walk(self: *Engine, start_tri: i32, target: mesh.Vertex) i32 {
        self.statInc("walk_calls");
        const xs = self.mesh.vertices.items(.x);
        const ys = self.mesh.vertices.items(.y);
        var curr = start_tri;
        var limit: usize = 10000;
        var steps: u64 = 0;

        while (curr != -1 and limit > 0) : (limit -= 1) {
            steps += 1;
            if (curr < 0) break;
            const curr_slot = @as(usize, @intCast(curr));
            if (curr_slot >= self.mesh.triangles.len) break;
            const tri = self.mesh.triangles.get(curr_slot);
            if (mesh.isDeadTriangle(tri)) break;

            const v0: usize = @intCast(tri.v0);
            const v1: usize = @intCast(tri.v1);
            const v2: usize = @intCast(tri.v2);

            if (predicates.orient2dCoords(xs[v0], ys[v0], xs[v1], ys[v1], target.x, target.y) < 0.0) {
                curr = tri.adj0;
                continue;
            }
            if (predicates.orient2dCoords(xs[v1], ys[v1], xs[v2], ys[v2], target.x, target.y) < 0.0) {
                curr = tri.adj1;
                continue;
            }
            if (predicates.orient2dCoords(xs[v2], ys[v2], xs[v0], ys[v0], target.x, target.y) < 0.0) {
                curr = tri.adj2;
                continue;
            }

            self.statAdd("walk_steps", steps);
            self.statMax("walk_max_steps", steps);
            return curr;
        }

        self.statAdd("walk_steps", steps);
        self.statMax("walk_max_steps", steps);
        self.statInc("walk_fallbacks");

        // Linear scan fallback
        var i: usize = 0;
        var scanned: u64 = 0;
        while (i < self.mesh.triangles.len) : (i += 1) {
            scanned += 1;
            const tri = self.mesh.triangles.get(i);
            if (mesh.isDeadTriangle(tri)) continue;
            const v0: usize = @intCast(tri.v0);
            const v1: usize = @intCast(tri.v1);
            const v2: usize = @intCast(tri.v2);

            if (predicates.orient2dCoords(xs[v0], ys[v0], xs[v1], ys[v1], target.x, target.y) >= 0.0 and
                predicates.orient2dCoords(xs[v1], ys[v1], xs[v2], ys[v2], target.x, target.y) >= 0.0 and
                predicates.orient2dCoords(xs[v2], ys[v2], xs[v0], ys[v0], target.x, target.y) >= 0.0)
            {
                self.statAdd("walk_fallback_scan_tris", scanned);
                return @as(i32, @intCast(i));
            }
        }

        self.statAdd("walk_fallback_scan_tris", scanned);
        return -1;
    }

    pub fn getVertex(self: *Engine, idx: i32) mesh.Vertex {
        return self.mesh.vertices.get(@as(usize, @intCast(idx)));
    }

    pub fn triangleAdj(tri: mesh.Triangle, side: usize) i32 {
        return switch (side) {
            0 => triangleAdjAt(0, tri),
            1 => triangleAdjAt(1, tri),
            else => triangleAdjAt(2, tri),
        };
    }

    pub fn triangleAdjAt(comptime side: usize, tri: mesh.Triangle) i32 {
        return switch (side) {
            0 => tri.adj0,
            1 => tri.adj1,
            2 => tri.adj2,
            else => @compileError("invalid triangle side"),
        };
    }

    pub fn setTriangleAdj(tri: *mesh.Triangle, side: usize, neighbor: i32) void {
        switch (side) {
            0 => setTriangleAdjAt(0, tri, neighbor),
            1 => setTriangleAdjAt(1, tri, neighbor),
            else => setTriangleAdjAt(2, tri, neighbor),
        }
    }

    pub fn setTriangleAdjAt(comptime side: usize, tri: *mesh.Triangle, neighbor: i32) void {
        switch (side) {
            0 => tri.adj0 = neighbor,
            1 => tri.adj1 = neighbor,
            2 => tri.adj2 = neighbor,
            else => @compileError("invalid triangle side"),
        }
    }

    pub fn triangleEdge(tri: mesh.Triangle, side: usize) EdgeVertices {
        return switch (side) {
            0 => triangleEdgeAt(0, tri),
            1 => triangleEdgeAt(1, tri),
            else => triangleEdgeAt(2, tri),
        };
    }

    pub fn triangleEdgeAt(comptime side: usize, tri: mesh.Triangle) EdgeVertices {
        return switch (side) {
            0 => .{ .v1 = tri.v0, .v2 = tri.v1 },
            1 => .{ .v1 = tri.v1, .v2 = tri.v2 },
            2 => .{ .v1 = tri.v2, .v2 = tri.v0 },
            else => @compileError("invalid triangle side"),
        };
    }

    pub fn edgeSide(tri: mesh.Triangle, a: i32, b: i32) ?usize {
        inline for (0..3) |side| {
            const edge = triangleEdgeAt(side, tri);
            if ((edge.v1 == a and edge.v2 == b) or (edge.v1 == b and edge.v2 == a)) {
                return side;
            }
        }
        return null;
    }

    fn edgeFlag(side: usize) u8 {
        return switch (side) {
            0 => edgeFlagAt(0),
            1 => edgeFlagAt(1),
            else => edgeFlagAt(2),
        };
    }

    fn edgeFlagAt(comptime side: usize) u8 {
        return switch (side) {
            0 => 1,
            1 => 2,
            2 => 4,
            else => @compileError("invalid triangle side"),
        };
    }

    pub fn oppositeVertex(tri: mesh.Triangle, side: usize) i32 {
        return switch (side) {
            0 => oppositeVertexAt(0, tri),
            1 => oppositeVertexAt(1, tri),
            else => oppositeVertexAt(2, tri),
        };
    }

    pub fn oppositeVertexAt(comptime side: usize, tri: mesh.Triangle) i32 {
        return switch (side) {
            0 => tri.v2,
            1 => tri.v0,
            2 => tri.v1,
            else => @compileError("invalid triangle side"),
        };
    }

    pub fn isConstrainedSide(self: *const Engine, tri_idx: i32, side: usize) bool {
        if (tri_idx < 0) return false;
        const slot = @as(usize, @intCast(tri_idx));
        if (slot >= self.mesh.edge_flags.items.len) return false;
        return (self.mesh.edge_flags.items[slot] & edgeFlag(side)) != 0;
    }

    pub fn setConstrainedSide(self: *Engine, tri_idx: i32, side: usize, value: bool) void {
        const slot = @as(usize, @intCast(tri_idx));
        var flags = self.mesh.edge_flags.items[slot];
        if (value) {
            flags |= edgeFlag(side);
        } else {
            flags &= ~edgeFlag(side);
        }
        self.mesh.setEdgeFlags(tri_idx, flags);
    }

    pub fn setConstrainedSideTrusted(self: *Engine, tri_idx: i32, side: usize, value: bool) void {
        const slot = @as(usize, @intCast(tri_idx));
        var flags = self.mesh.edge_flags.items[slot];
        if (value) {
            flags |= edgeFlag(side);
        } else {
            flags &= ~edgeFlag(side);
        }
        self.mesh.setEdgeFlagsTrusted(tri_idx, flags);
    }

    pub fn triangleVersion(self: *const Engine, tri_idx: i32) u32 {
        return self.mesh.triangle_versions.items[@as(usize, @intCast(tri_idx))].load(.acquire);
    }

    pub fn snapshotTriangleVersion(self: *const Engine, tri_idx: i32) TriangleVersionSnapshot {
        return .{ .tri = tri_idx, .version = self.triangleVersion(tri_idx) };
    }

    pub fn validateTriangleVersions(self: *const Engine, snapshots: []const TriangleVersionSnapshot) bool {
        for (snapshots) |snapshot| {
            if (snapshot.tri < 0) return false;
            const slot = @as(usize, @intCast(snapshot.tri));
            if (slot >= self.mesh.triangle_versions.items.len) return false;
            if (self.mesh.triangle_versions.items[slot].load(.acquire) != snapshot.version) return false;
        }
        return true;
    }

    fn isTriangleLocked(self: *const Engine, tri_idx: i32) bool {
        if (tri_idx < 0) return false;
        const slot = @as(usize, @intCast(tri_idx));
        if (slot >= self.mesh.triangle_locks.items.len) return false;
        return self.mesh.triangle_locks.items[slot].load(.acquire) != 0;
    }

    fn tryLockTriangle(self: *Engine, tri_idx: i32) bool {
        const slot = @as(usize, @intCast(tri_idx));
        return self.mesh.triangle_locks.items[slot].cmpxchgStrong(0, 1, .acquire, .monotonic) == null;
    }

    fn unlockTriangle(self: *Engine, tri_idx: i32) void {
        const slot = @as(usize, @intCast(tri_idx));
        self.mesh.triangle_locks.items[slot].store(0, .release);
    }

    fn containsTriangle(list: []const i32, tri_idx: i32) bool {
        for (list) |item| {
            if (item == tri_idx) return true;
        }
        return false;
    }

    pub fn appendTransactionTriangle(self: *const Engine, allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(i32), tri_idx: i32) !void {
        if (tri_idx < 0) return;
        const slot = @as(usize, @intCast(tri_idx));
        if (slot >= self.mesh.triangles.len) return;
        if (mesh.isDeadTriangle(self.mesh.triangles.get(slot))) return;
        if (containsTriangle(list.items, tri_idx)) return;
        try list.append(allocator, tri_idx);
    }

    pub fn collectCavityTransactionFootprint(self: *const Engine, allocator: std.mem.Allocator, cavity: []const i32, edges: []const Edge, footprint: *std.ArrayListUnmanaged(i32)) !void {
        footprint.clearRetainingCapacity();

        for (cavity) |tri_idx| {
            try self.appendTransactionTriangle(allocator, footprint, tri_idx);
        }
        for (edges) |edge| {
            try self.appendTransactionTriangle(allocator, footprint, edge.adj_tri);
        }
    }

    pub fn snapshotTransactionFootprint(self: *const Engine, allocator: std.mem.Allocator, footprint: []const i32, snapshots: *std.ArrayListUnmanaged(TriangleVersionSnapshot)) !bool {
        snapshots.clearRetainingCapacity();

        for (footprint) |tri_idx| {
            if (tri_idx < 0) return false;
            const slot = @as(usize, @intCast(tri_idx));
            if (slot >= self.mesh.triangles.len) return false;
            if (mesh.isDeadTriangle(self.mesh.triangles.get(slot))) return false;
            try snapshots.append(allocator, self.snapshotTriangleVersion(tri_idx));
        }

        return true;
    }

    fn sortTriangleIds(ids: []i32) void {
        std.mem.sortUnstable(i32, ids, {}, std.sort.asc(i32));
    }

    pub fn beginTriangleTransaction(self: *Engine, allocator: std.mem.Allocator, requested_triangles: []const i32, tx: *TriangleTransaction) !bool {
        const no_expected_versions: []const TriangleVersionSnapshot = &.{};
        return self.beginTriangleTransactionWithVersions(allocator, requested_triangles, no_expected_versions, tx);
    }

    pub fn beginTriangleTransactionWithVersions(self: *Engine, allocator: std.mem.Allocator, requested_triangles: []const i32, expected_versions: []const TriangleVersionSnapshot, tx: *TriangleTransaction) !bool {
        tx.locked.clearRetainingCapacity();
        tx.versions.clearRetainingCapacity();

        for (requested_triangles) |tri_idx| {
            if (tri_idx < 0) continue;
            const slot = @as(usize, @intCast(tri_idx));
            if (slot >= self.mesh.triangles.len) return false;
            if (mesh.isDeadTriangle(self.mesh.triangles.get(slot))) return false;
            if (containsTriangle(tx.locked.items, tri_idx)) continue;
            try tx.locked.append(allocator, tri_idx);
        }

        sortTriangleIds(tx.locked.items);

        var acquired: usize = 0;
        for (tx.locked.items) |tri_idx| {
            if (!self.tryLockTriangle(tri_idx)) {
                for (tx.locked.items[0..acquired]) |locked_tri| {
                    self.unlockTriangle(locked_tri);
                }
                tx.locked.clearRetainingCapacity();
                tx.versions.clearRetainingCapacity();
                return false;
            }
            acquired += 1;
            tx.versions.append(allocator, self.snapshotTriangleVersion(tri_idx)) catch |err| {
                for (tx.locked.items[0..acquired]) |locked_tri| {
                    self.unlockTriangle(locked_tri);
                }
                tx.locked.clearRetainingCapacity();
                tx.versions.clearRetainingCapacity();
                return err;
            };
        }

        if (!self.validateTriangleVersions(expected_versions)) {
            for (tx.locked.items[0..acquired]) |locked_tri| {
                self.unlockTriangle(locked_tri);
            }
            tx.locked.clearRetainingCapacity();
            tx.versions.clearRetainingCapacity();
            return false;
        }

        if (!self.revalidateTriangleTransaction(tx)) {
            for (tx.locked.items[0..acquired]) |locked_tri| {
                self.unlockTriangle(locked_tri);
            }
            tx.locked.clearRetainingCapacity();
            tx.versions.clearRetainingCapacity();
            return false;
        }

        return true;
    }

    pub fn revalidateTriangleTransaction(self: *const Engine, tx: *const TriangleTransaction) bool {
        if (!self.validateTriangleVersions(tx.versions.items)) return false;
        for (tx.locked.items) |tri_idx| {
            const slot = @as(usize, @intCast(tri_idx));
            if (slot >= self.mesh.triangles.len) return false;
            if (mesh.isDeadTriangle(self.mesh.triangles.get(slot))) return false;
        }
        return true;
    }

    pub fn endTriangleTransaction(self: *Engine, tx: *TriangleTransaction) void {
        for (tx.locked.items) |tri_idx| {
            if (tri_idx < 0) continue;
            const slot = @as(usize, @intCast(tri_idx));
            if (slot >= self.mesh.triangles.len) continue;
            self.unlockTriangle(tri_idx);
        }
        tx.locked.clearRetainingCapacity();
        tx.versions.clearRetainingCapacity();
    }

    pub fn setConstrainedTriangleEdge(self: *Engine, tri_idx: i32, side: usize, value: bool) !void {
        const tri = self.mesh.triangles.get(@as(usize, @intCast(tri_idx)));
        if (mesh.isDeadTriangle(tri)) return error.InvalidTriangleVertex;

        self.setConstrainedSide(tri_idx, side, value);
        const neighbor_idx = triangleAdj(tri, side);
        if (neighbor_idx == -1) return;

        const edge = triangleEdge(tri, side);
        const neighbor = self.mesh.triangles.get(@as(usize, @intCast(neighbor_idx)));
        const neighbor_side = edgeSide(neighbor, edge.v1, edge.v2) orelse return error.InvalidTriangleAdjacency;
        self.setConstrainedSide(neighbor_idx, neighbor_side, value);
    }

    pub fn setConstrainedTriangleEdgeTrusted(self: *Engine, tri_idx: i32, side: usize, value: bool) !void {
        const tri = self.mesh.triangles.get(@as(usize, @intCast(tri_idx)));
        if (mesh.isDeadTriangle(tri)) return error.InvalidTriangleVertex;

        self.setConstrainedSideTrusted(tri_idx, side, value);
        const neighbor_idx = triangleAdj(tri, side);
        if (neighbor_idx == -1) return;

        const edge = triangleEdge(tri, side);
        const neighbor = self.mesh.triangles.get(@as(usize, @intCast(neighbor_idx)));
        const neighbor_side = edgeSide(neighbor, edge.v1, edge.v2) orelse return error.InvalidTriangleAdjacency;
        self.setConstrainedSideTrusted(neighbor_idx, neighbor_side, value);
    }

    pub fn setConstrainedFoundEdgeTrusted(self: *Engine, found: LiveEdge, value: bool) void {
        self.setConstrainedSideTrusted(found.tri, found.side, value);
        if (found.neighbor != -1) {
            self.setConstrainedSideTrusted(found.neighbor, found.neighbor_side, value);
        }
    }

    fn liveEdgeFromTriangle(self: *Engine, tri_idx: i32, a: i32, b: i32) ?LiveEdge {
        if (tri_idx < 0) return null;
        const slot: usize = @intCast(tri_idx);
        if (slot >= self.mesh.triangles.len) return null;
        const tri = self.mesh.triangles.get(slot);
        if (mesh.isDeadTriangle(tri)) return null;
        const side = edgeSide(tri, a, b) orelse return null;
        const neighbor_idx = triangleAdj(tri, side);
        var neighbor_side: usize = 0;
        if (neighbor_idx != -1) {
            const neighbor = self.mesh.triangles.get(@as(usize, @intCast(neighbor_idx)));
            neighbor_side = edgeSide(neighbor, a, b) orelse return .{ .tri = tri_idx, .side = side };
        }
        return .{ .tri = tri_idx, .side = side, .neighbor = neighbor_idx, .neighbor_side = neighbor_side };
    }

    fn triangleHasVertex(tri: mesh.Triangle, vertex: i32) bool {
        return tri.v0 == vertex or tri.v1 == vertex or tri.v2 == vertex;
    }

    pub fn findLiveEdge(self: *Engine, a: i32, b: i32) ?LiveEdge {
        self.statInc("find_live_edge_calls");
        var scanned: u64 = 0;
        for (0..self.mesh.triangles.len) |i| {
            scanned += 1;
            const tri = self.mesh.triangles.get(i);
            if (mesh.isDeadTriangle(tri)) continue;
            if (edgeSide(tri, a, b)) |side| {
                self.statAdd("find_live_edge_scan_tris", scanned);
                const tri_idx = @as(i32, @intCast(i));
                const found = self.liveEdgeFromTriangle(tri_idx, a, b) orelse LiveEdge{ .tri = tri_idx, .side = side };
                self.noteLiveTriangleHint(tri_idx, tri);
                return found;
            }
        }
        self.statAdd("find_live_edge_scan_tris", scanned);
        return null;
    }

    pub fn findLiveEdgeFast(self: *Engine, a: i32, b: i32) ?LiveEdge {
        self.statInc("find_live_edge_fast_calls");
        if (a < 0 or @as(usize, @intCast(a)) >= self.vertex_hint_tri.items.len) return self.findLiveEdge(a, b);

        var stack: [64]i32 = undefined;
        var visited: [64]i32 = undefined;
        var stack_len: usize = 0;
        var visited_len: usize = 0;

        const start = self.vertex_hint_tri.items[@as(usize, @intCast(a))];
        if (start >= 0) {
            stack[stack_len] = start;
            stack_len += 1;
        }

        while (stack_len > 0) {
            stack_len -= 1;
            const tri_idx = stack[stack_len];
            if (tri_idx < 0) continue;

            var already_visited = false;
            for (visited[0..visited_len]) |seen| {
                if (seen == tri_idx) {
                    already_visited = true;
                    break;
                }
            }
            if (already_visited) continue;
            if (visited_len == visited.len) break;
            visited[visited_len] = tri_idx;
            visited_len += 1;

            const tri_slot: usize = @intCast(tri_idx);
            if (tri_slot >= self.mesh.triangles.len) continue;
            const tri = self.mesh.triangles.get(tri_slot);
            if (mesh.isDeadTriangle(tri) or !triangleHasVertex(tri, a)) continue;

            if (self.liveEdgeFromTriangle(tri_idx, a, b)) |found| {
                self.noteLiveTriangleHint(tri_idx, tri);
                return found;
            }

            const neighbors = [_]i32{ tri.adj0, tri.adj1, tri.adj2 };
            for (neighbors) |neighbor_idx| {
                if (neighbor_idx < 0) continue;
                const neighbor_slot: usize = @intCast(neighbor_idx);
                if (neighbor_slot >= self.mesh.triangles.len) continue;
                const neighbor = self.mesh.triangles.get(neighbor_slot);
                if (mesh.isDeadTriangle(neighbor) or !triangleHasVertex(neighbor, a)) continue;
                if (stack_len == stack.len) break;
                stack[stack_len] = neighbor_idx;
                stack_len += 1;
            }
        }

        self.statInc("find_live_edge_fast_fallbacks");
        return self.findLiveEdge(a, b);
    }

    pub fn setConstrainedEdgeByVertices(self: *Engine, a: i32, b: i32, value: bool) !bool {
        const found = self.findLiveEdge(a, b) orelse return false;
        try self.setConstrainedTriangleEdge(found.tri, found.side, value);
        return true;
    }

    pub fn setConstrainedEdgeByVerticesTrusted(self: *Engine, a: i32, b: i32, value: bool) !bool {
        const found = self.findLiveEdge(a, b) orelse return false;
        try self.setConstrainedTriangleEdgeTrusted(found.tri, found.side, value);
        return true;
    }

    pub fn linkTriangleSides(self: *Engine, tri_a_idx: i32, side_a: usize, tri_b_idx: i32, side_b: usize) !void {
        try self.linkTriangleSidesInternal(tri_a_idx, side_a, tri_b_idx, side_b, false);
    }

    pub fn linkTriangleSidesTrusted(self: *Engine, tri_a_idx: i32, side_a: usize, tri_b_idx: i32, side_b: usize) !void {
        try self.linkTriangleSidesInternal(tri_a_idx, side_a, tri_b_idx, side_b, true);
    }

    pub fn setTriangleAdjTrusted(self: *Engine, tri_idx: i32, side: usize, neighbor: i32) !void {
        if (tri_idx < 0) return;
        const tri_slot = @as(usize, @intCast(tri_idx));
        if (tri_slot >= self.mesh.triangles.len) return error.InvalidTriangleAdjacency;
        const tri = self.mesh.triangles.get(tri_slot);
        if (mesh.isDeadTriangle(tri)) return error.InvalidTriangleAdjacency;
        self.setTriangleAdjTrustedUnchecked(tri_slot, side, neighbor);
    }

    fn setTriangleAdjTrustedUnchecked(self: *Engine, tri_slot: usize, side: usize, neighbor: i32) void {
        switch (side) {
            0 => self.mesh.triangles.items(.adj0)[tri_slot] = neighbor,
            1 => self.mesh.triangles.items(.adj1)[tri_slot] = neighbor,
            else => self.mesh.triangles.items(.adj2)[tri_slot] = neighbor,
        }
    }

    pub fn linkTriangleSidesKnownTrusted(self: *Engine, tri_a_idx: i32, side_a: usize, tri_b_idx: i32, side_b: usize) !void {
        self.setTriangleAdjTrustedUnchecked(@as(usize, @intCast(tri_a_idx)), side_a, tri_b_idx);
        self.setTriangleAdjTrustedUnchecked(@as(usize, @intCast(tri_b_idx)), side_b, tri_a_idx);
    }

    fn linkTriangleSidesInternal(self: *Engine, tri_a_idx: i32, side_a: usize, tri_b_idx: i32, side_b: usize, comptime trusted: bool) !void {
        if (tri_a_idx < 0 or tri_b_idx < 0) return;
        const tri_a_slot = @as(usize, @intCast(tri_a_idx));
        const tri_b_slot = @as(usize, @intCast(tri_b_idx));
        if (tri_a_slot >= self.mesh.triangles.len or tri_b_slot >= self.mesh.triangles.len) return error.InvalidTriangleAdjacency;

        var tri_a = self.mesh.triangles.get(tri_a_slot);
        var tri_b = self.mesh.triangles.get(tri_b_slot);
        if (mesh.isDeadTriangle(tri_a) or mesh.isDeadTriangle(tri_b)) return error.InvalidTriangleAdjacency;

        const constrained = self.isConstrainedSide(tri_a_idx, side_a) or self.isConstrainedSide(tri_b_idx, side_b);
        setTriangleAdj(&tri_a, side_a, tri_b_idx);
        setTriangleAdj(&tri_b, side_b, tri_a_idx);
        if (trusted) {
            self.mesh.setTriangleTrusted(tri_a_idx, tri_a);
            self.mesh.setTriangleTrusted(tri_b_idx, tri_b);
            self.setConstrainedSideTrusted(tri_a_idx, side_a, constrained);
            self.setConstrainedSideTrusted(tri_b_idx, side_b, constrained);
        } else {
            self.mesh.setTriangle(tri_a_idx, tri_a);
            self.mesh.setTriangle(tri_b_idx, tri_b);
            self.setConstrainedSide(tri_a_idx, side_a, constrained);
            self.setConstrainedSide(tri_b_idx, side_b, constrained);
        }
    }

    pub fn linkTrianglesByEdge(self: *Engine, tri_a_idx: i32, tri_b_idx: i32, edge_v1: i32, edge_v2: i32) !void {
        if (tri_a_idx < 0 or tri_b_idx < 0) return;
        const tri_a = self.mesh.triangles.get(@as(usize, @intCast(tri_a_idx)));
        const tri_b = self.mesh.triangles.get(@as(usize, @intCast(tri_b_idx)));
        const side_a = edgeSide(tri_a, edge_v1, edge_v2) orelse return error.InvalidTriangleAdjacency;
        const side_b = edgeSide(tri_b, edge_v1, edge_v2) orelse return error.InvalidTriangleAdjacency;
        try self.linkTriangleSides(tri_a_idx, side_a, tri_b_idx, side_b);
    }

    pub fn linkTrianglesByEdgeTrusted(self: *Engine, tri_a_idx: i32, tri_b_idx: i32, edge_v1: i32, edge_v2: i32) !void {
        if (tri_a_idx < 0 or tri_b_idx < 0) return;
        const tri_a = self.mesh.triangles.get(@as(usize, @intCast(tri_a_idx)));
        const tri_b = self.mesh.triangles.get(@as(usize, @intCast(tri_b_idx)));
        const side_a = edgeSide(tri_a, edge_v1, edge_v2) orelse return error.InvalidTriangleAdjacency;
        const side_b = edgeSide(tri_b, edge_v1, edge_v2) orelse return error.InvalidTriangleAdjacency;
        try self.linkTriangleSidesTrusted(tri_a_idx, side_a, tri_b_idx, side_b);
    }

    pub fn linkBoundaryNeighborTrusted(self: *Engine, new_tri_idx: i32, boundary_side: usize, neighbor_idx: i32, edge_v1: i32, edge_v2: i32) !void {
        if (neighbor_idx < 0) return;
        const neighbor = self.mesh.triangles.get(@as(usize, @intCast(neighbor_idx)));
        const neighbor_side = edgeSide(neighbor, edge_v1, edge_v2) orelse return error.InvalidTriangleAdjacency;
        try self.linkTriangleSidesKnownTrusted(new_tri_idx, boundary_side, neighbor_idx, neighbor_side);
    }

    pub fn linkNewTriangles(self: *Engine, new_tri_indices: []const i32) !void {
        try self.linkNewTrianglesInternal(new_tri_indices, false);
    }

    pub fn linkNewTrianglesTrusted(self: *Engine, new_tri_indices: []const i32) !void {
        try self.linkNewTrianglesInternal(new_tri_indices, true);
    }

    fn ensureTrustedSpokeCapacity(self: *Engine, vertex_count: usize) !void {
        if (self.trusted_spoke_marks.items.len >= vertex_count) return;

        try self.trusted_spoke_marks.ensureTotalCapacity(self.allocator, vertex_count);
        try self.trusted_spoke_tris.ensureTotalCapacity(self.allocator, vertex_count);
        try self.trusted_spoke_sides.ensureTotalCapacity(self.allocator, vertex_count);
        while (self.trusted_spoke_marks.items.len < vertex_count) {
            try self.trusted_spoke_marks.append(self.allocator, 0);
            try self.trusted_spoke_tris.append(self.allocator, -1);
            try self.trusted_spoke_sides.append(self.allocator, 0);
        }
    }

    fn beginTrustedSpokes(self: *Engine, vertex_count: usize) !void {
        try self.ensureTrustedSpokeCapacity(vertex_count);
        self.trusted_spoke_generation +%= 1;
        if (self.trusted_spoke_generation == 0) {
            @memset(self.trusted_spoke_marks.items, 0);
            self.trusted_spoke_generation = 1;
        }
    }

    fn addTrustedSpoke(self: *Engine, vertex: i32, tri_idx: i32, side: usize) !void {
        const slot: usize = @intCast(vertex);
        if (self.trusted_spoke_marks.items[slot] == self.trusted_spoke_generation) {
            try self.linkTriangleSidesKnownTrusted(
                self.trusted_spoke_tris.items[slot],
                @intCast(self.trusted_spoke_sides.items[slot]),
                tri_idx,
                side,
            );
            return;
        }

        self.trusted_spoke_marks.items[slot] = self.trusted_spoke_generation;
        self.trusted_spoke_tris.items[slot] = tri_idx;
        self.trusted_spoke_sides.items[slot] = @intCast(side);
    }

    fn linkNewTrianglesInternal(self: *Engine, new_tri_indices: []const i32, comptime trusted: bool) !void {
        for (new_tri_indices, 0..) |tri_a_idx, i| {
            const tri_a = self.mesh.triangles.get(@as(usize, @intCast(tri_a_idx)));
            if (mesh.isDeadTriangle(tri_a)) continue;

            for (new_tri_indices[i + 1 ..]) |tri_b_idx| {
                const tri_b = self.mesh.triangles.get(@as(usize, @intCast(tri_b_idx)));
                if (mesh.isDeadTriangle(tri_b)) continue;

                inline for (0..3) |side_a| {
                    const edge = triangleEdgeAt(side_a, tri_a);
                    if (edgeSide(tri_b, edge.v1, edge.v2)) |side_b| {
                        try self.linkTriangleSidesInternal(tri_a_idx, side_a, tri_b_idx, side_b, trusted);
                    }
                }
            }
        }
    }

    pub fn liveTriangleCount(self: *Engine) usize {
        return self.mesh.live_triangle_count;
    }

    fn ensureInteriorMarkCapacity(self: *Engine, triangle_count: usize) !void {
        if (self.interior_triangle_marks.items.len >= triangle_count) return;

        try self.interior_triangle_marks.ensureTotalCapacity(self.allocator, triangle_count);
        while (self.interior_triangle_marks.items.len < triangle_count) {
            try self.interior_triangle_marks.append(self.allocator, 0);
        }
    }

    fn beginInteriorGeneration(self: *Engine, triangle_count: usize) !void {
        try self.ensureInteriorMarkCapacity(triangle_count);
        self.interior_triangle_generation +%= 1;
        if (self.interior_triangle_generation == 0) {
            @memset(self.interior_triangle_marks.items, 0);
            self.interior_triangle_generation = 1;
        }
    }

    fn markExteriorTriangle(self: *Engine, tri_idx: i32) void {
        const slot: usize = @intCast(tri_idx);
        self.interior_triangle_marks.items[slot] = self.interior_triangle_generation;
    }

    fn isExteriorTriangleMarked(self: *const Engine, tri_idx: i32) bool {
        const slot: usize = @intCast(tri_idx);
        return slot < self.interior_triangle_marks.items.len and
            self.interior_triangle_marks.items[slot] == self.interior_triangle_generation;
    }

    fn markExteriorTriangles(self: *Engine) !void {
        try self.beginInteriorGeneration(self.mesh.triangles.len);
        self.interior_triangle_queue.clearRetainingCapacity();

        for (0..self.mesh.triangles.len) |tri_idx| {
            const tri = self.mesh.triangles.get(tri_idx);
            if (mesh.isDeadTriangle(tri) or !triangleHasSuperVertex(tri)) continue;
            self.markExteriorTriangle(@intCast(tri_idx));
            try self.interior_triangle_queue.append(self.allocator, @intCast(tri_idx));
        }

        while (self.interior_triangle_queue.items.len > 0) {
            const tri_idx = self.interior_triangle_queue.pop().?;
            const tri_slot: usize = @intCast(tri_idx);
            const tri = self.mesh.triangles.get(tri_slot);
            for (0..3) |side| {
                if (self.isConstrainedSide(tri_idx, side)) continue;

                const neighbor_idx = triangleAdj(tri, side);
                if (neighbor_idx < 0) continue;
                const neighbor_slot: usize = @intCast(neighbor_idx);
                if (neighbor_slot >= self.mesh.triangles.len or self.isExteriorTriangleMarked(neighbor_idx)) continue;

                const neighbor = self.mesh.triangles.get(neighbor_slot);
                if (mesh.isDeadTriangle(neighbor)) continue;

                self.markExteriorTriangle(neighbor_idx);
                try self.interior_triangle_queue.append(self.allocator, neighbor_idx);
            }
        }
    }

    pub fn markInteriorTriangles(self: *Engine, allocator: std.mem.Allocator, interior: *std.ArrayListUnmanaged(bool)) !usize {
        interior.clearRetainingCapacity();
        try interior.ensureTotalCapacity(allocator, self.mesh.triangles.len);
        for (0..self.mesh.triangles.len) |_| {
            interior.appendAssumeCapacity(false);
        }

        try self.markExteriorTriangles();

        var count: usize = 0;
        for (0..self.mesh.triangles.len) |tri_idx| {
            const tri = self.mesh.triangles.get(tri_idx);
            const is_interior = !mesh.isDeadTriangle(tri) and !triangleHasSuperVertex(tri) and !self.isExteriorTriangleMarked(@intCast(tri_idx));
            interior.items[tri_idx] = is_interior;
            if (is_interior) count += 1;
        }
        return count;
    }

    pub fn countInteriorTriangles(self: *Engine) !usize {
        try self.markExteriorTriangles();

        var count: usize = 0;
        for (0..self.mesh.triangles.len) |tri_idx| {
            const tri = self.mesh.triangles.get(tri_idx);
            if (!mesh.isDeadTriangle(tri) and !triangleHasSuperVertex(tri) and !self.isExteriorTriangleMarked(@intCast(tri_idx))) {
                count += 1;
            }
        }
        return count;
    }

    pub fn hasLiveEdge(self: *Engine, a: i32, b: i32) bool {
        return self.findLiveEdge(a, b) != null;
    }

    pub fn validateTopology(self: *Engine) !void {
        if (self.mesh.triangles.len != self.mesh.edge_flags.items.len or
            self.mesh.triangles.len != self.mesh.triangle_versions.items.len or
            self.mesh.triangles.len != self.mesh.triangle_locks.items.len) return error.InvalidTriangleAdjacency;
        for (0..self.mesh.triangles.len) |i| {
            const tri = self.mesh.triangles.get(i);
            if (mesh.isDeadTriangle(tri)) continue;

            if (tri.v0 < 0 or tri.v1 < 0 or tri.v2 < 0) return error.InvalidTriangleVertex;
            if (tri.v0 == tri.v1 or tri.v1 == tri.v2 or tri.v2 == tri.v0) return error.DegenerateTriangle;
            if (@as(usize, @intCast(tri.v0)) >= self.mesh.vertices.len or
                @as(usize, @intCast(tri.v1)) >= self.mesh.vertices.len or
                @as(usize, @intCast(tri.v2)) >= self.mesh.vertices.len) return error.InvalidTriangleVertex;

            const neighbors = [_]i32{ tri.adj0, tri.adj1, tri.adj2 };
            for (neighbors, 0..) |neighbor_idx, side| {
                if (neighbor_idx == -1) continue;
                if (neighbor_idx < 0 or @as(usize, @intCast(neighbor_idx)) >= self.mesh.triangles.len) {
                    return error.InvalidTriangleAdjacency;
                }

                const neighbor = self.mesh.triangles.get(@as(usize, @intCast(neighbor_idx)));
                if (mesh.isDeadTriangle(neighbor)) return error.InvalidTriangleAdjacency;

                const edge = triangleEdge(tri, side);
                const neighbor_side = edgeSide(neighbor, edge.v1, edge.v2) orelse return error.InvalidTriangleAdjacency;
                if (triangleAdj(neighbor, neighbor_side) != @as(i32, @intCast(i))) return error.InvalidTriangleAdjacency;
            }
        }
    }

    pub fn validateConstraintRing(self: *Engine, mesh_ids: []const i32) !void {
        if (mesh_ids.len < 2) return;
        for (0..mesh_ids.len) |i| {
            const a = mesh_ids[i];
            const b = mesh_ids[(i + 1) % mesh_ids.len];
            if (!self.hasLiveEdge(a, b)) return error.MissingConstraintEdge;
        }
    }

    pub fn validateConstraintFlags(self: *Engine) !void {
        if (self.mesh.triangles.len != self.mesh.edge_flags.items.len or
            self.mesh.triangles.len != self.mesh.triangle_versions.items.len or
            self.mesh.triangles.len != self.mesh.triangle_locks.items.len) return error.InvalidTriangleAdjacency;

        for (0..self.mesh.triangles.len) |i| {
            const tri = self.mesh.triangles.get(i);
            const flags = self.mesh.edge_flags.items[i];
            if (mesh.isDeadTriangle(tri)) {
                if (flags != 0) return error.InvalidTriangleAdjacency;
                continue;
            }

            for (0..3) |side| {
                const neighbor_idx = triangleAdj(tri, side);
                if (neighbor_idx == -1) continue;
                const edge = triangleEdge(tri, side);
                const neighbor = self.mesh.triangles.get(@as(usize, @intCast(neighbor_idx)));
                const neighbor_side = edgeSide(neighbor, edge.v1, edge.v2) orelse return error.InvalidTriangleAdjacency;
                if (self.isConstrainedSide(@as(i32, @intCast(i)), side) != self.isConstrainedSide(neighbor_idx, neighbor_side)) {
                    return error.InvalidTriangleAdjacency;
                }
            }
        }
    }

    pub fn validateConstraintRingFlags(self: *Engine, mesh_ids: []const i32) !void {
        if (mesh_ids.len < 2) return;
        for (0..mesh_ids.len) |i| {
            const a = mesh_ids[i];
            const b = mesh_ids[(i + 1) % mesh_ids.len];
            const found = self.findLiveEdge(a, b) orelse return error.MissingConstraintEdge;
            if (!self.isConstrainedSide(found.tri, found.side)) return error.MissingConstraintEdge;
        }
    }

    pub fn rebuildAdjacency(self: *Engine) !void {
        const EdgeKey = struct {
            a: i32,
            b: i32,
        };
        const EdgeRef = struct {
            tri: i32,
            side: usize,
        };

        var edge_map = std.AutoHashMap(EdgeKey, EdgeRef).init(self.allocator);
        defer edge_map.deinit();

        for (0..self.mesh.triangles.len) |i| {
            var tri = self.mesh.triangles.get(i);
            if (mesh.isDeadTriangle(tri)) continue;
            tri.adj0 = -1;
            tri.adj1 = -1;
            tri.adj2 = -1;
            self.mesh.setTriangle(@as(i32, @intCast(i)), tri);
        }

        for (0..self.mesh.triangles.len) |i| {
            const tri = self.mesh.triangles.get(i);
            if (mesh.isDeadTriangle(tri)) continue;
            for (0..3) |side| {
                const edge = triangleEdgeAt(side, tri);
                const key = EdgeKey{
                    .a = @min(edge.v1, edge.v2),
                    .b = @max(edge.v1, edge.v2),
                };

                if (edge_map.get(key)) |other| {
                    var tri_mut = self.mesh.triangles.get(i);
                    var other_mut = self.mesh.triangles.get(@as(usize, @intCast(other.tri)));

                    // Non-manifold check: Is this edge already bound to another triangle?
                    if (triangleAdj(other_mut, other.side) != -1) {
                        const existing_adj = triangleAdj(other_mut, other.side);
                        const existing_tri = self.mesh.triangles.get(@as(usize, @intCast(existing_adj)));
                        std.debug.print("NonManifoldEdge: Tri {d} (v:{d},{d},{d}) and Tri {d} (v:{d},{d},{d}) share edge ({d},{d}), but Tri {d} is already bound to {d} (v:{d},{d},{d})\n", .{ i, tri_mut.v0, tri_mut.v1, tri_mut.v2, other.tri, other_mut.v0, other_mut.v1, other_mut.v2, key.a, key.b, other.tri, existing_adj, existing_tri.v0, existing_tri.v1, existing_tri.v2 });
                        return error.NonManifoldEdge;
                    }

                    setTriangleAdj(&tri_mut, side, other.tri);
                    setTriangleAdj(&other_mut, other.side, @as(i32, @intCast(i)));
                    self.mesh.setTriangle(@as(i32, @intCast(i)), tri_mut);
                    self.mesh.setTriangle(other.tri, other_mut);
                } else {
                    try edge_map.put(key, .{
                        .tri = @as(i32, @intCast(i)),
                        .side = side,
                    });
                }
            }
        }
    }

    pub fn isInsideCircumcircle(self: *Engine, tri_idx: i32, pt: mesh.Vertex) bool {
        return self.isInsideCircumcircleWithCoords(self.mesh.vertices.items(.x), self.mesh.vertices.items(.y), tri_idx, pt);
    }

    fn isInsideCircumcircleWithCoords(self: *Engine, xs: []const f64, ys: []const f64, tri_idx: i32, pt: mesh.Vertex) bool {
        if (tri_idx == -1) return false;
        const tri = self.mesh.triangles.get(@as(usize, @intCast(tri_idx)));
        if (mesh.isDeadTriangle(tri)) return false;
        if (build_options.circumcircle_filter and self.cachedCircumcircleRejects(tri_idx, pt)) return false;
        const v0: usize = @intCast(tri.v0);
        const v1: usize = @intCast(tri.v1);
        const v2: usize = @intCast(tri.v2);
        if (build_options.circumcircle_filter) self.statInc("circumcircle_filter_fallbacks");
        return predicates.incircleCoords(xs[v0], ys[v0], xs[v1], ys[v1], xs[v2], ys[v2], pt.x, pt.y) > 0.0;
    }

    fn cachedCircumcircleRejects(self: *Engine, tri_idx: i32, pt: mesh.Vertex) bool {
        const slot: usize = @intCast(tri_idx);
        if (slot >= self.mesh.circum_r2.items.len) return false;
        const r2 = self.mesh.circum_r2.items[slot];
        if (!(r2 >= 0.0) or !std.math.isFinite(r2)) return false;
        const cx = self.mesh.circum_x.items[slot];
        const cy = self.mesh.circum_y.items[slot];
        if (!std.math.isFinite(cx) or !std.math.isFinite(cy)) return false;

        const dx = pt.x - cx;
        const dy = pt.y - cy;
        const dist2 = dx * dx + dy * dy;
        const tol = @max(1e-12, @abs(r2) * 1e-12);
        if (dist2 > r2 + tol) {
            self.statInc("circumcircle_filter_rejects");
            return true;
        }
        return false;
    }

    fn updateTriangleCircumcircle(self: *Engine, tri_idx: i32, tri: mesh.Triangle) void {
        if (!build_options.circumcircle_filter) return;
        if (tri_idx < 0 or mesh.isDeadTriangle(tri)) return;
        const xs = self.mesh.vertices.items(.x);
        const ys = self.mesh.vertices.items(.y);
        const a: usize = @intCast(tri.v0);
        const b: usize = @intCast(tri.v1);
        const c: usize = @intCast(tri.v2);
        if (a >= xs.len or b >= xs.len or c >= xs.len) return;

        const ax = xs[a];
        const ay = ys[a];
        const bx = xs[b];
        const by = ys[b];
        const cx = xs[c];
        const cy = ys[c];
        const bax = bx - ax;
        const bay = by - ay;
        const cax = cx - ax;
        const cay = cy - ay;
        const det = 2.0 * (bax * cay - bay * cax);
        if (@abs(det) <= 1e-30 or !std.math.isFinite(det)) {
            self.mesh.clearCircumcircle(tri_idx);
            return;
        }

        const b_len = bax * bax + bay * bay;
        const c_len = cax * cax + cay * cay;
        const ux = ax + (cay * b_len - bay * c_len) / det;
        const uy = ay + (bax * c_len - cax * b_len) / det;
        const dx = ax - ux;
        const dy = ay - uy;
        const r2 = dx * dx + dy * dy;
        if (!std.math.isFinite(ux) or !std.math.isFinite(uy) or !std.math.isFinite(r2)) {
            self.mesh.clearCircumcircle(tri_idx);
            return;
        }
        self.mesh.setCircumcircle(tri_idx, ux, uy, r2);
    }

    fn triangleHasSuperVertex(tri: mesh.Triangle) bool {
        return tri.v0 < 3 or tri.v1 < 3 or tri.v2 < 3;
    }

    fn makeTriangleCcw(self: *Engine, a: i32, b: i32, c: i32) mesh.Triangle {
        var v1 = b;
        var v2 = c;
        if (predicates.orient2d(self.getVertex(a), self.getVertex(v1), self.getVertex(v2)) < 0.0) {
            const tmp = v1;
            v1 = v2;
            v2 = tmp;
        }
        return .{
            .v0 = a,
            .v1 = v1,
            .v2 = v2,
            .adj0 = -1,
            .adj1 = -1,
            .adj2 = -1,
        };
    }

    fn edgeIsFlipCandidate(self: *Engine, tri_idx: i32, side: usize) ?struct { neighbor: i32, neighbor_side: usize, a: i32, b: i32, c: i32, d: i32 } {
        if (tri_idx < 0) return null;
        const tri = self.mesh.triangles.get(@as(usize, @intCast(tri_idx)));
        if (mesh.isDeadTriangle(tri) or triangleHasSuperVertex(tri)) return null;
        if (self.isConstrainedSide(tri_idx, side)) return null;

        const neighbor_idx = triangleAdj(tri, side);
        if (neighbor_idx == -1) return null;
        const neighbor = self.mesh.triangles.get(@as(usize, @intCast(neighbor_idx)));
        if (mesh.isDeadTriangle(neighbor) or triangleHasSuperVertex(neighbor)) return null;

        const edge = triangleEdge(tri, side);
        const neighbor_side = edgeSide(neighbor, edge.v1, edge.v2) orelse return null;
        if (self.isConstrainedSide(neighbor_idx, neighbor_side)) return null;

        const c = oppositeVertex(tri, side);
        const d = oppositeVertex(neighbor, neighbor_side);
        if (c == d or c == edge.v1 or c == edge.v2 or d == edge.v1 or d == edge.v2) return null;

        const a_pt = self.getVertex(edge.v1);
        const b_pt = self.getVertex(edge.v2);
        const c_pt = self.getVertex(c);
        const d_pt = self.getVertex(d);
        const c_side = predicates.orient2d(a_pt, b_pt, c_pt);
        const d_side = predicates.orient2d(a_pt, b_pt, d_pt);
        if (c_side == 0.0 or d_side == 0.0 or c_side * d_side >= 0.0) return null;

        const new1 = self.makeTriangleCcw(c, edge.v1, d);
        const new2 = self.makeTriangleCcw(c, d, edge.v2);
        if (predicates.orient2d(self.getVertex(new1.v0), self.getVertex(new1.v1), self.getVertex(new1.v2)) <= 0.0) return null;
        if (predicates.orient2d(self.getVertex(new2.v0), self.getVertex(new2.v1), self.getVertex(new2.v2)) <= 0.0) return null;

        return .{
            .neighbor = neighbor_idx,
            .neighbor_side = neighbor_side,
            .a = edge.v1,
            .b = edge.v2,
            .c = c,
            .d = d,
        };
    }

    fn edgeNeedsFlip(self: *Engine, tri_idx: i32, side: usize) bool {
        const candidate = self.edgeIsFlipCandidate(tri_idx, side) orelse return false;

        var a = candidate.a;
        var b = candidate.b;
        const c = candidate.c;
        const d = candidate.d;
        if (predicates.orient2d(self.getVertex(a), self.getVertex(b), self.getVertex(c)) < 0.0) {
            const tmp = a;
            a = b;
            b = tmp;
        }
        return predicates.incircle(self.getVertex(a), self.getVertex(b), self.getVertex(c), self.getVertex(d)) > 0.0;
    }

    fn appendTriangleEdges(queue: *std.ArrayListUnmanaged(LegalizeEdge), allocator: std.mem.Allocator, tri_idx: i32) !void {
        inline for (0..3) |side| {
            try queue.append(allocator, .{ .tri = tri_idx, .side = side });
        }
    }

    fn transactionContainsTriangle(tx: *const TriangleTransaction, tri_idx: i32) bool {
        return containsTriangle(tx.locked.items, tri_idx);
    }

    fn flipEdge(self: *Engine, queue: *std.ArrayListUnmanaged(LegalizeEdge), allocator: std.mem.Allocator, tx: ?*const TriangleTransaction, tri_idx: i32, side: usize) !bool {
        const candidate = self.edgeIsFlipCandidate(tri_idx, side) orelse return false;
        if (!self.edgeNeedsFlip(tri_idx, side)) return false;

        const neighbor_idx = candidate.neighbor;
        const tri = self.mesh.triangles.get(@as(usize, @intCast(tri_idx)));
        const neighbor = self.mesh.triangles.get(@as(usize, @intCast(neighbor_idx)));

        const OldEdge = struct {
            v1: i32,
            v2: i32,
            adj: i32,
            constrained: bool,
        };

        var old_edges: [4]OldEdge = undefined;
        var old_len: usize = 0;
        for (0..3) |old_side| {
            if (old_side == side) continue;
            const edge = triangleEdge(tri, old_side);
            old_edges[old_len] = .{
                .v1 = edge.v1,
                .v2 = edge.v2,
                .adj = triangleAdj(tri, old_side),
                .constrained = self.isConstrainedSide(tri_idx, old_side),
            };
            old_len += 1;
        }
        for (0..3) |old_side| {
            if (old_side == candidate.neighbor_side) continue;
            const edge = triangleEdge(neighbor, old_side);
            old_edges[old_len] = .{
                .v1 = edge.v1,
                .v2 = edge.v2,
                .adj = triangleAdj(neighbor, old_side),
                .constrained = self.isConstrainedSide(neighbor_idx, old_side),
            };
            old_len += 1;
        }

        if (tx) |active_tx| {
            if (!transactionContainsTriangle(active_tx, tri_idx)) return error.TransactionFootprintExpansionRequired;
            if (!transactionContainsTriangle(active_tx, neighbor_idx)) return error.TransactionFootprintExpansionRequired;
            for (old_edges[0..old_len]) |old_edge| {
                if (old_edge.adj != -1 and !transactionContainsTriangle(active_tx, old_edge.adj)) {
                    return error.TransactionFootprintExpansionRequired;
                }
            }
        }

        self.mesh.setTriangleFresh(tri_idx, self.makeTriangleCcw(candidate.c, candidate.a, candidate.d));
        self.mesh.setTriangleFresh(neighbor_idx, self.makeTriangleCcw(candidate.c, candidate.d, candidate.b));

        try self.linkTrianglesByEdge(tri_idx, neighbor_idx, candidate.c, candidate.d);

        const new_tris = [_]i32{ tri_idx, neighbor_idx };
        for (old_edges[0..old_len]) |old_edge| {
            for (new_tris) |new_tri_idx| {
                const new_tri = self.mesh.triangles.get(@as(usize, @intCast(new_tri_idx)));
                if (edgeSide(new_tri, old_edge.v1, old_edge.v2)) |new_side| {
                    if (old_edge.constrained) self.setConstrainedSide(new_tri_idx, new_side, true);
                    if (old_edge.adj != -1) {
                        try self.linkTrianglesByEdge(new_tri_idx, old_edge.adj, old_edge.v1, old_edge.v2);
                    }
                    break;
                }
            }
        }

        try appendTriangleEdges(queue, allocator, tri_idx);
        try appendTriangleEdges(queue, allocator, neighbor_idx);
        self.last_valid_tri = tri_idx;
        return true;
    }

    pub fn legalizeFromTriangles(self: *Engine, allocator: std.mem.Allocator, seed_triangles: []const i32) !void {
        try self.legalizeFromTrianglesInTransaction(allocator, seed_triangles, null);
    }

    pub fn legalizeFromTrianglesInTransaction(self: *Engine, allocator: std.mem.Allocator, seed_triangles: []const i32, tx: ?*const TriangleTransaction) !void {
        var queue: std.ArrayListUnmanaged(LegalizeEdge) = .empty;
        defer queue.deinit(allocator);

        for (seed_triangles) |tri_idx| {
            try appendTriangleEdges(&queue, allocator, tri_idx);
        }

        var iterations: usize = 0;
        const limit = @max(@as(usize, 1024), self.mesh.triangles.len * 128 + queue.items.len * 16);
        while (queue.items.len > 0) {
            if (iterations > limit) return error.CdtLegalizationDidNotConverge;
            iterations += 1;

            const edge = queue.pop().?;
            if (try self.flipEdge(&queue, allocator, tx, edge.tri, edge.side)) {
                self.statInc("edge_flips");
            }
        }
        self.statAdd("legalization_tests", iterations);
    }

    pub fn validateCdtLegality(self: *Engine) !void {
        for (0..self.mesh.triangles.len) |tri_idx| {
            const tri_i32 = @as(i32, @intCast(tri_idx));
            const tri = self.mesh.triangles.get(tri_idx);
            if (mesh.isDeadTriangle(tri) or triangleHasSuperVertex(tri)) continue;

            for (0..3) |side| {
                const neighbor_idx = triangleAdj(tri, side);
                if (neighbor_idx == -1 or neighbor_idx < tri_i32) continue;
                if (self.isConstrainedSide(tri_i32, side)) continue;
                if (self.edgeNeedsFlip(tri_i32, side)) return error.IllegalDelaunayEdge;
            }
        }
    }

    fn cavityContains(cavity: []const i32, tri_idx: i32) bool {
        for (cavity) |c_idx| {
            if (c_idx == tri_idx) return true;
        }
        return false;
    }

    fn extractCavityBoundary(self: *Engine, allocator: std.mem.Allocator, cavity: []const i32, edges: *std.ArrayListUnmanaged(Edge)) !void {
        try self.cavity_edge_counter.reset(self.allocator, cavity.len * 3);

        for (cavity) |t_idx| {
            const tri = self.mesh.triangles.get(@as(usize, @intCast(t_idx)));
            const neighbors = [_]i32{ tri.adj0, tri.adj1, tri.adj2 };
            for (neighbors, 0..) |n_idx, side| {
                const edge = triangleEdge(tri, side);
                try self.cavity_edge_counter.add(self.allocator, .{
                    .adj_tri = n_idx,
                    .v1 = edge.v1,
                    .v2 = edge.v2,
                    .old_tri = t_idx,
                });
            }
        }

        try self.cavity_edge_counter.appendBoundaryTo(allocator, edges);

        for (edges.items) |e| {
            if (e.adj_tri != -1 and cavityContains(cavity, e.adj_tri)) {
                std.debug.print("InvalidCavityBoundary: boundary edge ({d},{d}) still points into cavity tri {d}\n", .{ e.v1, e.v2, e.adj_tri });
                return error.InvalidCavityBoundary;
            }
        }
    }

    fn extractCavityBoundaryTrusted(self: *Engine, allocator: std.mem.Allocator, cavity: []const i32, edges: *std.ArrayListUnmanaged(Edge)) !bool {
        edges.clearRetainingCapacity();
        try edges.ensureTotalCapacity(allocator, cavity.len * 3);
        try self.beginBoundaryVertexGeneration(self.mesh.vertices.len);

        var pinched = false;

        for (cavity) |t_idx| {
            const tri = self.mesh.triangles.get(@as(usize, @intCast(t_idx)));
            if (mesh.isDeadTriangle(tri)) return error.InvalidCavityBoundary;

            const neighbors = [_]i32{ tri.adj0, tri.adj1, tri.adj2 };
            for (neighbors, 0..) |n_idx, side| {
                if (self.isCavityMarked(n_idx)) continue;

                const edge = triangleEdge(tri, side);
                edges.appendAssumeCapacity(.{
                    .adj_tri = n_idx,
                    .v1 = edge.v1,
                    .v2 = edge.v2,
                    .old_tri = t_idx,
                });
                pinched = self.markBoundaryVertex(edge.v1) or pinched;
                pinched = self.markBoundaryVertex(edge.v2) or pinched;
            }
        }
        return pinched;
    }

    fn pointOnTriangleEdge(self: *Engine, tri: mesh.Triangle, pt: mesh.Vertex) bool {
        const xs = self.mesh.vertices.items(.x);
        const ys = self.mesh.vertices.items(.y);
        inline for (0..3) |side| {
            const edge = triangleEdgeAt(side, tri);
            const v1: usize = @intCast(edge.v1);
            const v2: usize = @intCast(edge.v2);
            if (predicates.pointOnSegmentCoords(xs[v1], ys[v1], xs[v2], ys[v2], pt.x, pt.y)) return true;
        }
        return false;
    }

    fn ensureBoundaryVertexCounters(self: *Engine, vertex_count: usize) !void {
        if (self.boundary_vertex_marks.items.len >= vertex_count) return;

        try self.boundary_vertex_marks.ensureTotalCapacity(self.allocator, vertex_count);
        try self.boundary_vertex_counts.ensureTotalCapacity(self.allocator, vertex_count);
        while (self.boundary_vertex_marks.items.len < vertex_count) {
            try self.boundary_vertex_marks.append(self.allocator, 0);
            try self.boundary_vertex_counts.append(self.allocator, 0);
        }
    }

    fn beginBoundaryVertexGeneration(self: *Engine, vertex_count: usize) !void {
        try self.ensureBoundaryVertexCounters(vertex_count);
        self.boundary_vertex_generation +%= 1;
        if (self.boundary_vertex_generation == 0) {
            @memset(self.boundary_vertex_marks.items, 0);
            self.boundary_vertex_generation = 1;
        }
    }

    fn markBoundaryVertex(self: *Engine, vertex: i32) bool {
        const idx: usize = @intCast(vertex);
        if (self.boundary_vertex_marks.items[idx] != self.boundary_vertex_generation) {
            self.boundary_vertex_marks.items[idx] = self.boundary_vertex_generation;
            self.boundary_vertex_counts.items[idx] = 1;
            return false;
        }

        if (self.boundary_vertex_counts.items[idx] == std.math.maxInt(u8)) return true;
        self.boundary_vertex_counts.items[idx] += 1;
        return self.boundary_vertex_counts.items[idx] > 2;
    }

    fn boundaryHasPinch(self: *Engine, edges: []const Edge) !bool {
        try self.beginBoundaryVertexGeneration(self.mesh.vertices.len);

        for (edges) |edge| {
            const vertices = [_]i32{ edge.v1, edge.v2 };
            for (vertices) |vertex| {
                if (self.markBoundaryVertex(vertex)) return true;
            }
        }
        return false;
    }

    fn ensureCavityMarkCapacity(self: *Engine, triangle_count: usize) !void {
        if (self.cavity_triangle_marks.items.len >= triangle_count) return;

        try self.cavity_triangle_marks.ensureTotalCapacity(self.allocator, triangle_count);
        while (self.cavity_triangle_marks.items.len < triangle_count) {
            try self.cavity_triangle_marks.append(self.allocator, 0);
        }
    }

    fn beginCavityGeneration(self: *Engine, triangle_count: usize) !void {
        try self.ensureCavityMarkCapacity(triangle_count);
        self.cavity_triangle_generation +%= 1;
        if (self.cavity_triangle_generation == 0) {
            @memset(self.cavity_triangle_marks.items, 0);
            self.cavity_triangle_generation = 1;
        }
    }

    fn markCavityTriangle(self: *Engine, tri_idx: i32) void {
        if (tri_idx < 0) return;
        const slot: usize = @intCast(tri_idx);
        if (slot >= self.cavity_triangle_marks.items.len) return;
        self.cavity_triangle_marks.items[slot] = self.cavity_triangle_generation;
    }

    fn isCavityMarked(self: *const Engine, tri_idx: i32) bool {
        if (tri_idx < 0) return false;
        const slot: usize = @intCast(tri_idx);
        return slot < self.cavity_triangle_marks.items.len and
            self.cavity_triangle_marks.items[slot] == self.cavity_triangle_generation;
    }

    fn appendCavityTriangle(self: *Engine, allocator: std.mem.Allocator, cavity: *std.ArrayListUnmanaged(i32), tri_idx: i32) !void {
        try cavity.append(allocator, tri_idx);
        self.markCavityTriangle(tri_idx);
    }

    fn completeCavityByGlobalScan(self: *Engine, allocator: std.mem.Allocator, cavity: *std.ArrayListUnmanaged(i32), pt: mesh.Vertex) !bool {
        var added = false;
        for (0..self.mesh.triangles.len) |tri_idx| {
            const tri_i32 = @as(i32, @intCast(tri_idx));
            if (self.isCavityMarked(tri_i32)) continue;

            const tri = self.mesh.triangles.get(tri_idx);
            if (mesh.isDeadTriangle(tri)) continue;

            if (self.isInsideCircumcircle(tri_i32, pt) or self.pointOnTriangleEdge(tri, pt)) {
                try self.appendCavityTriangle(allocator, cavity, tri_i32);
                added = true;
            }
        }
        return added;
    }

    fn repairBoundaryNonManifoldEdges(self: *Engine, allocator: std.mem.Allocator, cavity: *std.ArrayListUnmanaged(i32), edges: []const Edge) !bool {
        var added = false;
        for (edges) |edge| {
            var outside_count: usize = 0;
            for (0..self.mesh.triangles.len) |tri_idx| {
                const tri_i32 = @as(i32, @intCast(tri_idx));
                if (self.isCavityMarked(tri_i32)) continue;

                const tri = self.mesh.triangles.get(tri_idx);
                if (mesh.isDeadTriangle(tri)) continue;
                if (edgeSide(tri, edge.v1, edge.v2) == null) continue;

                outside_count += 1;
                if (outside_count > 1 and !self.isCavityMarked(tri_i32)) {
                    try self.appendCavityTriangle(allocator, cavity, tri_i32);
                    added = true;
                }
            }
        }
        return added;
    }

    pub fn insertPoint(self: *Engine, arena: *mesh.ThreadArena, pt: mesh.Vertex) !i32 {
        for (0..max_transaction_attempts) |_| {
            return self.insertPointAttempt(arena, pt, true, .transactional) catch |err| {
                if (isRetryableTransactionError(err)) continue;
                return err;
            };
        }
        return error.TransactionConflict;
    }

    pub fn insertUniquePoint(self: *Engine, arena: *mesh.ThreadArena, pt: mesh.Vertex) !i32 {
        for (0..max_transaction_attempts) |_| {
            return self.insertPointAttempt(arena, pt, false, .transactional) catch |err| {
                if (isRetryableTransactionError(err)) continue;
                return err;
            };
        }
        return error.TransactionConflict;
    }

    /// Single-thread fast path for already-deduplicated input. Not safe for concurrent mesh mutation.
    pub fn insertUniquePointTrusted(self: *Engine, arena: *mesh.ThreadArena, pt: mesh.Vertex) !i32 {
        return self.insertPointAttempt(arena, pt, false, .trusted);
    }

    // Simplified Bowyer-Watson insertion for testing
    fn insertPointAttempt(self: *Engine, arena: *mesh.ThreadArena, pt: mesh.Vertex, comptime check_duplicate: bool, comptime mode: MutationMode) !i32 {
        const use_transaction = mode == .transactional;
        // Prevent duplicate or extremely close points
        if (check_duplicate) {
            var v_idx: usize = 0;
            while (v_idx < self.mesh.vertices.len) : (v_idx += 1) {
                const existing_v = self.mesh.vertices.get(v_idx);
                if (@abs(existing_v.x - pt.x) < 1e-6 and @abs(existing_v.y - pt.y) < 1e-6) {
                    return @as(i32, @intCast(v_idx));
                }
            }
        }

        const pt_idx = @as(i32, @intCast(self.mesh.vertices.len));

        const start_tri = self.hintedStartTriangle(pt);
        const container = self.walk(start_tri, pt);

        if (container < 0) {
            return error.WalkFailed;
        }

        const scratch_allocator = if (use_transaction) arena.resetScratch(self.allocator) else self.allocator;
        const temp_allocator = if (use_transaction) scratch_allocator else self.allocator;
        var local_cavity: std.ArrayListUnmanaged(i32) = .empty;
        var local_edges: std.ArrayListUnmanaged(Edge) = .empty;
        var local_new_tri_indices: std.ArrayListUnmanaged(i32) = .empty;
        var cavity = if (use_transaction) &local_cavity else &self.trusted_cavity;
        var edges = if (use_transaction) &local_edges else &self.trusted_edges;
        var new_tri_indices = if (use_transaction) &local_new_tri_indices else &self.trusted_new_tri_indices;
        cavity.clearRetainingCapacity();
        edges.clearRetainingCapacity();
        new_tri_indices.clearRetainingCapacity();
        if (!use_transaction) try self.beginTrustedSpokes(self.mesh.vertices.len + 1);
        try self.beginCavityGeneration(self.mesh.triangles.len);

        try self.appendCavityTriangle(temp_allocator, cavity, container);

        const cavity_xs = self.mesh.vertices.items(.x);
        const cavity_ys = self.mesh.vertices.items(.y);
        var i: usize = 0;
        while (i < cavity.items.len) : (i += 1) {
            const t_idx = cavity.items[i];
            const tri = self.mesh.triangles.get(@as(usize, @intCast(t_idx)));
            inline for (0..3) |side| {
                const n_idx = triangleAdjAt(side, tri);
                if (!self.isCavityMarked(n_idx)) {
                    const edge = triangleEdgeAt(side, tri);
                    const inside_circumcircle = self.isInsideCircumcircleWithCoords(cavity_xs, cavity_ys, n_idx, pt);
                    const v1: usize = @intCast(edge.v1);
                    const v2: usize = @intCast(edge.v2);
                    const point_on_edge = !inside_circumcircle and n_idx != -1 and predicates.pointOnSegmentCoords(cavity_xs[v1], cavity_ys[v1], cavity_xs[v2], cavity_ys[v2], pt.x, pt.y);

                    if (inside_circumcircle or point_on_edge) {
                        try self.appendCavityTriangle(temp_allocator, cavity, n_idx);
                    }
                }
            }
        }

        while (true) {
            var trusted_boundary_pinched = false;
            if (use_transaction) {
                try self.extractCavityBoundary(temp_allocator, cavity.items, edges);
            } else {
                trusted_boundary_pinched = try self.extractCavityBoundaryTrusted(temp_allocator, cavity.items, edges);
            }

            if (use_transaction) {
                if (try self.repairBoundaryNonManifoldEdges(scratch_allocator, cavity, edges.items)) {
                    continue;
                }

                if (try self.boundaryHasPinch(edges.items)) {
                    const repaired = try self.completeCavityByGlobalScan(scratch_allocator, cavity, pt);
                    if (!repaired) {
                        std.debug.print("InvalidCavityBoundary: pinched boundary could not be repaired for point {d},{d}\n", .{ pt.x, pt.y });
                        return error.InvalidCavityBoundary;
                    }
                    continue;
                }
            } else if (trusted_boundary_pinched) {
                if (try self.repairBoundaryNonManifoldEdges(temp_allocator, cavity, edges.items)) {
                    continue;
                }
                const repaired = try self.completeCavityByGlobalScan(temp_allocator, cavity, pt);
                if (!repaired) {
                    std.debug.print("InvalidCavityBoundary: trusted pinched boundary could not be repaired for point {d},{d}\n", .{ pt.x, pt.y });
                    return error.InvalidCavityBoundary;
                }
                continue;
            }

            break;
        }

        self.statInc("inserted_points");
        self.statAdd("cavity_triangles", @intCast(cavity.items.len));
        self.statAdd("cavity_edges", @intCast(edges.items.len));
        self.statMax("cavity_max_triangles", @intCast(cavity.items.len));
        self.statMax("cavity_max_edges", @intCast(edges.items.len));

        var tx = TriangleTransaction{};
        var tx_started = false;
        errdefer if (tx_started) self.endTriangleTransaction(&tx);
        if (use_transaction) {
            var footprint: std.ArrayListUnmanaged(i32) = .empty;
            try self.collectCavityTransactionFootprint(scratch_allocator, cavity.items, edges.items, &footprint);

            var expected_versions: std.ArrayListUnmanaged(TriangleVersionSnapshot) = .empty;
            if (!try self.snapshotTransactionFootprint(scratch_allocator, footprint.items, &expected_versions)) return error.TransactionConflict;

            if (!try self.beginTriangleTransactionWithVersions(scratch_allocator, footprint.items, expected_versions.items, &tx)) return error.TransactionConflict;
            tx_started = true;
        }

        const reused_cavity_count = @min(edges.items.len, cavity.items.len);
        const needed_after_cavity = edges.items.len - reused_cavity_count;
        const reused_freelist_count = @min(needed_after_cavity, arena.freelist.items.len);
        const appended_triangle_count = needed_after_cavity - reused_freelist_count;
        const leftover_cavity_count = cavity.items.len - reused_cavity_count;

        try new_tri_indices.ensureTotalCapacity(temp_allocator, edges.items.len);
        for (0..reused_cavity_count) |edge_i| {
            new_tri_indices.appendAssumeCapacity(cavity.items[cavity.items.len - 1 - edge_i]);
        }
        for (0..reused_freelist_count) |free_i| {
            new_tri_indices.appendAssumeCapacity(arena.freelist.items[arena.freelist.items.len - 1 - free_i]);
        }
        for (0..appended_triangle_count) |append_i| {
            new_tri_indices.appendAssumeCapacity(@as(i32, @intCast(self.mesh.triangles.len + append_i)));
        }

        if (use_transaction) {
            try self.mesh.vertices.ensureUnusedCapacity(self.allocator, 1);
            try self.mesh.ensureTriangleCapacity(self.allocator, self.mesh.triangles.len + appended_triangle_count);
            try arena.freelist.ensureUnusedCapacity(self.allocator, leftover_cavity_count);
        } else {
            if (self.mesh.vertices.len + 1 > self.mesh.vertices.capacity) {
                try self.mesh.vertices.ensureUnusedCapacity(self.allocator, 1);
            }
            if (self.mesh.triangles.len + appended_triangle_count > self.mesh.triangles.capacity) {
                try self.mesh.ensureTriangleCapacity(self.allocator, self.mesh.triangles.len + appended_triangle_count);
            }
            if (arena.freelist.items.len + leftover_cavity_count > arena.freelist.capacity) {
                try arena.freelist.ensureUnusedCapacity(self.allocator, leftover_cavity_count);
            }
        }

        if (self.vertex_hint_tri.items.len < self.mesh.vertices.len + 1) {
            try self.ensureVertexMetadataCapacity(self.mesh.vertices.len + 1);
        }
        try self.mesh.vertices.append(self.allocator, pt);

        // Tombstone cavity slots after all allocations that can fail have succeeded.
        for (cavity.items, 0..) |t_idx, cavity_i| {
            if (use_transaction) {
                self.mesh.markDead(t_idx);
            } else {
                self.mesh.markDeadTrusted(t_idx);
            }
            if (cavity_i < leftover_cavity_count) {
                try arena.tombstone(self.allocator, t_idx);
            }
        }
        for (0..reused_freelist_count) |_| {
            _ = arena.getFreeSlot().?;
        }
        if (use_transaction) {
            for (0..appended_triangle_count) |append_i| {
                try self.mesh.ensureTriangleSlot(self.allocator, new_tri_indices.items[reused_cavity_count + reused_freelist_count + append_i]);
            }
        } else {
            try self.mesh.appendDeadTriangleSlotsTrusted(self.allocator, appended_triangle_count);
        }

        // Setup the new triangles and link them
        const emit_xs = self.mesh.vertices.items(.x);
        const emit_ys = self.mesh.vertices.items(.y);
        for (edges.items, 0..) |e, edge_i| {
            const t_idx = new_tri_indices.items[edge_i];
            self.last_valid_tri = t_idx;

            var a = e.v1;
            var b = e.v2;
            if (predicates.orient2dCoords(emit_xs[@as(usize, @intCast(a))], emit_ys[@as(usize, @intCast(a))], emit_xs[@as(usize, @intCast(b))], emit_ys[@as(usize, @intCast(b))], pt.x, pt.y) < 0.0) {
                const tmp = a;
                a = b;
                b = tmp;
            }

            const new_tri = mesh.Triangle{
                .v0 = a,
                .v1 = b,
                .v2 = pt_idx,
                .adj0 = -1,
                .adj1 = -1,
                .adj2 = -1,
            };
            if (use_transaction) {
                self.mesh.setTriangleFresh(t_idx, new_tri);
            } else {
                self.mesh.setTriangleFreshTrusted(t_idx, new_tri);
            }
            self.updateTriangleCircumcircle(t_idx, new_tri);
            if (@as(usize, @intCast(pt_idx)) < self.vertex_hint_tri.items.len) {
                self.vertex_hint_tri.items[@as(usize, @intCast(pt_idx))] = t_idx;
            }
            self.updateHintForPoint(.{ .x = emit_xs[@as(usize, @intCast(a))], .y = emit_ys[@as(usize, @intCast(a))] }, t_idx);
            self.updateHintForPoint(.{ .x = emit_xs[@as(usize, @intCast(b))], .y = emit_ys[@as(usize, @intCast(b))] }, t_idx);
            self.updateHintForPoint(pt, t_idx);

            if (e.adj_tri != -1) {
                if (use_transaction) {
                    try self.linkTrianglesByEdge(t_idx, e.adj_tri, e.v1, e.v2);
                } else {
                    try self.linkBoundaryNeighborTrusted(t_idx, 0, e.adj_tri, e.v1, e.v2);
                }
            }
            if (!use_transaction) {
                try self.addTrustedSpoke(a, t_idx, 2);
                try self.addTrustedSpoke(b, t_idx, 1);
            }
        }
        if (use_transaction) {
            try self.linkNewTriangles(new_tri_indices.items);
        }
        if (tx_started) {
            self.endTriangleTransaction(&tx);
            tx_started = false;
        }
        return pt_idx;
    }
};

test "cavity building" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    var arena = mesh.ThreadArena{};
    defer arena.deinit(std.testing.allocator);

    const vertices = [_]mesh.Vertex{
        .{ .x = 10.0, .y = 10.0 },
        .{ .x = 20.0, .y = 20.0 },
    };

    try engine.initSuperTriangle(&vertices);

    // Insert a point
    _ = try engine.insertPoint(&arena, mesh.Vertex{ .x = 15.0, .y = 15.0 });

    // The super triangle was tombstoned and replaced by 3 new triangles connecting to the new point
    try std.testing.expectEqual(0, arena.freelist.items.len);
    try std.testing.expectEqual(3, engine.mesh.triangles.len);

    // Let's also insert another point and verify
    _ = try engine.insertPoint(&arena, mesh.Vertex{ .x = 14.0, .y = 16.0 });
    try engine.validateTopology();
}

test "insert point walk failure does not append vertex" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    var arena = mesh.ThreadArena{};
    defer arena.deinit(std.testing.allocator);

    const before_vertices = engine.mesh.vertices.len;
    try std.testing.expectError(error.WalkFailed, engine.insertPoint(&arena, mesh.Vertex{ .x = 1.0, .y = 1.0 }));
    try std.testing.expectEqual(before_vertices, engine.mesh.vertices.len);
}

test "insert point transaction conflict does not append vertex" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    var arena = mesh.ThreadArena{};
    defer arena.deinit(std.testing.allocator);

    const vertices = [_]mesh.Vertex{
        .{ .x = 10.0, .y = 10.0 },
        .{ .x = 20.0, .y = 20.0 },
    };
    try engine.initSuperTriangle(&vertices);

    var tx = TriangleTransaction{};
    defer tx.deinit(std.testing.allocator);
    const requested = [_]i32{0};
    try std.testing.expect(try engine.beginTriangleTransaction(std.testing.allocator, &requested, &tx));
    defer engine.endTriangleTransaction(&tx);

    const before_vertices = engine.mesh.vertices.len;
    try std.testing.expectError(error.TransactionConflict, engine.insertPoint(&arena, mesh.Vertex{ .x = 15.0, .y = 15.0 }));
    try std.testing.expectEqual(before_vertices, engine.mesh.vertices.len);
}

test "duplicate point insertion returns existing vertex" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    var arena = mesh.ThreadArena{};
    defer arena.deinit(std.testing.allocator);

    const vertices = [_]mesh.Vertex{
        .{ .x = 10.0, .y = 10.0 },
        .{ .x = 20.0, .y = 20.0 },
    };
    try engine.initSuperTriangle(&vertices);

    const pt = mesh.Vertex{ .x = 15.0, .y = 15.0 };
    const first = try engine.insertPoint(&arena, pt);
    const before_vertices = engine.mesh.vertices.len;
    const second = try engine.insertPoint(&arena, pt);

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(before_vertices, engine.mesh.vertices.len);
}

test "trusted point insertion wires reciprocal adjacency" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    var arena = mesh.ThreadArena{};
    defer arena.deinit(std.testing.allocator);

    const vertices = [_]mesh.Vertex{
        .{ .x = 10.0, .y = 10.0 },
        .{ .x = 20.0, .y = 20.0 },
        .{ .x = 14.0, .y = 16.0 },
    };
    try engine.reserveForPointCount(vertices.len);
    try engine.initSuperTriangle(&vertices);

    _ = try engine.insertUniquePointTrusted(&arena, vertices[0]);
    _ = try engine.insertUniquePointTrusted(&arena, vertices[1]);
    _ = try engine.insertUniquePointTrusted(&arena, vertices[2]);

    try engine.validateTopology();
    try engine.validateCdtLegality();

    var scanned_live_count: usize = 0;
    for (0..engine.mesh.triangles.len) |tri_idx| {
        if (!mesh.isDeadTriangle(engine.mesh.triangles.get(tri_idx))) scanned_live_count += 1;
    }
    try std.testing.expectEqual(scanned_live_count, engine.liveTriangleCount());
}

test "fast live edge lookup falls back from stale hint" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    var arena = mesh.ThreadArena{};
    defer arena.deinit(std.testing.allocator);

    const vertices = [_]mesh.Vertex{
        .{ .x = 10.0, .y = 10.0 },
        .{ .x = 20.0, .y = 20.0 },
        .{ .x = 14.0, .y = 16.0 },
    };
    try engine.reserveForPointCount(vertices.len);
    try engine.initSuperTriangle(&vertices);

    const a = try engine.insertUniquePointTrusted(&arena, vertices[0]);
    const b = try engine.insertUniquePointTrusted(&arena, vertices[1]);
    _ = try engine.insertUniquePointTrusted(&arena, vertices[2]);

    const expected = engine.findLiveEdge(a, b).?;
    engine.vertex_hint_tri.items[@as(usize, @intCast(a))] = -1;
    const found = engine.findLiveEdgeFast(a, b).?;

    try std.testing.expectEqual(expected.tri, found.tri);
    try std.testing.expectEqual(expected.side, found.side);
    try std.testing.expect(engine.vertex_hint_tri.items[@as(usize, @intCast(a))] >= 0);
}

test "trusted found edge marking keeps reciprocal flags" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    var arena = mesh.ThreadArena{};
    defer arena.deinit(std.testing.allocator);

    const vertices = [_]mesh.Vertex{
        .{ .x = 10.0, .y = 10.0 },
        .{ .x = 20.0, .y = 20.0 },
        .{ .x = 14.0, .y = 16.0 },
    };
    try engine.reserveForPointCount(vertices.len);
    try engine.initSuperTriangle(&vertices);

    const a = try engine.insertUniquePointTrusted(&arena, vertices[0]);
    const b = try engine.insertUniquePointTrusted(&arena, vertices[1]);
    _ = try engine.insertUniquePointTrusted(&arena, vertices[2]);

    const found = engine.findLiveEdgeFast(a, b).?;
    engine.setConstrainedFoundEdgeTrusted(found, true);

    try std.testing.expect(engine.isConstrainedSide(found.tri, found.side));
    try engine.validateConstraintFlags();
}

test "cavity edge counter keeps only once-used boundary edges" {
    var counter = CavityEdgeCounter{};
    defer counter.deinit(std.testing.allocator);

    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    defer edges.deinit(std.testing.allocator);

    try counter.reset(std.testing.allocator, 3);
    try counter.add(std.testing.allocator, .{ .adj_tri = 10, .v1 = 1, .v2 = 2, .old_tri = 0 });
    try counter.add(std.testing.allocator, .{ .adj_tri = 11, .v1 = 2, .v2 = 1, .old_tri = 1 });
    try counter.add(std.testing.allocator, .{ .adj_tri = 12, .v1 = 2, .v2 = 3, .old_tri = 2 });

    try counter.appendBoundaryTo(std.testing.allocator, &edges);

    try std.testing.expectEqual(@as(usize, 1), edges.items.len);
    try std.testing.expectEqual(@as(i32, 2), edges.items[0].v1);
    try std.testing.expectEqual(@as(i32, 3), edges.items[0].v2);
}

fn initIllegalQuad(engine: *Engine) !struct { a: i32, b: i32, c: i32, d: i32 } {
    const allocator = std.testing.allocator;
    try engine.mesh.vertices.append(allocator, .{ .x = -100.0, .y = -100.0 });
    try engine.mesh.vertices.append(allocator, .{ .x = 0.0, .y = 100.0 });
    try engine.mesh.vertices.append(allocator, .{ .x = 100.0, .y = -100.0 });
    try engine.mesh.vertices.append(allocator, .{ .x = 0.0, .y = 0.0 });
    try engine.mesh.vertices.append(allocator, .{ .x = 1.0, .y = 0.0 });
    try engine.mesh.vertices.append(allocator, .{ .x = 0.0, .y = 1.0 });
    try engine.mesh.vertices.append(allocator, .{ .x = 0.5, .y = -0.1 });

    try engine.mesh.appendTriangle(allocator, .{
        .v0 = 3,
        .v1 = 4,
        .v2 = 5,
        .adj0 = 1,
        .adj1 = -1,
        .adj2 = -1,
    });
    try engine.mesh.appendTriangle(allocator, .{
        .v0 = 4,
        .v1 = 3,
        .v2 = 6,
        .adj0 = 0,
        .adj1 = -1,
        .adj2 = -1,
    });
    return .{ .a = 3, .b = 4, .c = 5, .d = 6 };
}

test "cavity transaction footprint includes cavity and live boundary neighbors" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    _ = try initIllegalQuad(&engine);

    var footprint: std.ArrayListUnmanaged(i32) = .empty;
    defer footprint.deinit(std.testing.allocator);

    const cavity = [_]i32{0};
    const edges = [_]Edge{
        .{ .adj_tri = 1, .v1 = 3, .v2 = 4, .old_tri = 0 },
        .{ .adj_tri = -1, .v1 = 4, .v2 = 5, .old_tri = 0 },
        .{ .adj_tri = 1, .v1 = 5, .v2 = 3, .old_tri = 0 },
        .{ .adj_tri = 99, .v1 = 5, .v2 = 6, .old_tri = 0 },
    };

    try engine.collectCavityTransactionFootprint(std.testing.allocator, &cavity, &edges, &footprint);

    try std.testing.expectEqual(@as(usize, 2), footprint.items.len);
    try std.testing.expectEqual(@as(i32, 0), footprint.items[0]);
    try std.testing.expectEqual(@as(i32, 1), footprint.items[1]);
}

test "edge flags are reciprocal sidecar metadata" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    const quad = try initIllegalQuad(&engine);
    try engine.validateTopology();
    try std.testing.expect(try engine.setConstrainedEdgeByVertices(quad.a, quad.b, true));

    const found = engine.findLiveEdge(quad.a, quad.b).?;
    try std.testing.expect(engine.isConstrainedSide(found.tri, found.side));
    try engine.validateConstraintFlags();
}

test "triangle version snapshots detect metadata and topology mutation" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    const quad = try initIllegalQuad(&engine);
    var snapshots = [_]TriangleVersionSnapshot{
        engine.snapshotTriangleVersion(0),
        engine.snapshotTriangleVersion(1),
    };
    try std.testing.expect(engine.validateTriangleVersions(&snapshots));

    try std.testing.expect(try engine.setConstrainedEdgeByVertices(quad.a, quad.b, true));
    try std.testing.expect(!engine.validateTriangleVersions(&snapshots));

    snapshots = [_]TriangleVersionSnapshot{
        engine.snapshotTriangleVersion(0),
        engine.snapshotTriangleVersion(1),
    };
    try engine.mesh.ensureTriangleSlot(std.testing.allocator, 2);
    engine.mesh.setTriangleFresh(2, .{ .v0 = 3, .v1 = 5, .v2 = 6, .adj0 = -1, .adj1 = -1, .adj2 = -1 });
    try std.testing.expect(engine.validateTriangleVersions(&snapshots));

    engine.mesh.markDead(0);
    try std.testing.expect(!engine.validateTriangleVersions(&snapshots));
}

test "triangle transactions lock in sorted unique order" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    _ = try initIllegalQuad(&engine);

    var tx = TriangleTransaction{};
    defer tx.deinit(std.testing.allocator);

    const requested = [_]i32{ 1, 0, 1 };
    try std.testing.expect(try engine.beginTriangleTransaction(std.testing.allocator, &requested, &tx));
    defer engine.endTriangleTransaction(&tx);

    try std.testing.expectEqual(@as(usize, 2), tx.locked.items.len);
    try std.testing.expectEqual(@as(i32, 0), tx.locked.items[0]);
    try std.testing.expectEqual(@as(i32, 1), tx.locked.items[1]);
    try std.testing.expect(engine.isTriangleLocked(0));
    try std.testing.expect(engine.isTriangleLocked(1));
    try std.testing.expect(engine.revalidateTriangleTransaction(&tx));
}

test "triangle transactions fail cleanly on lock conflict" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    _ = try initIllegalQuad(&engine);

    var tx1 = TriangleTransaction{};
    defer tx1.deinit(std.testing.allocator);
    var tx2 = TriangleTransaction{};
    defer tx2.deinit(std.testing.allocator);

    const requested = [_]i32{ 0, 1 };
    try std.testing.expect(try engine.beginTriangleTransaction(std.testing.allocator, &requested, &tx1));
    try std.testing.expect(!try engine.beginTriangleTransaction(std.testing.allocator, &requested, &tx2));
    try std.testing.expectEqual(@as(usize, 0), tx2.locked.items.len);
    try std.testing.expect(engine.isTriangleLocked(0));
    try std.testing.expect(engine.isTriangleLocked(1));

    engine.endTriangleTransaction(&tx1);
    try std.testing.expect(!engine.isTriangleLocked(0));
    try std.testing.expect(!engine.isTriangleLocked(1));
}

test "triangle transaction revalidation detects mutation" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    const quad = try initIllegalQuad(&engine);

    var tx = TriangleTransaction{};
    defer tx.deinit(std.testing.allocator);

    const requested = [_]i32{ 0, 1 };
    try std.testing.expect(try engine.beginTriangleTransaction(std.testing.allocator, &requested, &tx));

    try std.testing.expect(engine.revalidateTriangleTransaction(&tx));
    try std.testing.expect(try engine.setConstrainedEdgeByVertices(quad.a, quad.b, true));
    try std.testing.expect(!engine.revalidateTriangleTransaction(&tx));

    engine.endTriangleTransaction(&tx);
    try std.testing.expect(!engine.isTriangleLocked(0));
    try std.testing.expect(!engine.isTriangleLocked(1));
}

test "triangle transactions reject stale expected versions" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    const quad = try initIllegalQuad(&engine);

    const requested = [_]i32{ 0, 1 };
    var expected_versions: std.ArrayListUnmanaged(TriangleVersionSnapshot) = .empty;
    defer expected_versions.deinit(std.testing.allocator);
    try std.testing.expect(try engine.snapshotTransactionFootprint(std.testing.allocator, &requested, &expected_versions));

    try std.testing.expect(try engine.setConstrainedEdgeByVertices(quad.a, quad.b, true));

    var tx = TriangleTransaction{};
    defer tx.deinit(std.testing.allocator);
    try std.testing.expect(!try engine.beginTriangleTransactionWithVersions(std.testing.allocator, &requested, expected_versions.items, &tx));
    try std.testing.expectEqual(@as(usize, 0), tx.locked.items.len);
    try std.testing.expect(!engine.isTriangleLocked(0));
    try std.testing.expect(!engine.isTriangleLocked(1));
}

test "legalizer flips an illegal unconstrained quad edge" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    const quad = try initIllegalQuad(&engine);
    const seeds = [_]i32{ 0, 1 };
    try engine.legalizeFromTriangles(std.testing.allocator, &seeds);

    try engine.validateTopology();
    try engine.validateConstraintFlags();
    try engine.validateCdtLegality();
    try std.testing.expect(!engine.hasLiveEdge(quad.a, quad.b));
    try std.testing.expect(engine.hasLiveEdge(quad.c, quad.d));
}

test "transactional legalizer rejects unlocked flip footprint" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    _ = try initIllegalQuad(&engine);

    var tx = TriangleTransaction{};
    defer tx.deinit(std.testing.allocator);

    const requested = [_]i32{0};
    try std.testing.expect(try engine.beginTriangleTransaction(std.testing.allocator, &requested, &tx));
    defer engine.endTriangleTransaction(&tx);

    const seeds = [_]i32{0};
    try std.testing.expectError(error.TransactionFootprintExpansionRequired, engine.legalizeFromTrianglesInTransaction(std.testing.allocator, &seeds, &tx));
}

test "legalizer skips constrained illegal edges" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    const quad = try initIllegalQuad(&engine);
    try std.testing.expect(try engine.setConstrainedEdgeByVertices(quad.a, quad.b, true));

    const seeds = [_]i32{ 0, 1 };
    try engine.legalizeFromTriangles(std.testing.allocator, &seeds);

    try engine.validateTopology();
    try engine.validateConstraintFlags();
    try std.testing.expect(engine.hasLiveEdge(quad.a, quad.b));
    try engine.validateConstraintRingFlags(&[_]i32{ quad.a, quad.b });
}
