const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "tess",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    // Tests live in their own module (src/tests.zig), separate from the
    // production sources, and exercise the library through its public API.
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = tests_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Benchmark, always built optimized for meaningful numbers.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench_exe = b.addExecutable(.{ .name = "bench", .root_module = bench_mod });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run the tessellation benchmark");
    bench_step.dependOn(&run_bench.step);

    const default_libtess2_dir = "/home/niltempus/src/libtess2";
    const default_nanovg_dir = "/home/niltempus/src/nanovg";
    const libtess2_dir = b.option([]const u8, "libtess2-dir", "Path to libtess2 checkout") orelse default_libtess2_dir;
    const nanovg_dir = b.option([]const u8, "nanovg-dir", "Path to NanoVG checkout") orelse default_nanovg_dir;
    const fixture_dir = b.option([]const u8, "fixture-dir", "Path to p2t fixture directory") orelse "../tests/fixtures";
    const has_libtess2 = pathExists(b, b.pathJoin(&.{ libtess2_dir, "Include", "tesselator.h" })) and
        pathExists(b, b.pathJoin(&.{ libtess2_dir, "Source", "tess.c" }));
    const has_nanovg = pathExists(b, b.pathJoin(&.{ nanovg_dir, "src", "nanovg.h" })) and
        pathExists(b, b.pathJoin(&.{ nanovg_dir, "src", "nanovg.c" }));

    const compare_options = b.addOptions();
    compare_options.addOption(bool, "has_libtess2", has_libtess2);
    compare_options.addOption(bool, "has_nanovg", has_nanovg);
    compare_options.addOption([]const u8, "libtess2_dir", libtess2_dir);
    compare_options.addOption([]const u8, "nanovg_dir", nanovg_dir);
    compare_options.addOption([]const u8, "fixture_dir", fixture_dir);

    const compare_mod = b.createModule(.{
        .root_source_file = b.path("src/bench_compare.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    compare_mod.addOptions("build_options", compare_options);

    if (has_libtess2) {
        compare_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ libtess2_dir, "Include" }) });
        compare_mod.addCSourceFiles(.{
            .root = .{ .cwd_relative = b.pathJoin(&.{ libtess2_dir, "Source" }) },
            .files = &.{
                "bucketalloc.c",
                "dict.c",
                "geom.c",
                "mesh.c",
                "priorityq.c",
                "sweep.c",
                "tess.c",
            },
            .flags = &.{"-std=c99"},
        });
    }

    if (has_nanovg) {
        compare_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ nanovg_dir, "src" }) });
        compare_mod.addCSourceFiles(.{
            .root = .{ .cwd_relative = b.pathJoin(&.{ nanovg_dir, "src" }) },
            .files = &.{"nanovg.c"},
            .flags = &.{"-std=c99"},
        });
    }

    if (has_libtess2 or has_nanovg) {
        compare_mod.linkSystemLibrary("c", .{});
        compare_mod.linkSystemLibrary("m", .{});
    }

    const compare_exe = b.addExecutable(.{ .name = "bench-compare", .root_module = compare_mod });
    const run_compare = b.addRunArtifact(compare_exe);
    const compare_step = b.step("bench-compare", "Compare Zig fill tessellation against libtess2 and NanoVG");
    compare_step.dependOn(&run_compare.step);

    const xdg_shell_xml = "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml";
    const has_wayland_egl = pathExists(b, "/usr/bin/wayland-scanner") and
        pathExists(b, xdg_shell_xml) and
        pathExists(b, "/usr/include/wayland-client.h") and
        pathExists(b, "/usr/include/wayland-egl.h") and
        pathExists(b, "/usr/include/EGL/egl.h") and
        pathExists(b, "/usr/include/GLES2/gl2.h");
    if (has_wayland_egl) {
        const gl_options = b.addOptions();
        gl_options.addOption(bool, "has_wayland_egl", has_wayland_egl);

        const gl_mod = b.createModule(.{
            .root_source_file = b.path("src/bench_gl_wayland.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        });
        gl_mod.addOptions("build_options", gl_options);

        const xdg_header_cmd = b.addSystemCommand(&.{ "wayland-scanner", "client-header", xdg_shell_xml });
        const xdg_header = xdg_header_cmd.addOutputFileArg("xdg-shell-client-protocol.h");
        const xdg_code_cmd = b.addSystemCommand(&.{ "wayland-scanner", "private-code", xdg_shell_xml });
        const xdg_code = xdg_code_cmd.addOutputFileArg("xdg-shell-protocol.c");
        gl_mod.addIncludePath(xdg_header.dirname());
        gl_mod.addCSourceFile(.{ .file = xdg_code, .flags = &.{"-std=c99"} });
        gl_mod.linkSystemLibrary("c", .{});
        gl_mod.linkSystemLibrary("m", .{});
        gl_mod.linkSystemLibrary("wayland-client", .{});
        gl_mod.linkSystemLibrary("wayland-egl", .{});
        gl_mod.linkSystemLibrary("EGL", .{});
        gl_mod.linkSystemLibrary("GLESv2", .{});

        const gl_exe = b.addExecutable(.{ .name = "bench-gl-wayland", .root_module = gl_mod });
        const run_gl = b.addRunArtifact(gl_exe);
        const gl_step = b.step("bench-gl-wayland", "Run native Wayland/EGL input-to-output GPU benchmark");
        gl_step.dependOn(&run_gl.step);
    } else {
        const gl_step = b.step("bench-gl-wayland", "Run native Wayland/EGL input-to-output GPU benchmark");
        const skip = b.addSystemCommand(&.{ "sh", "-c", "echo 'bench-gl-wayland skipped: Wayland/EGL/GLES2 headers not found'" });
        gl_step.dependOn(&skip.step);
    }
}

fn pathExists(b: *std.Build, path: []const u8) bool {
    const path_z = b.allocator.dupeZ(u8, path) catch @panic("OOM");
    return std.os.linux.errno(std.os.linux.access(path_z, std.os.linux.F_OK)) == .SUCCESS;
}
