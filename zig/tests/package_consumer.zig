const std = @import("std");
const p2t = @import("p2t");

test "external consumer can tessellate through public module" {
    const F = p2t.GpuFillTess;
    const pts = [_]F.Vec{
        .{ .x = 0, .y = 0 },
        .{ .x = 80, .y = 0 },
        .{ .x = 80, .y = 40 },
        .{ .x = 0, .y = 40 },
    };

    var ft = F.init(std.testing.allocator);
    defer ft.deinit();
    try ft.addContour(&pts, .solid);

    var mesh = try ft.tessellateFill(.{
        .quality = .balanced,
        .strategy = .auto,
        .validation = .trusted,
        .keep_boundary_edges = true,
    });
    defer mesh.deinit();

    try std.testing.expectEqual(@as(usize, 4), mesh.vertices.len);
    try std.testing.expectEqual(@as(usize, 2), mesh.triangleCount());
    try std.testing.expectEqual(@as(usize, 4), mesh.boundary_edges.len);
    try std.testing.expect(mesh.diagnostics.used_fast_path);
}
