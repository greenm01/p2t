const std = @import("std");
const mesh = @import("mesh.zig");
const predicates = @import("predicates.zig");

const eps = 1e-12;

pub const Segment = struct {
    a: i32,
    b: i32,
};

const Node = struct {
    index: i32,
    prev: usize,
    next: usize,
    z: i32 = 0,
    active: bool = true,
};

const ZIndex = struct {
    order: []usize,
    min_x: f64,
    min_y: f64,
    inv_size: f64,
};

fn signedArea(vertices: []const mesh.Vertex) f64 {
    var sum: f64 = 0.0;
    for (vertices, 0..) |a, i| {
        const b = vertices[(i + 1) % vertices.len];
        sum += a.x * b.y - a.y * b.x;
    }
    return sum * 0.5;
}

fn ringSignedArea(vertices: []const mesh.Vertex, ring: []const i32) f64 {
    var sum: f64 = 0.0;
    for (ring, 0..) |a_idx, i| {
        const b_idx = ring[(i + 1) % ring.len];
        const a = vertices[@as(usize, @intCast(a_idx))];
        const b = vertices[@as(usize, @intCast(b_idx))];
        sum += a.x * b.y - a.y * b.x;
    }
    return sum * 0.5;
}

fn orient(vertices: []const mesh.Vertex, nodes: []const Node, a: usize, b: usize, c: usize) f64 {
    const pa = vertices[@as(usize, @intCast(nodes[a].index))];
    const pb = vertices[@as(usize, @intCast(nodes[b].index))];
    const pc = vertices[@as(usize, @intCast(nodes[c].index))];
    return predicates.orient2d(pa, pb, pc);
}

fn pointInTriangle(a: mesh.Vertex, b: mesh.Vertex, c: mesh.Vertex, p: mesh.Vertex) bool {
    return predicates.orient2d(a, b, p) >= -eps and
        predicates.orient2d(b, c, p) >= -eps and
        predicates.orient2d(c, a, p) >= -eps;
}

fn scaledCoord(value: f64, min_value: f64, inv_size: f64) u32 {
    if (inv_size <= 0.0 or !std.math.isFinite(inv_size)) return 0;
    const raw = (value - min_value) * inv_size;
    if (!(raw > 0.0)) return 0;
    if (raw >= 32767.0) return 32767;
    return @intFromFloat(raw);
}

fn zOrder(vertex: mesh.Vertex, min_x: f64, min_y: f64, inv_size: f64) i32 {
    var x = scaledCoord(vertex.x, min_x, inv_size);
    var y = scaledCoord(vertex.y, min_y, inv_size);

    x = (x | (x << 8)) & 0x00FF00FF;
    x = (x | (x << 4)) & 0x0F0F0F0F;
    x = (x | (x << 2)) & 0x33333333;
    x = (x | (x << 1)) & 0x55555555;

    y = (y | (y << 8)) & 0x00FF00FF;
    y = (y | (y << 4)) & 0x0F0F0F0F;
    y = (y | (y << 2)) & 0x33333333;
    y = (y | (y << 1)) & 0x55555555;

    return @intCast(x | (y << 1));
}

fn lessZ(nodes: []const Node, a: usize, b: usize) bool {
    return nodes[a].z < nodes[b].z;
}

fn buildZOrder(allocator: std.mem.Allocator, vertices: []const mesh.Vertex, nodes: []Node) !ZIndex {
    var min_x = vertices[0].x;
    var min_y = vertices[0].y;
    var max_x = vertices[0].x;
    var max_y = vertices[0].y;
    for (vertices[1..]) |vertex| {
        min_x = @min(min_x, vertex.x);
        min_y = @min(min_y, vertex.y);
        max_x = @max(max_x, vertex.x);
        max_y = @max(max_y, vertex.y);
    }

    const inv_size = 32767.0 / @max(max_x - min_x, max_y - min_y);
    var order = try allocator.alloc(usize, nodes.len);
    errdefer allocator.free(order);
    for (nodes, 0..) |*node, i| {
        node.z = zOrder(vertices[@as(usize, @intCast(node.index))], min_x, min_y, inv_size);
        order[i] = i;
    }
    std.mem.sortUnstable(usize, order, nodes, lessZ);
    return .{
        .order = order,
        .min_x = min_x,
        .min_y = min_y,
        .inv_size = inv_size,
    };
}

fn lowerBoundZ(nodes: []const Node, order: []const usize, z: i32) usize {
    var lo: usize = 0;
    var hi: usize = order.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (nodes[order[mid]].z < z) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

fn containsCandidate(vertices: []const mesh.Vertex, nodes: []const Node, a: usize, b: usize, c: usize, p: usize) bool {
    if (!nodes[p].active or p == a or p == b or p == c) return false;
    const pa = vertices[@as(usize, @intCast(nodes[a].index))];
    const pb = vertices[@as(usize, @intCast(nodes[b].index))];
    const pc = vertices[@as(usize, @intCast(nodes[c].index))];
    const pp = vertices[@as(usize, @intCast(nodes[p].index))];
    return pointInTriangle(pa, pb, pc, pp);
}

fn triangleZBounds(vertices: []const mesh.Vertex, nodes: []const Node, z_index: ZIndex, a: usize, b: usize, c: usize) struct { min: i32, max: i32 } {
    const pa = vertices[@as(usize, @intCast(nodes[a].index))];
    const pb = vertices[@as(usize, @intCast(nodes[b].index))];
    const pc = vertices[@as(usize, @intCast(nodes[c].index))];
    const min_x = @min(pa.x, @min(pb.x, pc.x));
    const min_y = @min(pa.y, @min(pb.y, pc.y));
    const max_x = @max(pa.x, @max(pb.x, pc.x));
    const max_y = @max(pa.y, @max(pb.y, pc.y));
    return .{
        .min = zOrder(.{ .x = min_x, .y = min_y }, z_index.min_x, z_index.min_y, z_index.inv_size),
        .max = zOrder(.{ .x = max_x, .y = max_y }, z_index.min_x, z_index.min_y, z_index.inv_size),
    };
}

fn isEar(vertices: []const mesh.Vertex, nodes: []const Node, z_index: ?ZIndex, ear: usize) bool {
    const a = nodes[ear].prev;
    const b = ear;
    const c = nodes[ear].next;
    if (a == b or b == c or c == a) return false;
    if (orient(vertices, nodes, a, b, c) <= eps) return false;

    if (z_index) |index| {
        const order = index.order;
        const bounds = triangleZBounds(vertices, nodes, index, a, b, c);
        var i = lowerBoundZ(nodes, order, bounds.min);
        while (i < order.len and nodes[order[i]].z <= bounds.max) : (i += 1) {
            if (containsCandidate(vertices, nodes, a, b, c, order[i])) return false;
        }
        return true;
    }

    var p = nodes[c].next;
    while (p != a) : (p = nodes[p].next) {
        if (containsCandidate(vertices, nodes, a, b, c, p)) return false;
    }
    return true;
}

fn removeNode(nodes: []Node, node: usize) usize {
    const prev = nodes[node].prev;
    const next = nodes[node].next;
    nodes[prev].next = next;
    nodes[next].prev = prev;
    nodes[node].active = false;
    return next;
}

pub fn triangulateSimple(allocator: std.mem.Allocator, vertices: []const mesh.Vertex, out_indices: *std.ArrayListUnmanaged(i32)) !void {
    const ring = try allocator.alloc(i32, vertices.len);
    defer allocator.free(ring);
    for (ring, 0..) |*idx, i| idx.* = @intCast(i);
    try triangulateRing(allocator, vertices, ring, out_indices);
}

pub fn triangulateRing(allocator: std.mem.Allocator, vertices: []const mesh.Vertex, ring: []const i32, out_indices: *std.ArrayListUnmanaged(i32)) !void {
    out_indices.clearRetainingCapacity();
    if (ring.len < 3) return error.InvalidTriangleVertex;

    const area = ringSignedArea(vertices, ring);
    if (@abs(area) <= eps) return error.DegenerateTriangle;

    const nodes = try allocator.alloc(Node, ring.len);
    defer allocator.free(nodes);

    const ccw = area > 0.0;
    for (nodes, 0..) |*node, i| {
        const source = if (ccw) i else ring.len - 1 - i;
        node.* = .{
            .index = ring[source],
            .prev = if (i == 0) ring.len - 1 else i - 1,
            .next = if (i + 1 == ring.len) 0 else i + 1,
        };
    }

    const z_index = if (ring.len > 80) try buildZOrder(allocator, vertices, nodes) else null;
    defer if (z_index) |index| allocator.free(index.order);

    try out_indices.ensureTotalCapacity(allocator, (ring.len - 2) * 3);

    var active_count = ring.len;
    var ear: usize = 0;
    var scanned: usize = 0;
    var guard: usize = 0;
    const guard_limit = ring.len * ring.len + ring.len;

    while (active_count > 3) {
        if (guard > guard_limit) return error.UntriangulablePolygon;
        guard += 1;

        if (isEar(vertices, nodes, z_index, ear)) {
            const a = nodes[ear].prev;
            const c = nodes[ear].next;
            out_indices.appendAssumeCapacity(nodes[a].index);
            out_indices.appendAssumeCapacity(nodes[ear].index);
            out_indices.appendAssumeCapacity(nodes[c].index);
            ear = removeNode(nodes, ear);
            active_count -= 1;
            scanned = 0;
            continue;
        }

        ear = nodes[ear].next;
        scanned += 1;
        if (scanned > active_count) return error.UntriangulablePolygon;
    }

    const a = ear;
    const b = nodes[a].next;
    const c = nodes[b].next;
    if (orient(vertices, nodes, a, b, c) <= eps) return error.DegenerateTriangle;
    out_indices.appendAssumeCapacity(nodes[a].index);
    out_indices.appendAssumeCapacity(nodes[b].index);
    out_indices.appendAssumeCapacity(nodes[c].index);
}

test "polygon seed triangulates convex polygon" {
    const vertices = [_]mesh.Vertex{
        .{ .x = 0.0, .y = 0.0 },
        .{ .x = 4.0, .y = 0.0 },
        .{ .x = 5.0, .y = 2.0 },
        .{ .x = 2.0, .y = 4.0 },
        .{ .x = -1.0, .y = 2.0 },
    };
    var indices: std.ArrayListUnmanaged(i32) = .empty;
    defer indices.deinit(std.testing.allocator);

    try triangulateSimple(std.testing.allocator, &vertices, &indices);
    try std.testing.expectEqual(@as(usize, (vertices.len - 2) * 3), indices.items.len);
}

test "polygon seed triangulates concave polygon" {
    const vertices = [_]mesh.Vertex{
        .{ .x = 0.0, .y = 0.0 },
        .{ .x = 4.0, .y = 0.0 },
        .{ .x = 4.0, .y = 3.0 },
        .{ .x = 2.0, .y = 1.0 },
        .{ .x = 0.0, .y = 3.0 },
    };
    var indices: std.ArrayListUnmanaged(i32) = .empty;
    defer indices.deinit(std.testing.allocator);

    try triangulateSimple(std.testing.allocator, &vertices, &indices);
    try std.testing.expectEqual(@as(usize, (vertices.len - 2) * 3), indices.items.len);
}
