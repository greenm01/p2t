const std = @import("std");

const PredicatePolicy = enum { adaptive, strict, fast };

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.
    const strict_predicates = b.option(bool, "strict-predicates", "Always use f128 geometric predicates") orelse false;
    const predicate_policy_name = b.option([]const u8, "predicate-policy", "Geometric predicate policy: adaptive, strict, or fast") orelse if (strict_predicates) "strict" else "adaptive";
    const instrument_predicates = b.option(bool, "instrument-predicates", "Count predicate calls and exact fallbacks for benchmark diagnostics") orelse false;
    const instrument_mesh_stats = b.option(bool, "instrument-mesh-stats", "Count mesh walk, cavity, legalization, and corridor metrics for benchmark diagnostics") orelse false;
    const circumcircle_filter = b.option(bool, "circumcircle-filter", "Enable cached circumcircle outside filter for insertion cavity expansion") orelse false;
    const spatial_hints = b.option(bool, "spatial-hints", "Enable coarse spatial triangle start hints for insertion walks") orelse false;
    const polygon_output_mode = b.option(bool, "polygon-output-mode", "Cull exterior/super triangles after boundary recovery in polygon-output benchmark prototypes") orelse false;
    const predicate_policy: PredicatePolicy = if (std.mem.eql(u8, predicate_policy_name, "adaptive"))
        .adaptive
    else if (std.mem.eql(u8, predicate_policy_name, "strict"))
        .strict
    else if (std.mem.eql(u8, predicate_policy_name, "fast"))
        .fast
    else
        @panic("invalid -Dpredicate-policy; expected adaptive, strict, or fast");
    const build_options = b.addOptions();
    build_options.addOption(bool, "strict_predicates", strict_predicates);
    build_options.addOption(PredicatePolicy, "predicate_policy", predicate_policy);
    build_options.addOption(bool, "instrument_predicates", instrument_predicates);
    build_options.addOption(bool, "instrument_mesh_stats", instrument_mesh_stats);
    build_options.addOption(bool, "circumcircle_filter", circumcircle_filter);
    build_options.addOption(bool, "spatial_hints", spatial_hints);
    build_options.addOption(bool, "polygon_output_mode", polygon_output_mode);

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("p2t", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });
    mod.addOptions("build_options", build_options);

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe_module = b.createModule(.{
        // b.createModule defines a new module just like b.addModule but,
        // unlike b.addModule, it does not expose the module to consumers of
        // this package, which is why in this case we don't have to give it a name.
        .root_source_file = b.path("src/main.zig"),
        // Target and optimization levels must be explicitly wired in when
        // defining an executable or library (in the root module), and you
        // can also hardcode a specific target for an executable or library
        // definition if desireable (e.g. firmware for embedded devices).
        .target = target,
        .optimize = optimize,
        // List of modules available for import in source files part of the
        // root module.
        .imports = &.{
            // Here "p2t" is the name you will use in your source code to
            // import this module (e.g. `@import("p2t")`). The name is
            // repeated because you are allowed to rename your imports, which
            // can be extremely useful in case of collisions (which can happen
            // importing modules from different packages).
            .{ .name = "p2t", .module = mod },
        },
    });
    exe_module.addOptions("build_options", build_options);

    const exe = b.addExecutable(.{
        .name = "p2t",
        .root_module = exe_module,
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const bench_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "p2t", .module = mod },
        },
    });
    bench_module.addOptions("build_options", build_options);
    const bench_exe = b.addExecutable(.{
        .name = "p2t-bench",
        .root_module = bench_module,
    });
    const bench_cmd = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run cleave benchmarks in ReleaseFast");
    bench_step.dependOn(&bench_cmd.step);

    const batch_bench_module = b.createModule(.{
        .root_source_file = b.path("src/batch_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "p2t", .module = mod },
        },
    });
    batch_bench_module.addOptions("build_options", build_options);
    const batch_bench_exe = b.addExecutable(.{
        .name = "p2t-batch-bench",
        .root_module = batch_bench_module,
    });
    const batch_bench_cmd = b.addRunArtifact(batch_bench_exe);
    const batch_bench_step = b.step("bench-batch", "Run Cleave independent-job throughput benchmarks in ReleaseFast");
    batch_bench_step.dependOn(&batch_bench_cmd.step);

    const single_bench_module = b.createModule(.{
        .root_source_file = b.path("src/single_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "p2t", .module = mod },
        },
    });
    single_bench_module.addOptions("build_options", build_options);
    const single_bench_exe = b.addExecutable(.{
        .name = "p2t-single-bench",
        .root_module = single_bench_module,
    });
    const single_bench_cmd = b.addRunArtifact(single_bench_exe);
    const single_bench_step = b.step("bench-single", "Run Cleave larger single-mesh benchmarks in ReleaseFast");
    single_bench_step.dependOn(&single_bench_cmd.step);

    const segment_bench_module = b.createModule(.{
        .root_source_file = b.path("src/segment_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "p2t", .module = mod },
        },
    });
    segment_bench_module.addOptions("build_options", build_options);
    const segment_bench_exe = b.addExecutable(.{
        .name = "p2t-segment-bench",
        .root_module = segment_bench_module,
    });
    const segment_bench_cmd = b.addRunArtifact(segment_bench_exe);
    const segment_bench_step = b.step("bench-segment", "Run Cleave long-constraint corridor benchmarks in ReleaseFast");
    segment_bench_step.dependOn(&segment_bench_cmd.step);

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
