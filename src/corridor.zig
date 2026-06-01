const std = @import("std");
const mesh = @import("mesh.zig");
const triangulate = @import("triangulate.zig");
const predicates = @import("predicates.zig");

pub const Corridor = struct {
    pierced_triangles: std.ArrayListUnmanaged(i32) = .empty,

    pub fn deinit(self: *Corridor, allocator: std.mem.Allocator) void {
        self.pierced_triangles.deinit(allocator);
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
                (v2.x == end_pt.x and v2.y == end_pt.y)) {
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
    try engine.insertPoint(&arena, mesh.Vertex{ .x = 12.0, .y = 15.0 });
    try engine.insertPoint(&arena, mesh.Vertex{ .x = 18.0, .y = 15.0 });

    var corridor = Corridor{};
    defer corridor.deinit(std.testing.allocator);

    const start_pt = engine.getVertex(3); // The first inserted point
    const end_pt = engine.getVertex(4);   // The second inserted point
    
    const start_tri = engine.walk(0, start_pt); // Find triangle containing start_pt

    try corridor.trace(std.testing.allocator, &engine, start_tri, end_pt, start_pt);

    try std.testing.expect(corridor.pierced_triangles.items.len > 0);
}
