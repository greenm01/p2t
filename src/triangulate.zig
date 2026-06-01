const std = @import("std");
const mesh = @import("mesh.zig");
const spatial = @import("spatial.zig");
const predicates = @import("predicates.zig");

pub const Edge = struct {
    adj_tri: i32,
    v1: i32,
    v2: i32,
    old_tri: i32,
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

    pub fn init(allocator: std.mem.Allocator) Engine {
        return .{
            .mesh = mesh.GlobalMesh{},
            .allocator = allocator,
            .last_valid_tri = 0,
            .cavity_edge_counter = .{},
        };
    }

    pub fn deinit(self: *Engine) void {
        self.cavity_edge_counter.deinit(self.allocator);
        self.mesh.deinit(self.allocator);
    }

    pub fn initSuperTriangle(self: *Engine, vertices: []const mesh.Vertex) !void {
        const bounds = spatial.BoundingBox.fromVertices(vertices);
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

        try self.mesh.vertices.append(self.allocator, v0);
        try self.mesh.vertices.append(self.allocator, v1);
        try self.mesh.vertices.append(self.allocator, v2);

        try self.mesh.triangles.append(self.allocator, .{
            .v0 = 0,
            .v1 = 2,
            .v2 = 1,
            .adj0 = -1,
            .adj1 = -1,
            .adj2 = -1,
            .lock = 0,
        });
        self.last_valid_tri = 0;
    }

    pub fn walk(self: *Engine, start_tri: i32, target: mesh.Vertex) i32 {
        var curr = start_tri;
        var limit: usize = 10000;

        while (curr != -1 and limit > 0) : (limit -= 1) {
            const tri = self.mesh.triangles.get(@as(usize, @intCast(curr)));
            if (mesh.isDeadTriangle(tri)) break;

            const v0 = self.mesh.vertices.get(@as(usize, @intCast(tri.v0)));
            const v1 = self.mesh.vertices.get(@as(usize, @intCast(tri.v1)));
            const v2 = self.mesh.vertices.get(@as(usize, @intCast(tri.v2)));

            if (predicates.orient2d(v0, v1, target) < 0.0) {
                curr = tri.adj0;
                continue;
            }
            if (predicates.orient2d(v1, v2, target) < 0.0) {
                curr = tri.adj1;
                continue;
            }
            if (predicates.orient2d(v2, v0, target) < 0.0) {
                curr = tri.adj2;
                continue;
            }

            return curr;
        }

        // Linear scan fallback
        var i: usize = 0;
        while (i < self.mesh.triangles.len) : (i += 1) {
            const tri = self.mesh.triangles.get(i);
            if (mesh.isDeadTriangle(tri)) continue;
            const v0 = self.mesh.vertices.get(@as(usize, @intCast(tri.v0)));
            const v1 = self.mesh.vertices.get(@as(usize, @intCast(tri.v1)));
            const v2 = self.mesh.vertices.get(@as(usize, @intCast(tri.v2)));

            if (predicates.orient2d(v0, v1, target) >= 0.0 and
                predicates.orient2d(v1, v2, target) >= 0.0 and
                predicates.orient2d(v2, v0, target) >= 0.0)
            {
                return @as(i32, @intCast(i));
            }
        }

        return -1;
    }

    pub fn getVertex(self: *Engine, idx: i32) mesh.Vertex {
        return self.mesh.vertices.get(@as(usize, @intCast(idx)));
    }

    pub fn triangleAdj(tri: mesh.Triangle, side: usize) i32 {
        return switch (side) {
            0 => tri.adj0,
            1 => tri.adj1,
            else => tri.adj2,
        };
    }

    pub fn setTriangleAdj(tri: *mesh.Triangle, side: usize, neighbor: i32) void {
        switch (side) {
            0 => tri.adj0 = neighbor,
            1 => tri.adj1 = neighbor,
            else => tri.adj2 = neighbor,
        }
    }

    pub fn triangleEdge(tri: mesh.Triangle, side: usize) struct { v1: i32, v2: i32 } {
        return switch (side) {
            0 => .{ .v1 = tri.v0, .v2 = tri.v1 },
            1 => .{ .v1 = tri.v1, .v2 = tri.v2 },
            else => .{ .v1 = tri.v2, .v2 = tri.v0 },
        };
    }

    pub fn edgeSide(tri: mesh.Triangle, a: i32, b: i32) ?usize {
        inline for (0..3) |side| {
            const edge = triangleEdge(tri, side);
            if ((edge.v1 == a and edge.v2 == b) or (edge.v1 == b and edge.v2 == a)) {
                return side;
            }
        }
        return null;
    }

    pub fn linkTriangleSides(self: *Engine, tri_a_idx: i32, side_a: usize, tri_b_idx: i32, side_b: usize) !void {
        if (tri_a_idx < 0 or tri_b_idx < 0) return;
        const tri_a_slot = @as(usize, @intCast(tri_a_idx));
        const tri_b_slot = @as(usize, @intCast(tri_b_idx));
        if (tri_a_slot >= self.mesh.triangles.len or tri_b_slot >= self.mesh.triangles.len) return error.InvalidTriangleAdjacency;

        var tri_a = self.mesh.triangles.get(tri_a_slot);
        var tri_b = self.mesh.triangles.get(tri_b_slot);
        if (mesh.isDeadTriangle(tri_a) or mesh.isDeadTriangle(tri_b)) return error.InvalidTriangleAdjacency;

        setTriangleAdj(&tri_a, side_a, tri_b_idx);
        setTriangleAdj(&tri_b, side_b, tri_a_idx);
        self.mesh.triangles.set(tri_a_slot, tri_a);
        self.mesh.triangles.set(tri_b_slot, tri_b);
    }

    pub fn linkTrianglesByEdge(self: *Engine, tri_a_idx: i32, tri_b_idx: i32, edge_v1: i32, edge_v2: i32) !void {
        if (tri_a_idx < 0 or tri_b_idx < 0) return;
        const tri_a = self.mesh.triangles.get(@as(usize, @intCast(tri_a_idx)));
        const tri_b = self.mesh.triangles.get(@as(usize, @intCast(tri_b_idx)));
        const side_a = edgeSide(tri_a, edge_v1, edge_v2) orelse return error.InvalidTriangleAdjacency;
        const side_b = edgeSide(tri_b, edge_v1, edge_v2) orelse return error.InvalidTriangleAdjacency;
        try self.linkTriangleSides(tri_a_idx, side_a, tri_b_idx, side_b);
    }

    pub fn linkNewTriangles(self: *Engine, new_tri_indices: []const i32) !void {
        for (new_tri_indices, 0..) |tri_a_idx, i| {
            const tri_a = self.mesh.triangles.get(@as(usize, @intCast(tri_a_idx)));
            if (mesh.isDeadTriangle(tri_a)) continue;

            for (new_tri_indices[i + 1 ..]) |tri_b_idx| {
                const tri_b = self.mesh.triangles.get(@as(usize, @intCast(tri_b_idx)));
                if (mesh.isDeadTriangle(tri_b)) continue;

                inline for (0..3) |side_a| {
                    const edge = triangleEdge(tri_a, side_a);
                    if (edgeSide(tri_b, edge.v1, edge.v2)) |side_b| {
                        try self.linkTriangleSides(tri_a_idx, side_a, tri_b_idx, side_b);
                    }
                }
            }
        }
    }

    pub fn liveTriangleCount(self: *Engine) usize {
        var count: usize = 0;
        for (0..self.mesh.triangles.len) |i| {
            if (!mesh.isDeadTriangle(self.mesh.triangles.get(i))) count += 1;
        }
        return count;
    }

    pub fn hasLiveEdge(self: *Engine, a: i32, b: i32) bool {
        for (0..self.mesh.triangles.len) |i| {
            const tri = self.mesh.triangles.get(i);
            if (mesh.isDeadTriangle(tri)) continue;
            if (edgeSide(tri, a, b) != null) return true;
        }
        return false;
    }

    pub fn validateTopology(self: *Engine) !void {
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
            self.mesh.triangles.set(i, tri);
        }

        for (0..self.mesh.triangles.len) |i| {
            const tri = self.mesh.triangles.get(i);
            if (mesh.isDeadTriangle(tri)) continue;
            for (0..3) |side| {
                const edge = triangleEdge(tri, side);
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
                    self.mesh.triangles.set(i, tri_mut);
                    self.mesh.triangles.set(@as(usize, @intCast(other.tri)), other_mut);
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
        if (tri_idx == -1) return false;
        const tri = self.mesh.triangles.get(@as(usize, @intCast(tri_idx)));
        if (mesh.isDeadTriangle(tri)) return false;
        const v0 = self.getVertex(tri.v0);
        const v1 = self.getVertex(tri.v1);
        const v2 = self.getVertex(tri.v2);
        return predicates.incircle(v0, v1, v2, pt) > 0.0;
    }

    fn cavityContains(cavity: []const i32, tri_idx: i32) bool {
        for (cavity) |c_idx| {
            if (c_idx == tri_idx) return true;
        }
        return false;
    }

    fn extractCavityBoundary(self: *Engine, cavity: []const i32, edges: *std.ArrayListUnmanaged(Edge)) !void {
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

        try self.cavity_edge_counter.appendBoundaryTo(self.allocator, edges);

        for (edges.items) |e| {
            if (e.adj_tri != -1 and cavityContains(cavity, e.adj_tri)) {
                std.debug.print("InvalidCavityBoundary: boundary edge ({d},{d}) still points into cavity tri {d}\n", .{ e.v1, e.v2, e.adj_tri });
                return error.InvalidCavityBoundary;
            }
        }
    }

    fn pointOnTriangleEdge(self: *Engine, tri: mesh.Triangle, pt: mesh.Vertex) bool {
        inline for (0..3) |side| {
            const edge = triangleEdge(tri, side);
            if (predicates.pointOnSegment(
                self.getVertex(edge.v1),
                self.getVertex(edge.v2),
                pt,
            )) return true;
        }
        return false;
    }

    fn boundaryHasPinch(edges: []const Edge) bool {
        for (edges) |edge| {
            var v1_count: usize = 0;
            var v2_count: usize = 0;
            for (edges) |other| {
                if (other.v1 == edge.v1 or other.v2 == edge.v1) v1_count += 1;
                if (other.v1 == edge.v2 or other.v2 == edge.v2) v2_count += 1;
            }
            if (v1_count > 2 or v2_count > 2) return true;
        }
        return false;
    }

    fn completeCavityByGlobalScan(self: *Engine, cavity: *std.ArrayListUnmanaged(i32), pt: mesh.Vertex) !bool {
        var added = false;
        for (0..self.mesh.triangles.len) |tri_idx| {
            const tri_i32 = @as(i32, @intCast(tri_idx));
            if (cavityContains(cavity.items, tri_i32)) continue;

            const tri = self.mesh.triangles.get(tri_idx);
            if (mesh.isDeadTriangle(tri)) continue;

            if (self.isInsideCircumcircle(tri_i32, pt) or self.pointOnTriangleEdge(tri, pt)) {
                try cavity.append(self.allocator, tri_i32);
                added = true;
            }
        }
        return added;
    }

    fn repairBoundaryNonManifoldEdges(self: *Engine, cavity: *std.ArrayListUnmanaged(i32), edges: []const Edge) !bool {
        var added = false;
        for (edges) |edge| {
            var outside_count: usize = 0;
            for (0..self.mesh.triangles.len) |tri_idx| {
                const tri_i32 = @as(i32, @intCast(tri_idx));
                if (cavityContains(cavity.items, tri_i32)) continue;

                const tri = self.mesh.triangles.get(tri_idx);
                if (mesh.isDeadTriangle(tri)) continue;
                if (edgeSide(tri, edge.v1, edge.v2) == null) continue;

                outside_count += 1;
                if (outside_count > 1 and !cavityContains(cavity.items, tri_i32)) {
                    try cavity.append(self.allocator, tri_i32);
                    added = true;
                }
            }
        }
        return added;
    }

    // Simplified Bowyer-Watson insertion for testing
    pub fn insertPoint(self: *Engine, arena: *mesh.ThreadArena, pt: mesh.Vertex) !i32 {
        // Prevent duplicate or extremely close points
        var v_idx: usize = 0;
        while (v_idx < self.mesh.vertices.len) : (v_idx += 1) {
            const existing_v = self.mesh.vertices.get(v_idx);
            if (@abs(existing_v.x - pt.x) < 1e-6 and @abs(existing_v.y - pt.y) < 1e-6) {
                return @as(i32, @intCast(v_idx));
            }
        }

        const pt_idx = @as(i32, @intCast(self.mesh.vertices.len));
        try self.mesh.vertices.append(self.allocator, pt);

        const start_tri = self.last_valid_tri;
        const container = self.walk(start_tri, pt);

        if (container < 0) {
            std.debug.print("Walk failed for point {d}, {d} with code {d}\n", .{ pt.x, pt.y, container });
            return error.WalkFailed;
        }

        var cavity: std.ArrayListUnmanaged(i32) = .empty;
        defer cavity.deinit(self.allocator);

        var edges: std.ArrayListUnmanaged(Edge) = .empty;
        defer edges.deinit(self.allocator);

        try cavity.append(self.allocator, container);

        var i: usize = 0;
        while (i < cavity.items.len) : (i += 1) {
            const t_idx = cavity.items[i];
            const tri = self.mesh.triangles.get(@as(usize, @intCast(t_idx)));
            const neighbors = [_]i32{ tri.adj0, tri.adj1, tri.adj2 };

            for (neighbors, 0..) |n_idx, side| {
                if (cavityContains(cavity.items, n_idx)) continue;

                const edge = triangleEdge(tri, side);
                const point_on_edge = n_idx != -1 and predicates.pointOnSegment(
                    self.getVertex(edge.v1),
                    self.getVertex(edge.v2),
                    pt,
                );

                if (point_on_edge or self.isInsideCircumcircle(n_idx, pt)) {
                    try cavity.append(self.allocator, n_idx);
                }
            }
        }

        while (true) {
            try self.extractCavityBoundary(cavity.items, &edges);

            if (try self.repairBoundaryNonManifoldEdges(&cavity, edges.items)) {
                continue;
            }

            if (boundaryHasPinch(edges.items)) {
                const repaired = try self.completeCavityByGlobalScan(&cavity, pt);
                if (!repaired) {
                    std.debug.print("InvalidCavityBoundary: pinched boundary could not be repaired for point {d},{d}\n", .{ pt.x, pt.y });
                    return error.InvalidCavityBoundary;
                }
                continue;
            }

            break;
        }

        // Tombstone cavity
        for (cavity.items) |t_idx| {
            self.mesh.markDead(t_idx);
            try arena.tombstone(self.allocator, t_idx);
        }

        var new_tri_indices: std.ArrayListUnmanaged(i32) = .empty;
        defer new_tri_indices.deinit(self.allocator);

        for (edges.items) |_| {
            const new_idx = arena.getFreeSlot() orelse @as(i32, @intCast(self.mesh.triangles.len));
            try new_tri_indices.append(self.allocator, new_idx);

            if (new_idx == self.mesh.triangles.len) {
                try self.mesh.triangles.append(self.allocator, undefined); // Placeholder
            }
        }

        // Setup the new triangles and link them
        for (edges.items, 0..) |e, edge_i| {
            const t_idx = new_tri_indices.items[edge_i];
            self.last_valid_tri = t_idx;

            var a = e.v1;
            var b = e.v2;
            const c = pt_idx;
            if (predicates.orient2d(self.getVertex(a), self.getVertex(b), self.getVertex(c)) < 0.0) {
                const tmp = a;
                a = b;
                b = tmp;
            }

            self.mesh.triangles.set(@as(usize, @intCast(t_idx)), .{
                .v0 = a,
                .v1 = b,
                .v2 = c,
                .adj0 = -1,
                .adj1 = -1,
                .adj2 = -1,
                .lock = 0,
            });

            if (e.adj_tri != -1) {
                try self.linkTrianglesByEdge(t_idx, e.adj_tri, e.v1, e.v2);
            }
        }
        try self.linkNewTriangles(new_tri_indices.items);
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
