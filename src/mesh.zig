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

pub const GlobalMesh = struct {
    vertices: std.MultiArrayList(Vertex) = .empty,
    triangles: std.MultiArrayList(Triangle) = .empty,

    pub fn deinit(self: *GlobalMesh, allocator: std.mem.Allocator) void {
        self.vertices.deinit(allocator);
        self.triangles.deinit(allocator);
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

    var arena = ThreadArena{};
    defer arena.deinit(allocator);

    try arena.tombstone(allocator, 42);
    try std.testing.expectEqual(42, arena.getFreeSlot().?);
    try std.testing.expectEqual(null, arena.getFreeSlot());
}
