//! Mutable triangle-adjacency refinement for renderer-oriented fill meshes.
//!
//! This is intentionally smaller than a general half-edge mesh.  It takes an
//! already valid triangle list, builds temporary adjacency, protects contour
//! edges, and performs bounded quality-improving edge swaps.

const std = @import("std");

pub fn Refiner(comptime VecType: type, comptime Index: type) type {
    return struct {
        const Self = @This();
        const W = f64;
        const nil: u32 = std.math.maxInt(u32);

        pub const Vec = VecType;
        pub const Edge = [2]Index;

        pub const Stats = struct {
            missing_constraints: usize = 0,
            constraint_flips: usize = 0,
            quality_flips: usize = 0,
            quality_budget_exhausted: bool = false,
        };

        const HalfEdge = struct {
            tri: u32,
            slot: u8,
        };

        allocator: std.mem.Allocator,
        tv: std.ArrayList([3]Index) = .empty,
        tn: std.ArrayList([3]u32) = .empty,
        stack: std.ArrayList(u32) = .empty,
        adjacency: std.AutoHashMap(u64, HalfEdge),
        constraints: std.AutoHashMap(u64, void),
        edge_set: std.AutoHashMap(u64, void),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .adjacency = std.AutoHashMap(u64, HalfEdge).init(allocator),
                .constraints = std.AutoHashMap(u64, void).init(allocator),
                .edge_set = std.AutoHashMap(u64, void).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            const allocator = self.allocator;
            self.tv.deinit(allocator);
            self.tn.deinit(allocator);
            self.stack.deinit(allocator);
            self.adjacency.deinit();
            self.constraints.deinit();
            self.edge_set.deinit();
            self.* = undefined;
        }

        pub fn reset(self: *Self) void {
            self.tv.clearRetainingCapacity();
            self.tn.clearRetainingCapacity();
            self.stack.clearRetainingCapacity();
            self.adjacency.clearRetainingCapacity();
            self.constraints.clearRetainingCapacity();
            self.edge_set.clearRetainingCapacity();
        }

        pub fn reserve(self: *Self, triangle_count: usize, constraint_count: usize) !void {
            const allocator = self.allocator;
            try self.tv.ensureTotalCapacity(allocator, triangle_count);
            try self.tn.ensureTotalCapacity(allocator, triangle_count);
            try self.stack.ensureTotalCapacity(allocator, triangle_count * 3);
            try self.adjacency.ensureTotalCapacity(@intCast(triangle_count * 3));
            try self.constraints.ensureTotalCapacity(@intCast(constraint_count));
            try self.edge_set.ensureTotalCapacity(@intCast(triangle_count * 3));
        }

        pub fn refine(
            allocator: std.mem.Allocator,
            vertices: []const Vec,
            indices: []Index,
            constraints_in: []const Edge,
            budget_in: usize,
        ) !Stats {
            var self = Self.init(allocator);
            defer self.deinit();
            return self.refineInPlace(vertices, indices, constraints_in, budget_in);
        }

        pub fn refineInPlace(
            self: *Self,
            vertices: []const Vec,
            indices: []Index,
            constraints_in: []const Edge,
            budget_in: usize,
        ) !Stats {
            var stats = Stats{};
            if (indices.len < 6) return stats;

            const allocator = self.allocator;
            const ntri = indices.len / 3;
            self.reset();
            try self.reserve(ntri, constraints_in.len);
            try self.tv.resize(allocator, ntri);
            try self.tn.resize(allocator, ntri);
            const tv = self.tv.items;
            const tn = self.tn.items;
            for (0..ntri) |t| {
                tv[t] = .{ indices[t * 3], indices[t * 3 + 1], indices[t * 3 + 2] };
                tn[t] = .{ nil, nil, nil };
            }

            for (constraints_in) |edge| {
                try self.constraints.put(edgeKey(edge[0], edge[1]), {});
            }

            try self.buildAdjacency(tv, tn);
            try buildEdgeSet(tv, &self.edge_set);

            var constraint_budget = 16 * ntri + 64;
            for (constraints_in) |edge| {
                const present = self.edge_set.contains(edgeKey(edge[0], edge[1]));
                if (!present) {
                    _ = insertConstraintBySwaps(vertices, tv, tn, &self.constraints, edge[0], edge[1], &constraint_budget, &stats);
                }
                if (!present and !edgeExists(tv, edge[0], edge[1])) stats.missing_constraints += 1;
            }
            if (stats.missing_constraints != 0) return stats;

            try self.stack.ensureTotalCapacity(allocator, ntri * 3);
            for (0..ntri) |t| {
                for (0..3) |slot| self.stack.appendAssumeCapacity(@intCast(t * 3 + slot));
            }

            var budget = if (budget_in == 0) 32 * ntri + 64 else budget_in;
            while (self.stack.pop()) |he| {
                if (budget == 0) {
                    stats.quality_budget_exhausted = self.stack.items.len > 0;
                    break;
                }
                budget -= 1;

                const t: usize = he / 3;
                const e: usize = he % 3;
                const ot_id = tn[t][e];
                if (ot_id == nil) continue;
                const ot: usize = ot_id;

                const s1 = tv[t][(e + 1) % 3];
                const s2 = tv[t][(e + 2) % 3];
                if (self.constraints.contains(edgeKey(s1, s2))) continue;

                var f: usize = 0;
                while (f < 3 and tn[ot][f] != t) : (f += 1) {}
                if (f == 3) continue;

                const apex_t = tv[t][e];
                const apex_ot = tv[ot][f];
                if (!isConvexQuad(vertices, apex_t, s1, apex_ot, s2)) continue;
                if (!flipImproves(vertices, apex_t, s1, s2, apex_ot)) continue;
                if (!flipEdge(vertices, tv, tn, t, e)) continue;

                stats.quality_flips += 1;
                try self.stack.append(allocator, @intCast(t * 3 + 1));
                try self.stack.append(allocator, @intCast(t * 3 + 2));
                try self.stack.append(allocator, @intCast(ot * 3 + 0));
                try self.stack.append(allocator, @intCast(ot * 3 + 2));
            }

            for (0..ntri) |t| {
                indices[t * 3] = tv[t][0];
                indices[t * 3 + 1] = tv[t][1];
                indices[t * 3 + 2] = tv[t][2];
            }
            return stats;
        }

        fn buildAdjacency(self: *Self, tv: []const [3]Index, tn: [][3]u32) !void {
            try self.adjacency.ensureTotalCapacity(@intCast(tv.len * 3));
            for (tv, 0..) |tri, t| {
                for (0..3) |slot| {
                    const a = tri[(slot + 1) % 3];
                    const b = tri[(slot + 2) % 3];
                    const key = edgeKey(a, b);
                    if (self.adjacency.fetchRemove(key)) |kv| {
                        const other = kv.value;
                        tn[t][slot] = other.tri;
                        tn[other.tri][other.slot] = @intCast(t);
                    } else {
                        try self.adjacency.put(key, .{ .tri = @intCast(t), .slot = @intCast(slot) });
                    }
                }
            }
        }

        fn buildEdgeSet(tv: []const [3]Index, set: *std.AutoHashMap(u64, void)) !void {
            for (tv) |tri| {
                for (0..3) |slot| {
                    try set.put(edgeKey(tri[(slot + 1) % 3], tri[(slot + 2) % 3]), {});
                }
            }
        }

        fn insertConstraintBySwaps(
            vertices: []const Vec,
            tv: [][3]Index,
            tn: [][3]u32,
            constraints: *const std.AutoHashMap(u64, void),
            a: Index,
            b: Index,
            budget: *usize,
            stats: *Stats,
        ) bool {
            while (!edgeExists(tv, a, b)) {
                if (budget.* == 0) return false;
                var flipped = false;
                outer: for (0..tv.len) |t| {
                    for (0..3) |slot| {
                        const ot = tn[t][slot];
                        if (ot == nil or t > ot) continue;
                        const e0 = tv[t][(slot + 1) % 3];
                        const e1 = tv[t][(slot + 2) % 3];
                        if (constraints.contains(edgeKey(e0, e1))) continue;
                        if (!segmentsProperlyCross(vertices[@intCast(a)], vertices[@intCast(b)], vertices[@intCast(e0)], vertices[@intCast(e1)])) continue;
                        if (!flipEdge(vertices, tv, tn, t, slot)) continue;
                        budget.* -= 1;
                        stats.constraint_flips += 1;
                        flipped = true;
                        break :outer;
                    }
                }
                if (!flipped) return false;
            }
            return true;
        }

        fn flipEdge(vertices: []const Vec, tv: [][3]Index, tn: [][3]u32, t: usize, e: usize) bool {
            const ot_id = tn[t][e];
            if (ot_id == nil) return false;
            const ot: usize = ot_id;
            var f: usize = 0;
            while (f < 3 and tn[ot][f] != t) : (f += 1) {}
            if (f == 3) return false;

            const s1 = tv[t][(e + 1) % 3];
            const s2 = tv[t][(e + 2) % 3];
            const apex_t = tv[t][e];
            const apex_ot = tv[ot][f];
            if (!isConvexQuad(vertices, apex_t, s1, apex_ot, s2)) return false;

            const next_t: [3]Index = .{ s2, apex_t, apex_ot };
            const next_ot: [3]Index = .{ apex_t, s1, apex_ot };
            if (orientIndex(vertices, next_t) <= 0 or orientIndex(vertices, next_ot) <= 0) return false;

            const n_ab = tn[t][(e + 1) % 3];
            const n_bc = tn[t][(e + 2) % 3];
            const n_cd = tn[ot][(f + 1) % 3];
            const n_da = tn[ot][(f + 2) % 3];

            tv[t] = next_t;
            tn[t] = .{ ot_id, n_da, n_ab };
            tv[ot] = next_ot;
            tn[ot] = .{ n_cd, @intCast(t), n_bc };

            if (n_bc != nil) {
                for (0..3) |k| {
                    if (tn[n_bc][k] == t) tn[n_bc][k] = @intCast(ot);
                }
            }
            if (n_da != nil) {
                for (0..3) |k| {
                    if (tn[n_da][k] == ot) tn[n_da][k] = @intCast(t);
                }
            }
            return true;
        }

        fn edgeExists(tv: []const [3]Index, a: Index, b: Index) bool {
            for (tv) |tri| {
                for (0..3) |slot| {
                    const e0 = tri[(slot + 1) % 3];
                    const e1 = tri[(slot + 2) % 3];
                    if ((e0 == a and e1 == b) or (e0 == b and e1 == a)) return true;
                }
            }
            return false;
        }

        fn flipImproves(vertices: []const Vec, apex_t: Index, s1: Index, s2: Index, apex_ot: Index) bool {
            const old_a = triMetric(vertices, apex_t, s1, s2);
            const old_b = triMetric(vertices, apex_ot, s2, s1);
            const new_a = triMetric(vertices, s2, apex_t, apex_ot);
            const new_b = triMetric(vertices, apex_t, s1, apex_ot);

            const old_min = @min(old_a.min_angle, old_b.min_angle);
            const new_min = @min(new_a.min_angle, new_b.min_angle);
            const old_sum = old_a.min_angle + old_b.min_angle;
            const new_sum = new_a.min_angle + new_b.min_angle;
            const eps = 1e-14;
            if (new_sum + eps < old_sum) return false;
            if (new_min > old_min + eps) return true;
            if (new_min + eps < old_min) return false;
            return new_a.aspect_proxy + new_b.aspect_proxy + eps < old_a.aspect_proxy + old_b.aspect_proxy;
        }

        const Metric = struct {
            min_angle: W,
            aspect_proxy: W,
        };

        fn triMetric(vertices: []const Vec, ai: Index, bi: Index, ci: Index) Metric {
            const a = vertices[@intCast(ai)];
            const b = vertices[@intCast(bi)];
            const c = vertices[@intCast(ci)];
            const ab = dist2(a, b);
            const bc = dist2(b, c);
            const ca = dist2(c, a);
            const longest = @max(ab, @max(bc, ca));
            const shortest = @max(@min(ab, @min(bc, ca)), 1e-30);
            return .{
                .min_angle = minAngleSin2(a, b, c),
                .aspect_proxy = longest / shortest,
            };
        }

        fn minAngleSin2(a: Vec, b: Vec, c: Vec) W {
            const ab = dist2(a, b);
            const bc = dist2(b, c);
            const ca = dist2(c, a);
            const shortest = @min(ab, @min(bc, ca));
            const area2 = orient(a, b, c);
            const area4 = area2 * area2;
            if (area4 <= 0) return 0;
            if (shortest == ab) return area4 / @max(ca * bc, 1e-30);
            if (shortest == bc) return area4 / @max(ab * ca, 1e-30);
            return area4 / @max(ab * bc, 1e-30);
        }

        fn isConvexQuad(vertices: []const Vec, a: Index, b: Index, c: Index, d: Index) bool {
            const va = vertices[@intCast(a)];
            const vb = vertices[@intCast(b)];
            const vc = vertices[@intCast(c)];
            const vd = vertices[@intCast(d)];
            const o1 = orient(va, vc, vb);
            const o2 = orient(va, vc, vd);
            return (o1 > 0 and o2 < 0) or (o1 < 0 and o2 > 0);
        }

        fn orientIndex(vertices: []const Vec, tri: [3]Index) W {
            const a = vertices[@intCast(tri[0])];
            const b = vertices[@intCast(tri[1])];
            const c = vertices[@intCast(tri[2])];
            return orient(a, b, c);
        }

        fn segmentsProperlyCross(a: Vec, b: Vec, c: Vec, d: Vec) bool {
            const o1 = orient(a, b, c);
            const o2 = orient(a, b, d);
            const o3 = orient(c, d, a);
            const o4 = orient(c, d, b);
            return ((o1 > 0 and o2 < 0) or (o1 < 0 and o2 > 0)) and
                ((o3 > 0 and o4 < 0) or (o3 < 0 and o4 > 0));
        }

        fn edgeKey(a: Index, b: Index) u64 {
            const lo: u64 = @intCast(@min(a, b));
            const hi: u64 = @intCast(@max(a, b));
            return (hi << 32) | lo;
        }

        fn orient(a: Vec, b: Vec, c: Vec) W {
            return (@as(W, @floatCast(b.x)) - @as(W, @floatCast(a.x))) *
                (@as(W, @floatCast(c.y)) - @as(W, @floatCast(a.y))) -
                (@as(W, @floatCast(b.y)) - @as(W, @floatCast(a.y))) *
                    (@as(W, @floatCast(c.x)) - @as(W, @floatCast(a.x)));
        }

        fn dist2(a: Vec, b: Vec) W {
            const dx = @as(W, @floatCast(a.x)) - @as(W, @floatCast(b.x));
            const dy = @as(W, @floatCast(a.y)) - @as(W, @floatCast(b.y));
            return dx * dx + dy * dy;
        }
    };
}
