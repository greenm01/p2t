//! Native Wayland/EGL/GLES2 input-to-output benchmark.
//!
//! This intentionally avoids GLX/X11/XWayland.  Each timed iteration starts
//! from contours, tessellates with GpuFillTess, uploads vertices+indices, draws
//! into a Wayland EGL surface, swaps, and synchronizes with glFinish().

const std = @import("std");
const linux = std.os.linux;
const opts = @import("build_options");
const tess = @import("root.zig");

const F = tess.GpuFillTess;
const Vec = F.Vec;

const c = if (opts.has_wayland_egl) @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wayland-egl.h");
    @cInclude("xdg-shell-client-protocol.h");
    @cInclude("EGL/egl.h");
    @cInclude("GLES2/gl2.h");
}) else struct {};

const width = 640;
const height = 640;

const Case = struct {
    name: []const u8,
    outer: []const Vec,
    holes: []const []const Vec = &.{},
    iterations: usize,
};

const GlBench = struct {
    best_ns: u64,
    mean_ns: u64,
    triangles: usize,
    vertices: usize,
    upload_bytes: usize,
};

const WaylandState = struct {
    display: *c.wl_display,
    registry: *c.wl_registry,
    compositor: ?*c.wl_compositor = null,
    wm_base: ?*c.xdg_wm_base = null,
};

const GlState = struct {
    wl: WaylandState,
    surface: *c.wl_surface,
    xdg_surface: *c.xdg_surface,
    xdg_toplevel: *c.xdg_toplevel,
    egl_window: *c.wl_egl_window,
    egl_display: c.EGLDisplay,
    egl_context: c.EGLContext,
    egl_surface: c.EGLSurface,
    program: c.GLuint,
    vbo: c.GLuint,
    ibo: c.GLuint,
    a_pos: c.GLint,
    u_scale: c.GLint,
    u_offset: c.GLint,

    fn deinit(self: *GlState) void {
        c.glDeleteBuffers(1, &self.ibo);
        c.glDeleteBuffers(1, &self.vbo);
        c.glDeleteProgram(self.program);
        _ = c.eglMakeCurrent(self.egl_display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, c.EGL_NO_CONTEXT);
        _ = c.eglDestroySurface(self.egl_display, self.egl_surface);
        _ = c.eglDestroyContext(self.egl_display, self.egl_context);
        _ = c.eglTerminate(self.egl_display);
        c.wl_egl_window_destroy(self.egl_window);
        c.xdg_toplevel_destroy(self.xdg_toplevel);
        c.xdg_surface_destroy(self.xdg_surface);
        c.wl_surface_destroy(self.surface);
        if (self.wl.wm_base) |wm_base| c.xdg_wm_base_destroy(wm_base);
        if (self.wl.compositor) |compositor| c.wl_compositor_destroy(compositor);
        c.wl_registry_destroy(self.wl.registry);
        c.wl_display_disconnect(self.wl.display);
    }
};

var shell_configured = false;
var shell_closed = false;

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn main() !void {
    if (!opts.has_wayland_egl) {
        std.debug.print("bench-gl-wayland skipped: Wayland/EGL/GLES2 headers not found\n", .{});
        return;
    }

    const allocator = std.heap.smp_allocator;
    var gl = initGl() catch |err| switch (err) {
        error.WaylandConnectFailed => {
            std.debug.print("bench-gl-wayland skipped: wl_display_connect failed; run inside a Wayland session\n", .{});
            return;
        },
        else => return err,
    };
    defer gl.deinit();

    std.debug.print("native Wayland/EGL input-to-output benchmark\n", .{});
    std.debug.print("  backend: wl_display + wl_egl_window + EGL + GLES2\n", .{});
    std.debug.print("  timing : tessellate + upload + draw + eglSwapBuffers + glFinish\n\n", .{});

    const ellipse_pts = try ellipse(allocator, 100, 200, 50);
    defer allocator.free(ellipse_pts);
    try runCase(allocator, &gl, .{ .name = "ellipse-100", .outer = ellipse_pts, .iterations = 2000 });

    const gear_pts = try gear(allocator, 32);
    defer allocator.free(gear_pts);
    try runCase(allocator, &gl, .{ .name = "gear-64", .outer = gear_pts, .iterations = 2000 });

    const wiggly_pts = try wiggly(allocator, 1000);
    defer allocator.free(wiggly_pts);
    try runCase(allocator, &gl, .{ .name = "wiggly-1000", .outer = wiggly_pts, .iterations = 200 });

    const outer = [_]Vec{
        .{ .x = 0, .y = 0 },
        .{ .x = 200, .y = 0 },
        .{ .x = 200, .y = 200 },
        .{ .x = 0, .y = 200 },
    };
    var hole_store: [4][4]Vec = undefined;
    var holes: [4][]const Vec = undefined;
    const centers = [_][2]f32{ .{ 50, 50 }, .{ 150, 50 }, .{ 50, 150 }, .{ 150, 150 } };
    for (centers, 0..) |center, i| {
        hole_store[i] = .{
            .{ .x = center[0] - 20, .y = center[1] - 20 },
            .{ .x = center[0] - 20, .y = center[1] + 20 },
            .{ .x = center[0] + 20, .y = center[1] + 20 },
            .{ .x = center[0] + 20, .y = center[1] - 20 },
        };
        holes[i] = &hole_store[i];
    }
    try runCase(allocator, &gl, .{ .name = "rect-4-holes", .outer = &outer, .holes = &holes, .iterations = 2000 });
}

fn runCase(allocator: std.mem.Allocator, gl: *GlState, case: Case) !void {
    const bounds = contourBounds(case.outer, case.holes);
    std.debug.print("{s}: {d} points, {d} holes, {d} runs\n", .{
        case.name,
        case.outer.len + countHolePoints(case.holes),
        case.holes.len,
        case.iterations,
    });
    std.debug.print("  mode       best us  mean us  tris  verts  upload KB\n", .{});
    try printMode(allocator, gl, case, bounds, .raw, "raw");
    try printMode(allocator, gl, case, bounds, .balanced, "balanced");
    try printMode(allocator, gl, case, bounds, .strict_cdt, "strict");
    std.debug.print("\n", .{});
}

fn printMode(
    allocator: std.mem.Allocator,
    gl: *GlState,
    case: Case,
    bounds: Bounds,
    quality: F.Quality,
    name: []const u8,
) !void {
    const result = try benchMode(allocator, gl, case, bounds, quality);
    std.debug.print("  {s:<9} {d:7.2} {d:8.2} {d:5} {d:6} {d:9.2}\n", .{
        name,
        @as(f64, @floatFromInt(result.best_ns)) / 1000.0,
        @as(f64, @floatFromInt(result.mean_ns)) / 1000.0,
        result.triangles,
        result.vertices,
        @as(f64, @floatFromInt(result.upload_bytes)) / 1024.0,
    });
}

fn benchMode(
    allocator: std.mem.Allocator,
    gl: *GlState,
    case: Case,
    bounds: Bounds,
    quality: F.Quality,
) !GlBench {
    var ft = F.init(allocator);
    defer ft.deinit();
    try ft.reserve(case.outer.len + countHolePoints(case.holes), case.holes.len + 1);

    try addContours(&ft, case);
    var first = try ft.tessellateFill(.{ .quality = quality });
    defer first.deinit();
    const first_indices = try toU16Indices(allocator, first.indices);
    defer allocator.free(first_indices);
    drawMesh(gl, first.vertices, first_indices, bounds);
    _ = c.eglSwapBuffers(gl.egl_display, gl.egl_surface);
    c.glFinish();

    var best: u64 = std.math.maxInt(u64);
    var total: u128 = 0;
    for (0..case.iterations) |_| {
        const t0 = nowNs();
        try addContours(&ft, case);
        var mesh = try ft.tessellateFill(.{ .quality = quality });
        defer mesh.deinit();
        const indices = try toU16Indices(allocator, mesh.indices);
        defer allocator.free(indices);
        drawMesh(gl, mesh.vertices, indices, bounds);
        if (c.eglSwapBuffers(gl.egl_display, gl.egl_surface) != c.EGL_TRUE) return error.EglSwapFailed;
        c.glFinish();
        _ = c.wl_display_dispatch_pending(gl.wl.display);
        if (shell_closed) return error.WaylandWindowClosed;
        const dt = nowNs() - t0;
        best = @min(best, dt);
        total += dt;
    }

    return .{
        .best_ns = best,
        .mean_ns = @intCast(total / case.iterations),
        .triangles = first.indices.len / 3,
        .vertices = first.vertices.len,
        .upload_bytes = first.vertices.len * @sizeOf(Vec) + first.indices.len * @sizeOf(u16),
    };
}

fn addContours(ft: *F, case: Case) !void {
    ft.reset();
    try ft.addContour(case.outer, .solid);
    for (case.holes) |hole| try ft.addContour(hole, .hole);
}

fn drawMesh(gl: *GlState, vertices: []const Vec, indices: []const u16, bounds: Bounds) void {
    c.glViewport(0, 0, width, height);
    c.glClearColor(0.08, 0.09, 0.10, 1.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT);
    c.glUseProgram(gl.program);

    const sx = 1.8 / @max(bounds.max_x - bounds.min_x, 1e-6);
    const sy = 1.8 / @max(bounds.max_y - bounds.min_y, 1e-6);
    const scale = @min(sx, sy);
    const cx = (bounds.min_x + bounds.max_x) * 0.5;
    const cy = (bounds.min_y + bounds.max_y) * 0.5;
    c.glUniform2f(gl.u_scale, scale, -scale);
    c.glUniform2f(gl.u_offset, -cx * scale, cy * scale);

    c.glBindBuffer(c.GL_ARRAY_BUFFER, gl.vbo);
    c.glBufferData(c.GL_ARRAY_BUFFER, @intCast(vertices.len * @sizeOf(Vec)), vertices.ptr, c.GL_STREAM_DRAW);
    c.glBindBuffer(c.GL_ELEMENT_ARRAY_BUFFER, gl.ibo);
    c.glBufferData(c.GL_ELEMENT_ARRAY_BUFFER, @intCast(indices.len * @sizeOf(u16)), indices.ptr, c.GL_STREAM_DRAW);
    c.glEnableVertexAttribArray(@intCast(gl.a_pos));
    c.glVertexAttribPointer(@intCast(gl.a_pos), 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Vec), null);
    c.glDrawElements(c.GL_TRIANGLES, @intCast(indices.len), c.GL_UNSIGNED_SHORT, null);
}

fn initGl() !GlState {
    const wl = try initWayland();
    errdefer {
        if (wl.wm_base) |wm_base| c.xdg_wm_base_destroy(wm_base);
        if (wl.compositor) |compositor| c.wl_compositor_destroy(compositor);
        c.wl_registry_destroy(wl.registry);
        c.wl_display_disconnect(wl.display);
    }

    const surface = c.wl_compositor_create_surface(wl.compositor.?) orelse return error.WaylandSurfaceFailed;
    errdefer c.wl_surface_destroy(surface);

    shell_configured = false;
    shell_closed = false;
    const xdg_surface = c.xdg_wm_base_get_xdg_surface(wl.wm_base.?, surface) orelse return error.XdgSurfaceFailed;
    errdefer c.xdg_surface_destroy(xdg_surface);
    if (c.xdg_surface_add_listener(xdg_surface, &xdg_surface_listener, null) != 0) return error.XdgSurfaceListenerFailed;
    const xdg_toplevel = c.xdg_surface_get_toplevel(xdg_surface) orelse return error.XdgToplevelFailed;
    errdefer c.xdg_toplevel_destroy(xdg_toplevel);
    if (c.xdg_toplevel_add_listener(xdg_toplevel, &xdg_toplevel_listener, null) != 0) return error.XdgToplevelListenerFailed;
    c.xdg_toplevel_set_title(xdg_toplevel, "p2t bench-gl-wayland");
    c.xdg_toplevel_set_app_id(xdg_toplevel, "p2t-bench-gl-wayland");
    c.wl_surface_commit(surface);
    while (!shell_configured) {
        if (c.wl_display_dispatch(wl.display) < 0) return error.WaylandConfigureFailed;
        if (shell_closed) return error.WaylandWindowClosed;
    }

    const egl_window = c.wl_egl_window_create(surface, width, height) orelse return error.WaylandEglWindowFailed;
    errdefer c.wl_egl_window_destroy(egl_window);

    const egl_display = c.eglGetDisplay(@ptrCast(wl.display));
    if (egl_display == c.EGL_NO_DISPLAY) return error.EglDisplayFailed;
    var major: c.EGLint = 0;
    var minor: c.EGLint = 0;
    if (c.eglInitialize(egl_display, &major, &minor) != c.EGL_TRUE) return error.EglInitFailed;
    errdefer _ = c.eglTerminate(egl_display);

    if (c.eglBindAPI(c.EGL_OPENGL_ES_API) != c.EGL_TRUE) return error.EglBindApiFailed;

    const attrs = [_]c.EGLint{
        c.EGL_SURFACE_TYPE,    c.EGL_WINDOW_BIT,
        c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_ES2_BIT,
        c.EGL_RED_SIZE,        8,
        c.EGL_GREEN_SIZE,      8,
        c.EGL_BLUE_SIZE,       8,
        c.EGL_ALPHA_SIZE,      8,
        c.EGL_NONE,
    };
    var config: c.EGLConfig = null;
    var nconfig: c.EGLint = 0;
    if (c.eglChooseConfig(egl_display, &attrs, &config, 1, &nconfig) != c.EGL_TRUE or nconfig == 0) return error.EglConfigFailed;

    const context_attrs = [_]c.EGLint{
        c.EGL_CONTEXT_CLIENT_VERSION, 2,
        c.EGL_NONE,
    };
    const context = c.eglCreateContext(egl_display, config, c.EGL_NO_CONTEXT, &context_attrs);
    if (context == c.EGL_NO_CONTEXT) return error.EglContextFailed;
    errdefer _ = c.eglDestroyContext(egl_display, context);

    const egl_surface = c.eglCreateWindowSurface(egl_display, config, @ptrCast(egl_window), null);
    if (egl_surface == c.EGL_NO_SURFACE) return error.EglSurfaceFailed;
    errdefer _ = c.eglDestroySurface(egl_display, egl_surface);

    if (c.eglMakeCurrent(egl_display, egl_surface, egl_surface, context) != c.EGL_TRUE) return error.EglMakeCurrentFailed;
    _ = c.eglSwapInterval(egl_display, 0);

    var vbo: c.GLuint = 0;
    var ibo: c.GLuint = 0;
    c.glGenBuffers(1, &vbo);
    c.glGenBuffers(1, &ibo);
    errdefer {
        c.glDeleteBuffers(1, &ibo);
        c.glDeleteBuffers(1, &vbo);
    }

    const program = try makeProgram();
    const a_pos = c.glGetAttribLocation(program, "a_pos");
    const u_scale = c.glGetUniformLocation(program, "u_scale");
    const u_offset = c.glGetUniformLocation(program, "u_offset");
    if (a_pos < 0 or u_scale < 0 or u_offset < 0) return error.GlProgramBindingsFailed;

    return .{
        .wl = wl,
        .surface = surface,
        .xdg_surface = xdg_surface,
        .xdg_toplevel = xdg_toplevel,
        .egl_window = egl_window,
        .egl_display = egl_display,
        .egl_context = context,
        .egl_surface = egl_surface,
        .program = program,
        .vbo = vbo,
        .ibo = ibo,
        .a_pos = a_pos,
        .u_scale = u_scale,
        .u_offset = u_offset,
    };
}

fn initWayland() !WaylandState {
    const display = c.wl_display_connect(null) orelse return error.WaylandConnectFailed;
    errdefer c.wl_display_disconnect(display);

    const registry = c.wl_display_get_registry(display) orelse return error.WaylandRegistryFailed;
    errdefer c.wl_registry_destroy(registry);

    var state = WaylandState{
        .display = display,
        .registry = registry,
    };
    if (c.wl_registry_add_listener(registry, &registry_listener, &state) != 0) return error.WaylandRegistryListenerFailed;
    if (c.wl_display_roundtrip(display) < 0) return error.WaylandRoundtripFailed;
    if (state.compositor == null) return error.WaylandCompositorMissing;
    if (state.wm_base == null) return error.XdgWmBaseMissing;
    if (c.xdg_wm_base_add_listener(state.wm_base.?, &wm_base_listener, null) != 0) return error.XdgWmBaseListenerFailed;
    return state;
}

const registry_listener = c.wl_registry_listener{
    .global = registryGlobal,
    .global_remove = registryGlobalRemove,
};

fn registryGlobal(
    data: ?*anyopaque,
    registry: ?*c.wl_registry,
    name: u32,
    interface: [*c]const u8,
    version: u32,
) callconv(.c) void {
    _ = version;
    const state: *WaylandState = @ptrCast(@alignCast(data.?));
    const iface = std.mem.sliceTo(interface, 0);
    if (std.mem.eql(u8, iface, "wl_compositor")) {
        state.compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, 4));
    } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
        state.wm_base = @ptrCast(c.wl_registry_bind(registry, name, &c.xdg_wm_base_interface, 2));
    }
}

fn registryGlobalRemove(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32) callconv(.c) void {
    _ = data;
    _ = registry;
    _ = name;
}

const wm_base_listener = c.xdg_wm_base_listener{
    .ping = wmBasePing,
};

fn wmBasePing(data: ?*anyopaque, wm_base: ?*c.xdg_wm_base, serial: u32) callconv(.c) void {
    _ = data;
    c.xdg_wm_base_pong(wm_base, serial);
}

const xdg_surface_listener = c.xdg_surface_listener{
    .configure = xdgSurfaceConfigure,
};

fn xdgSurfaceConfigure(data: ?*anyopaque, xdg_surface: ?*c.xdg_surface, serial: u32) callconv(.c) void {
    _ = data;
    c.xdg_surface_ack_configure(xdg_surface, serial);
    shell_configured = true;
}

const xdg_toplevel_listener = c.xdg_toplevel_listener{
    .configure = xdgToplevelConfigure,
    .close = xdgToplevelClose,
    .configure_bounds = xdgToplevelConfigureBounds,
    .wm_capabilities = xdgToplevelWmCapabilities,
};

fn xdgToplevelConfigure(data: ?*anyopaque, toplevel: ?*c.xdg_toplevel, next_width: i32, next_height: i32, states: ?*c.wl_array) callconv(.c) void {
    _ = data;
    _ = toplevel;
    _ = next_width;
    _ = next_height;
    _ = states;
}

fn xdgToplevelClose(data: ?*anyopaque, toplevel: ?*c.xdg_toplevel) callconv(.c) void {
    _ = data;
    _ = toplevel;
    shell_closed = true;
}

fn xdgToplevelConfigureBounds(data: ?*anyopaque, toplevel: ?*c.xdg_toplevel, next_width: i32, next_height: i32) callconv(.c) void {
    _ = data;
    _ = toplevel;
    _ = next_width;
    _ = next_height;
}

fn xdgToplevelWmCapabilities(data: ?*anyopaque, toplevel: ?*c.xdg_toplevel, capabilities: ?*c.wl_array) callconv(.c) void {
    _ = data;
    _ = toplevel;
    _ = capabilities;
}

fn makeProgram() !c.GLuint {
    const vs = try compileShader(c.GL_VERTEX_SHADER,
        \\attribute vec2 a_pos;
        \\uniform vec2 u_scale;
        \\uniform vec2 u_offset;
        \\void main() {
        \\  gl_Position = vec4(a_pos * u_scale + u_offset, 0.0, 1.0);
        \\}
    );
    defer c.glDeleteShader(vs);
    const fs = try compileShader(c.GL_FRAGMENT_SHADER,
        \\precision mediump float;
        \\void main() {
        \\  gl_FragColor = vec4(0.18, 0.68, 0.92, 1.0);
        \\}
    );
    defer c.glDeleteShader(fs);

    const program = c.glCreateProgram();
    c.glAttachShader(program, vs);
    c.glAttachShader(program, fs);
    c.glLinkProgram(program);
    var ok: c.GLint = 0;
    c.glGetProgramiv(program, c.GL_LINK_STATUS, &ok);
    if (ok != c.GL_TRUE) {
        c.glDeleteProgram(program);
        return error.GlProgramLinkFailed;
    }
    return program;
}

fn compileShader(kind: c.GLenum, source: [:0]const u8) !c.GLuint {
    const shader = c.glCreateShader(kind);
    var sources = [_][*c]const u8{source.ptr};
    c.glShaderSource(shader, 1, &sources, null);
    c.glCompileShader(shader);
    var ok: c.GLint = 0;
    c.glGetShaderiv(shader, c.GL_COMPILE_STATUS, &ok);
    if (ok != c.GL_TRUE) {
        c.glDeleteShader(shader);
        return error.GlShaderCompileFailed;
    }
    return shader;
}

fn toU16Indices(allocator: std.mem.Allocator, indices: []const u32) ![]u16 {
    const out = try allocator.alloc(u16, indices.len);
    for (indices, 0..) |idx, i| {
        if (idx > std.math.maxInt(u16)) return error.TooManyVerticesForGles2U16;
        out[i] = @intCast(idx);
    }
    return out;
}

const Bounds = struct {
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,
};

fn contourBounds(outer: []const Vec, holes: []const []const Vec) Bounds {
    var b = Bounds{
        .min_x = outer[0].x,
        .min_y = outer[0].y,
        .max_x = outer[0].x,
        .max_y = outer[0].y,
    };
    addBounds(&b, outer);
    for (holes) |hole| addBounds(&b, hole);
    return b;
}

fn addBounds(bounds: *Bounds, points: []const Vec) void {
    for (points) |p| {
        bounds.min_x = @min(bounds.min_x, p.x);
        bounds.min_y = @min(bounds.min_y, p.y);
        bounds.max_x = @max(bounds.max_x, p.x);
        bounds.max_y = @max(bounds.max_y, p.y);
    }
}

fn countHolePoints(holes: []const []const Vec) usize {
    var count: usize = 0;
    for (holes) |hole| count += hole.len;
    return count;
}

fn ellipse(allocator: std.mem.Allocator, n: usize, rx: f32, ry: f32) ![]Vec {
    const pts = try allocator.alloc(Vec, n);
    for (0..n) |k| {
        const a = 2.0 * std.math.pi * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
        pts[k] = .{ .x = rx * @cos(a), .y = ry * @sin(a) };
    }
    return pts;
}

fn gear(allocator: std.mem.Allocator, teeth: usize) ![]Vec {
    const n = teeth * 2;
    const pts = try allocator.alloc(Vec, n);
    for (0..n) |k| {
        const r: f32 = if (k % 2 == 0) 100.0 else 60.0;
        const a = 2.0 * std.math.pi * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
        pts[k] = .{ .x = r * @cos(a), .y = r * @sin(a) };
    }
    return pts;
}

fn wiggly(allocator: std.mem.Allocator, n: usize) ![]Vec {
    const pts = try allocator.alloc(Vec, n);
    for (0..n) |k| {
        const a = 2.0 * std.math.pi * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
        const r = 100.0 + 30.0 * @sin(7.0 * a) + 15.0 * @sin(13.0 * a) + 8.0 * @sin(23.0 * a);
        pts[k] = .{ .x = r * @cos(a), .y = r * @sin(a) };
    }
    return pts;
}
