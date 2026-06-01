const std = @import("std");
const mesh = @import("mesh.zig");
const triangulate = @import("triangulate.zig");
const predicates = @import("predicates.zig");
const parser = @import("parser.zig");
const spatial = @import("spatial.zig");
const cavity = @import("cavity.zig");

pub const Corridor = struct {
    pierced_triangles: std.ArrayListUnmanaged(i32) = .empty,
    left_vertices: std.ArrayListUnmanaged(i32) = .empty,
    right_vertices: std.ArrayListUnmanaged(i32) = .empty,

    const EdgeKey = struct { v1: i32, v2: i32 };
    const EdgeRecord = struct { v1: i32, v2: i32 };
    const BoundaryEdge = struct { v1: i32, v2: i32, adj_tri: i32 };
    const BoundaryNode = struct {
        neighbors: [8]i32 = [_]i32{-1} ** 8,
        degree: u8 = 0,

        fn addNeighbor(self: *BoundaryNode, neighbor: i32) !void {
            for (self.neighbors[0..self.degree]) |existing| {
                if (existing == neighbor) return;
            }
            if (self.degree >= self.neighbors.len) return error.InvalidCorridorBoundary;
            self.neighbors[self.degree] = neighbor;
            self.degree += 1;
        }
    };

    const ChainCandidate = struct {
        side: i32,
        score: f64,
        vertices: std.ArrayListUnmanaged(i32) = .empty,
    };

    const LocalCavityPair = struct {
        left: std.ArrayListUnmanaged(cavity.LocalTriangle) = .empty,
        right: std.ArrayListUnmanaged(cavity.LocalTriangle) = .empty,
    };

    pub fn deinit(self: *Corridor, allocator: std.mem.Allocator) void {
        self.pierced_triangles.deinit(allocator);
        self.left_vertices.deinit(allocator);
        self.right_vertices.deinit(allocator);
    }

    fn containsPierced(self: *const Corridor, tri_idx: i32) bool {
        for (self.pierced_triangles.items) |pierced_idx| {
            if (pierced_idx == tri_idx) return true;
        }
        return false;
    }

    fn collectTransactionFootprint(self: *const Corridor, allocator: std.mem.Allocator, engine: *const triangulate.Engine, outer_edges: []const BoundaryEdge, footprint: *std.ArrayListUnmanaged(i32)) !void {
        footprint.clearRetainingCapacity();

        for (self.pierced_triangles.items) |tri_idx| {
            try engine.appendTransactionTriangle(allocator, footprint, tri_idx);
        }
        for (outer_edges) |edge| {
            try engine.appendTransactionTriangle(allocator, footprint, edge.adj_tri);
        }
    }

    fn triangleHasVertex(tri: mesh.Triangle, vertex_idx: i32) bool {
        return tri.v0 == vertex_idx or tri.v1 == vertex_idx or tri.v2 == vertex_idx;
    }

    fn pointInTriangle(engine: *triangulate.Engine, tri: mesh.Triangle, pt: mesh.Vertex) bool {
        const eps = 1e-9;
        const v0 = engine.getVertex(tri.v0);
        const v1 = engine.getVertex(tri.v1);
        const v2 = engine.getVertex(tri.v2);
        return predicates.orient2d(v0, v1, pt) >= -eps and
            predicates.orient2d(v1, v2, pt) >= -eps and
            predicates.orient2d(v2, v0, pt) >= -eps;
    }

    fn samePoint(a: mesh.Vertex, b: mesh.Vertex) bool {
        return a.x == b.x and a.y == b.y;
    }

    fn appendUniqueVertex(list: *std.ArrayListUnmanaged(i32), allocator: std.mem.Allocator, vertex_idx: i32) !void {
        if (list.items.len > 0 and list.items[list.items.len - 1] == vertex_idx) return;
        try list.append(allocator, vertex_idx);
    }

    fn appendTraceVertex(
        self: *Corridor,
        allocator: std.mem.Allocator,
        engine: *triangulate.Engine,
        start_pt_idx: i32,
        end_pt_idx: i32,
        vertex_idx: i32,
    ) !void {
        if (vertex_idx == start_pt_idx or vertex_idx == end_pt_idx) return;

        const start_pt = engine.getVertex(start_pt_idx);
        const end_pt = engine.getVertex(end_pt_idx);
        const side = predicates.orient2d(start_pt, end_pt, engine.getVertex(vertex_idx));
        if (side > 0.0) {
            try appendUniqueVertex(&self.left_vertices, allocator, vertex_idx);
        } else if (side < 0.0) {
            try appendUniqueVertex(&self.right_vertices, allocator, vertex_idx);
        }
    }

    fn segmentHitsEdge(start_pt: mesh.Vertex, end_pt: mesh.Vertex, a: mesh.Vertex, b: mesh.Vertex) bool {
        return predicates.intersect(start_pt, end_pt, a, b) or
            predicates.pointOnSegment(start_pt, end_pt, a) or
            predicates.pointOnSegment(start_pt, end_pt, b);
    }

    fn segmentIntersectsTriangle(engine: *triangulate.Engine, tri: mesh.Triangle, start_pt: mesh.Vertex, end_pt: mesh.Vertex) bool {
        const v0 = engine.getVertex(tri.v0);
        const v1 = engine.getVertex(tri.v1);
        const v2 = engine.getVertex(tri.v2);

        if (pointInTriangle(engine, tri, start_pt) and !samePoint(start_pt, v0) and !samePoint(start_pt, v1) and !samePoint(start_pt, v2)) return true;
        if (pointInTriangle(engine, tri, end_pt) and !samePoint(end_pt, v0) and !samePoint(end_pt, v1) and !samePoint(end_pt, v2)) return true;

        return predicates.intersect(start_pt, end_pt, v0, v1) or
            predicates.intersect(start_pt, end_pt, v1, v2) or
            predicates.intersect(start_pt, end_pt, v2, v0);
    }

    fn augmentPiercedBySegmentScan(self: *Corridor, allocator: std.mem.Allocator, engine: *triangulate.Engine, start_pt_idx: i32, end_pt_idx: i32) !void {
        const start_pt = engine.getVertex(start_pt_idx);
        const end_pt = engine.getVertex(end_pt_idx);
        const near_start = mesh.Vertex{
            .x = start_pt.x + (end_pt.x - start_pt.x) * 1e-7,
            .y = start_pt.y + (end_pt.y - start_pt.y) * 1e-7,
        };
        const near_end = mesh.Vertex{
            .x = end_pt.x + (start_pt.x - end_pt.x) * 1e-7,
            .y = end_pt.y + (start_pt.y - end_pt.y) * 1e-7,
        };

        for (0..engine.mesh.triangles.len) |tri_idx| {
            const tri_i32 = @as(i32, @intCast(tri_idx));
            if (self.containsPierced(tri_i32)) continue;

            const tri = engine.mesh.triangles.get(tri_idx);
            if (mesh.isDeadTriangle(tri)) continue;

            const enters_from_start = triangleHasVertex(tri, start_pt_idx) and pointInTriangle(engine, tri, near_start);
            const enters_from_end = triangleHasVertex(tri, end_pt_idx) and pointInTriangle(engine, tri, near_end);
            if (enters_from_start or enters_from_end or segmentIntersectsTriangle(engine, tri, start_pt, end_pt)) {
                try self.pierced_triangles.append(allocator, tri_i32);
            }
        }
    }

    pub fn trace(self: *Corridor, allocator: std.mem.Allocator, engine: *triangulate.Engine, start_tri: i32, end_pt_idx: i32, start_pt_idx: i32) !void {
        self.pierced_triangles.clearRetainingCapacity();
        self.left_vertices.clearRetainingCapacity();
        self.right_vertices.clearRetainingCapacity();

        const start_pt = engine.getVertex(start_pt_idx);
        const end_pt = engine.getVertex(end_pt_idx);
        var curr = start_tri;

        // Safety limit
        var limit: usize = 10000;

        while (curr != -1 and limit > 0) : (limit -= 1) {
            try self.pierced_triangles.append(allocator, curr);

            const tri = engine.mesh.triangles.get(@as(usize, @intCast(curr)));
            const v0 = engine.getVertex(tri.v0);
            const v1 = engine.getVertex(tri.v1);
            const v2 = engine.getVertex(tri.v2);

            // Have we reached a triangle that contains the end_pt?
            // If end_pt is a vertex of this triangle, we are done.
            if (tri.v0 == end_pt_idx or tri.v1 == end_pt_idx or tri.v2 == end_pt_idx) {
                break;
            }

            // Which edge does the segment (start_pt, end_pt) intersect?
            // We check the 3 edges. We don't want to step back, so we should step forward.
            // A segment intersects an edge if `intersect` is true.
            // Also need to handle collinear cases or vertex intersections in a robust way,
            // but for a strict Delaunay base mesh without co-circular/collinear degeneracies,
            // strict intersection works.

            var next_tri: i32 = -1;
            var crossed_side: ?usize = null;

            if (tri.v0 != start_pt_idx and tri.v1 != start_pt_idx and tri.v0 != end_pt_idx and tri.v1 != end_pt_idx and segmentHitsEdge(start_pt, end_pt, v0, v1)) {
                // To avoid stepping backwards, we should verify it's moving closer to end_pt
                // Actually, if it intersects and is not the triangle we came from, we can go there.
                // But since we just append, let's just check if we already visited it.
                if (self.pierced_triangles.items.len < 2 or self.pierced_triangles.items[self.pierced_triangles.items.len - 2] != tri.adj0) {
                    next_tri = tri.adj0;
                    crossed_side = 0;
                }
            }
            if (next_tri == -1 and tri.v1 != start_pt_idx and tri.v2 != start_pt_idx and tri.v1 != end_pt_idx and tri.v2 != end_pt_idx and segmentHitsEdge(start_pt, end_pt, v1, v2)) {
                if (self.pierced_triangles.items.len < 2 or self.pierced_triangles.items[self.pierced_triangles.items.len - 2] != tri.adj1) {
                    next_tri = tri.adj1;
                    crossed_side = 1;
                }
            }
            if (next_tri == -1 and tri.v2 != start_pt_idx and tri.v0 != start_pt_idx and tri.v2 != end_pt_idx and tri.v0 != end_pt_idx and segmentHitsEdge(start_pt, end_pt, v2, v0)) {
                if (self.pierced_triangles.items.len < 2 or self.pierced_triangles.items[self.pierced_triangles.items.len - 2] != tri.adj2) {
                    next_tri = tri.adj2;
                    crossed_side = 2;
                }
            }

            if (next_tri == -1) {
                // Should not happen in a valid mesh unless we hit an exact vertex.
                // For this proof of concept, we just break.
                break;
            }

            const crossed = triangulate.Engine.triangleEdge(tri, crossed_side.?);
            try self.appendTraceVertex(allocator, engine, start_pt_idx, end_pt_idx, crossed.v1);
            try self.appendTraceVertex(allocator, engine, start_pt_idx, end_pt_idx, crossed.v2);

            curr = next_tri;
        }
    }

    fn canonicalEdge(a: i32, b: i32) EdgeKey {
        return .{ .v1 = @min(a, b), .v2 = @max(a, b) };
    }

    fn addBoundaryNeighbor(engine: *triangulate.Engine, nodes: *std.AutoHashMap(i32, BoundaryNode), a: i32, b: i32) !void {
        var entry = try nodes.getOrPut(a);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        if (entry.value_ptr.degree >= entry.value_ptr.neighbors.len) {
            const av = engine.getVertex(a);
            const bv = engine.getVertex(b);
            std.debug.print("InvalidCorridorBoundary: vertex {d} ({d},{d}) exceeded boundary neighbor capacity with {d} ({d},{d})\n", .{ a, av.x, av.y, b, bv.x, bv.y });
            return error.InvalidCorridorBoundary;
        }
        try entry.value_ptr.addNeighbor(b);
    }

    fn countPiercedEdges(
        self: *Corridor,
        engine: *triangulate.Engine,
        edge_counts: *std.AutoHashMap(EdgeKey, usize),
    ) !void {
        for (self.pierced_triangles.items) |t_idx| {
            const tri = engine.mesh.triangles.get(@as(usize, @intCast(t_idx)));
            const edges = [_]EdgeRecord{
                .{ .v1 = tri.v0, .v2 = tri.v1 },
                .{ .v1 = tri.v1, .v2 = tri.v2 },
                .{ .v1 = tri.v2, .v2 = tri.v0 },
            };

            for (edges) |e| {
                const key = canonicalEdge(e.v1, e.v2);
                const count = edge_counts.get(key) orelse 0;
                try edge_counts.put(key, count + 1);
            }
        }
    }

    fn buildBoundaryNodesFromEdgeCounts(
        engine: *triangulate.Engine,
        edge_counts: *std.AutoHashMap(EdgeKey, usize),
        nodes: *std.AutoHashMap(i32, BoundaryNode),
    ) !void {
        var it = edge_counts.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != 1) continue;
            const a = entry.key_ptr.v1;
            const b = entry.key_ptr.v2;
            try addBoundaryNeighbor(engine, nodes, a, b);
            try addBoundaryNeighbor(engine, nodes, b, a);
        }
    }

    fn validateBoundaryDegrees(nodes: *std.AutoHashMap(i32, BoundaryNode), start_pt_idx: i32, end_pt_idx: i32) !void {
        var it = nodes.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* == start_pt_idx or entry.key_ptr.* == end_pt_idx) {
                if (entry.value_ptr.degree >= 2) continue;
            }
            if (entry.value_ptr.degree != 2) {
                std.debug.print("InvalidCorridorBoundary: vertex {d} has boundary degree {d}\n", .{ entry.key_ptr.*, entry.value_ptr.degree });
                return error.InvalidCorridorBoundary;
            }
        }
    }

    fn traceBoundaryChain(
        nodes: *std.AutoHashMap(i32, BoundaryNode),
        allocator: std.mem.Allocator,
        start_pt_idx: i32,
        end_pt_idx: i32,
        first_neighbor: i32,
        out: *std.ArrayListUnmanaged(i32),
    ) !void {
        out.clearRetainingCapacity();

        var prev = start_pt_idx;
        var curr = first_neighbor;
        var steps: usize = 0;
        const limit = nodes.count() + 1;

        while (curr != end_pt_idx) : (steps += 1) {
            if (steps > limit) {
                return error.InvalidCorridorBoundary;
            }
            if (curr == start_pt_idx) {
                return error.InvalidCorridorBoundary;
            }

            try out.append(allocator, curr);

            const node = nodes.get(curr) orelse return error.InvalidCorridorBoundary;
            if (node.degree != 2) {
                return error.InvalidCorridorBoundary;
            }
            const next = if (node.neighbors[0] == prev) node.neighbors[1] else if (node.neighbors[1] == prev) node.neighbors[0] else {
                return error.InvalidCorridorBoundary;
            };

            prev = curr;
            curr = next;
        }
    }

    fn chainSideScore(engine: *triangulate.Engine, start_pt_idx: i32, end_pt_idx: i32, chain: []const i32) struct { side: i32, score: f64 } {
        if (chain.len == 0) return .{ .side = 0, .score = std.math.inf(f64) };
        const start_pt = engine.getVertex(start_pt_idx);
        const end_pt = engine.getVertex(end_pt_idx);
        var side: i32 = 0;
        var score = std.math.inf(f64);
        for (chain) |v_idx| {
            const orient = predicates.orient2d(start_pt, end_pt, engine.getVertex(v_idx));
            if (orient > 0.0 and side == 0) side = 1;
            if (orient < 0.0 and side == 0) side = -1;
            if (orient != 0.0) score = @min(score, @abs(orient));
        }
        return .{ .side = side, .score = score };
    }

    fn collectOuterBoundaryEdges(
        self: *Corridor,
        allocator: std.mem.Allocator,
        engine: *triangulate.Engine,
        edge_counts: *std.AutoHashMap(EdgeKey, usize),
        edges: *std.ArrayListUnmanaged(BoundaryEdge),
    ) !void {
        edges.clearRetainingCapacity();
        for (self.pierced_triangles.items) |t_idx| {
            const tri = engine.mesh.triangles.get(@as(usize, @intCast(t_idx)));
            const tri_edges = [_]struct { v1: i32, v2: i32, adj: i32 }{
                .{ .v1 = tri.v0, .v2 = tri.v1, .adj = tri.adj0 },
                .{ .v1 = tri.v1, .v2 = tri.v2, .adj = tri.adj1 },
                .{ .v1 = tri.v2, .v2 = tri.v0, .adj = tri.adj2 },
            };

            for (tri_edges) |edge| {
                if ((edge_counts.get(canonicalEdge(edge.v1, edge.v2)) orelse 0) != 1) continue;
                if (edge.adj == -1 or self.containsPierced(edge.adj)) continue;
                try edges.append(allocator, .{
                    .v1 = edge.v1,
                    .v2 = edge.v2,
                    .adj_tri = edge.adj,
                });
            }
        }
    }

    fn buildLeftCavityVertices(
        allocator: std.mem.Allocator,
        start_pt_idx: i32,
        end_pt_idx: i32,
        wall: []const i32,
        out: *std.ArrayListUnmanaged(i32),
    ) !void {
        out.clearRetainingCapacity();
        try out.append(allocator, end_pt_idx);
        var i = wall.len;
        while (i > 0) {
            i -= 1;
            try out.append(allocator, wall[i]);
        }
        try out.append(allocator, start_pt_idx);
    }

    fn buildRightCavityVertices(
        allocator: std.mem.Allocator,
        start_pt_idx: i32,
        end_pt_idx: i32,
        wall: []const i32,
        out: *std.ArrayListUnmanaged(i32),
    ) !void {
        out.clearRetainingCapacity();
        try out.append(allocator, start_pt_idx);
        for (wall) |vertex_idx| {
            try out.append(allocator, vertex_idx);
        }
        try out.append(allocator, end_pt_idx);
    }

    fn localOuterEdgeNeedsFlip(engine: *triangulate.Engine, local_tri: cavity.LocalTriangle, local_side: usize, outer_tri_idx: i32) !bool {
        if (outer_tri_idx < 0) return false;
        const outer_tri = engine.mesh.triangles.get(@as(usize, @intCast(outer_tri_idx)));
        if (mesh.isDeadTriangle(outer_tri)) return false;

        const edge = switch (local_side) {
            0 => EdgeRecord{ .v1 = local_tri.v0, .v2 = local_tri.v1 },
            1 => EdgeRecord{ .v1 = local_tri.v1, .v2 = local_tri.v2 },
            else => EdgeRecord{ .v1 = local_tri.v2, .v2 = local_tri.v0 },
        };
        const outer_side = triangulate.Engine.edgeSide(outer_tri, edge.v1, edge.v2) orelse return error.InvalidCavity;
        if (engine.isConstrainedSide(outer_tri_idx, outer_side)) return false;

        const local_opposite = cavity.localOppositeVertex(local_tri, local_side);
        const outer_opposite = triangulate.Engine.oppositeVertex(outer_tri, outer_side);
        if (local_opposite == outer_opposite or local_opposite == edge.v1 or local_opposite == edge.v2 or outer_opposite == edge.v1 or outer_opposite == edge.v2) return false;

        const local_side_orient = predicates.orient2d(engine.getVertex(edge.v1), engine.getVertex(edge.v2), engine.getVertex(local_opposite));
        const outer_side_orient = predicates.orient2d(engine.getVertex(edge.v1), engine.getVertex(edge.v2), engine.getVertex(outer_opposite));
        if (local_side_orient == 0.0 or outer_side_orient == 0.0 or local_side_orient * outer_side_orient >= 0.0) return false;

        var a = edge.v1;
        var b = edge.v2;
        if (predicates.orient2d(engine.getVertex(a), engine.getVertex(b), engine.getVertex(local_opposite)) < 0.0) {
            const tmp = a;
            a = b;
            b = tmp;
        }
        return predicates.incircle(engine.getVertex(a), engine.getVertex(b), engine.getVertex(local_opposite), engine.getVertex(outer_opposite)) > 0.0;
    }

    fn localTrisContainValidOuterEdge(engine: *triangulate.Engine, local_tris: []const cavity.LocalTriangle, outer_edge: BoundaryEdge) !bool {
        for (local_tris) |local_tri| {
            const local_side = cavity.localEdgeSide(local_tri, outer_edge.v1, outer_edge.v2) orelse continue;
            if (try localOuterEdgeNeedsFlip(engine, local_tri, local_side, outer_edge.adj_tri)) return error.NonDelaunayLocalCavity;
            return true;
        }
        return false;
    }

    fn validateLocalAgainstOuterEdges(engine: *triangulate.Engine, left_tris: []const cavity.LocalTriangle, right_tris: []const cavity.LocalTriangle, outer_edges: []const BoundaryEdge) !void {
        for (outer_edges) |outer_edge| {
            if (try localTrisContainValidOuterEdge(engine, left_tris, outer_edge)) continue;
            if (try localTrisContainValidOuterEdge(engine, right_tris, outer_edge)) continue;
            return error.InvalidCavity;
        }
    }

    fn buildLocalCavities(
        allocator: std.mem.Allocator,
        engine: *triangulate.Engine,
        start_pt_idx: i32,
        end_pt_idx: i32,
        left_wall: []const i32,
        right_wall: []const i32,
        outer_edges: []const BoundaryEdge,
        result: *LocalCavityPair,
    ) !void {
        result.left.clearRetainingCapacity();
        result.right.clearRetainingCapacity();

        var left_vertices: std.ArrayListUnmanaged(i32) = .empty;
        var right_vertices: std.ArrayListUnmanaged(i32) = .empty;
        defer left_vertices.deinit(allocator);
        defer right_vertices.deinit(allocator);

        try buildLeftCavityVertices(allocator, start_pt_idx, end_pt_idx, left_wall, &left_vertices);
        try buildRightCavityVertices(allocator, start_pt_idx, end_pt_idx, right_wall, &right_vertices);

        try cavity.triangulateCavity(allocator, engine, left_vertices.items, &result.left);
        try cavity.triangulateCavity(allocator, engine, right_vertices.items, &result.right);
        try validateLocalAgainstOuterEdges(engine, result.left.items, result.right.items, outer_edges);
    }

    fn shouldUseLocalCavity(left_wall: []const i32, right_wall: []const i32, pierced_triangles: []const i32) bool {
        const wall_vertices = left_wall.len + right_wall.len;
        return wall_vertices >= 12 and pierced_triangles.len >= 8;
    }

    fn emitLocalTriangles(
        allocator: std.mem.Allocator,
        engine: *triangulate.Engine,
        arena: *mesh.ThreadArena,
        local_tris: []const cavity.LocalTriangle,
        emitted: *std.ArrayListUnmanaged(i32),
    ) !void {
        const base = emitted.items.len;
        const map = try allocator.alloc(i32, local_tris.len);
        for (local_tris, 0..) |local_tri, i| {
            _ = local_tri;
            const new_tri_idx = arena.getFreeSlot() orelse @as(i32, @intCast(engine.mesh.triangles.len));
            try engine.mesh.ensureTriangleSlot(allocator, new_tri_idx);
            map[i] = new_tri_idx;
            try emitted.append(allocator, new_tri_idx);
        }

        for (local_tris, 0..) |local_tri, i| {
            const tri = mesh.Triangle{
                .v0 = local_tri.v0,
                .v1 = local_tri.v1,
                .v2 = local_tri.v2,
                .adj0 = if (local_tri.adj0 >= 0) map[@as(usize, @intCast(local_tri.adj0))] else -1,
                .adj1 = if (local_tri.adj1 >= 0) map[@as(usize, @intCast(local_tri.adj1))] else -1,
                .adj2 = if (local_tri.adj2 >= 0) map[@as(usize, @intCast(local_tri.adj2))] else -1,
            };
            if (predicates.orient2d(engine.getVertex(tri.v0), engine.getVertex(tri.v1), engine.getVertex(tri.v2)) < 0.0) return error.InvalidCavity;
            engine.mesh.setTriangleFresh(emitted.items[base + i], tri);
        }
    }

    fn linkCentralConstraint(engine: *triangulate.Engine, emitted: []const i32, start_pt_idx: i32, end_pt_idx: i32) !void {
        var first: i32 = -1;
        var second: i32 = -1;
        for (emitted) |tri_idx| {
            const tri = engine.mesh.triangles.get(@as(usize, @intCast(tri_idx)));
            if (triangulate.Engine.edgeSide(tri, start_pt_idx, end_pt_idx) == null) continue;
            if (first == -1) {
                first = tri_idx;
            } else {
                second = tri_idx;
                break;
            }
        }
        if (first != -1 and second != -1) {
            try engine.linkTrianglesByEdge(first, second, start_pt_idx, end_pt_idx);
        }
    }

    pub fn triangulatePseudoPolygon(
        self: *Corridor,
        allocator: std.mem.Allocator,
        engine: *triangulate.Engine,
        arena: *mesh.ThreadArena,
        start_pt_idx: i32,
        end_pt_idx: i32,
        wall: []const i32,
        is_left: bool,
        emitted: *std.ArrayListUnmanaged(i32),
    ) !void {
        _ = self;
        if (wall.len == 0) return;

        var stack: std.ArrayListUnmanaged(i32) = .empty;
        defer stack.deinit(allocator);

        try stack.append(allocator, start_pt_idx);
        try stack.append(allocator, wall[0]);

        for (wall[1..]) |p_idx| {
            const p = engine.getVertex(p_idx);
            while (stack.items.len >= 2) {
                const top_idx = stack.items[stack.items.len - 1];
                const prev_idx = stack.items[stack.items.len - 2];

                const top = engine.getVertex(top_idx);
                const prev = engine.getVertex(prev_idx);

                const orient = predicates.orient2d(prev, top, p);

                // If it's the left wall, CCW (orient > 0) is inside.
                // If it's the right wall, CW (orient < 0) is inside.
                const is_convex = if (is_left) orient < 0.0 else orient > 0.0;

                if (is_convex) {
                    // Create triangle
                    const new_tri_idx = arena.getFreeSlot() orelse @as(i32, @intCast(engine.mesh.triangles.len));
                    try engine.mesh.ensureTriangleSlot(allocator, new_tri_idx);
                    try emitted.append(allocator, new_tri_idx);

                    const t0 = prev_idx;
                    var t1 = p_idx;
                    var t2 = top_idx;

                    // Enforce CCW
                    if (predicates.orient2d(engine.getVertex(t0), engine.getVertex(t1), engine.getVertex(t2)) < 0.0) {
                        const tmp = t1;
                        t1 = t2;
                        t2 = tmp;
                    }

                    engine.mesh.setTriangleFresh(new_tri_idx, .{
                        .v0 = t0,
                        .v1 = t1,
                        .v2 = t2,
                        .adj0 = -1, // Adjacency linking is omitted for brevity
                        .adj1 = -1,
                        .adj2 = -1,
                    });

                    _ = stack.pop();
                } else {
                    break;
                }
            }
            try stack.append(allocator, p_idx);
        }

        // Connect remaining stack to end_pt
        const p_idx = end_pt_idx;
        while (stack.items.len >= 2) {
            const top_idx = stack.items[stack.items.len - 1];
            const prev_idx = stack.items[stack.items.len - 2];

            const new_tri_idx = arena.getFreeSlot() orelse @as(i32, @intCast(engine.mesh.triangles.len));
            try engine.mesh.ensureTriangleSlot(allocator, new_tri_idx);
            try emitted.append(allocator, new_tri_idx);

            const t0 = prev_idx;
            var t1 = p_idx;
            var t2 = top_idx;

            if (predicates.orient2d(engine.getVertex(t0), engine.getVertex(t1), engine.getVertex(t2)) < 0.0) {
                const tmp = t1;
                t1 = t2;
                t2 = tmp;
            }

            engine.mesh.setTriangleFresh(new_tri_idx, .{
                .v0 = t0,
                .v1 = t1,
                .v2 = t2,
                .adj0 = -1,
                .adj1 = -1,
                .adj2 = -1,
            });

            _ = stack.pop();
        }
    }

    pub fn clearAndRetriangulate(self: *Corridor, allocator: std.mem.Allocator, engine: *triangulate.Engine, arena: *mesh.ThreadArena, start_pt_idx: i32, end_pt_idx: i32) !void {
        const scratch_allocator = arena.resetScratch(allocator);

        var edge_counts = std.AutoHashMap(EdgeKey, usize).init(scratch_allocator);
        defer edge_counts.deinit();

        try self.countPiercedEdges(engine, &edge_counts);

        var outer_edges: std.ArrayListUnmanaged(BoundaryEdge) = .empty;
        try self.collectOuterBoundaryEdges(scratch_allocator, engine, &edge_counts, &outer_edges);

        var used_boundary_fallback = false;
        var left_wall = self.left_vertices.items;
        var right_wall = self.right_vertices.items;
        if (self.left_vertices.items.len == 0 or self.right_vertices.items.len == 0) {
            used_boundary_fallback = true;
            try self.augmentPiercedBySegmentScan(allocator, engine, start_pt_idx, end_pt_idx);
            edge_counts.clearRetainingCapacity();
            try self.countPiercedEdges(engine, &edge_counts);
            try self.collectOuterBoundaryEdges(scratch_allocator, engine, &edge_counts, &outer_edges);

            var boundary_nodes = std.AutoHashMap(i32, BoundaryNode).init(scratch_allocator);
            defer boundary_nodes.deinit();
            try buildBoundaryNodesFromEdgeCounts(engine, &edge_counts, &boundary_nodes);
            try validateBoundaryDegrees(&boundary_nodes, start_pt_idx, end_pt_idx);

            const start_node = boundary_nodes.get(start_pt_idx) orelse return error.InvalidCorridorBoundary;
            const end_node = boundary_nodes.get(end_pt_idx) orelse return error.InvalidCorridorBoundary;
            if (start_node.degree < 2 or end_node.degree < 2) return error.InvalidCorridorBoundary;

            var candidates: std.ArrayListUnmanaged(ChainCandidate) = .empty;
            for (start_node.neighbors[0..start_node.degree]) |neighbor| {
                var chain: std.ArrayListUnmanaged(i32) = .empty;
                traceBoundaryChain(&boundary_nodes, scratch_allocator, start_pt_idx, end_pt_idx, neighbor, &chain) catch continue;
                const side_score = chainSideScore(engine, start_pt_idx, end_pt_idx, chain.items);
                try candidates.append(scratch_allocator, .{
                    .side = side_score.side,
                    .score = side_score.score,
                    .vertices = chain,
                });
            }

            var left_chain: ?usize = null;
            var right_chain: ?usize = null;
            for (candidates.items, 0..) |candidate, idx| {
                if (candidate.side > 0) {
                    if (left_chain == null or candidate.score < candidates.items[left_chain.?].score) left_chain = idx;
                } else if (candidate.side < 0) {
                    if (right_chain == null or candidate.score < candidates.items[right_chain.?].score) right_chain = idx;
                }
            }

            if (left_chain == null or right_chain == null) return error.InvalidCorridorBoundary;
            left_wall = candidates.items[left_chain.?].vertices.items;
            right_wall = candidates.items[right_chain.?].vertices.items;
        }

        var local_cavities = LocalCavityPair{};
        var use_local_cavity = !used_boundary_fallback and shouldUseLocalCavity(left_wall, right_wall, self.pierced_triangles.items);
        if (use_local_cavity) {
            buildLocalCavities(scratch_allocator, engine, start_pt_idx, end_pt_idx, left_wall, right_wall, outer_edges.items, &local_cavities) catch |err| {
                switch (err) {
                    error.InvalidCavity, error.NonDelaunayLocalCavity => use_local_cavity = false,
                    else => return err,
                }
            };
        }

        var footprint: std.ArrayListUnmanaged(i32) = .empty;
        try self.collectTransactionFootprint(scratch_allocator, engine, outer_edges.items, &footprint);

        var expected_versions: std.ArrayListUnmanaged(triangulate.TriangleVersionSnapshot) = .empty;
        if (!try engine.snapshotTransactionFootprint(scratch_allocator, footprint.items, &expected_versions)) return error.TransactionConflict;

        var tx = triangulate.TriangleTransaction{};
        if (!try engine.beginTriangleTransactionWithVersions(scratch_allocator, footprint.items, expected_versions.items, &tx)) return error.TransactionConflict;
        errdefer engine.endTriangleTransaction(&tx);

        // 2. Detach live outer neighbors from the soon-to-be-cleared corridor.
        for (self.pierced_triangles.items) |t_idx| {
            const tri = engine.mesh.triangles.get(@as(usize, @intCast(t_idx)));
            const neighbors = [_]i32{ tri.adj0, tri.adj1, tri.adj2 };

            for (neighbors) |neighbor_idx| {
                if (neighbor_idx == -1) continue;

                var neighbor_is_pierced = false;
                for (self.pierced_triangles.items) |pierced_idx| {
                    if (neighbor_idx == pierced_idx) {
                        neighbor_is_pierced = true;
                        break;
                    }
                }
                if (neighbor_is_pierced) continue;

                const neighbor_slot = @as(usize, @intCast(neighbor_idx));
                var neighbor = engine.mesh.triangles.get(neighbor_slot);
                if (mesh.isDeadTriangle(neighbor)) continue;
                if (neighbor.adj0 == t_idx) neighbor.adj0 = -1;
                if (neighbor.adj1 == t_idx) neighbor.adj1 = -1;
                if (neighbor.adj2 == t_idx) neighbor.adj2 = -1;
                engine.mesh.setTriangle(neighbor_idx, neighbor);
            }
        }

        // 3. Tombstone all pierced triangles after their boundary data has been read.
        for (self.pierced_triangles.items) |t_idx| {
            engine.mesh.markDead(t_idx);
            try arena.tombstone(allocator, t_idx);
        }

        var emitted: std.ArrayListUnmanaged(i32) = .empty;

        if (use_local_cavity) {
            try emitLocalTriangles(scratch_allocator, engine, arena, local_cavities.left.items, &emitted);
            try emitLocalTriangles(scratch_allocator, engine, arena, local_cavities.right.items, &emitted);
            try linkCentralConstraint(engine, emitted.items, start_pt_idx, end_pt_idx);
        } else {
            try self.triangulatePseudoPolygon(scratch_allocator, engine, arena, start_pt_idx, end_pt_idx, left_wall, true, &emitted);
            try self.triangulatePseudoPolygon(scratch_allocator, engine, arena, start_pt_idx, end_pt_idx, right_wall, false, &emitted);
            try engine.linkNewTriangles(emitted.items);
        }

        for (outer_edges.items) |edge| {
            for (emitted.items) |new_tri_idx| {
                const new_tri = engine.mesh.triangles.get(@as(usize, @intCast(new_tri_idx)));
                if (triangulate.Engine.edgeSide(new_tri, edge.v1, edge.v2) != null) {
                    try engine.linkTrianglesByEdge(new_tri_idx, edge.adj_tri, edge.v1, edge.v2);
                    break;
                }
            }
        }

        if (!try engine.setConstrainedEdgeByVertices(start_pt_idx, end_pt_idx, true)) return error.MissingConstraintEdge;
        if (!use_local_cavity) {
            // A concurrent worker should abort and retry if legalization needs to
            // expand beyond the locked corridor footprint.
            try engine.legalizeFromTrianglesInTransaction(scratch_allocator, emitted.items, &tx);
        }
        engine.endTriangleTransaction(&tx);
    }

    pub fn recoverConstraint(self: *Corridor, allocator: std.mem.Allocator, engine: *triangulate.Engine, arena: *mesh.ThreadArena, start_pt_idx: i32, end_pt_idx: i32) !void {
        if (engine.hasLiveEdge(start_pt_idx, end_pt_idx)) {
            _ = try engine.setConstrainedEdgeByVertices(start_pt_idx, end_pt_idx, true);
            return;
        }

        const start_pt = engine.getVertex(start_pt_idx);

        for (0..triangulate.max_transaction_attempts) |_| {
            const start_tri = engine.walk(engine.last_valid_tri, start_pt);
            if (start_tri < 0) return error.WalkFailed;

            try self.trace(allocator, engine, start_tri, end_pt_idx, start_pt_idx);
            self.clearAndRetriangulate(allocator, engine, arena, start_pt_idx, end_pt_idx) catch |err| {
                switch (err) {
                    error.TransactionConflict => continue,
                    else => return err,
                }
            };
            return;
        }

        return error.TransactionConflict;
    }
};

test "corridor trace" {
    var engine = triangulate.Engine.init(std.testing.allocator);
    defer engine.deinit();

    var arena = mesh.ThreadArena{};
    defer arena.deinit(std.testing.allocator);

    const vertices = [_]mesh.Vertex{
        .{ .x = 10.0, .y = 10.0 },
        .{ .x = 20.0, .y = 20.0 },
    };

    try engine.initSuperTriangle(&vertices);

    // Insert some points
    _ = try engine.insertPoint(&arena, mesh.Vertex{ .x = 12.0, .y = 15.0 });
    _ = try engine.insertPoint(&arena, mesh.Vertex{ .x = 18.0, .y = 15.0 });

    var corridor = Corridor{};
    defer corridor.deinit(std.testing.allocator);

    const start_idx: i32 = 3;
    const end_idx: i32 = 4;
    const start_pt = engine.getVertex(start_idx); // The first inserted point

    const start_tri = engine.walk(0, start_pt); // Find triangle containing start_pt

    try corridor.trace(std.testing.allocator, &engine, start_tri, end_idx, start_idx);

    try std.testing.expect(corridor.pierced_triangles.items.len > 0);
    const end_pt = engine.getVertex(end_idx);
    for (corridor.left_vertices.items) |vertex_idx| {
        try std.testing.expect(predicates.orient2d(start_pt, end_pt, engine.getVertex(vertex_idx)) > 0.0);
    }
    for (corridor.right_vertices.items) |vertex_idx| {
        try std.testing.expect(predicates.orient2d(start_pt, end_pt, engine.getVertex(vertex_idx)) < 0.0);
    }
}

test "corridor cavity vertex ordering" {
    var left: std.ArrayListUnmanaged(i32) = .empty;
    var right: std.ArrayListUnmanaged(i32) = .empty;
    defer left.deinit(std.testing.allocator);
    defer right.deinit(std.testing.allocator);

    const wall = [_]i32{ 10, 11, 12 };
    try Corridor.buildLeftCavityVertices(std.testing.allocator, 1, 2, &wall, &left);
    try Corridor.buildRightCavityVertices(std.testing.allocator, 1, 2, &wall, &right);

    try std.testing.expectEqualSlices(i32, &[_]i32{ 2, 12, 11, 10, 1 }, left.items);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 10, 11, 12, 2 }, right.items);
}

fn validateFixtureConstraintRecovery(allocator: std.mem.Allocator, fixture_path: []const u8) !void {
    const fixture = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, fixture_path, allocator, .limited(1024 * 1024));
    defer allocator.free(fixture);

    const points = try parser.parseDatString(allocator, fixture);
    defer allocator.free(points);

    const vertices = try allocator.alloc(mesh.Vertex, points.len);
    defer allocator.free(vertices);
    for (points, 0..) |p, i| {
        vertices[i] = .{ .x = p.x, .y = p.y };
    }

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
        try engine.validateTopology();
    }

    var corridor = Corridor{};
    defer corridor.deinit(allocator);

    for (0..vertices.len) |i| {
        const start_idx = mesh_ids[i];
        const end_idx = mesh_ids[(i + 1) % vertices.len];
        try corridor.recoverConstraint(allocator, &engine, &arena, start_idx, end_idx);
        try engine.validateTopology();
        try engine.validateConstraintFlags();
        try engine.validateCdtLegality();
    }

    try engine.validateConstraintRing(mesh_ids);
    try engine.validateConstraintRingFlags(mesh_ids);
}

test "fixture constraint recovery remains manifold" {
    const allocator = std.testing.allocator;
    try validateFixtureConstraintRecovery(allocator, "tests/fixtures/test.dat");
    try validateFixtureConstraintRecovery(allocator, "tests/fixtures/diamond.dat");
    try validateFixtureConstraintRecovery(allocator, "tests/fixtures/star.dat");
    try validateFixtureConstraintRecovery(allocator, "tests/fixtures/dude.dat");
}
