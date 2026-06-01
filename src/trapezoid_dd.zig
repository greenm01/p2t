const std = @import("std");
const build_options = @import("build_options");
const mesh = @import("mesh.zig");
const polygon_seed = @import("polygon_seed.zig");
const predicates = @import("predicates.zig");
const triangulate = @import("triangulate.zig");

const eps = 1e-9;

pub const Piece = struct {
    start: usize,
    len: usize,
};

pub const Stats = struct {
    pieces: usize = 0,
    diagonals: usize = 0,
    max_piece_vertices: usize = 0,
    total_piece_vertices: usize = 0,
    split_candidates: u64 = 0,
    midpoint_scans: u64 = 0,
    edge_scans: u64 = 0,
    aabb_rejects: u64 = 0,
    cone_rejects: u64 = 0,
    accepted_diagonals: u64 = 0,
    failed_splits: u64 = 0,
};

const Diagnostics = struct {
    split_candidates: u64 = 0,
    midpoint_scans: u64 = 0,
    edge_scans: u64 = 0,
    aabb_rejects: u64 = 0,
    cone_rejects: u64 = 0,
    accepted_diagonals: u64 = 0,
    failed_splits: u64 = 0,

    inline fn inc(self: *Diagnostics, comptime field: []const u8) void {
        if (build_options.instrument_mesh_stats) @field(self, field) += 1;
    }

    inline fn add(self: *Diagnostics, comptime field: []const u8, value: u64) void {
        if (build_options.instrument_mesh_stats) @field(self, field) += value;
    }
};

pub const Decomposition = struct {
    rings: std.ArrayListUnmanaged(i32) = .empty,
    pieces: std.ArrayListUnmanaged(Piece) = .empty,
    diagonals: std.ArrayListUnmanaged(polygon_seed.Segment) = .empty,
    diagnostics: Diagnostics = .{},

    pub fn deinit(self: *Decomposition, allocator: std.mem.Allocator) void {
        self.diagonals.deinit(allocator);
        self.pieces.deinit(allocator);
        self.rings.deinit(allocator);
    }

    pub fn clearRetainingCapacity(self: *Decomposition) void {
        self.rings.clearRetainingCapacity();
        self.pieces.clearRetainingCapacity();
        self.diagonals.clearRetainingCapacity();
        self.diagnostics = .{};
    }

    pub fn stats(self: *const Decomposition) Stats {
        var out = Stats{
            .pieces = self.pieces.items.len,
            .diagonals = self.diagonals.items.len,
            .split_candidates = self.diagnostics.split_candidates,
            .midpoint_scans = self.diagnostics.midpoint_scans,
            .edge_scans = self.diagnostics.edge_scans,
            .aabb_rejects = self.diagnostics.aabb_rejects,
            .cone_rejects = self.diagnostics.cone_rejects,
            .accepted_diagonals = self.diagnostics.accepted_diagonals,
            .failed_splits = self.diagnostics.failed_splits,
        };
        for (self.pieces.items) |piece| {
            out.total_piece_vertices += piece.len;
            out.max_piece_vertices = @max(out.max_piece_vertices, piece.len);
        }
        return out;
    }
};

const WorkRing = struct {
    start: usize,
    len: usize,
};

fn polygonArea(vertices: []const mesh.Vertex) f64 {
    var sum: f64 = 0.0;
    for (vertices, 0..) |a, i| {
        const b = vertices[(i + 1) % vertices.len];
        sum += a.x * b.y - a.y * b.x;
    }
    return sum * 0.5;
}

fn orient(a: mesh.Vertex, b: mesh.Vertex, c: mesh.Vertex) f64 {
    return predicates.orient2d(a, b, c);
}

fn pointOnSegment(a: mesh.Vertex, b: mesh.Vertex, p: mesh.Vertex) bool {
    if (p.x < @min(a.x, b.x) - eps or p.x > @max(a.x, b.x) + eps) return false;
    if (p.y < @min(a.y, b.y) - eps or p.y > @max(a.y, b.y) + eps) return false;
    return @abs(orient(a, b, p)) <= eps;
}

fn segmentsTouchOrCross(a: mesh.Vertex, b: mesh.Vertex, c: mesh.Vertex, d: mesh.Vertex) bool {
    const o1 = orient(a, b, c);
    const o2 = orient(a, b, d);
    const o3 = orient(c, d, a);
    const o4 = orient(c, d, b);
    if (o1 * o2 < 0.0 and o3 * o4 < 0.0) return true;
    if (@abs(o1) <= eps and pointOnSegment(a, b, c)) return true;
    if (@abs(o2) <= eps and pointOnSegment(a, b, d)) return true;
    if (@abs(o3) <= eps and pointOnSegment(c, d, a)) return true;
    if (@abs(o4) <= eps and pointOnSegment(c, d, b)) return true;
    return false;
}

fn pointInRing(vertices: []const mesh.Vertex, ring: []const i32, p: mesh.Vertex, diagnostics: *Diagnostics) bool {
    var inside = false;
    var j = ring.len - 1;
    for (0..ring.len) |i| {
        diagnostics.inc("midpoint_scans");
        const vi = vertices[@as(usize, @intCast(ring[i]))];
        const vj = vertices[@as(usize, @intCast(ring[j]))];
        if (pointOnSegment(vj, vi, p)) return true;
        if ((vi.y > p.y) != (vj.y > p.y)) {
            const x_intersect = (vj.x - vi.x) * (p.y - vi.y) / (vj.y - vi.y) + vi.x;
            if (p.x < x_intersect) inside = !inside;
        }
        j = i;
    }
    return inside;
}

fn ringDistanceForward(len: usize, i: usize, j: usize) usize {
    return if (j >= i) j - i else len - i + j;
}

fn areAdjacent(len: usize, i: usize, j: usize) bool {
    const dist = ringDistanceForward(len, i, j);
    return dist == 1 or dist + 1 == len;
}

fn bboxDisjoint(a: mesh.Vertex, b: mesh.Vertex, c: mesh.Vertex, d: mesh.Vertex) bool {
    return @max(a.x, b.x) < @min(c.x, d.x) - eps or
        @max(c.x, d.x) < @min(a.x, b.x) - eps or
        @max(a.y, b.y) < @min(c.y, d.y) - eps or
        @max(c.y, d.y) < @min(a.y, b.y) - eps;
}

fn locallyVisibleFrom(vertices: []const mesh.Vertex, ring: []const i32, vertex_pos: usize, target_pos: usize) bool {
    const prev_pos = if (vertex_pos == 0) ring.len - 1 else vertex_pos - 1;
    const next_pos = (vertex_pos + 1) % ring.len;
    const prev = vertices[@as(usize, @intCast(ring[prev_pos]))];
    const curr = vertices[@as(usize, @intCast(ring[vertex_pos]))];
    const next = vertices[@as(usize, @intCast(ring[next_pos]))];
    const target = vertices[@as(usize, @intCast(ring[target_pos]))];

    const turn = orient(prev, curr, next);
    const left_next = orient(curr, next, target);
    const left_prev = orient(prev, curr, target);
    if (turn >= -eps) {
        return left_next >= -eps and left_prev >= -eps;
    }
    return !(left_next < -eps and left_prev < -eps);
}

fn visibleDiagonal(vertices: []const mesh.Vertex, ring: []const i32, i: usize, j: usize, diagnostics: *Diagnostics) bool {
    if (i == j or areAdjacent(ring.len, i, j)) return false;
    diagnostics.inc("split_candidates");

    if (build_options.decomposition_fast_visible and (!locallyVisibleFrom(vertices, ring, i, j) or !locallyVisibleFrom(vertices, ring, j, i))) {
        diagnostics.inc("cone_rejects");
        return false;
    }

    const a_idx = ring[i];
    const b_idx = ring[j];
    const a = vertices[@as(usize, @intCast(a_idx))];
    const b = vertices[@as(usize, @intCast(b_idx))];
    const mid = mesh.Vertex{ .x = (a.x + b.x) * 0.5, .y = (a.y + b.y) * 0.5 };
    if (!pointInRing(vertices, ring, mid, diagnostics)) return false;

    for (0..ring.len) |k| {
        const next = (k + 1) % ring.len;
        const c_idx = ring[k];
        const d_idx = ring[next];
        if (c_idx == a_idx or c_idx == b_idx or d_idx == a_idx or d_idx == b_idx) continue;
        const c = vertices[@as(usize, @intCast(c_idx))];
        const d = vertices[@as(usize, @intCast(d_idx))];
        if (build_options.decomposition_fast_visible and bboxDisjoint(a, b, c, d)) {
            diagnostics.inc("aabb_rejects");
            continue;
        }
        diagnostics.inc("edge_scans");
        if (segmentsTouchOrCross(a, b, c, d)) return false;
    }

    diagnostics.inc("accepted_diagonals");
    return true;
}

fn findSplitDiagonal(vertices: []const mesh.Vertex, ring: []const i32, diagnostics: *Diagnostics) ?struct { i: usize, j: usize } {
    if (ring.len <= 6) return null;

    const i_stride = @max(@as(usize, 1), ring.len / 64);
    const half = ring.len / 2;
    const offsets = [_]isize{ 0, -1, 1, -4, 4, -8, 8, -16, 16, -32, 32 };

    var i: usize = 0;
    while (i < ring.len) : (i += i_stride) {
        for (offsets) |offset| {
            const raw = @as(isize, @intCast(i + half)) + offset;
            const wrapped = @mod(raw, @as(isize, @intCast(ring.len)));
            const j: usize = @intCast(wrapped);
            if (i == j or areAdjacent(ring.len, i, j)) continue;
            if (!visibleDiagonal(vertices, ring, i, j, diagnostics)) continue;
            return .{ .i = i, .j = j };
        }
    }

    diagnostics.inc("failed_splits");
    return null;
}

fn appendRing(storage: *std.ArrayListUnmanaged(i32), allocator: std.mem.Allocator, ring: []const i32) !WorkRing {
    const start = storage.items.len;
    try storage.appendSlice(allocator, ring);
    return .{ .start = start, .len = ring.len };
}

fn appendForwardSlice(out: *std.ArrayListUnmanaged(i32), allocator: std.mem.Allocator, ring: []const i32, start: usize, end_inclusive: usize) !void {
    var pos = start;
    while (true) {
        try out.append(allocator, ring[pos]);
        if (pos == end_inclusive) break;
        pos = (pos + 1) % ring.len;
    }
}

pub fn decomposeSimple(allocator: std.mem.Allocator, vertices: []const mesh.Vertex, max_piece_vertices: usize, out: *Decomposition) !void {
    out.clearRetainingCapacity();
    if (vertices.len < 3) return error.InvalidTriangleVertex;

    var work_storage: std.ArrayListUnmanaged(i32) = .empty;
    defer work_storage.deinit(allocator);
    var work: std.ArrayListUnmanaged(WorkRing) = .empty;
    defer work.deinit(allocator);
    var child_a: std.ArrayListUnmanaged(i32) = .empty;
    defer child_a.deinit(allocator);
    var child_b: std.ArrayListUnmanaged(i32) = .empty;
    defer child_b.deinit(allocator);

    const ccw = polygonArea(vertices) > 0.0;
    const initial_start = work_storage.items.len;
    try work_storage.ensureUnusedCapacity(allocator, vertices.len);
    for (0..vertices.len) |i| {
        const idx = if (ccw) i else vertices.len - 1 - i;
        work_storage.appendAssumeCapacity(@intCast(idx));
    }
    try work.append(allocator, .{ .start = initial_start, .len = vertices.len });

    while (work.items.len > 0) {
        const item = work.pop().?;
        const ring = work_storage.items[item.start .. item.start + item.len];
        if (ring.len <= max_piece_vertices) {
            const start = out.rings.items.len;
            try out.rings.appendSlice(allocator, ring);
            try out.pieces.append(allocator, .{ .start = start, .len = ring.len });
            continue;
        }

        const split = findSplitDiagonal(vertices, ring, &out.diagnostics) orelse {
            const start = out.rings.items.len;
            try out.rings.appendSlice(allocator, ring);
            try out.pieces.append(allocator, .{ .start = start, .len = ring.len });
            continue;
        };

        child_a.clearRetainingCapacity();
        child_b.clearRetainingCapacity();
        try appendForwardSlice(&child_a, allocator, ring, split.i, split.j);
        try appendForwardSlice(&child_b, allocator, ring, split.j, split.i);
        if (child_a.items.len < 3 or child_b.items.len < 3) {
            const start = out.rings.items.len;
            try out.rings.appendSlice(allocator, ring);
            try out.pieces.append(allocator, .{ .start = start, .len = ring.len });
            continue;
        }

        try out.diagonals.append(allocator, .{ .a = ring[split.i], .b = ring[split.j] });
        try work.append(allocator, try appendRing(&work_storage, allocator, child_a.items));
        try work.append(allocator, try appendRing(&work_storage, allocator, child_b.items));
    }
}

test "trapezoid decomposition leaves convex polygon as valid pieces" {
    const vertices = [_]mesh.Vertex{
        .{ .x = 0.0, .y = 0.0 },
        .{ .x = 4.0, .y = 0.0 },
        .{ .x = 4.0, .y = 4.0 },
        .{ .x = 0.0, .y = 4.0 },
    };
    var decomposition = Decomposition{};
    defer decomposition.deinit(std.testing.allocator);

    try decomposeSimple(std.testing.allocator, &vertices, 8, &decomposition);
    try std.testing.expectEqual(@as(usize, 1), decomposition.pieces.items.len);
    try std.testing.expectEqual(@as(usize, 0), decomposition.diagonals.items.len);
}

test "trapezoid decomposition splits larger polygon into bounded pieces" {
    const vertices = [_]mesh.Vertex{
        .{ .x = 0.0, .y = 0.0 },
        .{ .x = 2.0, .y = 0.0 },
        .{ .x = 4.0, .y = 0.0 },
        .{ .x = 5.0, .y = 2.0 },
        .{ .x = 4.0, .y = 4.0 },
        .{ .x = 2.0, .y = 4.0 },
        .{ .x = 0.0, .y = 4.0 },
        .{ .x = -1.0, .y = 2.0 },
    };
    var decomposition = Decomposition{};
    defer decomposition.deinit(std.testing.allocator);

    try decomposeSimple(std.testing.allocator, &vertices, 5, &decomposition);
    try std.testing.expect(decomposition.pieces.items.len >= 2);
    try std.testing.expect(decomposition.diagonals.items.len >= 1);
}

test "trapezoid decomposition seed local and seam legalization" {
    const vertices = [_]mesh.Vertex{
        .{ .x = 0.0, .y = 0.0 },
        .{ .x = 2.0, .y = 0.0 },
        .{ .x = 4.0, .y = 0.0 },
        .{ .x = 5.0, .y = 2.0 },
        .{ .x = 4.0, .y = 4.0 },
        .{ .x = 2.0, .y = 4.0 },
        .{ .x = 0.0, .y = 4.0 },
        .{ .x = -1.0, .y = 2.0 },
    };

    var decomposition = Decomposition{};
    defer decomposition.deinit(std.testing.allocator);
    try decomposeSimple(std.testing.allocator, &vertices, 5, &decomposition);

    var all_indices: std.ArrayListUnmanaged(i32) = .empty;
    defer all_indices.deinit(std.testing.allocator);
    var piece_indices: std.ArrayListUnmanaged(i32) = .empty;
    defer piece_indices.deinit(std.testing.allocator);
    var ranges: std.ArrayListUnmanaged(Piece) = .empty;
    defer ranges.deinit(std.testing.allocator);

    for (decomposition.pieces.items) |piece| {
        const ring = decomposition.rings.items[piece.start .. piece.start + piece.len];
        piece_indices.clearRetainingCapacity();
        try polygon_seed.triangulateRing(std.testing.allocator, &vertices, ring, &piece_indices);
        const start_tri = all_indices.items.len / 3;
        try all_indices.appendSlice(std.testing.allocator, piece_indices.items);
        try ranges.append(std.testing.allocator, .{ .start = start_tri, .len = piece_indices.items.len / 3 });
    }

    var engine = triangulate.Engine.init(std.testing.allocator);
    defer engine.deinit();
    try engine.buildPolygonSeedMesh(&vertices, all_indices.items);
    try engine.setConstraintSegmentsTrusted(std.testing.allocator, decomposition.diagonals.items, true, null);

    var seeds: std.ArrayListUnmanaged(i32) = .empty;
    defer seeds.deinit(std.testing.allocator);
    for (ranges.items) |range| {
        seeds.clearRetainingCapacity();
        try seeds.ensureTotalCapacity(std.testing.allocator, range.len);
        for (0..range.len) |offset| seeds.appendAssumeCapacity(@intCast(range.start + offset));
        try engine.legalizeFromTriangles(std.testing.allocator, seeds.items);
    }

    seeds.clearRetainingCapacity();
    try engine.setConstraintSegmentsTrusted(std.testing.allocator, decomposition.diagonals.items, false, &seeds);
    try engine.legalizeFromTriangles(std.testing.allocator, seeds.items);

    const mesh_ids = [_]i32{ 0, 1, 2, 3, 4, 5, 6, 7 };
    try std.testing.expectEqual(vertices.len - 2, engine.liveTriangleCount());
    try engine.validateTopology();
    try engine.validateConstraintRingFlags(&mesh_ids);
    try engine.validateCdtLegality();
}
