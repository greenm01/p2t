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
};

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

    for (0..vertex_count) |i| {
        next[i] = if (i + 1 < vertex_count) i + 1 else vertex_count;
        prev[i] = if (i > 0) i - 1 else vertex_count;
        permutation[i] = i;
    }

    return .{ .next = next, .prev = prev, .permutation = permutation };
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

fn lineDistanceScore(engine: *triangulate.Engine, a: i32, b: i32, p: i32) f64 {
    return @abs(predicates.orient2d(engine.getVertex(a), engine.getVertex(b), engine.getVertex(p)));
}

fn vertexCloserThanNeighbors(engine: *triangulate.Engine, list: *const LinkedCavity, vertices: []const i32, segment_a: i32, segment_b: i32, pos: usize) bool {
    const prev_pos = list.prev[pos];
    const next_pos = list.next[pos];
    if (prev_pos >= vertices.len or next_pos >= vertices.len) return false;

    const score = lineDistanceScore(engine, segment_a, segment_b, vertices[pos]);
    const prev_score = lineDistanceScore(engine, segment_a, segment_b, vertices[prev_pos]);
    const next_score = lineDistanceScore(engine, segment_a, segment_b, vertices[next_pos]);
    return score <= prev_score and score <= next_score;
}

fn selectDeletionPermutationIndex(
    engine: *triangulate.Engine,
    list: *const LinkedCavity,
    vertices: []const i32,
    segment_a: i32,
    segment_b: i32,
    last_perm_index: usize,
    rng_state: *u64,
) usize {
    const first_perm_index: usize = 1;
    var candidate_perm_index = first_perm_index + @as(usize, @intCast(nextRandom(rng_state) % (last_perm_index - first_perm_index + 1)));
    for (0..last_perm_index) |_| {
        const pos = list.permutation[candidate_perm_index];
        if (!vertexCloserThanNeighbors(engine, list, vertices, segment_a, segment_b, pos)) return candidate_perm_index;
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
    }

    if (vertices.len <= 3) return list;

    const segment_a = vertices[vertices.len - 1];
    const segment_b = vertices[0];
    var rng_state = mixSeed(@as(u64, @intCast(segment_a)) ^ (@as(u64, @intCast(segment_b)) << 32) ^ @as(u64, @intCast(vertices.len)));

    var last_perm_index = vertices.len - 2;
    while (last_perm_index >= 2) : (last_perm_index -= 1) {
        const selected_perm_index = selectDeletionPermutationIndex(engine, &list, vertices, segment_a, segment_b, last_perm_index, &rng_state);
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

fn addPointCavity(
    allocator: std.mem.Allocator,
    engine: *triangulate.Engine,
    tris: *std.ArrayListUnmanaged(TempTriangle),
    u: i32,
    v: i32,
    w: i32,
    depth: usize,
) !void {
    if (depth > 256) return error.InvalidCavity;
    if (u == v or v == w or u == w) return error.InvalidCavity;

    const adjacent = findAdjacentTemp(tris.items, w, v);
    var insert = true;
    if (adjacent) |adj| {
        const inside = incircleInside(engine, w, v, adj.opposite, u);
        const orient = predicates.orient2d(engine.getVertex(u), engine.getVertex(v), engine.getVertex(w));
        insert = !inside and orient > 0.0;
        if (!insert) {
            tris.items[adj.tri_index].dead = true;
            try addPointCavity(allocator, engine, tris, u, v, adj.opposite, depth + 1);
            try addPointCavity(allocator, engine, tris, u, adj.opposite, w, depth + 1);
            return;
        }
    }

    try appendTempTriangle(allocator, engine, tris, u, v, w);
}

fn buildLocalAdjacency(tris: []LocalTriangle) !void {
    for (tris) |*tri| {
        tri.adj0 = -1;
        tri.adj1 = -1;
        tri.adj2 = -1;
    }

    for (tris, 0..) |tri_a, i| {
        for (tris[i + 1 ..], i + 1..) |tri_b, j| {
            inline for (0..3) |side_a| {
                const edge = localTriangleEdge(tri_a, side_a);
                if (localEdgeSide(tri_b, edge.v1, edge.v2)) |side_b| {
                    if (localTriangleAdj(tris[i], side_a) != -1 or localTriangleAdj(tris[j], side_b) != -1) {
                        return error.InvalidCavity;
                    }
                    setLocalTriangleAdj(&tris[i], side_a, @as(i32, @intCast(j)));
                    setLocalTriangleAdj(&tris[j], side_b, @as(i32, @intCast(i)));
                }
            }
        }
    }
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
    if (hasRepeatedVertex(vertices)) return error.InvalidCavity;
    if (vertices.len == 3) {
        try out.append(allocator, try makeLocalTriangle(engine, vertices[0], vertices[1], vertices[2]));
        return;
    }

    const list = try prepareCavityOrder(engine, allocator, vertices);
    defer {
        allocator.free(list.next);
        allocator.free(list.prev);
        allocator.free(list.permutation);
    }

    var temp_tris: std.ArrayListUnmanaged(TempTriangle) = .empty;
    defer temp_tris.deinit(allocator);

    try appendTempTriangle(allocator, engine, &temp_tris, vertices[0], vertices[list.permutation[1]], vertices[vertices.len - 1]);
    if (vertices.len > 3) {
        for (2..vertices.len - 1) |perm_index| {
            const pos = list.permutation[perm_index];
            try addPointCavity(allocator, engine, &temp_tris, vertices[pos], vertices[list.next[pos]], vertices[list.prev[pos]], 0);
        }
    }

    try appendLiveTriangles(allocator, temp_tris.items, out);
    try buildLocalAdjacency(out.items);
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

test "local cavity rejects repeated vertices" {
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

    const cavity_vertices = [_]i32{ 3, 4, 4, 5 };
    try std.testing.expectError(error.InvalidCavity, triangulateCavity(std.testing.allocator, &engine, &cavity_vertices, &out));
}
