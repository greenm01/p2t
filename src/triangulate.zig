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

pub const Engine = struct {
    mesh: mesh.GlobalMesh,
    allocator: std.mem.Allocator,
    last_valid_tri: i32,
    
    pub fn init(allocator: std.mem.Allocator) Engine {
        return .{
            .mesh = mesh.GlobalMesh{},
            .allocator = allocator,
            .last_valid_tri = 0,
        };
    }

    pub fn deinit(self: *Engine) void {
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
            // Check if it's tombstoned. If we somehow hit a tombstoned tri, break.
            if (tri.v0 == tri.v1 and tri.v1 == tri.v2) break; // simplistic check, but let's assume it's valid if adj is valid

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
            const v0 = self.mesh.vertices.get(@as(usize, @intCast(tri.v0)));
            const v1 = self.mesh.vertices.get(@as(usize, @intCast(tri.v1)));
            const v2 = self.mesh.vertices.get(@as(usize, @intCast(tri.v2)));

            if (predicates.orient2d(v0, v1, target) >= 0.0 and
                predicates.orient2d(v1, v2, target) >= 0.0 and
                predicates.orient2d(v2, v0, target) >= 0.0) {
                return @as(i32, @intCast(i));
            }
        }

        return -1;
    }

    pub fn getVertex(self: *Engine, idx: i32) mesh.Vertex {
        return self.mesh.vertices.get(@as(usize, @intCast(idx)));
    }

    pub fn isInsideCircumcircle(self: *Engine, tri_idx: i32, pt: mesh.Vertex) bool {
        if (tri_idx == -1) return false;
        const tri = self.mesh.triangles.get(@as(usize, @intCast(tri_idx)));
        const v0 = self.getVertex(tri.v0);
        const v1 = self.getVertex(tri.v1);
        const v2 = self.getVertex(tri.v2);
        return predicates.incircle(v0, v1, v2, pt) > 0.0;
    }

    // Simplified Bowyer-Watson insertion for testing
    pub fn insertPoint(self: *Engine, arena: *mesh.ThreadArena, pt: mesh.Vertex) !void {
        // Prevent duplicate or extremely close points
        var v_idx: usize = 0;
        while (v_idx < self.mesh.vertices.len) : (v_idx += 1) {
            const existing_v = self.mesh.vertices.get(v_idx);
            if (@abs(existing_v.x - pt.x) < 1e-6 and @abs(existing_v.y - pt.y) < 1e-6) {
                return;
            }
        }

        _ = @as(i32, @intCast(self.mesh.vertices.len)); // pt_idx for future retriangulation
        try self.mesh.vertices.append(self.allocator, pt);

        const start_tri = self.last_valid_tri;
        const container = self.walk(start_tri, pt);

        if (container < 0) {
            std.debug.print("Walk failed for point {d}, {d} with code {d}\n", .{pt.x, pt.y, container});
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

            // check neighbors
            const neighbors = [_]i32{ tri.adj0, tri.adj1, tri.adj2 };
            const edges_v = [_]struct { v1: i32, v2: i32 }{ 
                .{ .v1 = tri.v0, .v2 = tri.v1 },
                .{ .v1 = tri.v1, .v2 = tri.v2 },
                .{ .v1 = tri.v2, .v2 = tri.v0 } 
            };

            for (neighbors, 0..) |n_idx, n| {
                var in_cavity = false;
                for (cavity.items) |c_idx| {
                    if (c_idx == n_idx) {
                        in_cavity = true;
                        break;
                    }
                }

                if (!in_cavity and self.isInsideCircumcircle(n_idx, pt)) {
                    try cavity.append(self.allocator, n_idx);
                } else if (!in_cavity) {
                    // It's a boundary edge
                    try edges.append(self.allocator, .{ .adj_tri = n_idx, .v1 = edges_v[n].v1, .v2 = edges_v[n].v2, .old_tri = t_idx });
                }
            }
        }

        // Tombstone cavity
        for (cavity.items) |t_idx| {
            try arena.tombstone(self.allocator, t_idx);
        }

        const pt_idx = @as(i32, @intCast(self.mesh.vertices.len - 1));

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
            
            // find internal neighbors
            var adj1: i32 = -1; // neighbor sharing (e.v2, pt_idx)
            var adj2: i32 = -1; // neighbor sharing (pt_idx, e.v1)
            
            for (edges.items, 0..) |other_e, edge_j| {
                if (edge_i == edge_j) continue;
                if (other_e.v1 == e.v2) adj1 = @as(i32, @intCast(new_tri_indices.items[edge_j]));
                if (other_e.v2 == e.v1) adj2 = @as(i32, @intCast(new_tri_indices.items[edge_j]));
            }
            
            self.mesh.triangles.set(@as(usize, @intCast(t_idx)), .{
                .v0 = e.v1,
                .v1 = e.v2,
                .v2 = pt_idx,
                .adj0 = e.adj_tri,
                .adj1 = adj1,
                .adj2 = adj2,
                .lock = 0,
            });

            // update external neighbor to point to us
            if (e.adj_tri != -1) {
                const ext_idx = @as(usize, @intCast(e.adj_tri));
                var ext_tri = self.mesh.triangles.get(ext_idx);
                if (ext_tri.adj0 == e.old_tri) {
                    ext_tri.adj0 = t_idx;
                } else if (ext_tri.adj1 == e.old_tri) {
                    ext_tri.adj1 = t_idx;
                } else if (ext_tri.adj2 == e.old_tri) {
                    ext_tri.adj2 = t_idx;
                }
                self.mesh.triangles.set(ext_idx, ext_tri);
            }
        }
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
    try engine.insertPoint(&arena, mesh.Vertex{ .x = 15.0, .y = 15.0 });
    
    // The super triangle was tombstoned and replaced by 3 new triangles connecting to the new point
    try std.testing.expectEqual(0, arena.freelist.items.len);
    try std.testing.expectEqual(3, engine.mesh.triangles.len);
    
    // Let's also insert another point and verify
    try engine.insertPoint(&arena, mesh.Vertex{ .x = 14.0, .y = 16.0 });
}