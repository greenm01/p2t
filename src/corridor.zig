const std = @import("std");
const mesh = @import("mesh.zig");
const triangulate = @import("triangulate.zig");
const predicates = @import("predicates.zig");
const parser = @import("parser.zig");
const spatial = @import("spatial.zig");

pub const Corridor = struct {
    pierced_triangles: std.ArrayListUnmanaged(i32) = .empty,

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

        fn deinit(self: *ChainCandidate, allocator: std.mem.Allocator) void {
            self.vertices.deinit(allocator);
        }
    };

    pub fn deinit(self: *Corridor, allocator: std.mem.Allocator) void {
        self.pierced_triangles.deinit(allocator);
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

    pub fn trace(self: *Corridor, allocator: std.mem.Allocator, engine: *triangulate.Engine, start_tri: i32, end_pt: mesh.Vertex, start_pt: mesh.Vertex) !void {
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
            if ((v0.x == end_pt.x and v0.y == end_pt.y) or
                (v1.x == end_pt.x and v1.y == end_pt.y) or
                (v2.x == end_pt.x and v2.y == end_pt.y))
            {
                break;
            }

            // Which edge does the segment (start_pt, end_pt) intersect?
            // We check the 3 edges. We don't want to step back, so we should step forward.
            // A segment intersects an edge if `intersect` is true.
            // Also need to handle collinear cases or vertex intersections in a robust way,
            // but for a strict Delaunay base mesh without co-circular/collinear degeneracies,
            // strict intersection works.

            var next_tri: i32 = -1;

            if (predicates.intersect(start_pt, end_pt, v0, v1)) {
                // To avoid stepping backwards, we should verify it's moving closer to end_pt
                // Actually, if it intersects and is not the triangle we came from, we can go there.
                // But since we just append, let's just check if we already visited it.
                if (self.pierced_triangles.items.len < 2 or self.pierced_triangles.items[self.pierced_triangles.items.len - 2] != tri.adj0) {
                    next_tri = tri.adj0;
                }
            }
            if (next_tri == -1 and predicates.intersect(start_pt, end_pt, v1, v2)) {
                if (self.pierced_triangles.items.len < 2 or self.pierced_triangles.items[self.pierced_triangles.items.len - 2] != tri.adj1) {
                    next_tri = tri.adj1;
                }
            }
            if (next_tri == -1 and predicates.intersect(start_pt, end_pt, v2, v0)) {
                if (self.pierced_triangles.items.len < 2 or self.pierced_triangles.items[self.pierced_triangles.items.len - 2] != tri.adj2) {
                    next_tri = tri.adj2;
                }
            }

            if (next_tri == -1) {
                // Should not happen in a valid mesh unless we hit an exact vertex.
                // For this proof of concept, we just break.
                break;
            }

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

    fn buildBoundaryGraph(
        self: *Corridor,
        engine: *triangulate.Engine,
        edge_counts: *std.AutoHashMap(EdgeKey, usize),
        nodes: *std.AutoHashMap(i32, BoundaryNode),
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
        try self.augmentPiercedBySegmentScan(allocator, engine, start_pt_idx, end_pt_idx);

        var edge_counts = std.AutoHashMap(EdgeKey, usize).init(allocator);
        defer edge_counts.deinit();

        var boundary_nodes = std.AutoHashMap(i32, BoundaryNode).init(allocator);
        defer boundary_nodes.deinit();

        try self.buildBoundaryGraph(engine, &edge_counts, &boundary_nodes);
        try validateBoundaryDegrees(&boundary_nodes, start_pt_idx, end_pt_idx);

        var outer_edges: std.ArrayListUnmanaged(BoundaryEdge) = .empty;
        defer outer_edges.deinit(allocator);
        try self.collectOuterBoundaryEdges(allocator, engine, &edge_counts, &outer_edges);

        const start_node = boundary_nodes.get(start_pt_idx) orelse {
            std.debug.print("InvalidCorridorBoundary: missing start vertex {d} in boundary\n", .{start_pt_idx});
            return error.InvalidCorridorBoundary;
        };
        const end_node = boundary_nodes.get(end_pt_idx) orelse {
            std.debug.print("InvalidCorridorBoundary: missing end vertex {d} in boundary\n", .{end_pt_idx});
            return error.InvalidCorridorBoundary;
        };
        if (start_node.degree < 2 or end_node.degree < 2) {
            std.debug.print("InvalidCorridorBoundary: endpoint degrees start {d}:{d}, end {d}:{d}\n", .{ start_pt_idx, start_node.degree, end_pt_idx, end_node.degree });
            return error.InvalidCorridorBoundary;
        }

        var candidates: std.ArrayListUnmanaged(ChainCandidate) = .empty;
        defer {
            for (candidates.items) |*candidate| candidate.deinit(allocator);
            candidates.deinit(allocator);
        }

        for (start_node.neighbors[0..start_node.degree]) |neighbor| {
            var chain: std.ArrayListUnmanaged(i32) = .empty;
            traceBoundaryChain(&boundary_nodes, allocator, start_pt_idx, end_pt_idx, neighbor, &chain) catch {
                chain.deinit(allocator);
                continue;
            };
            const side_score = chainSideScore(engine, start_pt_idx, end_pt_idx, chain.items);
            try candidates.append(allocator, .{
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

        if (left_chain == null or right_chain == null) {
            std.debug.print("InvalidCorridorBoundary: could not split {d} chains into opposite sides\n", .{candidates.items.len});
            return error.InvalidCorridorBoundary;
        }

        var footprint: std.ArrayListUnmanaged(i32) = .empty;
        defer footprint.deinit(allocator);
        try self.collectTransactionFootprint(allocator, engine, outer_edges.items, &footprint);

        var expected_versions: std.ArrayListUnmanaged(triangulate.TriangleVersionSnapshot) = .empty;
        defer expected_versions.deinit(allocator);
        if (!try engine.snapshotTransactionFootprint(allocator, footprint.items, &expected_versions)) return error.TransactionConflict;

        var tx = triangulate.TriangleTransaction{};
        defer tx.deinit(allocator);
        if (!try engine.beginTriangleTransactionWithVersions(allocator, footprint.items, expected_versions.items, &tx)) return error.TransactionConflict;
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
        defer emitted.deinit(allocator);

        try self.triangulatePseudoPolygon(allocator, engine, arena, start_pt_idx, end_pt_idx, candidates.items[left_chain.?].vertices.items, true, &emitted);
        try self.triangulatePseudoPolygon(allocator, engine, arena, start_pt_idx, end_pt_idx, candidates.items[right_chain.?].vertices.items, false, &emitted);

        try engine.linkNewTriangles(emitted.items);
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
        // This is still single-thread scaffolding: legalization can currently
        // expand past the original corridor footprint as it flips edges.
        try engine.legalizeFromTriangles(allocator, emitted.items);
        engine.endTriangleTransaction(&tx);
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

    const start_pt = engine.getVertex(3); // The first inserted point
    const end_pt = engine.getVertex(4); // The second inserted point

    const start_tri = engine.walk(0, start_pt); // Find triangle containing start_pt

    try corridor.trace(std.testing.allocator, &engine, start_tri, end_pt, start_pt);

    try std.testing.expect(corridor.pierced_triangles.items.len > 0);
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

        if (engine.hasLiveEdge(start_idx, end_idx)) {
            _ = try engine.setConstrainedEdgeByVertices(start_idx, end_idx, true);
            continue;
        }

        const start_pt = engine.getVertex(start_idx);
        const end_pt = engine.getVertex(end_idx);

        corridor.pierced_triangles.clearRetainingCapacity();

        const start_tri = engine.walk(engine.last_valid_tri, start_pt);
        try std.testing.expect(start_tri >= 0);
        try corridor.trace(allocator, &engine, start_tri, end_pt, start_pt);
        try corridor.clearAndRetriangulate(allocator, &engine, &arena, start_idx, end_idx);
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
