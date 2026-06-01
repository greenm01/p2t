const std = @import("std");

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
    triangle_versions: std.ArrayListUnmanaged(std.atomic.Value(u32)) = .empty,
    triangle_locks: std.ArrayListUnmanaged(std.atomic.Value(u8)) = .empty,

    pub fn deinit(self: *GlobalMesh, allocator: std.mem.Allocator) void {
        self.vertices.deinit(allocator);
        self.triangles.deinit(allocator);
        self.edge_flags.deinit(allocator);
        self.triangle_versions.deinit(allocator);
        self.triangle_locks.deinit(allocator);
    }

    pub fn appendTriangle(self: *GlobalMesh, allocator: std.mem.Allocator, tri: Triangle) !void {
        try self.triangles.append(allocator, tri);
        errdefer _ = self.triangles.pop();
        try self.edge_flags.append(allocator, 0);
        errdefer _ = self.edge_flags.pop();
        try self.triangle_versions.append(allocator, std.atomic.Value(u32).init(1));
        errdefer _ = self.triangle_versions.pop();
        try self.triangle_locks.append(allocator, std.atomic.Value(u8).init(0));
    }

    pub fn ensureTriangleSlot(self: *GlobalMesh, allocator: std.mem.Allocator, triangle_index: i32) !void {
        const slot = @as(usize, @intCast(triangle_index));
        if (slot < self.triangles.len) return;
        if (slot != self.triangles.len) return error.InvalidTriangleVertex;
        try self.appendTriangle(allocator, deadTriangle());
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
        self.triangles.set(slot, tri);
        self.bumpTriangleVersion(triangle_index);
    }

    pub fn setTriangleFresh(self: *GlobalMesh, triangle_index: i32, tri: Triangle) void {
        const slot = @as(usize, @intCast(triangle_index));
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
        self.triangles.set(slot, deadTriangle());
        self.edge_flags.items[slot] = 0;
        self.bumpTriangleVersion(triangle_index);
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
    const version = mesh.triangle_versions.items[0].load(.acquire);
    mesh.setTriangleFresh(0, .{ .v0 = 0, .v1 = 0, .v2 = 0, .adj0 = -1, .adj1 = -1, .adj2 = -1 });
    try std.testing.expect(mesh.triangle_versions.items[0].load(.acquire) != version);

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
