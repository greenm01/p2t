const std = @import("std");
const build_options = @import("build_options");

pub const Vertex = struct {
    x: f64,
    y: f64,
};

pub const Triangle = struct {
    v0: i32,
    v1: i32,
    v2: i32,
    adj0: i32,
    adj1: i32,
    adj2: i32,
};

pub fn deadTriangle() Triangle {
    return .{
        .v0 = -1,
        .v1 = -1,
        .v2 = -1,
        .adj0 = -1,
        .adj1 = -1,
        .adj2 = -1,
    };
}

pub fn isDeadTriangle(tri: Triangle) bool {
    return tri.v0 < 0 or tri.v1 < 0 or tri.v2 < 0;
}

pub const GlobalMesh = struct {
    vertices: std.MultiArrayList(Vertex) = .empty,
    triangles: std.MultiArrayList(Triangle) = .empty,
    edge_flags: std.ArrayListUnmanaged(u8) = .empty,
    circum_x: std.ArrayListUnmanaged(f64) = .empty,
    circum_y: std.ArrayListUnmanaged(f64) = .empty,
    circum_r2: std.ArrayListUnmanaged(f64) = .empty,
    triangle_versions: std.ArrayListUnmanaged(std.atomic.Value(u32)) = .empty,
    triangle_locks: std.ArrayListUnmanaged(std.atomic.Value(u8)) = .empty,
    live_triangle_count: usize = 0,

    pub fn deinit(self: *GlobalMesh, allocator: std.mem.Allocator) void {
        self.vertices.deinit(allocator);
        self.triangles.deinit(allocator);
        self.edge_flags.deinit(allocator);
        self.circum_x.deinit(allocator);
        self.circum_y.deinit(allocator);
        self.circum_r2.deinit(allocator);
        self.triangle_versions.deinit(allocator);
        self.triangle_locks.deinit(allocator);
    }

    pub fn clearRetainingCapacity(self: *GlobalMesh) void {
        self.vertices.clearRetainingCapacity();
        self.triangles.clearRetainingCapacity();
        self.edge_flags.clearRetainingCapacity();
        self.circum_x.clearRetainingCapacity();
        self.circum_y.clearRetainingCapacity();
        self.circum_r2.clearRetainingCapacity();
        self.triangle_versions.clearRetainingCapacity();
        self.triangle_locks.clearRetainingCapacity();
        self.live_triangle_count = 0;
    }

    pub fn reserve(self: *GlobalMesh, allocator: std.mem.Allocator, vertex_capacity: usize, triangle_capacity: usize) !void {
        try self.vertices.ensureTotalCapacity(allocator, vertex_capacity);
        try self.ensureTriangleCapacity(allocator, triangle_capacity);
    }

    pub fn appendTriangle(self: *GlobalMesh, allocator: std.mem.Allocator, tri: Triangle) !void {
        try self.triangles.append(allocator, tri);
        errdefer _ = self.triangles.pop();
        try self.edge_flags.append(allocator, 0);
        errdefer _ = self.edge_flags.pop();
        if (build_options.circumcircle_filter) {
            try self.circum_x.append(allocator, std.math.nan(f64));
            errdefer _ = self.circum_x.pop();
            try self.circum_y.append(allocator, std.math.nan(f64));
            errdefer _ = self.circum_y.pop();
            try self.circum_r2.append(allocator, -1.0);
            errdefer _ = self.circum_r2.pop();
        }
        try self.triangle_versions.append(allocator, std.atomic.Value(u32).init(1));
        errdefer _ = self.triangle_versions.pop();
        try self.triangle_locks.append(allocator, std.atomic.Value(u8).init(0));
        if (!isDeadTriangle(tri)) self.live_triangle_count += 1;
    }

    pub fn ensureTriangleSlot(self: *GlobalMesh, allocator: std.mem.Allocator, triangle_index: i32) !void {
        const slot = @as(usize, @intCast(triangle_index));
        if (slot < self.triangles.len) return;
        if (slot != self.triangles.len) return error.InvalidTriangleVertex;
        try self.appendTriangle(allocator, deadTriangle());
    }

    pub fn appendDeadTriangleSlotsTrusted(self: *GlobalMesh, allocator: std.mem.Allocator, count: usize) !void {
        if (count == 0) return;
        try self.ensureTriangleCapacity(allocator, self.triangles.len + count);
        for (0..count) |_| {
            self.triangles.appendAssumeCapacity(deadTriangle());
            self.edge_flags.appendAssumeCapacity(0);
            if (build_options.circumcircle_filter) {
                self.circum_x.appendAssumeCapacity(std.math.nan(f64));
                self.circum_y.appendAssumeCapacity(std.math.nan(f64));
                self.circum_r2.appendAssumeCapacity(-1.0);
            }
            self.triangle_versions.appendAssumeCapacity(std.atomic.Value(u32).init(1));
            self.triangle_locks.appendAssumeCapacity(std.atomic.Value(u8).init(0));
        }
    }

    pub fn ensureTriangleCapacity(self: *GlobalMesh, allocator: std.mem.Allocator, capacity: usize) !void {
        try self.triangles.ensureTotalCapacity(allocator, capacity);
        try self.edge_flags.ensureTotalCapacity(allocator, capacity);
        if (build_options.circumcircle_filter) {
            try self.circum_x.ensureTotalCapacity(allocator, capacity);
            try self.circum_y.ensureTotalCapacity(allocator, capacity);
            try self.circum_r2.ensureTotalCapacity(allocator, capacity);
        }
        try self.triangle_versions.ensureTotalCapacity(allocator, capacity);
        try self.triangle_locks.ensureTotalCapacity(allocator, capacity);
    }

    pub fn bumpTriangleVersion(self: *GlobalMesh, triangle_index: i32) void {
        const slot = @as(usize, @intCast(triangle_index));
        const previous = self.triangle_versions.items[slot].fetchAdd(1, .release);
        if (previous == std.math.maxInt(u32)) {
            self.triangle_versions.items[slot].store(1, .release);
        }
    }

    pub fn setTriangle(self: *GlobalMesh, triangle_index: i32, tri: Triangle) void {
        const slot = @as(usize, @intCast(triangle_index));
        self.adjustLiveCount(self.triangles.get(slot), tri);
        self.triangles.set(slot, tri);
        self.bumpTriangleVersion(triangle_index);
    }

    pub fn setTriangleFresh(self: *GlobalMesh, triangle_index: i32, tri: Triangle) void {
        const slot = @as(usize, @intCast(triangle_index));
        self.adjustLiveCount(self.triangles.get(slot), tri);
        self.triangles.set(slot, tri);
        self.edge_flags.items[slot] = 0;
        self.bumpTriangleVersion(triangle_index);
    }

    pub fn setEdgeFlags(self: *GlobalMesh, triangle_index: i32, flags: u8) void {
        const slot = @as(usize, @intCast(triangle_index));
        if (self.edge_flags.items[slot] == flags) return;
        self.edge_flags.items[slot] = flags;
        self.bumpTriangleVersion(triangle_index);
    }

    pub fn markDead(self: *GlobalMesh, triangle_index: i32) void {
        const slot = @as(usize, @intCast(triangle_index));
        self.adjustLiveCount(self.triangles.get(slot), deadTriangle());
        self.triangles.set(slot, deadTriangle());
        self.edge_flags.items[slot] = 0;
        self.bumpTriangleVersion(triangle_index);
    }

    fn adjustLiveCount(self: *GlobalMesh, old_tri: Triangle, new_tri: Triangle) void {
        const was_live = !isDeadTriangle(old_tri);
        const is_live = !isDeadTriangle(new_tri);
        if (!was_live and is_live) {
            self.live_triangle_count += 1;
        } else if (was_live and !is_live) {
            self.live_triangle_count -= 1;
        }
    }

    pub fn setTriangleTrusted(self: *GlobalMesh, triangle_index: i32, tri: Triangle) void {
        const slot = @as(usize, @intCast(triangle_index));
        self.adjustLiveCount(self.triangles.get(slot), tri);
        self.triangles.set(slot, tri);
    }

    pub fn setTriangleFreshTrusted(self: *GlobalMesh, triangle_index: i32, tri: Triangle) void {
        const slot = @as(usize, @intCast(triangle_index));
        self.adjustLiveCount(self.triangles.get(slot), tri);
        self.triangles.set(slot, tri);
        self.edge_flags.items[slot] = 0;
    }

    pub fn setLiveTriangleFreshTrusted(self: *GlobalMesh, triangle_index: i32, tri: Triangle) void {
        const slot = @as(usize, @intCast(triangle_index));
        self.triangles.set(slot, tri);
        self.edge_flags.items[slot] = 0;
    }

    pub fn setDeadTriangleFreshTrusted(self: *GlobalMesh, triangle_index: i32, tri: Triangle) void {
        const slot = @as(usize, @intCast(triangle_index));
        self.triangles.set(slot, tri);
        self.edge_flags.items[slot] = 0;
        if (!isDeadTriangle(tri)) self.live_triangle_count += 1;
    }

    pub fn setEdgeFlagsTrusted(self: *GlobalMesh, triangle_index: i32, flags: u8) void {
        const slot = @as(usize, @intCast(triangle_index));
        self.edge_flags.items[slot] = flags;
    }

    pub fn markDeadTrusted(self: *GlobalMesh, triangle_index: i32) void {
        const slot = @as(usize, @intCast(triangle_index));
        self.adjustLiveCount(self.triangles.get(slot), deadTriangle());
        self.triangles.set(slot, deadTriangle());
        self.edge_flags.items[slot] = 0;
    }

    pub fn setCircumcircle(self: *GlobalMesh, triangle_index: i32, x: f64, y: f64, r2: f64) void {
        const slot = @as(usize, @intCast(triangle_index));
        if (!build_options.circumcircle_filter or slot >= self.circum_r2.items.len) return;
        self.circum_x.items[slot] = x;
        self.circum_y.items[slot] = y;
        self.circum_r2.items[slot] = r2;
    }

    pub fn clearCircumcircle(self: *GlobalMesh, triangle_index: i32) void {
        const slot = @as(usize, @intCast(triangle_index));
        if (!build_options.circumcircle_filter or slot >= self.circum_r2.items.len) return;
        self.circum_x.items[slot] = std.math.nan(f64);
        self.circum_y.items[slot] = std.math.nan(f64);
        self.circum_r2.items[slot] = -1.0;
    }
};

pub const ThreadArena = struct {
    freelist: std.ArrayListUnmanaged(i32) = .empty,
    scratch: ?std.heap.ArenaAllocator = null,

    pub fn deinit(self: *ThreadArena, allocator: std.mem.Allocator) void {
        self.freelist.deinit(allocator);
        if (self.scratch) |scratch| scratch.deinit();
    }

    pub fn tombstone(self: *ThreadArena, allocator: std.mem.Allocator, triangle_index: i32) !void {
        try self.freelist.append(allocator, triangle_index);
    }

    pub fn resetRetainingCapacity(self: *ThreadArena) void {
        self.freelist.clearRetainingCapacity();
        if (self.scratch) |*scratch| {
            _ = scratch.reset(.retain_capacity);
        }
    }

    pub fn getFreeSlot(self: *ThreadArena) ?i32 {
        if (self.freelist.items.len == 0) return null;
        return self.freelist.pop();
    }

    pub fn resetScratch(self: *ThreadArena, allocator: std.mem.Allocator) std.mem.Allocator {
        if (self.scratch) |*scratch| {
            _ = scratch.reset(.retain_capacity);
            return scratch.allocator();
        }

        self.scratch = std.heap.ArenaAllocator.init(allocator);
        return self.scratch.?.allocator();
    }
};

test "GlobalMesh and ThreadArena" {
    const allocator = std.testing.allocator;
    var mesh = GlobalMesh{};
    defer mesh.deinit(allocator);

    try mesh.vertices.append(allocator, .{ .x = 1.0, .y = 2.0 });
    try std.testing.expectEqual(1, mesh.vertices.len);
    try mesh.appendTriangle(allocator, .{ .v0 = 0, .v1 = 0, .v2 = 0, .adj0 = -1, .adj1 = -1, .adj2 = -1 });
    try std.testing.expectEqual(mesh.triangles.len, mesh.edge_flags.items.len);
    try std.testing.expectEqual(mesh.triangles.len, mesh.triangle_versions.items.len);
    try std.testing.expectEqual(mesh.triangles.len, mesh.triangle_locks.items.len);
    try std.testing.expectEqual(@as(usize, 1), mesh.live_triangle_count);
    const version = mesh.triangle_versions.items[0].load(.acquire);
    mesh.setTriangleFresh(0, .{ .v0 = 0, .v1 = 0, .v2 = 0, .adj0 = -1, .adj1 = -1, .adj2 = -1 });
    try std.testing.expect(mesh.triangle_versions.items[0].load(.acquire) != version);
    const trusted_version = mesh.triangle_versions.items[0].load(.acquire);
    mesh.setTriangleFreshTrusted(0, .{ .v0 = 0, .v1 = 0, .v2 = 0, .adj0 = -1, .adj1 = -1, .adj2 = -1 });
    try std.testing.expectEqual(trusted_version, mesh.triangle_versions.items[0].load(.acquire));
    mesh.setLiveTriangleFreshTrusted(0, .{ .v0 = 0, .v1 = 0, .v2 = 0, .adj0 = -1, .adj1 = -1, .adj2 = -1 });
    try std.testing.expectEqual(@as(usize, 1), mesh.live_triangle_count);
    mesh.markDeadTrusted(0);
    try std.testing.expectEqual(@as(usize, 0), mesh.live_triangle_count);

    var arena = ThreadArena{};
    defer arena.deinit(allocator);

    try arena.tombstone(allocator, 42);
    try std.testing.expectEqual(42, arena.getFreeSlot().?);
    try std.testing.expectEqual(null, arena.getFreeSlot());

    const scratch = arena.resetScratch(allocator);
    const tmp = try scratch.alloc(i32, 4);
    tmp[0] = 7;
    const reset_scratch = arena.resetScratch(allocator);
    const reset_tmp = try reset_scratch.alloc(i32, 4);
    reset_tmp[0] = 9;
    try std.testing.expectEqual(@as(i32, 9), reset_tmp[0]);
}
