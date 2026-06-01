const std = @import("std");
const mesh = @import("mesh.zig");
const build_options = @import("build_options");

pub const PredicateStats = struct {
    orient_calls: u64 = 0,
    orient_exact: u64 = 0,
    incircle_calls: u64 = 0,
    incircle_exact: u64 = 0,

    pub fn any(self: PredicateStats) bool {
        return self.orient_calls != 0 or self.incircle_calls != 0;
    }
};

var predicate_stats = PredicateStats{};

inline fn statInc(comptime field: []const u8) void {
    if (build_options.instrument_predicates) {
        @field(predicate_stats, field) += 1;
    }
}

pub fn resetStats() void {
    if (build_options.instrument_predicates) {
        predicate_stats = .{};
    }
}

pub fn statsSnapshot() PredicateStats {
    if (build_options.instrument_predicates) {
        return predicate_stats;
    }
    return .{};
}

fn orient2dExactCoords(ax_f64: f64, ay_f64: f64, bx_f64: f64, by_f64: f64, cx_f64: f64, cy_f64: f64) f64 {
    const ax: f128 = @floatCast(ax_f64);
    const ay: f128 = @floatCast(ay_f64);
    const bx: f128 = @floatCast(bx_f64);
    const by: f128 = @floatCast(by_f64);
    const cx: f128 = @floatCast(cx_f64);
    const cy: f128 = @floatCast(cy_f64);
    const res = (ax - cx) * (by - cy) - (ay - cy) * (bx - cx);
    return @floatCast(res);
}

pub fn orient2dCoords(ax: f64, ay: f64, bx: f64, by: f64, cx: f64, cy: f64) f64 {
    statInc("orient_calls");
    if (build_options.predicate_policy == .strict) {
        statInc("orient_exact");
        return orient2dExactCoords(ax, ay, bx, by, cx, cy);
    }

    const acx = ax - cx;
    const bcx = bx - cx;
    const acy = ay - cy;
    const bcy = by - cy;
    const det = acx * bcy - acy * bcx;
    if (build_options.predicate_policy == .fast) return det;

    const permanent = @abs(acx * bcy) + @abs(acy * bcx);
    if (@abs(det) > permanent * 1.0e-15) return det;
    statInc("orient_exact");
    return orient2dExactCoords(ax, ay, bx, by, cx, cy);
}

pub fn orient2d(a: mesh.Vertex, b: mesh.Vertex, c: mesh.Vertex) f64 {
    return orient2dCoords(a.x, a.y, b.x, b.y, c.x, c.y);
}

fn incircleExactCoords(ax_f64: f64, ay_f64: f64, bx_f64: f64, by_f64: f64, cx_f64: f64, cy_f64: f64, dx_f64: f64, dy_f64: f64) f64 {
    const ax: f128 = @floatCast(ax_f64);
    const ay: f128 = @floatCast(ay_f64);
    const bx: f128 = @floatCast(bx_f64);
    const by: f128 = @floatCast(by_f64);
    const cx: f128 = @floatCast(cx_f64);
    const cy: f128 = @floatCast(cy_f64);
    const dx: f128 = @floatCast(dx_f64);
    const dy: f128 = @floatCast(dy_f64);
    const adx = ax - dx;
    const ady = ay - dy;
    const bdx = bx - dx;
    const bdy = by - dy;
    const cdx = cx - dx;
    const cdy = cy - dy;

    const alift = adx * adx + ady * ady;
    const blift = bdx * bdx + bdy * bdy;
    const clift = cdx * cdx + cdy * cdy;

    const res = alift * (bdx * cdy - cdx * bdy) +
        blift * (cdx * ady - adx * cdy) +
        clift * (adx * bdy - bdx * ady);

    return @floatCast(res);
}

pub fn incircleCoords(ax: f64, ay: f64, bx: f64, by: f64, cx: f64, cy: f64, dx: f64, dy: f64) f64 {
    statInc("incircle_calls");
    if (build_options.predicate_policy == .strict) {
        statInc("incircle_exact");
        return incircleExactCoords(ax, ay, bx, by, cx, cy, dx, dy);
    }

    const adx = ax - dx;
    const ady = ay - dy;
    const bdx = bx - dx;
    const bdy = by - dy;
    const cdx = cx - dx;
    const cdy = cy - dy;

    const abdet = bdx * cdy - cdx * bdy;
    const bcdet = cdx * ady - adx * cdy;
    const cadet = adx * bdy - bdx * ady;
    const alift = adx * adx + ady * ady;
    const blift = bdx * bdx + bdy * bdy;
    const clift = cdx * cdx + cdy * cdy;
    const det = alift * abdet + blift * bcdet + clift * cadet;
    if (build_options.predicate_policy == .fast) return det;

    const permanent = @abs(alift * abdet) + @abs(blift * bcdet) + @abs(clift * cadet);
    if (@abs(det) > permanent * 1.0e-12) return det;
    statInc("incircle_exact");
    return incircleExactCoords(ax, ay, bx, by, cx, cy, dx, dy);
}

pub fn incircle(a: mesh.Vertex, b: mesh.Vertex, c: mesh.Vertex, d: mesh.Vertex) f64 {
    return incircleCoords(a.x, a.y, b.x, b.y, c.x, c.y, d.x, d.y);
}

pub fn intersect(a: mesh.Vertex, b: mesh.Vertex, c: mesh.Vertex, d: mesh.Vertex) bool {
    const o1 = orient2d(a, b, c);
    const o2 = orient2d(a, b, d);
    const o3 = orient2d(c, d, a);
    const o4 = orient2d(c, d, b);

    if (o1 * o2 < 0.0 and o3 * o4 < 0.0) return true;
    return false;
}

pub fn pointOnSegment(a: mesh.Vertex, b: mesh.Vertex, p: mesh.Vertex) bool {
    return pointOnSegmentCoords(a.x, a.y, b.x, b.y, p.x, p.y);
}

pub fn pointOnSegmentCoords(ax: f64, ay: f64, bx: f64, by: f64, px: f64, py: f64) bool {
    const eps = 1e-9;
    if (px < @min(ax, bx) - eps or px > @max(ax, bx) + eps) return false;
    if (py < @min(ay, by) - eps or py > @max(ay, by) + eps) return false;
    return @abs(orient2dCoords(ax, ay, bx, by, px, py)) <= eps;
}

test "predicates" {
    const a = mesh.Vertex{ .x = 0.0, .y = 0.0 };
    const b = mesh.Vertex{ .x = 10.0, .y = 0.0 };
    const c = mesh.Vertex{ .x = 0.0, .y = 10.0 };

    // CCW orientation
    try std.testing.expect(orient2d(a, b, c) > 0.0);

    // CW orientation
    try std.testing.expect(orient2d(a, c, b) < 0.0);

    // Collinear
    const c_collinear = mesh.Vertex{ .x = 5.0, .y = 0.0 };
    try std.testing.expect(orient2d(a, b, c_collinear) == 0.0);
    try std.testing.expect(pointOnSegment(a, b, c_collinear));
    try std.testing.expect(!pointOnSegment(a, b, mesh.Vertex{ .x = 11.0, .y = 0.0 }));
    try std.testing.expect(!pointOnSegment(a, b, mesh.Vertex{ .x = 5.0, .y = 1.0 }));

    // InCircle
    const d_inside = mesh.Vertex{ .x = 2.0, .y = 2.0 };
    try std.testing.expect(incircle(a, b, c, d_inside) > 0.0);

    const d_outside = mesh.Vertex{ .x = 20.0, .y = 20.0 };
    try std.testing.expect(incircle(a, b, c, d_outside) < 0.0);
}
