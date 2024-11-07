const std = @import("std");

fn buildCli(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: *std.Build.Step.Options,
) void {
    const exe = b.addExecutable(.{
        .name = "rv64i_emu",
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    exe.root_module.addOptions("config", options);
    b.installArtifact(exe);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_log_instructions = b.option(bool, "log_instructions", "Decides if the emulator saves executed instructions") orelse (optimize == .Debug);
    const use_errors = b.option(bool, "errors", "Decides if the emulator returns decode errors") orelse (optimize == .Debug);

    const options = b.addOptions();
    options.addOption(bool, "enable_exceptions", use_errors);
    options.addOption(bool, "enable_verbose_instructions", use_log_instructions);

    const exe = b.addExecutable(.{
        .name = "rv64i_emu_gui",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe.root_module.addOptions("config", options);
    b.installArtifact(exe);

    buildCli(b, target, optimize, options);

    if (b.lazyDependency("glfw", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        exe.linkLibrary(dep.artifact("glfw"));
        @import("glfw").addPaths(&exe.root_module);
        exe.linkLibrary(dep.artifact("glfw"));
    }

    exe.addIncludePath(b.path("vendor"));
    exe.addIncludePath(b.path("vendor/glad/include"));

    exe.addCSourceFiles(.{
        .files = &.{ "vendor/glad/src/glad.c", "vendor/nuklear.c" },
        .flags = &.{ "-march=native", "-fno-sanitize=undefined" },
    });

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
