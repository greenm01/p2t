const std = @import("std");
const math = std.math;
const mesh = @import("mesh.zig");
const predicates = @import("predicates.zig");

pub const QualityStats = struct {
    count: usize = 0,
    minAngle: f64 = 180.0,
    maxAngle: f64 = 0.0,
    meanMinAngle: f64 = 0.0,
    slivers20: usize = 0,
    slivers30: usize = 0,
    maxAspect: f64 = 0.0,
    meanAspect: f64 = 0.0,
    hist: [9]usize = [_]usize{0} ** 9,
    
    sumMin: f64 = 0.0,
    sumAspect: f64 = 0.0,

    fn dist2(p1: mesh.Vertex, p2: mesh.Vertex) f64 {
        const dx = p1.x - p2.x;
        const dy = p1.y - p2.y;
        return dx*dx + dy*dy;
    }

    fn ang(opp: f64, s1: f64, s2: f64) f64 {
        const v = (s1*s1 + s2*s2 - opp*opp) / (2.0 * s1 * s2);
        return math.acos(std.math.clamp(v, -1.0, 1.0)) * 180.0 / math.pi;
    }

    fn triAngles(a: mesh.Vertex, b: mesh.Vertex, c: mesh.Vertex) struct { min: f64, max: f64 } {
        const la = @sqrt(dist2(b, c));
        const lb = @sqrt(dist2(a, c));
        const lc = @sqrt(dist2(a, b));

        const angA = ang(la, lb, lc);
        const angB = ang(lb, la, lc);
        const angC = 180.0 - angA - angB;

        const min_ang = @min(angA, @min(angB, angC));
        const max_ang = @max(angA, @max(angB, angC));
        return .{ .min = min_ang, .max = max_ang };
    }

    fn triangleArea(a: mesh.Vertex, b: mesh.Vertex, c: mesh.Vertex) f64 {
        return @abs((a.x*(b.y - c.y) + b.x*(c.y - a.y) + c.x*(a.y - b.y)) / 2.0);
    }

    pub fn accumulate(self: *QualityStats, a: mesh.Vertex, b: mesh.Vertex, c: mesh.Vertex) void {
        const area = triangleArea(a, b, c);
        if (area <= 0.0) return;
        self.count += 1;

        const angles = triAngles(a, b, c);
        self.minAngle = @min(self.minAngle, angles.min);
        self.maxAngle = @max(self.maxAngle, angles.max);
        self.sumMin += angles.min;

        if (angles.min < 20.0) self.slivers20 += 1;
        if (angles.min < 30.0) self.slivers30 += 1;

        const bucket = std.math.clamp(@as(usize, @intFromFloat(angles.min / 10.0)), 0, 8);
        self.hist[bucket] += 1;

        const e0 = @sqrt(dist2(a, b));
        const e1 = @sqrt(dist2(b, c));
        const e2 = @sqrt(dist2(c, a));
        const max_e = @max(e0, @max(e1, e2));
        const min_e = @max(@min(e0, @min(e1, e2)), 1e-30);
        const aspect = max_e / min_e;

        self.maxAspect = @max(self.maxAspect, aspect);
        self.sumAspect += aspect;
    }

    pub fn finalize(self: *QualityStats) void {
        if (self.count > 0) {
            self.meanMinAngle = self.sumMin / @as(f64, @floatFromInt(self.count));
            self.meanAspect = self.sumAspect / @as(f64, @floatFromInt(self.count));
        }
    }

    pub fn print(self: *const QualityStats, name: []const u8) void {
        std.debug.print("  {s} (Zig)\n", .{name});
        std.debug.print("    triangles   : {d}\n", .{self.count});
        std.debug.print("    min angle   : {d:>7.3} deg   (higher is better)\n", .{self.minAngle});
        std.debug.print("    max angle   : {d:>7.3} deg   (lower is better)\n", .{self.maxAngle});
        std.debug.print("    mean min ang: {d:>7.3} deg   (higher is better)\n", .{self.meanMinAngle});
        std.debug.print("    slivers <20 : {d}   <30: {d}\n", .{self.slivers20, self.slivers30});
        std.debug.print("    aspect ratio: max {d:>7.2}  mean {d:>6.2}\n", .{self.maxAspect, self.meanAspect});
    }
};
