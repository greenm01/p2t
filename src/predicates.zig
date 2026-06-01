const std = @import("std");
const mesh = @import("mesh.zig");

pub fn orient2d(a: mesh.Vertex, b: mesh.Vertex, c: mesh.Vertex) f64 {
    return (a.x - c.x) * (b.y - c.y) - (a.y - c.y) * (b.x - c.x);
}

pub fn incircle(a: mesh.Vertex, b: mesh.Vertex, c: mesh.Vertex, d: mesh.Vertex) f64 {
    const adx = a.x - d.x;
    const ady = a.y - d.y;
    const bdx = b.x - d.x;
    const bdy = b.y - d.y;
    const cdx = c.x - d.x;
    const cdy = c.y - d.y;

    const alift = adx * adx + ady * ady;
    const blift = bdx * bdx + bdy * bdy;
    const clift = cdx * cdx + cdy * cdy;

    return alift * (bdx * cdy - cdx * bdy) +
           blift * (cdx * ady - adx * cdy) +
           clift * (adx * bdy - bdx * ady);
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

    // InCircle
    const d_inside = mesh.Vertex{ .x = 2.0, .y = 2.0 };
    try std.testing.expect(incircle(a, b, c, d_inside) > 0.0);

    const d_outside = mesh.Vertex{ .x = 20.0, .y = 20.0 };
    try std.testing.expect(incircle(a, b, c, d_outside) < 0.0);
}
