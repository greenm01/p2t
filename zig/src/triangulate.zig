//! CPU polygon triangulation producing a clean, non-overlapping triangle mesh
//! for GPU rendering.
//!
//! Pipeline (built up incrementally):
//!   1. Ear clipping of the contours -> a valid triangulation.       (this file)
//!   2. Hole bridging so holes feed into the same ear-clip.          (next)
//!   3. Constrained Lawson flips -> Delaunay quality for the GPU.    (next)
//!
//! Step 1 alone matches what earcut/nanovg give (valid but slivery); step 3 is
//! what turns it into a GPU-friendly mesh (good aspect ratios, single pass).

const std = @import("std");

pub const Vec2 = struct { x: f64, y: f64 };

pub const Mesh = struct {
    vertices: []Vec2,
    indices: []u32, // triangle list, length is a multiple of 3
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

const nil: u32 = std.math.maxInt(u32);

const Node = struct {
    i: u32, // index into the vertex array
    x: f64,
    y: f64,
    prev: u32, // node-pool indices (circular doubly-linked list)
    next: u32,
    steiner: bool,
};

/// Twice the signed area of triangle (o, a, b). > 0 iff counter-clockwise.
inline fn cross(o: Vec2, a: Vec2, b: Vec2) f64 {
    return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
}

/// Standard shoelace: > 0 iff the ring is counter-clockwise (y-up convention,
/// matching cross()).
fn signedAreaCCW(points: []const Vec2) f64 {
    var sum: f64 = 0;
    for (0..points.len) |i| {
        const a = points[i];
        const b = points[(i + 1) % points.len];
        sum += a.x * b.y - b.x * a.y;
    }
    return sum;
}

/// Builder that owns the node pool and emits triangles.
const EarClipper = struct {
    nodes: std.ArrayList(Node),
    out: std.ArrayList(u32),
    a: std.mem.Allocator,

    fn node(self: *EarClipper, k: u32) *Node {
        return &self.nodes.items[k];
    }

    fn newNode(self: *EarClipper, i: u32, p: Vec2) !u32 {
        const k: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.a, .{
            .i = i,
            .x = p.x,
            .y = p.y,
            .prev = nil,
            .next = nil,
            .steiner = false,
        });
        return k;
    }

    /// Build a circular doubly-linked list over points[start..end] mapping to
    /// vertex indices base..base+len. `ccw` forces counter-clockwise winding.
    fn linkedList(
        self: *EarClipper,
        points: []const Vec2,
        base: u32,
        ccw: bool,
    ) !u32 {
        var last: u32 = nil;
        // Emit in whichever direction yields the requested winding, so that for
        // a CCW ring a convex vertex has cross(prev, cur, next) > 0.
        const ccwInput = signedAreaCCW(points) > 0;
        const forward = ccwInput == ccw;
        if (forward) {
            for (0..points.len) |idx| {
                last = try self.insertAfter(last, base + @as(u32, @intCast(idx)), points[idx]);
            }
        } else {
            var idx: usize = points.len;
            while (idx > 0) {
                idx -= 1;
                last = try self.insertAfter(last, base + @as(u32, @intCast(idx)), points[idx]);
            }
        }
        if (last != nil and self.eq(last, self.node(last).next)) {
            const nx = self.node(last).next;
            self.removeNode(last);
            last = nx;
        }
        return last;
    }

    fn insertAfter(self: *EarClipper, last: u32, i: u32, p: Vec2) !u32 {
        const k = try self.newNode(i, p);
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

    inline fn eq(self: *EarClipper, a: u32, b: u32) bool {
        const na = self.node(a);
        const nb = self.node(b);
        return na.x == nb.x and na.y == nb.y;
    }

    fn removeNode(self: *EarClipper, k: u32) void {
        const p = self.node(k).prev;
        const n = self.node(k).next;
        self.node(p).next = n;
        self.node(n).prev = p;
    }

    fn vec(self: *EarClipper, k: u32) Vec2 {
        const nd = self.node(k);
        return .{ .x = nd.x, .y = nd.y };
    }

    /// Drop collinear or coincident vertices to keep ear-finding clean.
    fn filterPoints(self: *EarClipper, startIn: u32, endIn: u32) u32 {
        if (startIn == nil) return startIn;
        var start = startIn;
        var end = if (endIn == nil) startIn else endIn;
        var p = start;
        var again = true;
        while (again or p != end) {
            again = false;
            const np = self.node(p);
            const collinear = cross(self.vec(np.prev), self.vec(p), self.vec(np.next)) == 0;
            if (!np.steiner and (self.eq(p, np.next) or collinear)) {
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
            start = p;
        }
        return end;
    }

    /// Is `ear` a valid ear: convex, and no other reflex vertex inside it.
    fn isEar(self: *EarClipper, ear: u32) bool {
        const a = self.vec(self.node(ear).prev);
        const b = self.vec(ear);
        const c = self.vec(self.node(ear).next);
        if (cross(a, b, c) <= 0) return false; // reflex or flat (CCW: convex is > 0)

        var p = self.node(self.node(ear).next).next;
        while (p != self.node(ear).prev) {
            const pp = self.vec(p);
            // Reject if a reflex vertex (cross <= 0) lies inside the candidate ear.
            if (pointInTriangle(a, b, c, pp) and
                cross(self.vec(self.node(p).prev), pp, self.vec(self.node(p).next)) <= 0)
            {
                return false;
            }
            p = self.node(p).next;
        }
        return true;
    }

    fn emit(self: *EarClipper, a: u32, b: u32, c: u32) !void {
        try self.out.append(self.a, self.node(a).i);
        try self.out.append(self.a, self.node(b).i);
        try self.out.append(self.a, self.node(c).i);
    }

    /// Ear-clip the ring rooted at `earIn` (assumed counter-clockwise).
    fn earcutLinked(self: *EarClipper, earIn: u32) !void {
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
                // Could not find an ear: input is self-intersecting or
                // degenerate. Recover by clipping the current vertex anyway so
                // we always terminate with a valid-ish mesh.
                try self.emit(self.node(ear).prev, ear, self.node(ear).next);
                self.removeNode(ear);
                ear = self.node(ear).next;
                stop = ear;
            }
        }
    }
};

inline fn pointInTriangle(a: Vec2, b: Vec2, c: Vec2, p: Vec2) bool {
    // p inside (or on) triangle abc, abc given counter-clockwise here as cw in
    // cross() sign terms; use the standard same-side-of-all-edges test.
    const d1 = cross(a, b, p);
    const d2 = cross(b, c, p);
    const d3 = cross(c, a, p);
    const hasNeg = (d1 < 0) or (d2 < 0) or (d3 < 0);
    const hasPos = (d1 > 0) or (d2 > 0) or (d3 > 0);
    return !(hasNeg and hasPos);
}

/// Triangulate a single simple polygon (no holes yet) into a GPU-ready mesh.
pub fn triangulateSimple(
    allocator: std.mem.Allocator,
    points: []const Vec2,
) !Mesh {
    var clipper = EarClipper{
        .nodes = .empty,
        .out = .empty,
        .a = allocator,
    };
    defer clipper.nodes.deinit(allocator);
    errdefer clipper.out.deinit(allocator);

    if (points.len >= 3) {
        const ring = try clipper.linkedList(points, 0, true);
        try clipper.earcutLinked(ring);
    }

    const verts = try allocator.alloc(Vec2, points.len);
    @memcpy(verts, points);
    return .{
        .vertices = verts,
        .indices = try clipper.out.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}
