const std = @import("std");

const Config = struct {
    version: []const u8,
    test_data_present: bool,
};

const names = .{
    .source_dir = "src",
    .main_file = "main.zig",
    .exe_name = "SHCResourceConverterCLI-Zig",
    .test_exe_suffix = "test",
};

// currently duplicate from zig zon, see: https://github.com/vezel-dev/graf/issues/15
const version = "1.0.0";

const single_threaded = true; // since it should be a simple cli

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const only_emit_test = b.option(
        bool,
        "only-emit-test",
        "Only emit test exes on test builds. Do not execute them.",
    ) orelse false;
    const test_data_present = b.option(
        bool,
        "test-data-present",
        "Indicates that the test data files are present and " ++
            "the tests using them should be executed.",
    ) orelse false;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path(b.pathJoin(&.{ names.source_dir, names.main_file })),
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
    });
    // note: only ReleaseSmall strips debug symbols by default, which will make it a lot smaller then the other targets

    addDependencies(b, exe_mod);
    addConfig(b, exe_mod, &.{
        .version = version,
        .test_data_present = test_data_present,
    });

    const exe = b.addExecutable(.{
        .name = names.exe_name,
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
        .name = b.fmt("{s}-{s}", .{ names.exe_name, names.test_exe_suffix }),
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

fn addDependencies(b: *std.Build, exe_mod: *std.Build.Module) void {
    // argument parser
    const clap = b.dependency("clap", .{});
    exe_mod.addImport("clap", clap.module("clap"));
}

fn addConfig(b: *std.Build, exe_mod: *std.Build.Module, config: *const Config) void {
    const options = b.addOptions();

    inline for (@typeInfo(std.meta.Child(@TypeOf(config))).@"struct".fields) |*field| {
        options.addOption(field.type, field.name, @field(config, field.name));
    }

    exe_mod.addOptions("config", options);
}
