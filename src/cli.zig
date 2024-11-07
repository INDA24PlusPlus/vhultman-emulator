const std = @import("std");
const Emulator = @import("Emulator.zig");

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    const file_name = args[1];
    const code_start = try std.fmt.parseUnsigned(u32, args[2], 16);

    const binary_file = try std.fs.cwd().readFileAlloc(gpa, file_name, 1_000_000);
    defer gpa.free(binary_file);

    var emu = try Emulator.init(gpa, binary_file[code_start..]);
    defer emu.deinit();

    while (!try emu.next()) {}

    _ = try std.io.getStdOut().write("Program finished\n");
}
