//! CPU polygon triangulation producing a clean, non-overlapping triangle mesh
//! for GPU rendering.
//!
//! Pipeline (built up incrementally):
//!   1. Ear clipping of the contours -> a valid triangulation.       (done)
//!   2. Hole bridging so holes feed into the same ear-clip.          (done)
//!   3. Constrained Lawson flips -> Delaunay quality for the GPU.    (next)
//!
//! The ear-clipping + hole-bridging core is a port of the well-known earcut
//! algorithm. Step 3 is what turns the slivery earcut output into a
//! GPU-friendly mesh (good aspect ratios, single pass) - unlike nanovg, which
//! never builds a real mesh at all.

const std = @import("std");

/// A generic tessellator.
///
/// `Coord` is the stored coordinate type: `f32` for compact GPU vertices, `f64`
/// for extra precision. `Index` is the triangle index type: `u16` for small
/// meshes, `u32` otherwise. These are comptime so each instantiation is
/// monomorphized with no runtime dispatch.
///
/// Geometric predicates always evaluate in `f64` (`W` below) regardless of
/// `Coord`, so robustness does not depend on the storage precision - the
/// up-cast is a no-op when `Coord == f64`.
pub fn Tessellator(comptime Coord: type, comptime Index: type) type {
    return struct {
        const Self = @This();
        const W = f64; // predicate working precision
        const nil: u32 = std.math.maxInt(u32);

        pub const Vec = struct { x: Coord, y: Coord };

        pub const Mesh = struct {
            vertices: []Vec,
            indices: []Index, // triangle list, length is a multiple of 3
            allocator: std.mem.Allocator,

            pub fn triangleCount(self: Mesh) usize {
                return self.indices.len / 3;
            }

            pub fn deinit(self: *Mesh) void {
                self.allocator.free(self.vertices);
                self.allocator.free(self.indices);
                self.* = undefined;
            }
        };

        const Node = struct {
            i: u32, // index into the vertex array
            x: W,
            y: W,
            prev: u32, // node-pool indices (circular doubly-linked list)
            next: u32,
            steiner: bool,
        };

        nodes: std.ArrayList(Node),
        out: std.ArrayList(Index),
        a: std.mem.Allocator,

        // ---- node-pool primitives ----

        inline fn node(self: *Self, k: u32) *Node {
            return &self.nodes.items[k];
        }

        fn newNode(self: *Self, i: u32, x: W, y: W) !u32 {
            const k: u32 = @intCast(self.nodes.items.len);
            try self.nodes.append(self.a, .{
                .i = i,
                .x = x,
                .y = y,
                .prev = nil,
                .next = nil,
                .steiner = false,
            });
            return k;
        }

        fn insertNode(self: *Self, i: u32, x: W, y: W, last: u32) !u32 {
            const k = try self.newNode(i, x, y);
            if (last == nil) {
                self.node(k).prev = k;
                self.node(k).next = k;
            } else {
                const nx = self.node(last).next;
                self.node(k).next = nx;
                self.node(k).prev = last;
                self.node(nx).prev = k;
                self.node(last).next = k;
            }
            return k;
        }

        fn removeNode(self: *Self, k: u32) void {
            const p = self.node(k).prev;
            const n = self.node(k).next;
            self.node(p).next = n;
            self.node(n).prev = p;
        }

        // ---- geometry (all in W) ----

        /// Twice the signed area of triangle (p, q, r); follows the earcut sign
        /// convention where a value < 0 means the corner at q is convex.
        inline fn area(self: *Self, p: u32, q: u32, r: u32) W {
            const P = self.node(p);
            const Q = self.node(q);
            const R = self.node(r);
            return (Q.y - P.y) * (R.x - Q.x) - (Q.x - P.x) * (R.y - Q.y);
        }

        inline fn equals(self: *Self, p: u32, q: u32) bool {
            return self.node(p).x == self.node(q).x and self.node(p).y == self.node(q).y;
        }

        fn pointInTriangle(ax: W, ay: W, bx: W, by: W, cx: W, cy: W, px: W, py: W) bool {
            return (cx - px) * (ay - py) - (ax - px) * (cy - py) >= 0 and
                (ax - px) * (by - py) - (bx - px) * (ay - py) >= 0 and
                (bx - px) * (cy - py) - (cx - px) * (by - py) >= 0;
        }

        /// Is segment b locally inside the polygon at vertex a?
        fn locallyInside(self: *Self, a: u32, b: u32) bool {
            const ap = self.node(a).prev;
            const an = self.node(a).next;
            return if (self.area(ap, a, an) < 0)
                self.area(a, b, an) >= 0 and self.area(a, ap, b) >= 0
            else
                self.area(a, b, ap) < 0 or self.area(a, an, b) < 0;
        }

        // ---- ring construction ----

        /// Mapbox-style signed area (> 0 for a clockwise ring in screen space).
        fn ringArea(points: []const Vec) W {
            var sum: W = 0;
            var j = points.len - 1;
            for (0..points.len) |i| {
                sum += (@as(W, points[j].x) - @as(W, points[i].x)) *
                    (@as(W, points[i].y) + @as(W, points[j].y));
                j = i;
            }
            return sum;
        }

        /// Build a circular doubly-linked list over `points`, assigning vertex
        /// indices base..base+len. `clockwise` selects the winding earcut wants
        /// (true for the outer ring, false for holes).
        fn linkedList(self: *Self, points: []const Vec, base: u32, clockwise: bool) !u32 {
            var last: u32 = nil;
            const forward = clockwise == (ringArea(points) > 0);
            if (forward) {
                for (0..points.len) |idx| {
                    last = try self.insertNode(base + @as(u32, @intCast(idx)), points[idx].x, points[idx].y, last);
                }
            } else {
                var idx: usize = points.len;
                while (idx > 0) {
                    idx -= 1;
                    last = try self.insertNode(base + @as(u32, @intCast(idx)), points[idx].x, points[idx].y, last);
                }
            }
            if (last != nil and self.equals(last, self.node(last).next)) {
                const nx = self.node(last).next;
                self.removeNode(last);
                last = nx;
            }
            return last;
        }

        /// Drop collinear or coincident vertices.
        fn filterPoints(self: *Self, startIn: u32, endIn: u32) u32 {
            if (startIn == nil) return startIn;
            var end = if (endIn == nil) startIn else endIn;
            var p = startIn;
            var again = true;
            while (again or p != end) {
                again = false;
                const np = self.node(p);
                if (!np.steiner and (self.equals(p, np.next) or self.area(np.prev, p, np.next) == 0)) {
                    const prev = np.prev;
                    const next = np.next;
                    self.removeNode(p);
                    p = prev;
                    end = prev;
                    if (p == next) break;
                    again = true;
                } else {
                    p = self.node(p).next;
                }
            }
            return end;
        }

        // ---- ear clipping ----

        fn isEar(self: *Self, ear: u32) bool {
            const a = self.node(ear).prev;
            const b = ear;
            const c = self.node(ear).next;
            if (self.area(a, b, c) >= 0) return false; // reflex corner

            const ax = self.node(a).x;
            const ay = self.node(a).y;
            const bx = self.node(b).x;
            const by = self.node(b).y;
            const cx = self.node(c).x;
            const cy = self.node(c).y;

            var p = self.node(c).next;
            while (p != a) {
                const pp = self.node(p);
                if (pointInTriangle(ax, ay, bx, by, cx, cy, pp.x, pp.y) and
                    self.area(pp.prev, p, pp.next) >= 0)
                {
                    return false;
                }
                p = self.node(p).next;
            }
            return true;
        }

        fn emit(self: *Self, a: u32, b: u32, c: u32) !void {
            try self.out.append(self.a, @intCast(self.node(a).i));
            try self.out.append(self.a, @intCast(self.node(b).i));
            try self.out.append(self.a, @intCast(self.node(c).i));
        }

        fn earcutLinked(self: *Self, earIn: u32) !void {
            var ear = self.filterPoints(earIn, nil);
            if (ear == nil or self.node(ear).next == self.node(ear).prev) return;

            var stop = ear;
            while (self.node(ear).prev != self.node(ear).next) {
                const prev = self.node(ear).prev;
                const next = self.node(ear).next;
                if (self.isEar(ear)) {
                    try self.emit(prev, ear, next);
                    self.removeNode(ear);
                    ear = self.node(next).next;
                    stop = self.node(next).next;
                    continue;
                }
                ear = next;
                if (ear == stop) {
                    // No ear found: degenerate / self-intersecting input (which
                    // the caller is expected to avoid). Clip anyway to terminate.
                    try self.emit(self.node(ear).prev, ear, self.node(ear).next);
                    self.removeNode(ear);
                    ear = self.node(ear).next;
                    stop = ear;
                }
            }
        }

        // ---- hole bridging ----

        fn getLeftmost(self: *Self, start: u32) u32 {
            var p = start;
            var leftmost = start;
            while (true) {
                const np = self.node(p);
                const lm = self.node(leftmost);
                if (np.x < lm.x or (np.x == lm.x and np.y < lm.y)) leftmost = p;
                p = np.next;
                if (p == start) break;
            }
            return leftmost;
        }

        fn splitPolygon(self: *Self, a: u32, b: u32) !u32 {
            const a2 = try self.newNode(self.node(a).i, self.node(a).x, self.node(a).y);
            const b2 = try self.newNode(self.node(b).i, self.node(b).x, self.node(b).y);
            const an = self.node(a).next;
            const bp = self.node(b).prev;

            self.node(a).next = b;
            self.node(b).prev = a;
            self.node(a2).next = an;
            self.node(an).prev = a2;
            self.node(b2).next = a2;
            self.node(a2).prev = b2;
            self.node(bp).next = b2;
            self.node(b2).prev = bp;
            return b2;
        }

        /// Find a vertex of the outer ring visible from the hole's leftmost
        /// vertex, to bridge the hole into the outer polygon.
        fn findHoleBridge(self: *Self, hole: u32, outerNode: u32) u32 {
            var p = outerNode;
            const hx = self.node(hole).x;
            const hy = self.node(hole).y;
            var qx: W = -std.math.inf(W);
            var m: u32 = nil;

            // Cast a ray from the hole leftward; find the closest outer edge.
            while (true) {
                const np = self.node(p);
                const nn = self.node(np.next);
                if (hy <= np.y and hy >= nn.y and nn.y != np.y) {
                    const x = np.x + (hy - np.y) * (nn.x - np.x) / (nn.y - np.y);
                    if (x <= hx and x > qx) {
                        qx = x;
                        m = if (np.x < nn.x) p else np.next;
                        if (x == hx) return m; // hole touches an outer vertex
                    }
                }
                p = np.next;
                if (p == outerNode) break;
            }
            if (m == nil) return nil;

            // Refine: if other reflex vertices block visibility to m, pick the
            // one minimizing the angle to the ray.
            const stop = m;
            const mx = self.node(m).x;
            const my = self.node(m).y;
            var tanMin: W = std.math.inf(W);
            p = m;
            while (true) {
                const np = self.node(p);
                if (hx >= np.x and np.x >= mx and hx != np.x and
                    pointInTriangle(
                        if (hy < my) hx else qx,
                        hy,
                        mx,
                        my,
                        if (hy < my) qx else hx,
                        hy,
                        np.x,
                        np.y,
                    ))
                {
                    const tan = @abs(hy - np.y) / (hx - np.x);
                    if (self.locallyInside(p, hole) and
                        (tan < tanMin or (tan == tanMin and np.x > self.node(m).x)))
                    {
                        m = p;
                        tanMin = tan;
                    }
                }
                p = self.node(p).next;
                if (p == stop) break;
            }
            return m;
        }

        fn eliminateHole(self: *Self, holeIn: u32, outerNode: u32) !u32 {
            const hole = self.filterPoints(holeIn, nil);
            const bridge = self.findHoleBridge(hole, outerNode);
            if (bridge == nil) return outerNode;
            const bridgeReverse = try self.splitPolygon(bridge, hole);
            _ = self.filterPoints(bridgeReverse, self.node(bridgeReverse).next);
            return self.filterPoints(bridge, self.node(bridge).next);
        }

        fn compareHoleX(self: *Self, lhs: u32, rhs: u32) bool {
            return self.node(lhs).x < self.node(rhs).x;
        }

        fn eliminateHoles(self: *Self, holes: []const []const Vec, outerNodeIn: u32, baseStart: u32) !u32 {
            var queue: std.ArrayList(u32) = .empty;
            defer queue.deinit(self.a);

            var base = baseStart;
            for (holes) |hole| {
                const list = try self.linkedList(hole, base, false);
                if (list != nil) {
                    if (list == self.node(list).next) self.node(list).steiner = true;
                    try queue.append(self.a, self.getLeftmost(list));
                }
                base += @intCast(hole.len);
            }

            std.mem.sort(u32, queue.items, self, compareHoleX);

            var outerNode = outerNodeIn;
            for (queue.items) |h| {
                outerNode = try self.eliminateHole(h, outerNode);
            }
            return outerNode;
        }

        // ---- public entry points ----

        fn buildMesh(self: *Self, outer: []const Vec, holes: []const []const Vec) !Mesh {
            var total: usize = outer.len;
            for (holes) |h| total += h.len;

            const verts = try self.a.alloc(Vec, total);
            errdefer self.a.free(verts);
            @memcpy(verts[0..outer.len], outer);
            var off: usize = outer.len;
            for (holes) |h| {
                @memcpy(verts[off .. off + h.len], h);
                off += h.len;
            }

            if (outer.len >= 3) {
                var ring = try self.linkedList(outer, 0, true);
                if (holes.len > 0) {
                    ring = try self.eliminateHoles(holes, ring, @intCast(outer.len));
                }
                try self.earcutLinked(ring);
            }

            return .{
                .vertices = verts,
                .indices = try self.out.toOwnedSlice(self.a),
                .allocator = self.a,
            };
        }

        /// Triangulate an outer contour with holes into a GPU-ready mesh.
        /// `outer` should be counter-clockwise and each hole clockwise; winding
        /// is normalized internally regardless.
        pub fn triangulate(
            allocator: std.mem.Allocator,
            outer: []const Vec,
            holes: []const []const Vec,
        ) !Mesh {
            var self = Self{ .nodes = .empty, .out = .empty, .a = allocator };
            defer self.nodes.deinit(allocator);
            errdefer self.out.deinit(allocator);
            return self.buildMesh(outer, holes);
        }

        /// Triangulate a single simple polygon (no holes).
        pub fn triangulateSimple(allocator: std.mem.Allocator, points: []const Vec) !Mesh {
            return triangulate(allocator, points, &.{});
        }
    };
}

/// GPU-friendly default: compact f32 vertices, 32-bit indices.
pub const GpuTess = Tessellator(f32, u32);

/// Double-precision default.
pub const Tess = Tessellator(f64, u32);
