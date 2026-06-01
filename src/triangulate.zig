const std = @import("std");
const mesh = @import("mesh.zig");
const spatial = @import("spatial.zig");
const predicates = @import("predicates.zig");

pub const Edge = struct {
    adj_tri: i32,
    v1: i32,
    v2: i32,
};

pub const Engine = struct {
    mesh: mesh.GlobalMesh,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Engine {
        return .{
            .mesh = mesh.GlobalMesh{},
            .allocator = allocator,
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
    }

    pub fn walk(self: *Engine, start_tri: i32, target: mesh.Vertex) i32 {
        var curr = start_tri;
        var limit: usize = 10000;
        
        while (curr != -1 and limit > 0) : (limit -= 1) {
            const tri = self.mesh.triangles.get(@as(usize, @intCast(curr)));
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

        return curr;
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
        _ = @as(i32, @intCast(self.mesh.vertices.len)); // pt_idx for future retriangulation
        try self.mesh.vertices.append(self.allocator, pt);

        // Normally we'd use the last created triangle as a hint
        const start_tri = 0; 
        const container = self.walk(start_tri, pt);

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
                    try edges.append(self.allocator, .{ .adj_tri = n_idx, .v1 = edges_v[n].v1, .v2 = edges_v[n].v2 });
                }
            }
        }

        // Tombstone cavity
        for (cavity.items) |t_idx| {
            try arena.tombstone(self.allocator, t_idx);
        }

        // We skip retriangulation and hooking up adjacencies for now 
        // to keep this incremental and verify cavity expansion works.
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
    
    // 0 should be tombstoned
    try std.testing.expect(arena.freelist.items.len > 0);
}