const std = @import("std");

pub const Point = struct {
    x: f64,
    y: f64,
};

pub fn parseDatString(allocator: std.mem.Allocator, content: []const u8) ![]Point {
    var points: std.ArrayListUnmanaged(Point) = .empty;
    defer points.deinit(allocator);

    var tokenizer = std.mem.tokenizeAny(u8, content, " \t\r\n");
    while (tokenizer.next()) |x_str| {
        const y_str = tokenizer.next() orelse return error.InvalidFormat;

        const x = try std.fmt.parseFloat(f64, x_str);
        const y = try std.fmt.parseFloat(f64, y_str);

        try points.append(allocator, .{ .x = x, .y = y });
    }

    return try points.toOwnedSlice(allocator);
}

test "parse test.dat" {
    const allocator = std.testing.allocator;
    const test_data =
        \\227.15518 452.33157
        \\344.46202 352.32647
        \\472.15156 452.33157
        \\603.11967 352.32647
        \\344.46202 725.78132
        \\81.390847 352.32647
    ;
    const points = try parseDatString(allocator, test_data);
    defer allocator.free(points);

    try std.testing.expect(points.len == 6);
    try std.testing.expectEqual(227.15518, points[0].x);
    try std.testing.expectEqual(452.33157, points[0].y);
}
