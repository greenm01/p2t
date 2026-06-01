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
    lock: u8,
};

pub fn deadTriangle() Triangle {
    return .{
        .v0 = -1,
        .v1 = -1,
        .v2 = -1,
        .adj0 = -1,
        .adj1 = -1,
        .adj2 = -1,
        .lock = 0,
    };
}

pub fn isDeadTriangle(tri: Triangle) bool {
    return tri.v0 < 0 or tri.v1 < 0 or tri.v2 < 0;
}

pub const GlobalMesh = struct {
    vertices: std.MultiArrayList(Vertex) = .empty,
    triangles: std.MultiArrayList(Triangle) = .empty,
    edge_flags: std.ArrayListUnmanaged(u8) = .empty,

    pub fn deinit(self: *GlobalMesh, allocator: std.mem.Allocator) void {
        self.vertices.deinit(allocator);
        self.triangles.deinit(allocator);
        self.edge_flags.deinit(allocator);
    }

    pub fn appendTriangle(self: *GlobalMesh, allocator: std.mem.Allocator, tri: Triangle) !void {
        try self.triangles.append(allocator, tri);
        errdefer _ = self.triangles.pop();
        try self.edge_flags.append(allocator, 0);
    }

    pub fn ensureTriangleSlot(self: *GlobalMesh, allocator: std.mem.Allocator, triangle_index: i32) !void {
        const slot = @as(usize, @intCast(triangle_index));
        if (slot < self.triangles.len) return;
        if (slot != self.triangles.len) return error.InvalidTriangleVertex;
        try self.appendTriangle(allocator, deadTriangle());
    }

    pub fn setTriangleFresh(self: *GlobalMesh, triangle_index: i32, tri: Triangle) void {
        const slot = @as(usize, @intCast(triangle_index));
        self.triangles.set(slot, tri);
        self.edge_flags.items[slot] = 0;
    }

    pub fn markDead(self: *GlobalMesh, triangle_index: i32) void {
        const slot = @as(usize, @intCast(triangle_index));
        self.triangles.set(slot, deadTriangle());
        self.edge_flags.items[slot] = 0;
    }
};

pub const ThreadArena = struct {
    freelist: std.ArrayListUnmanaged(i32) = .empty,

    pub fn deinit(self: *ThreadArena, allocator: std.mem.Allocator) void {
        self.freelist.deinit(allocator);
    }

    pub fn tombstone(self: *ThreadArena, allocator: std.mem.Allocator, triangle_index: i32) !void {
        try self.freelist.append(allocator, triangle_index);
    }

    pub fn getFreeSlot(self: *ThreadArena) ?i32 {
        if (self.freelist.items.len == 0) return null;
        return self.freelist.pop();
    }
};

test "GlobalMesh and ThreadArena" {
    const allocator = std.testing.allocator;
    var mesh = GlobalMesh{};
    defer mesh.deinit(allocator);

    try mesh.vertices.append(allocator, .{ .x = 1.0, .y = 2.0 });
    try std.testing.expectEqual(1, mesh.vertices.len);
    try mesh.appendTriangle(allocator, .{ .v0 = 0, .v1 = 0, .v2 = 0, .adj0 = -1, .adj1 = -1, .adj2 = -1, .lock = 0 });
    try std.testing.expectEqual(mesh.triangles.len, mesh.edge_flags.items.len);

    var arena = ThreadArena{};
    defer arena.deinit(allocator);

    try arena.tombstone(allocator, 42);
    try std.testing.expectEqual(42, arena.getFreeSlot().?);
    try std.testing.expectEqual(null, arena.getFreeSlot());
}
