const std = @import("std");

const source_dir = "src";
const main_file = "main.zig";
const exe_name = "SHCResourceConverterCLI-Zig";
const test_exe_suffix = "test";

const single_threaded = true; // since it should be a simple cli

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const only_emit_test = b.option(
        bool,
        "only-emit-test",
        "Only emit test exes on test builds. Do not execute them.",
    ) orelse false;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path(b.pathJoin(&.{ source_dir, main_file })),
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
    });
    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const exe_unit_tests = b.addTest(.{
        .name = b.fmt("{s}-{s}", .{ exe_name, test_exe_suffix }),
        .root_module = exe_mod,
    });
    const install_exe_unit_tests = b.addInstallArtifact(exe_unit_tests, .{});
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&install_exe_unit_tests.step);

    if (!only_emit_test) {
        test_step.dependOn(&run_exe_unit_tests.step);
    }
}
