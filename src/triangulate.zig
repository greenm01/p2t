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

const LegalizeEdge = struct {
    tri: i32,
    side: usize,
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

    pub fn resetRetainingCapacity(self: *Engine) void {
        self.mesh.clearRetainingCapacity();
        self.last_valid_tri = 0;
    }

    pub fn reserveForPointCount(self: *Engine, point_count: usize) !void {
        try self.mesh.reserve(self.allocator, point_count + 3, point_count * 3 + 8);
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

        try self.mesh.appendTriangle(self.allocator, .{
            .v0 = 0,
            .v1 = 2,
            .v2 = 1,
            .adj0 = -1,
            .adj1 = -1,
            .adj2 = -1,
        });
        self.last_valid_tri = 0;
    }

    pub fn walk(self: *Engine, start_tri: i32, target: mesh.Vertex) i32 {
        var curr = start_tri;
        var limit: usize = 10000;

        while (curr != -1 and limit > 0) : (limit -= 1) {
            if (curr < 0) break;
            const curr_slot = @as(usize, @intCast(curr));
            if (curr_slot >= self.mesh.triangles.len) break;
            const tri = self.mesh.triangles.get(curr_slot);
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

    fn edgeFlag(side: usize) u8 {
        return @as(u8, 1) << @as(u3, @intCast(side));
    }

    pub fn oppositeVertex(tri: mesh.Triangle, side: usize) i32 {
        return switch (side) {
            0 => tri.v2,
            1 => tri.v0,
            else => tri.v1,
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

    pub fn findLiveEdge(self: *Engine, a: i32, b: i32) ?struct { tri: i32, side: usize } {
        for (0..self.mesh.triangles.len) |i| {
            const tri = self.mesh.triangles.get(i);
            if (mesh.isDeadTriangle(tri)) continue;
            if (edgeSide(tri, a, b)) |side| {
                return .{ .tri = @as(i32, @intCast(i)), .side = side };
            }
        }
        return null;
    }

    pub fn setConstrainedEdgeByVertices(self: *Engine, a: i32, b: i32, value: bool) !bool {
        const found = self.findLiveEdge(a, b) orelse return false;
        try self.setConstrainedTriangleEdge(found.tri, found.side, value);
        return true;
    }

    pub fn linkTriangleSides(self: *Engine, tri_a_idx: i32, side_a: usize, tri_b_idx: i32, side_b: usize) !void {
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
        self.mesh.setTriangle(tri_a_idx, tri_a);
        self.mesh.setTriangle(tri_b_idx, tri_b);
        self.setConstrainedSide(tri_a_idx, side_a, constrained);
        self.setConstrainedSide(tri_b_idx, side_b, constrained);
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
        if (tri_idx == -1) return false;
        const tri = self.mesh.triangles.get(@as(usize, @intCast(tri_idx)));
        if (mesh.isDeadTriangle(tri)) return false;
        const v0 = self.getVertex(tri.v0);
        const v1 = self.getVertex(tri.v1);
        const v2 = self.getVertex(tri.v2);
        return predicates.incircle(v0, v1, v2, pt) > 0.0;
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
            _ = try self.flipEdge(&queue, allocator, tx, edge.tri, edge.side);
        }
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

    fn completeCavityByGlobalScan(self: *Engine, allocator: std.mem.Allocator, cavity: *std.ArrayListUnmanaged(i32), pt: mesh.Vertex) !bool {
        var added = false;
        for (0..self.mesh.triangles.len) |tri_idx| {
            const tri_i32 = @as(i32, @intCast(tri_idx));
            if (cavityContains(cavity.items, tri_i32)) continue;

            const tri = self.mesh.triangles.get(tri_idx);
            if (mesh.isDeadTriangle(tri)) continue;

            if (self.isInsideCircumcircle(tri_i32, pt) or self.pointOnTriangleEdge(tri, pt)) {
                try cavity.append(allocator, tri_i32);
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
                if (cavityContains(cavity.items, tri_i32)) continue;

                const tri = self.mesh.triangles.get(tri_idx);
                if (mesh.isDeadTriangle(tri)) continue;
                if (edgeSide(tri, edge.v1, edge.v2) == null) continue;

                outside_count += 1;
                if (outside_count > 1 and !cavityContains(cavity.items, tri_i32)) {
                    try cavity.append(allocator, tri_i32);
                    added = true;
                }
            }
        }
        return added;
    }

    pub fn insertPoint(self: *Engine, arena: *mesh.ThreadArena, pt: mesh.Vertex) !i32 {
        for (0..max_transaction_attempts) |_| {
            return self.insertPointAttempt(arena, pt, true) catch |err| {
                if (isRetryableTransactionError(err)) continue;
                return err;
            };
        }
        return error.TransactionConflict;
    }

    pub fn insertUniquePoint(self: *Engine, arena: *mesh.ThreadArena, pt: mesh.Vertex) !i32 {
        for (0..max_transaction_attempts) |_| {
            return self.insertPointAttempt(arena, pt, false) catch |err| {
                if (isRetryableTransactionError(err)) continue;
                return err;
            };
        }
        return error.TransactionConflict;
    }

    // Simplified Bowyer-Watson insertion for testing
    fn insertPointAttempt(self: *Engine, arena: *mesh.ThreadArena, pt: mesh.Vertex, check_duplicate: bool) !i32 {
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

        const start_tri = self.last_valid_tri;
        const container = self.walk(start_tri, pt);

        if (container < 0) {
            return error.WalkFailed;
        }

        const scratch_allocator = arena.resetScratch(self.allocator);
        var cavity: std.ArrayListUnmanaged(i32) = .empty;

        var edges: std.ArrayListUnmanaged(Edge) = .empty;

        try cavity.append(scratch_allocator, container);

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
                    try cavity.append(scratch_allocator, n_idx);
                }
            }
        }

        while (true) {
            try self.extractCavityBoundary(scratch_allocator, cavity.items, &edges);

            if (try self.repairBoundaryNonManifoldEdges(scratch_allocator, &cavity, edges.items)) {
                continue;
            }

            if (boundaryHasPinch(edges.items)) {
                const repaired = try self.completeCavityByGlobalScan(scratch_allocator, &cavity, pt);
                if (!repaired) {
                    std.debug.print("InvalidCavityBoundary: pinched boundary could not be repaired for point {d},{d}\n", .{ pt.x, pt.y });
                    return error.InvalidCavityBoundary;
                }
                continue;
            }

            break;
        }

        var footprint: std.ArrayListUnmanaged(i32) = .empty;
        try self.collectCavityTransactionFootprint(scratch_allocator, cavity.items, edges.items, &footprint);

        var expected_versions: std.ArrayListUnmanaged(TriangleVersionSnapshot) = .empty;
        if (!try self.snapshotTransactionFootprint(scratch_allocator, footprint.items, &expected_versions)) return error.TransactionConflict;

        var tx = TriangleTransaction{};
        if (!try self.beginTriangleTransactionWithVersions(scratch_allocator, footprint.items, expected_versions.items, &tx)) return error.TransactionConflict;
        errdefer self.endTriangleTransaction(&tx);

        var new_tri_indices: std.ArrayListUnmanaged(i32) = .empty;
        const reused_cavity_count = @min(edges.items.len, cavity.items.len);
        const needed_after_cavity = edges.items.len - reused_cavity_count;
        const reused_freelist_count = @min(needed_after_cavity, arena.freelist.items.len);
        const appended_triangle_count = needed_after_cavity - reused_freelist_count;
        const leftover_cavity_count = cavity.items.len - reused_cavity_count;

        try new_tri_indices.ensureTotalCapacity(scratch_allocator, edges.items.len);
        for (0..reused_cavity_count) |edge_i| {
            try new_tri_indices.append(scratch_allocator, cavity.items[cavity.items.len - 1 - edge_i]);
        }
        for (0..reused_freelist_count) |free_i| {
            try new_tri_indices.append(scratch_allocator, arena.freelist.items[arena.freelist.items.len - 1 - free_i]);
        }
        for (0..appended_triangle_count) |append_i| {
            try new_tri_indices.append(scratch_allocator, @as(i32, @intCast(self.mesh.triangles.len + append_i)));
        }

        try self.mesh.vertices.ensureUnusedCapacity(self.allocator, 1);
        try self.mesh.ensureTriangleCapacity(self.allocator, self.mesh.triangles.len + appended_triangle_count);
        try arena.freelist.ensureUnusedCapacity(self.allocator, leftover_cavity_count);

        try self.mesh.vertices.append(self.allocator, pt);

        // Tombstone cavity slots after all allocations that can fail have succeeded.
        for (cavity.items, 0..) |t_idx, cavity_i| {
            self.mesh.markDead(t_idx);
            if (cavity_i < leftover_cavity_count) {
                try arena.tombstone(self.allocator, t_idx);
            }
        }
        for (0..reused_freelist_count) |_| {
            _ = arena.getFreeSlot().?;
        }
        for (0..appended_triangle_count) |append_i| {
            try self.mesh.ensureTriangleSlot(self.allocator, new_tri_indices.items[reused_cavity_count + reused_freelist_count + append_i]);
        }

        // Setup the new triangles and link them
        for (edges.items, 0..) |e, edge_i| {
            const t_idx = new_tri_indices.items[edge_i];
            self.last_valid_tri = t_idx;

            var a = e.v1;
            var b = e.v2;
            if (predicates.orient2d(self.getVertex(a), self.getVertex(b), pt) < 0.0) {
                const tmp = a;
                a = b;
                b = tmp;
            }

            self.mesh.setTriangleFresh(t_idx, .{
                .v0 = a,
                .v1 = b,
                .v2 = pt_idx,
                .adj0 = -1,
                .adj1 = -1,
                .adj2 = -1,
            });

            if (e.adj_tri != -1) {
                try self.linkTrianglesByEdge(t_idx, e.adj_tri, e.v1, e.v2);
            }
        }
        try self.linkNewTriangles(new_tri_indices.items);
        self.endTriangleTransaction(&tx);
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
