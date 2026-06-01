const std = @import("std");
const math = std.math;

fn triAngles(a: @Vector(2, f64), b: @Vector(2, f64), c: @Vector(2, f64)) struct { min: f64, max: f64 } {
    const dist2 = struct {
        fn dist2(p1: @Vector(2, f64), p2: @Vector(2, f64)) f64 {
            const dx = p1[0] - p2[0];
            const dy = p1[1] - p2[1];
            return dx*dx + dy*dy;
        }
    }.dist2;

    const la = @sqrt(dist2(b, c));
    const lb = @sqrt(dist2(a, c));
    const lc = @sqrt(dist2(a, b));

    const ang = struct {
        fn ang(opp: f64, s1: f64, s2: f64) f64 {
            const v = (s1*s1 + s2*s2 - opp*opp) / (2.0 * s1 * s2);
            return math.acos(std.math.clamp(v, -1.0, 1.0)) * 180.0 / math.pi;
        }
    }.ang;

    const angA = ang(la, lb, lc);
    const angB = ang(lb, la, lc);
    const angC = 180.0 - angA - angB;

    const min_ang = @min(angA, @min(angB, angC));
    const max_ang = @max(angA, @max(angB, angC));
    return .{ .min = min_ang, .max = max_ang };
}

pub fn main() void {
    const a = @Vector(2, f64){0.0, 0.0};
    const b = @Vector(2, f64){10.0, 0.0};
    const c = @Vector(2, f64){0.0, 10.0};
    const res = triAngles(a, b, c);
    std.debug.print("min: {d}, max: {d}\n", .{res.min, res.max});
}
