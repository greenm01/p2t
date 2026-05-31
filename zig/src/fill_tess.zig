//! GPU-first fill tessellation workspace.
//!
//! This module is the renderer-facing API: trusted 2D contours in, indexed
//! fill triangles out.  The complex fallback currently delegates to the
//! existing earcut + local-flip triangulator; the workspace/API shape is meant
//! to stay stable while the fallback is replaced with a specialized sweep mesh.

const std = @import("std");
const fist = @import("fist_earcut.zig");
const mutable = @import("mutable_mesh.zig");
const tri = @import("triangulate.zig");

pub fn FillTessellator(comptime Coord: type, comptime Index: type) type {
    return struct {
        const Self = @This();
        const Backend = tri.Tessellator(Coord, Index);
        const W = f64;

        pub const Vec = Backend.Vec;
        const FistBackend = fist.FistEarcut(Vec, Index);
        const MeshRefiner = mutable.Refiner(Vec, Index);
        pub const BoundaryEdge = [2]Index;
        const experimental_area_error_limit = 1e-5;

        pub const ContourKind = enum {
            solid,
            hole,
        };

        pub const FillRule = enum {
            non_zero,
            even_odd,
        };

        pub const Quality = enum {
            raw,
            balanced,
            strict_cdt,
        };

        pub const Strategy = enum {
            auto,
            stable,
            strict,
            experimental_fist,
        };

        pub const TriangleStrategy = enum {
            none,
            fast_path,
            stable_raw,
            stable_balanced,
            strict_cdt,
            fist_earcut_raw,
            fist_earcut_balanced,
        };

        pub const SeedBackend = enum {
            none,
            stable_earcut,
            fist_earcut,
        };

        pub const Validation = enum {
            trusted,
            basic,
        };

        pub const Options = struct {
            fill_rule: FillRule = .non_zero,
            quality: Quality = .balanced,
            strategy: Strategy = .auto,
            validation: Validation = .trusted,
            keep_boundary_edges: bool = false,
        };

        pub const Diagnostics = struct {
            contours: usize = 0,
            vertices: usize = 0,
            triangles: usize = 0,
            used_fast_path: bool = false,
            refined: bool = false,
            refine_converged: bool = true,
            validation_skipped: bool = true,
            quality: Quality = .balanced,
            strategy: Strategy = .auto,
            triangle_strategy: TriangleStrategy = .none,
            seed_backend: SeedBackend = .none,
            area_error: f64 = 0,
            constraint_failures: usize = 0,
            constraint_flips: usize = 0,
            quality_flips: usize = 0,
            quality_budget_exhausted: bool = false,
            fallback_used: bool = false,
            experimental_used: bool = false,
        };

        pub const FillMesh = struct {
            vertices: []Vec,
            indices: []Index,
            boundary_edges: []BoundaryEdge,
            diagnostics: Diagnostics,
            allocator: std.mem.Allocator,

            pub fn triangleCount(self: FillMesh) usize {
                return self.indices.len / 3;
            }

            pub fn deinit(self: *FillMesh) void {
                self.allocator.free(self.vertices);
                self.allocator.free(self.indices);
                self.allocator.free(self.boundary_edges);
                self.* = undefined;
            }
        };

        const ContourRange = struct {
            start: usize,
            len: usize,
            kind: ContourKind,
        };

        pub const Error = error{
            EmptyContour,
            TooFewVertices,
            NonFiniteCoordinate,
            HoleWithoutSolid,
            NoSolidContour,
            UnsupportedFillRule,
        };

        allocator: std.mem.Allocator,
        points: std.ArrayList(Vec),
        contours: std.ArrayList(ContourRange),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .points = .empty,
                .contours = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            self.points.deinit(self.allocator);
            self.contours.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn reset(self: *Self) void {
            self.points.clearRetainingCapacity();
            self.contours.clearRetainingCapacity();
        }

        pub fn reserve(self: *Self, point_count: usize, contour_count: usize) !void {
            try self.points.ensureTotalCapacity(self.allocator, point_count);
            try self.contours.ensureTotalCapacity(self.allocator, contour_count);
        }

        pub fn addContour(self: *Self, points: []const Vec, kind: ContourKind) !void {
            if (points.len == 0) return Error.EmptyContour;
            const start = self.points.items.len;
            try self.points.appendSlice(self.allocator, points);
            try self.contours.append(self.allocator, .{
                .start = start,
                .len = points.len,
                .kind = kind,
            });
        }

        pub fn tessellateFill(self: *Self, options: Options) !FillMesh {
            if (options.fill_rule != .non_zero) return Error.UnsupportedFillRule;
            if (options.validation == .basic) try self.validateBasic();

            var vertices: std.ArrayList(Vec) = .empty;
            errdefer vertices.deinit(self.allocator);
            var indices: std.ArrayList(Index) = .empty;
            errdefer indices.deinit(self.allocator);
            var boundary_edges: std.ArrayList(BoundaryEdge) = .empty;
            errdefer boundary_edges.deinit(self.allocator);

            var diagnostics = Diagnostics{
                .contours = self.contours.items.len,
                .vertices = self.points.items.len,
                .validation_skipped = options.validation == .trusted,
                .quality = options.quality,
                .strategy = options.strategy,
            };

            var saw_solid = false;
            var i: usize = 0;
            while (i < self.contours.items.len) {
                const outer_range = self.contours.items[i];
                if (outer_range.kind == .hole) return Error.HoleWithoutSolid;
                saw_solid = true;

                var j = i + 1;
                while (j < self.contours.items.len and self.contours.items[j].kind == .hole) : (j += 1) {}

                const base: Index = @intCast(vertices.items.len);
                if (i + 1 == j and try self.emitFastGroup(
                    outer_range,
                    options,
                    &vertices,
                    &indices,
                    &boundary_edges,
                )) {
                    diagnostics.used_fast_path = true;
                    diagnostics.triangle_strategy = .fast_path;
                    diagnostics.seed_backend = .none;
                } else {
                    try self.emitBackendGroup(
                        outer_range,
                        self.contours.items[i + 1 .. j],
                        options,
                        &vertices,
                        &indices,
                        &diagnostics,
                    );
                    if (options.keep_boundary_edges) {
                        try self.addBoundaryEdgesForGroup(base, outer_range, self.contours.items[i + 1 .. j], &boundary_edges);
                    }
                }

                i = j;
            }
            if (!saw_solid and self.contours.items.len > 0) return Error.NoSolidContour;

            diagnostics.triangles = indices.items.len / 3;
            return .{
                .vertices = try vertices.toOwnedSlice(self.allocator),
                .indices = try indices.toOwnedSlice(self.allocator),
                .boundary_edges = try boundary_edges.toOwnedSlice(self.allocator),
                .diagnostics = diagnostics,
                .allocator = self.allocator,
            };
        }

        fn validateBasic(self: *Self) !void {
            var have_solid = false;
            for (self.contours.items) |contour| {
                if (contour.len < 3) return Error.TooFewVertices;
                if (contour.kind == .solid) have_solid = true;
                if (contour.kind == .hole and !have_solid) return Error.HoleWithoutSolid;
                for (self.points.items[contour.start .. contour.start + contour.len]) |p| {
                    if (!std.math.isFinite(@as(W, @floatCast(p.x))) or !std.math.isFinite(@as(W, @floatCast(p.y)))) {
                        return Error.NonFiniteCoordinate;
                    }
                }
            }
        }

        fn emitBackendGroup(
            self: *Self,
            outer_range: ContourRange,
            hole_ranges: []const ContourRange,
            options: Options,
            vertices: *std.ArrayList(Vec),
            indices: *std.ArrayList(Index),
            diagnostics: *Diagnostics,
        ) !void {
            var holes: std.ArrayList([]const Vec) = .empty;
            defer holes.deinit(self.allocator);
            for (hole_ranges) |hole| {
                try holes.append(self.allocator, self.points.items[hole.start .. hole.start + hole.len]);
            }

            const outer = self.points.items[outer_range.start .. outer_range.start + outer_range.len];
            switch (self.selectTriangleStrategy(outer_range, hole_ranges, options)) {
                .fast_path, .none => unreachable,
                .stable_raw => {
                    diagnostics.triangle_strategy = .stable_raw;
                    diagnostics.seed_backend = .stable_earcut;
                    var mesh = try Backend.triangulateRaw(self.allocator, outer, holes.items);
                    defer mesh.deinit();
                    try appendBackendMesh(self.allocator, mesh, vertices, indices);
                },
                .strict_cdt => {
                    diagnostics.triangle_strategy = .strict_cdt;
                    diagnostics.seed_backend = .stable_earcut;
                    var mesh = try Backend.triangulate(self.allocator, outer, holes.items);
                    defer mesh.deinit();
                    diagnostics.refined = true;
                    try appendBackendMesh(self.allocator, mesh, vertices, indices);
                },
                .stable_balanced => {
                    try self.emitStableBalanced(outer_range, hole_ranges, outer, holes.items, vertices, indices, diagnostics);
                },
                .fist_earcut_raw => {
                    try self.emitFistRaw(outer, holes.items, vertices, indices, diagnostics);
                },
                .fist_earcut_balanced => {
                    try self.emitFistBalanced(outer_range, hole_ranges, outer, holes.items, vertices, indices, diagnostics);
                },
            }
        }

        fn appendBackendMesh(
            allocator: std.mem.Allocator,
            mesh: anytype,
            vertices: *std.ArrayList(Vec),
            indices: *std.ArrayList(Index),
        ) !void {
            const base = vertices.items.len;
            try vertices.appendSlice(allocator, mesh.vertices);
            try indices.ensureUnusedCapacity(allocator, mesh.indices.len);
            for (mesh.indices) |idx| {
                indices.appendAssumeCapacity(@intCast(base + @as(usize, @intCast(idx))));
            }
        }

        fn selectTriangleStrategy(
            self: *Self,
            outer_range: ContourRange,
            hole_ranges: []const ContourRange,
            options: Options,
        ) TriangleStrategy {
            _ = self;
            if (options.strategy == .strict or options.quality == .strict_cdt) return .strict_cdt;

            if (options.strategy == .experimental_fist and canUseExperimentalFist(outer_range, hole_ranges)) {
                return switch (options.quality) {
                    .raw => .fist_earcut_raw,
                    .balanced => .fist_earcut_balanced,
                    .strict_cdt => .strict_cdt,
                };
            }

            return switch (options.quality) {
                .raw => .stable_raw,
                .balanced => .stable_balanced,
                .strict_cdt => .strict_cdt,
            };
        }

        fn canUseExperimentalFist(outer_range: ContourRange, hole_ranges: []const ContourRange) bool {
            return hole_ranges.len == 0 and outer_range.len > 80;
        }

        fn emitStableBalanced(
            self: *Self,
            outer_range: ContourRange,
            hole_ranges: []const ContourRange,
            outer: []const Vec,
            holes: []const []const Vec,
            vertices: *std.ArrayList(Vec),
            indices: *std.ArrayList(Index),
            diagnostics: *Diagnostics,
        ) !void {
            diagnostics.triangle_strategy = .stable_balanced;
            diagnostics.seed_backend = .stable_earcut;

            var mesh = try Backend.triangulateRaw(self.allocator, outer, holes);
            defer mesh.deinit();

            var constraints: std.ArrayList(BoundaryEdge) = .empty;
            defer constraints.deinit(self.allocator);
            try self.addConstraintEdgesForGroup(outer_range, hole_ranges, &constraints);

            const stats = try MeshRefiner.refine(
                self.allocator,
                mesh.vertices,
                mesh.indices,
                constraints.items,
                0,
            );
            applyRefineStats(diagnostics, stats);

            if (stats.missing_constraints != 0) {
                diagnostics.fallback_used = true;
                diagnostics.triangle_strategy = .strict_cdt;
                var fallback = try Backend.triangulate(self.allocator, outer, holes);
                defer fallback.deinit();
                try appendBackendMesh(self.allocator, fallback, vertices, indices);
            } else {
                try appendBackendMesh(self.allocator, mesh, vertices, indices);
            }
        }

        fn emitFistRaw(
            self: *Self,
            outer: []const Vec,
            holes: []const []const Vec,
            vertices: *std.ArrayList(Vec),
            indices: *std.ArrayList(Index),
            diagnostics: *Diagnostics,
        ) !void {
            diagnostics.experimental_used = true;
            diagnostics.triangle_strategy = .fist_earcut_raw;
            diagnostics.seed_backend = .fist_earcut;

            var mesh = try FistBackend.triangulateRaw(self.allocator, outer, holes);
            defer mesh.deinit();
            diagnostics.area_error = relativeAreaError(mesh, outer, holes);
            if (diagnostics.area_error > experimental_area_error_limit) {
                diagnostics.fallback_used = true;
                diagnostics.triangle_strategy = .stable_raw;
                diagnostics.seed_backend = .stable_earcut;
                var fallback = try Backend.triangulateRaw(self.allocator, outer, holes);
                defer fallback.deinit();
                try appendBackendMesh(self.allocator, fallback, vertices, indices);
            } else {
                try appendBackendMesh(self.allocator, mesh, vertices, indices);
            }
        }

        fn emitFistBalanced(
            self: *Self,
            outer_range: ContourRange,
            hole_ranges: []const ContourRange,
            outer: []const Vec,
            holes: []const []const Vec,
            vertices: *std.ArrayList(Vec),
            indices: *std.ArrayList(Index),
            diagnostics: *Diagnostics,
        ) !void {
            diagnostics.experimental_used = true;
            diagnostics.triangle_strategy = .fist_earcut_balanced;
            diagnostics.seed_backend = .fist_earcut;

            var mesh = try FistBackend.triangulateRaw(self.allocator, outer, holes);
            defer mesh.deinit();
            diagnostics.area_error = relativeAreaError(mesh, outer, holes);

            var constraints: std.ArrayList(BoundaryEdge) = .empty;
            defer constraints.deinit(self.allocator);
            try self.addConstraintEdgesForGroup(outer_range, hole_ranges, &constraints);

            const stats = try MeshRefiner.refine(
                self.allocator,
                mesh.vertices,
                mesh.indices,
                constraints.items,
                0,
            );
            applyRefineStats(diagnostics, stats);

            if (stats.missing_constraints != 0 or diagnostics.area_error > experimental_area_error_limit) {
                diagnostics.fallback_used = true;
                try self.emitStableBalanced(outer_range, hole_ranges, outer, holes, vertices, indices, diagnostics);
            } else {
                try appendBackendMesh(self.allocator, mesh, vertices, indices);
            }
        }

        fn applyRefineStats(diagnostics: *Diagnostics, stats: MeshRefiner.Stats) void {
            diagnostics.constraint_failures += stats.missing_constraints;
            diagnostics.constraint_flips += stats.constraint_flips;
            diagnostics.quality_flips += stats.quality_flips;
            diagnostics.quality_budget_exhausted = diagnostics.quality_budget_exhausted or stats.quality_budget_exhausted;
            diagnostics.refine_converged = diagnostics.refine_converged and !stats.quality_budget_exhausted;
            diagnostics.refined = diagnostics.refined or stats.quality_flips != 0 or stats.constraint_flips != 0;
        }

        fn emitFastGroup(
            self: *Self,
            outer_range: ContourRange,
            options: Options,
            vertices: *std.ArrayList(Vec),
            indices: *std.ArrayList(Index),
            boundary_edges: *std.ArrayList(BoundaryEdge),
        ) !bool {
            if (outer_range.len != 3 and outer_range.len != 4) return false;
            const outer = self.points.items[outer_range.start .. outer_range.start + outer_range.len];
            if (outer_range.len == 4 and !convexQuad(outer)) return false;

            const base: Index = @intCast(vertices.items.len);
            try vertices.appendSlice(self.allocator, outer);
            if (outer_range.len == 3) {
                try appendTri(vertices.items, indices, self.allocator, base, 0, 1, 2);
            } else {
                try appendBestQuad(vertices.items, indices, self.allocator, base);
            }
            if (options.keep_boundary_edges) {
                try addLoopEdges(base, @intCast(outer_range.len), boundary_edges, self.allocator);
            }
            return true;
        }

        fn addBoundaryEdgesForGroup(
            self: *Self,
            base: Index,
            outer_range: ContourRange,
            hole_ranges: []const ContourRange,
            boundary_edges: *std.ArrayList(BoundaryEdge),
        ) !void {
            var offset: Index = 0;
            try addLoopEdges(base + offset, @intCast(outer_range.len), boundary_edges, self.allocator);
            offset += @intCast(outer_range.len);
            for (hole_ranges) |hole| {
                try addLoopEdges(base + offset, @intCast(hole.len), boundary_edges, self.allocator);
                offset += @intCast(hole.len);
            }
        }

        fn addConstraintEdgesForGroup(
            self: *Self,
            outer_range: ContourRange,
            hole_ranges: []const ContourRange,
            constraints: *std.ArrayList(BoundaryEdge),
        ) !void {
            var offset: Index = 0;
            try addLoopEdges(offset, @intCast(outer_range.len), constraints, self.allocator);
            offset += @intCast(outer_range.len);
            for (hole_ranges) |hole| {
                try addLoopEdges(offset, @intCast(hole.len), constraints, self.allocator);
                offset += @intCast(hole.len);
            }
        }

        fn addLoopEdges(
            base: Index,
            len: Index,
            boundary_edges: *std.ArrayList(BoundaryEdge),
            allocator: std.mem.Allocator,
        ) !void {
            if (len < 2) return;
            var i: Index = 0;
            while (i < len) : (i += 1) {
                try boundary_edges.append(allocator, .{ base + i, base + ((i + 1) % len) });
            }
        }

        fn appendBestQuad(
            vertices: []const Vec,
            indices: *std.ArrayList(Index),
            allocator: std.mem.Allocator,
            base: Index,
        ) !void {
            const a = vertices[@intCast(base + 0)];
            const b = vertices[@intCast(base + 1)];
            const c = vertices[@intCast(base + 2)];
            const d = vertices[@intCast(base + 3)];
            const q02 = @min(triQuality(a, b, c), triQuality(a, c, d));
            const q13 = @min(triQuality(a, b, d), triQuality(b, c, d));
            if (q02 >= q13) {
                try appendTri(vertices, indices, allocator, base, 0, 1, 2);
                try appendTri(vertices, indices, allocator, base, 0, 2, 3);
            } else {
                try appendTri(vertices, indices, allocator, base, 0, 1, 3);
                try appendTri(vertices, indices, allocator, base, 1, 2, 3);
            }
        }

        fn appendTri(
            vertices: []const Vec,
            indices: *std.ArrayList(Index),
            allocator: std.mem.Allocator,
            base: Index,
            ai: Index,
            bi: Index,
            ci: Index,
        ) !void {
            const a = vertices[@intCast(base + ai)];
            const b = vertices[@intCast(base + bi)];
            const c = vertices[@intCast(base + ci)];
            if (orient(a, b, c) >= 0) {
                try indices.appendSlice(allocator, &.{ base + ai, base + bi, base + ci });
            } else {
                try indices.appendSlice(allocator, &.{ base + ai, base + ci, base + bi });
            }
        }

        fn convexQuad(points: []const Vec) bool {
            var sign: i32 = 0;
            for (0..4) |i| {
                const o = orient(points[i], points[(i + 1) % 4], points[(i + 2) % 4]);
                if (@abs(o) <= 1e-12) return false;
                const s: i32 = if (o > 0) 1 else -1;
                if (sign == 0) sign = s else if (sign != s) return false;
            }
            return true;
        }

        fn relativeAreaError(mesh: anytype, outer: []const Vec, holes: []const []const Vec) f64 {
            const expected = expectedArea(outer, holes);
            const got = meshArea(mesh);
            if (expected <= 0) return if (got == 0) 0 else std.math.inf(f64);
            return @abs(got - expected) / expected;
        }

        fn expectedArea(outer: []const Vec, holes: []const []const Vec) f64 {
            var area = polygonAreaAbs(outer);
            for (holes) |hole| area -= polygonAreaAbs(hole);
            return @max(area, 0);
        }

        fn polygonAreaAbs(points: []const Vec) f64 {
            if (points.len < 3) return 0;
            var sum: f64 = 0;
            var j = points.len - 1;
            for (points, 0..) |p, i| {
                const q = points[j];
                sum += @as(f64, @floatCast(q.x)) * @as(f64, @floatCast(p.y)) -
                    @as(f64, @floatCast(p.x)) * @as(f64, @floatCast(q.y));
                j = i;
            }
            return @abs(sum) * 0.5;
        }

        fn meshArea(mesh: anytype) f64 {
            var sum: f64 = 0;
            var i: usize = 0;
            while (i < mesh.indices.len) : (i += 3) {
                const a = mesh.vertices[mesh.indices[i]];
                const b = mesh.vertices[mesh.indices[i + 1]];
                const c = mesh.vertices[mesh.indices[i + 2]];
                sum += @abs(orient(a, b, c)) * 0.5;
            }
            return sum;
        }

        fn triQuality(a: Vec, b: Vec, c: Vec) W {
            const ab = dist2(a, b);
            const bc = dist2(b, c);
            const ca = dist2(c, a);
            const longest = @max(ab, @max(bc, ca));
            const area2 = @abs(orient(a, b, c));
            if (longest <= 0 or area2 <= 0) return 0;
            return area2 / longest;
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

pub const GpuFillTess = FillTessellator(f32, u32);
pub const FillTess = GpuFillTess;
