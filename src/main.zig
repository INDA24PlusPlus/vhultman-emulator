const std = @import("std");
const assert = std.debug.assert;

const InstType = enum(u8) {
    i_type = 0b0010011,
};

const IType = packed struct(u32) {
    opcode: u7,
    rd: u5,
    funct3: u3,
    rs1: u5,
    imm: u12,
};

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa_state.deinit() == .ok);
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    const file_name = args[1];
    const code_start = try std.fmt.parseUnsigned(u32, args[2], 16);

    const binary_file = try std.fs.cwd().readFileAlloc(gpa, file_name, 1_000_000);
    defer gpa.free(binary_file);

    const program_stack = try gpa.alignedAlloc(u8, 128, 2 * (1 << 20));
    defer gpa.free(program_stack);

    var pc: u64 = code_start;
    var registers = [_]u64{0} ** 32;

    // stack pointer
    registers[0x2] = @intFromPtr(program_stack.ptr);

    var buf: [524]u8 = undefined;
    const stdin = std.io.getStdIn().reader();

    while (true) : (pc += 4) {
        _ = try stdin.readUntilDelimiter(&buf, '\n');

        const instruction = std.mem.readInt(u32, binary_file[code_start..][0..4], .little);
        const opcode: InstType = @enumFromInt(instruction & 0x7F);

        switch (opcode) {
            .i_type => {
                const inst: IType = @bitCast(instruction);
                switch (inst.funct3) {
                    0x0 => {
                        // addi
                    },
                    0x4 => {},
                }
                std.debug.print("{}\n", .{inst});
                std.debug.print("inst {b}\n", .{instruction});
            },
        }
    }
}
