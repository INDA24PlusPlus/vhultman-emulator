const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "emu2",
        .root_source_file = b.path("src/main2.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    b.installArtifact(exe);

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
