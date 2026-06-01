const std = @import("std");
const mesh = @import("mesh.zig");
const triangulate = @import("triangulate.zig");
const predicates = @import("predicates.zig");

pub const LocalTriangle = struct {
    v0: i32,
    v1: i32,
    v2: i32,
    adj0: i32 = -1,
    adj1: i32 = -1,
    adj2: i32 = -1,
};

const TempTriangle = struct {
    tri: LocalTriangle,
    dead: bool = false,
};

const LinkedCavity = struct {
    next: []usize,
    prev: []usize,
    permutation: []usize,
    distance: []f64,
};

const EdgeKey = struct { a: i32, b: i32 };
const AdjRef = struct { tri: usize, side: usize };

fn localTriangleEdge(tri: LocalTriangle, side: usize) struct { v1: i32, v2: i32 } {
    return switch (side) {
        0 => .{ .v1 = tri.v0, .v2 = tri.v1 },
        1 => .{ .v1 = tri.v1, .v2 = tri.v2 },
        else => .{ .v1 = tri.v2, .v2 = tri.v0 },
    };
}

pub fn localTriangleAdj(tri: LocalTriangle, side: usize) i32 {
    return switch (side) {
        0 => tri.adj0,
        1 => tri.adj1,
        else => tri.adj2,
    };
}

fn setLocalTriangleAdj(tri: *LocalTriangle, side: usize, neighbor: i32) void {
    switch (side) {
        0 => tri.adj0 = neighbor,
        1 => tri.adj1 = neighbor,
        else => tri.adj2 = neighbor,
    }
}

pub fn localEdgeSide(tri: LocalTriangle, a: i32, b: i32) ?usize {
    inline for (0..3) |side| {
        const edge = localTriangleEdge(tri, side);
        if ((edge.v1 == a and edge.v2 == b) or (edge.v1 == b and edge.v2 == a)) return side;
    }
    return null;
}

pub fn localOppositeVertex(tri: LocalTriangle, side: usize) i32 {
    return switch (side) {
        0 => tri.v2,
        1 => tri.v0,
        else => tri.v1,
    };
}

fn makeLocalTriangle(engine: *triangulate.Engine, a: i32, b: i32, c: i32) !LocalTriangle {
    if (a == b or b == c or c == a) return error.InvalidCavity;

    var v1 = b;
    var v2 = c;
    const orient = predicates.orient2d(engine.getVertex(a), engine.getVertex(v1), engine.getVertex(v2));
    if (orient == 0.0) return error.InvalidCavity;
    if (orient < 0.0) {
        const tmp = v1;
        v1 = v2;
        v2 = tmp;
    }
    return .{ .v0 = a, .v1 = v1, .v2 = v2 };
}

fn canonicalEdge(a: i32, b: i32) EdgeKey {
    return .{ .a = @min(a, b), .b = @max(a, b) };
}

fn hasRepeatedVertex(vertices: []const i32) bool {
    for (vertices, 0..) |v, i| {
        for (vertices[i + 1 ..]) |other| {
            if (v == other) return true;
        }
    }
    return false;
}

fn initLinkedCavity(allocator: std.mem.Allocator, vertex_count: usize) !LinkedCavity {
    const next = try allocator.alloc(usize, vertex_count);
    const prev = try allocator.alloc(usize, vertex_count);
    const permutation = try allocator.alloc(usize, vertex_count);
    const distance = try allocator.alloc(f64, vertex_count);

    for (0..vertex_count) |i| {
        next[i] = if (i + 1 < vertex_count) i + 1 else vertex_count;
        prev[i] = if (i > 0) i - 1 else vertex_count;
        permutation[i] = i;
        distance[i] = 0.0;
    }

    return .{ .next = next, .prev = prev, .permutation = permutation, .distance = distance };
}

fn mixSeed(seed: u64) u64 {
    var x = seed +% 0x9E3779B97F4A7C15;
    x = (x ^ (x >> 30)) *% 0xBF58476D1CE4E5B9;
    x = (x ^ (x >> 27)) *% 0x94D049BB133111EB;
    return x ^ (x >> 31);
}

fn nextRandom(state: *u64) u64 {
    state.* = mixSeed(state.*);
    return state.*;
}

fn lineDistanceScoreRaw(engine: *triangulate.Engine, a: i32, b: i32, p: i32) f64 {
    const av = engine.getVertex(a);
    const bv = engine.getVertex(b);
    const pv = engine.getVertex(p);
    return @abs((av.x - pv.x) * (bv.y - pv.y) - (av.y - pv.y) * (bv.x - pv.x));
}

fn vertexCloserThanNeighbors(list: *const LinkedCavity, vertices: []const i32, pos: usize) bool {
    const prev_pos = list.prev[pos];
    const next_pos = list.next[pos];
    if (prev_pos >= vertices.len or next_pos >= vertices.len) return false;

    const score = list.distance[pos];
    const prev_score = list.distance[prev_pos];
    const next_score = list.distance[next_pos];
    return score <= prev_score and score <= next_score;
}

fn selectDeletionPermutationIndex(
    engine: *triangulate.Engine,
    list: *const LinkedCavity,
    vertices: []const i32,
    last_perm_index: usize,
    rng_state: *u64,
) usize {
    _ = engine;
    const first_perm_index: usize = 1;
    var candidate_perm_index = first_perm_index + @as(usize, @intCast(nextRandom(rng_state) % (last_perm_index - first_perm_index + 1)));
    for (0..last_perm_index) |_| {
        const pos = list.permutation[candidate_perm_index];
        if (!vertexCloserThanNeighbors(list, vertices, pos)) return candidate_perm_index;
        candidate_perm_index += 1;
        if (candidate_perm_index > last_perm_index) candidate_perm_index = first_perm_index;
    }
    return candidate_perm_index;
}

fn deleteLinkedVertex(list: *LinkedCavity, pos: usize) void {
    const prev_pos = list.prev[pos];
    const next_pos = list.next[pos];
    if (prev_pos < list.next.len) list.next[prev_pos] = next_pos;
    if (next_pos < list.prev.len) list.prev[next_pos] = prev_pos;
}

fn prepareCavityOrder(engine: *triangulate.Engine, allocator: std.mem.Allocator, vertices: []const i32) !LinkedCavity {
    var list = try initLinkedCavity(allocator, vertices.len);
    errdefer {
        allocator.free(list.next);
        allocator.free(list.prev);
        allocator.free(list.permutation);
        allocator.free(list.distance);
    }

    if (vertices.len <= 3) return list;

    const segment_a = vertices[vertices.len - 1];
    const segment_b = vertices[0];
    for (vertices, 0..) |vertex_idx, i| {
        list.distance[i] = lineDistanceScoreRaw(engine, segment_a, segment_b, vertex_idx);
    }

    var rng_state = mixSeed(@as(u64, @intCast(segment_a)) ^ (@as(u64, @intCast(segment_b)) << 32) ^ @as(u64, @intCast(vertices.len)));

    var last_perm_index = vertices.len - 2;
    while (last_perm_index >= 2) : (last_perm_index -= 1) {
        const selected_perm_index = selectDeletionPermutationIndex(engine, &list, vertices, last_perm_index, &rng_state);
        const selected_pos = list.permutation[selected_perm_index];
        deleteLinkedVertex(&list, selected_pos);
        const tmp = list.permutation[last_perm_index];
        list.permutation[last_perm_index] = list.permutation[selected_perm_index];
        list.permutation[selected_perm_index] = tmp;
    }

    return list;
}

fn localEdgeSideTemp(tri: TempTriangle, a: i32, b: i32) ?usize {
    if (tri.dead) return null;
    return localEdgeSide(tri.tri, a, b);
}

fn findAdjacentTemp(tris: []const TempTriangle, a: i32, b: i32) ?struct { tri_index: usize, side: usize, opposite: i32 } {
    for (tris, 0..) |tri, tri_index| {
        const side = localEdgeSideTemp(tri, a, b) orelse continue;
        return .{
            .tri_index = tri_index,
            .side = side,
            .opposite = localOppositeVertex(tri.tri, side),
        };
    }
    return null;
}

fn incircleInside(engine: *triangulate.Engine, a: i32, b: i32, c: i32, p: i32) bool {
    var av = a;
    var bv = b;
    const cv = c;
    if (predicates.orient2d(engine.getVertex(av), engine.getVertex(bv), engine.getVertex(cv)) < 0.0) {
        const tmp = av;
        av = bv;
        bv = tmp;
    }
    return predicates.incircle(engine.getVertex(av), engine.getVertex(bv), engine.getVertex(cv), engine.getVertex(p)) > 0.0;
}

fn appendTempTriangle(allocator: std.mem.Allocator, engine: *triangulate.Engine, tris: *std.ArrayListUnmanaged(TempTriangle), a: i32, b: i32, c: i32) !void {
    try tris.append(allocator, .{ .tri = try makeLocalTriangle(engine, a, b, c) });
}

fn appendMarkedVertex(allocator: std.mem.Allocator, marked: *std.ArrayListUnmanaged(i32), vertex_idx: i32) !void {
    for (marked.items) |existing| {
        if (existing == vertex_idx) return;
    }
    try marked.append(allocator, vertex_idx);
}

fn tempTriangleAllMarked(tri: LocalTriangle, marked: []const i32) bool {
    const vertices = [_]i32{ tri.v0, tri.v1, tri.v2 };
    for (vertices) |vertex_idx| {
        var found = false;
        for (marked) |marked_idx| {
            if (marked_idx == vertex_idx) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

const FanSortContext = struct {
    engine: *triangulate.Engine,
    cx: f64,
    cy: f64,
};

fn fanHalf(dx: f64, dy: f64) bool {
    return dy > 0.0 or (dy == 0.0 and dx >= 0.0);
}

fn fanVertexLess(ctx: FanSortContext, a: i32, b: i32) bool {
    const av = ctx.engine.getVertex(a);
    const bv = ctx.engine.getVertex(b);
    const adx = av.x - ctx.cx;
    const ady = av.y - ctx.cy;
    const bdx = bv.x - ctx.cx;
    const bdy = bv.y - ctx.cy;
    const ah = fanHalf(adx, ady);
    const bh = fanHalf(bdx, bdy);
    if (ah != bh) return ah;
    const cross = adx * bdy - ady * bdx;
    if (cross != 0.0) return cross > 0.0;
    return a < b;
}

fn repairMarkedFan(
    allocator: std.mem.Allocator,
    engine: *triangulate.Engine,
    tris: *std.ArrayListUnmanaged(TempTriangle),
    marked: *std.ArrayListUnmanaged(i32),
) anyerror!void {
    if (marked.items.len < 4) {
        marked.clearRetainingCapacity();
        return;
    }

    var fan_triangle_count: usize = 0;
    for (tris.items) |tri| {
        if (!tri.dead and tempTriangleAllMarked(tri.tri, marked.items)) fan_triangle_count += 1;
    }
    if (fan_triangle_count <= 1) {
        marked.clearRetainingCapacity();
        return;
    }

    var cx: f64 = 0.0;
    var cy: f64 = 0.0;
    for (marked.items) |vertex_idx| {
        const vertex = engine.getVertex(vertex_idx);
        cx += vertex.x;
        cy += vertex.y;
    }
    cx /= @as(f64, @floatFromInt(marked.items.len));
    cy /= @as(f64, @floatFromInt(marked.items.len));
    std.mem.sort(i32, marked.items, FanSortContext{ .engine = engine, .cx = cx, .cy = cy }, fanVertexLess);

    var fan_tris: std.ArrayListUnmanaged(LocalTriangle) = .empty;
    defer fan_tris.deinit(allocator);
    try triangulateCavity(allocator, engine, marked.items, &fan_tris);

    for (tris.items) |*tri| {
        if (!tri.dead and tempTriangleAllMarked(tri.tri, marked.items)) tri.dead = true;
    }
    for (fan_tris.items) |local_tri| {
        try tris.append(allocator, .{ .tri = local_tri });
    }
    marked.clearRetainingCapacity();
}

fn addPointCavity(
    allocator: std.mem.Allocator,
    engine: *triangulate.Engine,
    tris: *std.ArrayListUnmanaged(TempTriangle),
    marked: *std.ArrayListUnmanaged(i32),
    u: i32,
    v: i32,
    w: i32,
    depth: usize,
    known_positive_orientation: bool,
) !void {
    if (depth > 256) return error.InvalidCavity;
    if (u == v or v == w or u == w) return error.InvalidCavity;

    const adjacent = findAdjacentTemp(tris.items, w, v);
    var insert = true;
    var positive_orientation = known_positive_orientation;
    if (adjacent) |adj| {
        const inside = incircleInside(engine, w, v, adj.opposite, u);
        if (!positive_orientation) {
            positive_orientation = predicates.orient2d(engine.getVertex(u), engine.getVertex(v), engine.getVertex(w)) > 0.0;
        }
        insert = !inside and positive_orientation;
        if (!insert) {
            tris.items[adj.tri_index].dead = true;
            try addPointCavity(allocator, engine, tris, marked, u, v, adj.opposite, depth + 1, positive_orientation);
            try addPointCavity(allocator, engine, tris, marked, u, adj.opposite, w, depth + 1, positive_orientation);
            if (!inside) {
                try appendMarkedVertex(allocator, marked, u);
                try appendMarkedVertex(allocator, marked, v);
                try appendMarkedVertex(allocator, marked, w);
                try appendMarkedVertex(allocator, marked, adj.opposite);
            }
            return;
        }
    }

    try appendTempTriangle(allocator, engine, tris, u, v, w);
}

fn buildLocalAdjacency(allocator: std.mem.Allocator, tris: []LocalTriangle) !void {
    for (tris) |*tri| {
        tri.adj0 = -1;
        tri.adj1 = -1;
        tri.adj2 = -1;
    }

    var edge_map = std.AutoHashMap(EdgeKey, AdjRef).init(allocator);
    defer edge_map.deinit();
    try edge_map.ensureTotalCapacity(@intCast(tris.len * 3));

    for (tris, 0..) |tri_a, i| {
        _ = tri_a;
        inline for (0..3) |side_a| {
            const edge = localTriangleEdge(tris[i], side_a);
            const key = canonicalEdge(edge.v1, edge.v2);
            const entry = try edge_map.getOrPut(key);
            if (!entry.found_existing) {
                entry.value_ptr.* = .{ .tri = i, .side = side_a };
            } else {
                const other = entry.value_ptr.*;
                if (localTriangleAdj(tris[i], side_a) != -1 or localTriangleAdj(tris[other.tri], other.side) != -1) {
                    return error.InvalidCavity;
                }
                setLocalTriangleAdj(&tris[i], side_a, @as(i32, @intCast(other.tri)));
                setLocalTriangleAdj(&tris[other.tri], other.side, @as(i32, @intCast(i)));
                _ = edge_map.remove(key);
            }
        }
    }
}

fn compactAdjacentDuplicates(allocator: std.mem.Allocator, vertices: []const i32) ![]i32 {
    var compacted: std.ArrayListUnmanaged(i32) = .empty;
    errdefer compacted.deinit(allocator);
    try compacted.ensureTotalCapacity(allocator, vertices.len);

    for (vertices) |vertex_idx| {
        if (compacted.items.len == 0 or compacted.items[compacted.items.len - 1] != vertex_idx) {
            compacted.appendAssumeCapacity(vertex_idx);
        }
    }

    if (compacted.items.len > 1 and compacted.items[0] == compacted.items[compacted.items.len - 1]) {
        _ = compacted.pop();
    }

    return try compacted.toOwnedSlice(allocator);
}

fn appendLiveTriangles(allocator: std.mem.Allocator, temp_tris: []const TempTriangle, out: *std.ArrayListUnmanaged(LocalTriangle)) !void {
    for (temp_tris) |tri| {
        if (tri.dead) continue;
        try out.append(allocator, tri.tri);
    }
}

fn edgeNeedsLocalFlip(engine: *triangulate.Engine, tri: LocalTriangle, side: usize, neighbor: LocalTriangle, neighbor_side: usize) bool {
    const edge = localTriangleEdge(tri, side);
    const c = localOppositeVertex(tri, side);
    const d = localOppositeVertex(neighbor, neighbor_side);
    if (c == d or c == edge.v1 or c == edge.v2 or d == edge.v1 or d == edge.v2) return false;

    const c_side = predicates.orient2d(engine.getVertex(edge.v1), engine.getVertex(edge.v2), engine.getVertex(c));
    const d_side = predicates.orient2d(engine.getVertex(edge.v1), engine.getVertex(edge.v2), engine.getVertex(d));
    if (c_side == 0.0 or d_side == 0.0 or c_side * d_side >= 0.0) return false;

    return incircleInside(engine, edge.v1, edge.v2, c, d);
}

fn validateLocalDelaunay(engine: *triangulate.Engine, tris: []const LocalTriangle) !void {
    for (tris, 0..) |tri, tri_index| {
        for (0..3) |side| {
            const neighbor = localTriangleAdj(tri, side);
            if (neighbor < 0 or neighbor < @as(i32, @intCast(tri_index))) continue;
            const neighbor_tri = tris[@as(usize, @intCast(neighbor))];
            const edge = localTriangleEdge(tri, side);
            const neighbor_side = localEdgeSide(neighbor_tri, edge.v1, edge.v2) orelse return error.InvalidCavity;
            if (edgeNeedsLocalFlip(engine, tri, side, neighbor_tri, neighbor_side)) return error.NonDelaunayLocalCavity;
        }
    }
}

pub fn triangulateCavity(allocator: std.mem.Allocator, engine: *triangulate.Engine, vertices: []const i32, out: *std.ArrayListUnmanaged(LocalTriangle)) !void {
    out.clearRetainingCapacity();
    if (vertices.len < 3) return;

    const work_vertices = try compactAdjacentDuplicates(allocator, vertices);
    defer allocator.free(work_vertices);

    if (work_vertices.len < 3) return;
    if (hasRepeatedVertex(work_vertices)) return error.RepeatedCavityVertex;
    if (work_vertices.len == 3) {
        try out.append(allocator, try makeLocalTriangle(engine, work_vertices[0], work_vertices[1], work_vertices[2]));
        return;
    }

    const list = try prepareCavityOrder(engine, allocator, work_vertices);
    defer {
        allocator.free(list.next);
        allocator.free(list.prev);
        allocator.free(list.permutation);
        allocator.free(list.distance);
    }

    var temp_tris: std.ArrayListUnmanaged(TempTriangle) = .empty;
    defer temp_tris.deinit(allocator);

    var marked_vertices: std.ArrayListUnmanaged(i32) = .empty;
    defer marked_vertices.deinit(allocator);

    try appendTempTriangle(allocator, engine, &temp_tris, work_vertices[0], work_vertices[list.permutation[1]], work_vertices[work_vertices.len - 1]);
    if (work_vertices.len > 3) {
        for (2..work_vertices.len - 1) |perm_index| {
            const pos = list.permutation[perm_index];
            try addPointCavity(allocator, engine, &temp_tris, &marked_vertices, work_vertices[pos], work_vertices[list.next[pos]], work_vertices[list.prev[pos]], 0, false);
            try repairMarkedFan(allocator, engine, &temp_tris, &marked_vertices);
        }
    }

    try appendLiveTriangles(allocator, temp_tris.items, out);
    try buildLocalAdjacency(allocator, out.items);
    try validateLocalDelaunay(engine, out.items);
}

test "local cavity triangulates a convex polygon" {
    var engine = triangulate.Engine.init(std.testing.allocator);
    defer engine.deinit();

    const vertices = [_]mesh.Vertex{
        .{ .x = 0.0, .y = 0.0 },
        .{ .x = 1.0, .y = 0.0 },
        .{ .x = 1.0, .y = 1.0 },
        .{ .x = 0.0, .y = 1.0 },
    };
    try engine.initSuperTriangle(&vertices);
    for (vertices) |vertex| {
        try engine.mesh.vertices.append(std.testing.allocator, vertex);
    }

    var out: std.ArrayListUnmanaged(LocalTriangle) = .empty;
    defer out.deinit(std.testing.allocator);

    const cavity_vertices = [_]i32{ 3, 4, 5, 6 };
    try triangulateCavity(std.testing.allocator, &engine, &cavity_vertices, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
}

test "local cavity rejects non-adjacent repeated vertices with distinct reason" {
    var engine = triangulate.Engine.init(std.testing.allocator);
    defer engine.deinit();

    const vertices = [_]mesh.Vertex{
        .{ .x = 0.0, .y = 0.0 },
        .{ .x = 1.0, .y = 0.0 },
        .{ .x = 1.0, .y = 1.0 },
    };
    try engine.initSuperTriangle(&vertices);
    for (vertices) |vertex| {
        try engine.mesh.vertices.append(std.testing.allocator, vertex);
    }

    var out: std.ArrayListUnmanaged(LocalTriangle) = .empty;
    defer out.deinit(std.testing.allocator);

    const cavity_vertices = [_]i32{ 3, 4, 5, 4 };
    try std.testing.expectError(error.RepeatedCavityVertex, triangulateCavity(std.testing.allocator, &engine, &cavity_vertices, &out));
}

test "local cavity compacts adjacent repeated vertices" {
    var engine = triangulate.Engine.init(std.testing.allocator);
    defer engine.deinit();

    const vertices = [_]mesh.Vertex{
        .{ .x = 0.0, .y = 0.0 },
        .{ .x = 1.0, .y = 0.0 },
        .{ .x = 1.0, .y = 1.0 },
        .{ .x = 0.0, .y = 1.0 },
    };
    try engine.initSuperTriangle(&vertices);
    for (vertices) |vertex| {
        try engine.mesh.vertices.append(std.testing.allocator, vertex);
    }

    var out: std.ArrayListUnmanaged(LocalTriangle) = .empty;
    defer out.deinit(std.testing.allocator);

    const cavity_vertices = [_]i32{ 3, 4, 4, 5, 6 };
    try triangulateCavity(std.testing.allocator, &engine, &cavity_vertices, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
}
