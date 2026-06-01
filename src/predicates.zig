const std = @import("std");
const mesh = @import("mesh.zig");
const build_options = @import("build_options");

fn orient2dExact(a: mesh.Vertex, b: mesh.Vertex, c: mesh.Vertex) f64 {
    const ax: f128 = @floatCast(a.x);
    const ay: f128 = @floatCast(a.y);
    const bx: f128 = @floatCast(b.x);
    const by: f128 = @floatCast(b.y);
    const cx: f128 = @floatCast(c.x);
    const cy: f128 = @floatCast(c.y);

    const res = (ax - cx) * (by - cy) - (ay - cy) * (bx - cx);
    return @floatCast(res);
}

pub fn orient2d(a: mesh.Vertex, b: mesh.Vertex, c: mesh.Vertex) f64 {
    if (build_options.strict_predicates) return orient2dExact(a, b, c);

    const acx = a.x - c.x;
    const bcx = b.x - c.x;
    const acy = a.y - c.y;
    const bcy = b.y - c.y;
    const det = acx * bcy - acy * bcx;
    const permanent = @abs(acx * bcy) + @abs(acy * bcx);
    if (@abs(det) > permanent * 1.0e-15) return det;
    return orient2dExact(a, b, c);
}

fn incircleExact(a: mesh.Vertex, b: mesh.Vertex, c: mesh.Vertex, d: mesh.Vertex) f64 {
    const ax: f128 = @floatCast(a.x);
    const ay: f128 = @floatCast(a.y);
    const bx: f128 = @floatCast(b.x);
    const by: f128 = @floatCast(b.y);
    const cx: f128 = @floatCast(c.x);
    const cy: f128 = @floatCast(c.y);
    const dx: f128 = @floatCast(d.x);
    const dy: f128 = @floatCast(d.y);

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

pub fn incircle(a: mesh.Vertex, b: mesh.Vertex, c: mesh.Vertex, d: mesh.Vertex) f64 {
    if (build_options.strict_predicates) return incircleExact(a, b, c, d);

    const adx = a.x - d.x;
    const ady = a.y - d.y;
    const bdx = b.x - d.x;
    const bdy = b.y - d.y;
    const cdx = c.x - d.x;
    const cdy = c.y - d.y;

    const abdet = bdx * cdy - cdx * bdy;
    const bcdet = cdx * ady - adx * cdy;
    const cadet = adx * bdy - bdx * ady;
    const alift = adx * adx + ady * ady;
    const blift = bdx * bdx + bdy * bdy;
    const clift = cdx * cdx + cdy * cdy;
    const det = alift * abdet + blift * bcdet + clift * cadet;
    const permanent = @abs(alift * abdet) + @abs(blift * bcdet) + @abs(clift * cadet);
    if (@abs(det) > permanent * 1.0e-12) return det;
    return incircleExact(a, b, c, d);
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
    const eps = 1e-9;
    if (p.x < @min(a.x, b.x) - eps or p.x > @max(a.x, b.x) + eps) return false;
    if (p.y < @min(a.y, b.y) - eps or p.y > @max(a.y, b.y) + eps) return false;
    return @abs(orient2d(a, b, p)) <= eps;
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
