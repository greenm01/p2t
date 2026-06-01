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

    pub fn triangulatePseudoPolygon(self: *Corridor, allocator: std.mem.Allocator, engine: *triangulate.Engine, arena: *mesh.ThreadArena, start_pt_idx: i32, end_pt_idx: i32, wall: []i32, is_left: bool) !void {
        _ = self;
        if (wall.len == 0) return;

        const start_pt = engine.getVertex(start_pt_idx);
        const end_pt = engine.getVertex(end_pt_idx);

        // Sort wall by projection along the segment
        const dx = end_pt.x - start_pt.x;
        const dy = end_pt.y - start_pt.y;

        const Context = struct {
            engine: *triangulate.Engine,
            start: mesh.Vertex,
            dx: f64,
            dy: f64,

            pub fn lessThan(ctx: @This(), a_idx: i32, b_idx: i32) bool {
                const a = ctx.engine.getVertex(a_idx);
                const b = ctx.engine.getVertex(b_idx);
                const proj_a = (a.x - ctx.start.x) * ctx.dx + (a.y - ctx.start.y) * ctx.dy;
                const proj_b = (b.x - ctx.start.x) * ctx.dx + (b.y - ctx.start.y) * ctx.dy;
                return proj_a < proj_b;
            }
        };

        std.mem.sortUnstable(i32, wall, Context{ .engine = engine, .start = start_pt, .dx = dx, .dy = dy }, Context.lessThan);

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
                    // Create triangle (prev, top, p)
                    const new_tri_idx = arena.getFreeSlot() orelse @as(i32, @intCast(engine.mesh.triangles.len));
                    if (new_tri_idx == engine.mesh.triangles.len) {
                        try engine.mesh.triangles.append(allocator, undefined);
                    }

                    const t0 = if (is_left) prev_idx else prev_idx;
                    const t1 = if (is_left) p_idx else top_idx;
                    const t2 = if (is_left) top_idx else p_idx;

                    engine.mesh.triangles.set(@as(usize, @intCast(new_tri_idx)), .{
                        .v0 = t0,
                        .v1 = t1,
                        .v2 = t2,
                        .adj0 = -1, // Adjacency linking is omitted for brevity
                        .adj1 = -1,
                        .adj2 = -1,
                        .lock = 0,
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
            if (new_tri_idx == engine.mesh.triangles.len) {
                try engine.mesh.triangles.append(allocator, undefined);
            }

            const t0 = if (is_left) prev_idx else prev_idx;
            const t1 = if (is_left) p_idx else top_idx;
            const t2 = if (is_left) top_idx else p_idx;

            engine.mesh.triangles.set(@as(usize, @intCast(new_tri_idx)), .{
                .v0 = t0,
                .v1 = t1,
                .v2 = t2,
                .adj0 = -1,
                .adj1 = -1,
                .adj2 = -1,
                .lock = 0,
            });

            _ = stack.pop();
        }
    }

    pub fn clearAndRetriangulate(self: *Corridor, allocator: std.mem.Allocator, engine: *triangulate.Engine, arena: *mesh.ThreadArena, start_pt_idx: i32, end_pt_idx: i32) !void {
        const EdgeKey = struct { v1: i32, v2: i32 };

        // 1. Extract boundaries
        // We collect all boundary edges of the corridor. A boundary edge is one that belongs to exactly one pierced triangle.
        var edge_counts = std.AutoHashMap(EdgeKey, usize).init(allocator);
        defer edge_counts.deinit();

        var edge_to_adj = std.AutoHashMap(EdgeKey, i32).init(allocator);
        defer edge_to_adj.deinit();

        for (self.pierced_triangles.items) |t_idx| {
            const tri = engine.mesh.triangles.get(@as(usize, @intCast(t_idx)));
            const edges = [_]struct { v1: i32, v2: i32, adj: i32 }{
                .{ .v1 = tri.v0, .v2 = tri.v1, .adj = tri.adj0 },
                .{ .v1 = tri.v1, .v2 = tri.v2, .adj = tri.adj1 },
                .{ .v1 = tri.v2, .v2 = tri.v0, .adj = tri.adj2 },
            };

            for (edges) |e| {
                const min_v = @min(e.v1, e.v2);
                const max_v = @max(e.v1, e.v2);
                const key = EdgeKey{ .v1 = min_v, .v2 = max_v };

                const count = edge_counts.get(key) orelse 0;
                try edge_counts.put(key, count + 1);
                try edge_to_adj.put(key, e.adj);
            }
        }

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
                engine.mesh.triangles.set(neighbor_slot, neighbor);
            }
        }

        // 3. Tombstone all pierced triangles after their boundary data has been read.
        for (self.pierced_triangles.items) |t_idx| {
            engine.mesh.markDead(t_idx);
            try arena.tombstone(allocator, t_idx);
        }

        const start_pt = engine.getVertex(start_pt_idx);
        const end_pt = engine.getVertex(end_pt_idx);

        var left_wall_set = std.AutoHashMap(i32, void).init(allocator);
        defer left_wall_set.deinit();

        var right_wall_set = std.AutoHashMap(i32, void).init(allocator);
        defer right_wall_set.deinit();

        // Separate boundary vertices into left and right walls based on orientation
        var it = edge_counts.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == 1) { // It's a boundary edge
                const v1_idx = entry.key_ptr.v1;
                const v2_idx = entry.key_ptr.v2;

                if (v1_idx != start_pt_idx and v1_idx != end_pt_idx) {
                    const v1 = engine.getVertex(v1_idx);
                    if (predicates.orient2d(start_pt, end_pt, v1) > 0.0) {
                        try left_wall_set.put(v1_idx, {});
                    } else {
                        try right_wall_set.put(v1_idx, {});
                    }
                }

                if (v2_idx != start_pt_idx and v2_idx != end_pt_idx) {
                    const v2 = engine.getVertex(v2_idx);
                    if (predicates.orient2d(start_pt, end_pt, v2) > 0.0) {
                        try left_wall_set.put(v2_idx, {});
                    } else {
                        try right_wall_set.put(v2_idx, {});
                    }
                }
            }
        }

        var left_wall: std.ArrayListUnmanaged(i32) = .empty;
        defer left_wall.deinit(allocator);
        var left_it = left_wall_set.keyIterator();
        while (left_it.next()) |v| try left_wall.append(allocator, v.*);

        var right_wall: std.ArrayListUnmanaged(i32) = .empty;
        defer right_wall.deinit(allocator);
        var right_it = right_wall_set.keyIterator();
        while (right_it.next()) |v| try right_wall.append(allocator, v.*);

        // 4. Linear Triangulation (Stack-based algorithm for monotone polygon)
        try self.triangulatePseudoPolygon(allocator, engine, arena, start_pt_idx, end_pt_idx, left_wall.items, true);
        try self.triangulatePseudoPolygon(allocator, engine, arena, start_pt_idx, end_pt_idx, right_wall.items, false);
        try engine.rebuildAdjacency();
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
