const std = @import("std");

pub fn build(b: *std.Build) void {
    var feature_sub = std.Target.Cpu.Feature.Set.empty;
    feature_sub.addFeature(@intFromEnum(std.Target.riscv.Feature.d));
    feature_sub.addFeature(@intFromEnum(std.Target.riscv.Feature.a));
    feature_sub.addFeature(@intFromEnum(std.Target.riscv.Feature.c));
    feature_sub.addFeature(@intFromEnum(std.Target.riscv.Feature.m));
    feature_sub.addFeature(@intFromEnum(std.Target.riscv.Feature.f));
    feature_sub.addFeature(@intFromEnum(std.Target.riscv.Feature.zicsr));
    feature_sub.addFeature(@intFromEnum(std.Target.riscv.Feature.zmmul));

    var feature_add = std.Target.Cpu.Feature.Set.empty;
    feature_add.addFeature(@intFromEnum(std.Target.riscv.Feature.i));

    const query = std.Target.Query{
        .os_tag = .freestanding,
        .cpu_arch = .riscv64,
        .cpu_features_sub = feature_sub,
        .cpu_features_add = feature_add,
    };

    const exe = b.addExecutable(.{
        .name = "zig_code",
        .root_source_file = b.path("src/main.zig"),
        .target = b.resolveTargetQuery(query),
        .optimize = .ReleaseSmall,
        .pic = false,
        .strip = true,
        .single_threaded = true,
    });
    exe.pie = false;

    exe.setLinkerScript(b.path("linker.ld"));

    const obj_dump = b.addSystemCommand(&.{"llvm-objcopy"});
    obj_dump.step.dependOn(&exe.step);
    obj_dump.addArgs(&.{ "-O", "binary" });

    const file = std.Build.LazyPath.join(exe.getEmittedBinDirectory(), b.allocator, exe.out_filename) catch @panic("OOM");
    obj_dump.addFileArg(file);
    const out_name = b.fmt("{s}.bin", .{exe.out_filename});
    const output = obj_dump.addOutputFileArg(out_name);

    var asm_out = std.Build.GeneratedFile{
        .step = &exe.step,
    };

    exe.generated_asm = &asm_out;

    b.getInstallStep().dependOn(&b.addInstallFileWithDir(output, .bin, out_name).step);
    b.installArtifact(exe);
}
