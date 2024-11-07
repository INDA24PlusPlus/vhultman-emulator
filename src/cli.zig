const std = @import("std");
const Emulator = @import("Emulator.zig");

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len != 3) {
        std.process.fatal("Usage: ./rv64i_emu_gui <bin_file> <start of code (hex)>", .{});
    }

    const file_name = args[1];

    const binary_file = std.fs.cwd().readFileAlloc(gpa, file_name, 1_000_000) catch |err| {
        std.process.fatal("Failed to open file {s} with error: {s}", .{ file_name, @errorName(err) });
    };
    defer gpa.free(binary_file);

    const code_start = std.fmt.parseUnsigned(u32, args[2], 16) catch |err| {
        std.process.fatal("Failed to parse code start with error: {s}", .{@errorName(err)});
    };

    var emu = try Emulator.init(gpa, binary_file[code_start..]);
    defer emu.deinit();

    while (!try emu.next()) {}

    _ = try std.io.getStdOut().write("Program finished\n");
}
