//! Experimental FIST/Mapbox-Earcut style triangulator.
//!
//! This is intentionally kept separate from `triangulate.zig` so benchmarks can
//! compare the current simple ear-clip backend against a closer Earcut/FIST
//! seed: z-order hashing for large contours plus local-intersection curing and
//! polygon splitting fallback.

const std = @import("std");

pub fn FistEarcut(comptime VecType: type, comptime Index: type) type {
    return struct {
        const Self = @This();
        const W = f64;
        const nil: u32 = std.math.maxInt(u32);

        pub const Vec = VecType;

        pub const Mesh = struct {
            vertices: []Vec,
            indices: []Index,
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
            i: u32,
            x: W,
            y: W,
            z: u32 = 0,
            z_valid: bool = false,
            steiner: bool = false,
            prev: u32 = nil,
            next: u32 = nil,
            prev_z: u32 = nil,
            next_z: u32 = nil,
        };

        const Bounds = struct {
            min_x: W = 0,
            min_y: W = 0,
            inv_size: W = 0,

            fn enabled(self: Bounds) bool {
                return self.inv_size > 0;
            }
        };

        nodes: std.ArrayList(Node),
        out: std.ArrayList(Index),
        a: std.mem.Allocator,

        inline fn node(self: *Self, k: u32) *Node {
            return &self.nodes.items[k];
        }

        fn newNode(self: *Self, i: u32, x: W, y: W) !u32 {
            const k: u32 = @intCast(self.nodes.items.len);
            try self.nodes.append(self.a, .{ .i = i, .x = x, .y = y });
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

            const pz = self.node(k).prev_z;
            const nz = self.node(k).next_z;
            if (pz != nil) self.node(pz).next_z = nz;
            if (nz != nil) self.node(nz).prev_z = pz;
        }

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

        fn pointInTriangleExceptFirst(ax: W, ay: W, bx: W, by: W, cx: W, cy: W, px: W, py: W) bool {
            return !(ax == px and ay == py) and pointInTriangle(ax, ay, bx, by, cx, cy, px, py);
        }

        fn ringArea(points: []const Vec) W {
            var sum: W = 0;
            var j = points.len - 1;
            for (0..points.len) |i| {
                sum += (@as(W, @floatCast(points[j].x)) - @as(W, @floatCast(points[i].x))) *
                    (@as(W, @floatCast(points[i].y)) + @as(W, @floatCast(points[j].y)));
                j = i;
            }
            return sum;
        }

        fn linkedList(self: *Self, points: []const Vec, base: u32, clockwise: bool) !u32 {
            var last: u32 = nil;
            const forward = clockwise == (ringArea(points) > 0);
            if (forward) {
                for (points, 0..) |p, idx| {
                    last = try self.insertNode(base + @as(u32, @intCast(idx)), p.x, p.y, last);
                }
            } else {
                var idx: usize = points.len;
                while (idx > 0) {
                    idx -= 1;
                    const p = points[idx];
                    last = try self.insertNode(base + @as(u32, @intCast(idx)), p.x, p.y, last);
                }
            }
            if (last != nil and self.equals(last, self.node(last).next)) {
                const nx = self.node(last).next;
                self.removeNode(last);
                last = nx;
            }
            return last;
        }

        fn filterPoints(self: *Self, start_in: u32, end_in: u32) u32 {
            if (start_in == nil) return nil;
            var end = if (end_in == nil) start_in else end_in;
            var p = start_in;
            var again = true;
            while (again or p != end) {
                again = false;
                const np = self.node(p);
                if ((!np.steiner and self.equals(p, np.next)) or self.area(np.prev, p, np.next) == 0) {
                    const prev = np.prev;
                    const next = np.next;
                    self.removeNode(p);
                    p = prev;
                    end = prev;
                    if (p == next) return nil;
                    again = true;
                } else {
                    p = np.next;
                }
            }
            return end;
        }

        fn emit(self: *Self, a: u32, b: u32, c: u32) !void {
            try self.out.append(self.a, @intCast(self.node(a).i));
            try self.out.append(self.a, @intCast(self.node(b).i));
            try self.out.append(self.a, @intCast(self.node(c).i));
        }

        fn earcutLinked(self: *Self, ear_in: u32, bounds: Bounds, pass: i32) std.mem.Allocator.Error!void {
            var ear = if (pass == -1) self.filterPoints(ear_in, nil) else ear_in;
            if (ear == nil) return;
            if (pass == -1 and bounds.enabled()) self.indexCurve(ear, bounds);

            var stop = ear;
            while (self.node(ear).prev != self.node(ear).next) {
                const prev = self.node(ear).prev;
                const next = self.node(ear).next;

                const ok = if (bounds.enabled()) self.isEarHashed(ear, bounds) else self.isEar(ear);
                if (ok) {
                    try self.emit(prev, ear, next);
                    self.removeNode(ear);
                    ear = self.node(next).next;
                    stop = ear;
                    continue;
                }

                ear = next;
                if (ear == stop) {
                    if (pass == -1) {
                        try self.earcutLinked(self.filterPoints(ear, nil), bounds, 1);
                    } else if (pass == 1) {
                        ear = try self.cureLocalIntersections(self.filterPoints(ear, nil));
                        try self.earcutLinked(ear, bounds, 2);
                    } else if (pass == 2) {
                        try self.splitEarcut(ear, bounds);
                    }
                    break;
                }
            }
        }

        fn isEar(self: *Self, ear: u32) bool {
            const a = self.node(ear).prev;
            const b = ear;
            const c = self.node(ear).next;
            if (self.area(a, b, c) >= 0) return false;

            const an = self.node(a);
            const bn = self.node(b);
            const cn = self.node(c);
            const min_x = @min(an.x, @min(bn.x, cn.x));
            const min_y = @min(an.y, @min(bn.y, cn.y));
            const max_x = @max(an.x, @max(bn.x, cn.x));
            const max_y = @max(an.y, @max(bn.y, cn.y));
            var p = self.node(c).next;
            while (p != a) {
                const pn = self.node(p);
                if (pn.x >= min_x and pn.x <= max_x and pn.y >= min_y and pn.y <= max_y and
                    pointInTriangleExceptFirst(an.x, an.y, bn.x, bn.y, cn.x, cn.y, pn.x, pn.y) and
                    self.area(pn.prev, p, pn.next) >= 0)
                {
                    return false;
                }
                p = pn.next;
            }
            return true;
        }

        fn isEarHashed(self: *Self, ear: u32, bounds: Bounds) bool {
            const a = self.node(ear).prev;
            const b = ear;
            const c = self.node(ear).next;
            if (self.area(a, b, c) >= 0) return false;

            const an = self.node(a);
            const bn = self.node(b);
            const cn = self.node(c);
            const min_tx = @min(an.x, @min(bn.x, cn.x));
            const min_ty = @min(an.y, @min(bn.y, cn.y));
            const max_tx = @max(an.x, @max(bn.x, cn.x));
            const max_ty = @max(an.y, @max(bn.y, cn.y));
            const min_z = zOrder(min_tx, min_ty, bounds);
            const max_z = zOrder(max_tx, max_ty, bounds);

            var p = self.node(ear).next_z;
            while (p != nil and self.node(p).z <= max_z) {
                const pn = self.node(p);
                if (p != a and p != c and
                    pointInTriangleExceptFirst(an.x, an.y, bn.x, bn.y, cn.x, cn.y, pn.x, pn.y) and
                    self.area(pn.prev, p, pn.next) >= 0)
                {
                    return false;
                }
                p = pn.next_z;
            }

            p = self.node(ear).prev_z;
            while (p != nil and self.node(p).z >= min_z) {
                const pn = self.node(p);
                if (p != a and p != c and
                    pointInTriangleExceptFirst(an.x, an.y, bn.x, bn.y, cn.x, cn.y, pn.x, pn.y) and
                    self.area(pn.prev, p, pn.next) >= 0)
                {
                    return false;
                }
                p = pn.prev_z;
            }
            return true;
        }

        fn zOrder(x: W, y: W, bounds: Bounds) u32 {
            var lx: u32 = @intFromFloat(std.math.clamp((x - bounds.min_x) * bounds.inv_size, 0.0, 32767.0));
            var ly: u32 = @intFromFloat(std.math.clamp((y - bounds.min_y) * bounds.inv_size, 0.0, 32767.0));
            lx = (lx | (lx << 8)) & 0x00FF00FF;
            lx = (lx | (lx << 4)) & 0x0F0F0F0F;
            lx = (lx | (lx << 2)) & 0x33333333;
            lx = (lx | (lx << 1)) & 0x55555555;
            ly = (ly | (ly << 8)) & 0x00FF00FF;
            ly = (ly | (ly << 4)) & 0x0F0F0F0F;
            ly = (ly | (ly << 2)) & 0x33333333;
            ly = (ly | (ly << 1)) & 0x55555555;
            return lx | (ly << 1);
        }

        fn indexCurve(self: *Self, start: u32, bounds: Bounds) void {
            var p = start;
            while (true) {
                if (!self.node(p).z_valid) {
                    self.node(p).z = zOrder(self.node(p).x, self.node(p).y, bounds);
                    self.node(p).z_valid = true;
                }
                self.node(p).prev_z = self.node(p).prev;
                self.node(p).next_z = self.node(p).next;
                p = self.node(p).next;
                if (p == start) break;
            }

            const tail = self.node(p).prev_z;
            self.node(tail).next_z = nil;
            self.node(p).prev_z = nil;
            _ = self.sortLinked(p);
        }

        fn sortLinked(self: *Self, list: u32) u32 {
            var in_size: usize = 1;
            var head: u32 = list;
            while (true) {
                var p = head;
                head = nil;
                var tail: u32 = nil;
                var merges: usize = 0;

                while (p != nil) {
                    merges += 1;
                    var q = p;
                    var p_size: usize = 0;
                    while (p_size < in_size) : (p_size += 1) {
                        q = self.node(q).next_z;
                        if (q == nil) break;
                    }

                    var q_size = in_size;
                    while (p_size > 0 or (q_size > 0 and q != nil)) {
                        const e = if (p_size == 0) blk: {
                            const out = q;
                            q = self.node(q).next_z;
                            q_size -= 1;
                            break :blk out;
                        } else if (q_size == 0 or q == nil) blk: {
                            const out = p;
                            p = self.node(p).next_z;
                            p_size -= 1;
                            break :blk out;
                        } else if (self.node(p).z <= self.node(q).z) blk: {
                            const out = p;
                            p = self.node(p).next_z;
                            p_size -= 1;
                            break :blk out;
                        } else blk: {
                            const out = q;
                            q = self.node(q).next_z;
                            q_size -= 1;
                            break :blk out;
                        };

                        if (tail != nil) {
                            self.node(tail).next_z = e;
                        } else {
                            head = e;
                        }
                        self.node(e).prev_z = tail;
                        tail = e;
                    }
                    p = q;
                }

                self.node(tail).next_z = nil;
                in_size *= 2;
                if (merges <= 1) break;
            }
            return head;
        }

        fn cureLocalIntersections(self: *Self, start: u32) std.mem.Allocator.Error!u32 {
            var s = start;
            var p = s;
            while (true) {
                const a = self.node(p).prev;
                const pn = self.node(p).next;
                const b = self.node(pn).next;
                if (!self.equals(a, b) and self.intersects(a, p, pn, b) and self.locallyInside(a, b) and self.locallyInside(b, a)) {
                    try self.emit(a, p, b);
                    const b_next = self.node(b).next;
                    self.removeNode(p);
                    self.removeNode(pn);
                    p = b_next;
                    s = b;
                    continue;
                }
                p = self.node(p).next;
                if (p == s) return self.filterPoints(p, nil);
            }
        }

        fn splitEarcut(self: *Self, start: u32, bounds: Bounds) std.mem.Allocator.Error!void {
            var a = start;
            while (true) {
                var b = self.node(self.node(a).next).next;
                while (b != self.node(a).prev) {
                    if (self.node(a).i != self.node(b).i and self.isValidDiagonal(a, b)) {
                        const c = try self.splitPolygon(a, b);
                        const a_filtered = self.filterPoints(a, self.node(a).next);
                        const c_filtered = self.filterPoints(c, self.node(c).next);
                        try self.earcutLinked(a_filtered, bounds, -1);
                        try self.earcutLinked(c_filtered, bounds, -1);
                        return;
                    }
                    b = self.node(b).next;
                }
                a = self.node(a).next;
                if (a == start) return;
            }
        }

        fn getLeftmost(self: *Self, start: u32) u32 {
            var p = start;
            var leftmost = start;
            while (true) {
                if (self.node(p).x < self.node(leftmost).x or
                    (self.node(p).x == self.node(leftmost).x and self.node(p).y < self.node(leftmost).y))
                {
                    leftmost = p;
                }
                p = self.node(p).next;
                if (p == start) break;
            }
            return leftmost;
        }

        fn eliminateHoles(self: *Self, holes: []const []const Vec, outer_in: u32, base_start: u32) !u32 {
            var queue: std.ArrayList(u32) = .empty;
            defer queue.deinit(self.a);

            var base = base_start;
            for (holes) |hole| {
                const list = try self.linkedList(hole, base, false);
                if (list != nil) {
                    if (list == self.node(list).next) self.node(list).steiner = true;
                    try queue.append(self.a, self.getLeftmost(list));
                }
                base += @intCast(hole.len);
            }

            std.mem.sort(u32, queue.items, self, compareNodeX);
            var outer = outer_in;
            for (queue.items) |hole| {
                if (self.findHoleBridge(hole, outer)) |bridge| {
                    const reverse = try self.splitPolygon(bridge, hole);
                    _ = self.filterPoints(reverse, self.node(reverse).next);
                    outer = self.filterPoints(outer, self.node(outer).next);
                }
            }
            return outer;
        }

        fn compareNodeX(self: *Self, lhs: u32, rhs: u32) bool {
            const a = self.node(lhs);
            const b = self.node(rhs);
            if (a.x != b.x) return a.x < b.x;
            if (a.y != b.y) return a.y < b.y;
            const an = self.node(a.next);
            const bn = self.node(b.next);
            const a_slope = (an.y - a.y) / (an.x - a.x);
            const b_slope = (bn.y - b.y) / (bn.x - b.x);
            return a_slope < b_slope;
        }

        fn findHoleBridge(self: *Self, hole: u32, outer: u32) ?u32 {
            const hx = self.node(hole).x;
            const hy = self.node(hole).y;
            var qx: W = -std.math.inf(W);
            var m: u32 = nil;
            var p = outer;

            if (self.equals(hole, p)) return p;
            while (true) {
                const n = self.node(p).next;
                if (self.equals(hole, n)) return n;
                if (hy <= self.node(p).y and hy >= self.node(n).y and self.node(n).y != self.node(p).y) {
                    const x = self.node(p).x + (hy - self.node(p).y) * (self.node(n).x - self.node(p).x) / (self.node(n).y - self.node(p).y);
                    if (x <= hx and x > qx) {
                        qx = x;
                        m = if (self.node(p).x < self.node(n).x) p else n;
                        if (x == hx) return m;
                    }
                }
                p = self.node(p).next;
                if (p == outer) break;
            }
            if (m == nil) return null;
            if (hx == qx) return self.node(m).prev;

            const stop = m;
            const mx = self.node(m).x;
            const my = self.node(m).y;
            var tan_min: W = std.math.inf(W);
            p = m;
            while (true) {
                const pn = self.node(p);
                if (hx >= pn.x and pn.x >= mx and hx != pn.x and
                    pointInTriangle(if (hy < my) hx else qx, hy, mx, my, if (hy < my) qx else hx, hy, pn.x, pn.y))
                {
                    const tan = @abs(hy - pn.y) / (hx - pn.x);
                    if (self.locallyInside(p, hole) and
                        (tan < tan_min or
                            (tan == tan_min and
                                (pn.x > self.node(m).x or (pn.x == self.node(m).x and self.sectorContainsSector(m, p))))))
                    {
                        m = p;
                        tan_min = tan;
                    }
                }
                p = pn.next;
                if (p == stop) break;
            }
            return m;
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

        fn isValidDiagonal(self: *Self, a: u32, b: u32) bool {
            const a_next = self.node(a).next;
            const a_prev = self.node(a).prev;
            if (a_next == b or a_prev == b) return false;

            const b_next = self.node(b).next;
            const b_prev = self.node(b).prev;
            const locally_visible = self.locallyInside(a, b) and
                self.locallyInside(b, a) and
                self.middleInside(a, b) and
                (self.area(a_prev, a, b_prev) != 0 or self.area(a, b_prev, b) != 0);
            const zero_length_valid = self.equals(a, b) and
                self.area(a_prev, a, a_next) > 0 and
                self.area(b_prev, b, b_next) > 0;
            return (locally_visible or zero_length_valid) and !self.intersectsPolygon(a, b);
        }

        fn middleInside(self: *Self, a: u32, b: u32) bool {
            const px = (self.node(a).x + self.node(b).x) / 2;
            const py = (self.node(a).y + self.node(b).y) / 2;
            var inside = false;
            var p = a;
            while (true) {
                const n = self.node(p).next;
                if (((self.node(p).y > py) != (self.node(n).y > py)) and self.node(n).y != self.node(p).y and
                    (px < (self.node(n).x - self.node(p).x) * (py - self.node(p).y) / (self.node(n).y - self.node(p).y) + self.node(p).x))
                {
                    inside = !inside;
                }
                p = n;
                if (p == a) break;
            }
            return inside;
        }

        fn intersectsPolygon(self: *Self, a: u32, b: u32) bool {
            const x0 = @min(self.node(a).x, self.node(b).x);
            const y0 = @min(self.node(a).y, self.node(b).y);
            const x1 = @max(self.node(a).x, self.node(b).x);
            const y1 = @max(self.node(a).y, self.node(b).y);
            var p = a;
            while (true) {
                const n = self.node(p).next;
                const px0 = @min(self.node(p).x, self.node(n).x);
                const py0 = @min(self.node(p).y, self.node(n).y);
                const px1 = @max(self.node(p).x, self.node(n).x);
                const py1 = @max(self.node(p).y, self.node(n).y);
                if (self.node(p).i != self.node(a).i and
                    self.node(n).i != self.node(a).i and
                    self.node(p).i != self.node(b).i and
                    self.node(n).i != self.node(b).i and
                    px0 <= x1 and px1 >= x0 and py0 <= y1 and py1 >= y0 and
                    self.intersects(p, n, a, b))
                {
                    return true;
                }
                p = n;
                if (p == a) break;
            }
            return false;
        }

        fn intersects(self: *Self, p1: u32, q1: u32, p2: u32, q2: u32) bool {
            const o1 = sign(self.area(p1, q1, p2));
            const o2 = sign(self.area(p1, q1, q2));
            const o3 = sign(self.area(p2, q2, p1));
            const o4 = sign(self.area(p2, q2, q1));
            return (o1 != o2 and o3 != o4) or
                (o3 == 0 and self.onSegment(p2, p1, q2)) or
                (o4 == 0 and self.onSegment(p2, q1, q2)) or
                (o2 == 0 and self.onSegment(p1, q2, q1)) or
                (o1 == 0 and self.onSegment(p1, p2, q1));
        }

        fn locallyInside(self: *Self, a: u32, b: u32) bool {
            return if (self.area(self.node(a).prev, a, self.node(a).next) < 0)
                self.area(a, b, self.node(a).next) >= 0 and self.area(a, self.node(a).prev, b) >= 0
            else
                self.area(a, b, self.node(a).prev) < 0 or self.area(a, self.node(a).next, b) < 0;
        }

        fn sectorContainsSector(self: *Self, m: u32, p: u32) bool {
            return self.area(self.node(m).prev, m, self.node(p).prev) < 0 and
                self.area(self.node(p).next, m, self.node(m).next) < 0;
        }

        fn onSegment(self: *Self, p: u32, q: u32, r: u32) bool {
            const pn = self.node(p);
            const qn = self.node(q);
            const rn = self.node(r);
            return qn.x <= @max(pn.x, rn.x) and qn.y <= @max(pn.y, rn.y) and
                qn.x >= @min(pn.x, rn.x) and qn.y >= @min(pn.y, rn.y);
        }

        fn sign(v: W) i32 {
            return @as(i32, @intFromBool(v > 0)) - @as(i32, @intFromBool(v < 0));
        }

        fn computeBounds(outer: []const Vec, holes: []const []const Vec) Bounds {
            var total = outer.len;
            for (holes) |hole| total += hole.len;
            if (total <= 80 or outer.len == 0) return .{};

            var min_x: W = @floatCast(outer[0].x);
            var min_y: W = @floatCast(outer[0].y);
            var max_x = min_x;
            var max_y = min_y;
            for (outer) |p| {
                const x: W = @floatCast(p.x);
                const y: W = @floatCast(p.y);
                min_x = @min(min_x, x);
                min_y = @min(min_y, y);
                max_x = @max(max_x, x);
                max_y = @max(max_y, y);
            }
            const size = @max(max_x - min_x, max_y - min_y);
            return .{ .min_x = min_x, .min_y = min_y, .inv_size = if (size == 0) 0 else 32767.0 / size };
        }

        fn buildMesh(self: *Self, outer: []const Vec, holes: []const []const Vec) !Mesh {
            var total: usize = outer.len;
            for (holes) |h| total += h.len;

            const verts = try self.a.alloc(Vec, total);
            errdefer self.a.free(verts);
            @memcpy(verts[0..outer.len], outer);
            var off = outer.len;
            for (holes) |h| {
                @memcpy(verts[off .. off + h.len], h);
                off += h.len;
            }

            if (outer.len >= 3) {
                var ring = try self.linkedList(outer, 0, true);
                if (holes.len > 0) ring = try self.eliminateHoles(holes, ring, @intCast(outer.len));
                try self.earcutLinked(ring, computeBounds(outer, holes), -1);
            }

            return .{
                .vertices = verts,
                .indices = try self.out.toOwnedSlice(self.a),
                .allocator = self.a,
            };
        }

        pub fn triangulateRaw(
            allocator: std.mem.Allocator,
            outer: []const Vec,
            holes: []const []const Vec,
        ) !Mesh {
            var self = Self{ .nodes = .empty, .out = .empty, .a = allocator };
            defer self.nodes.deinit(allocator);
            errdefer self.out.deinit(allocator);
            return self.buildMesh(outer, holes);
        }

        pub fn triangulateSimple(allocator: std.mem.Allocator, points: []const Vec) !Mesh {
            return triangulateRaw(allocator, points, &.{});
        }
    };
}

pub const GpuVec = struct { x: f32, y: f32 };
pub const F64Vec = struct { x: f64, y: f64 };
pub const GpuFistEarcut = FistEarcut(GpuVec, u32);
pub const FistEarcut64 = FistEarcut(F64Vec, u32);
