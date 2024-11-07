const std = @import("std");
const Allocator = std.mem.Allocator;
const Emulator = @This();

const log = std.log.scoped(.emu);

const enable_exceptions = true;
const enable_verbose_instructions = true;

// 2 MB
const stack_size = 2 * (1 << 20);

const InstType = enum(u7) {
    i_type = 0b0010011,
    s_type = 0b0100011,
    load = 0b0000011,

    jalr = 0b1100111,
    sys_type = 0b1110011,
    rv64_i_type = 0b0011011,
    rv64_type = 0b0111011,
    lui = 0b0110111,
    auipc = 0b0010111,
};

const IType = packed struct(u32) {
    opcode: u7,
    rd: u5,
    funct3: u3,
    rs1: u5,
    imm: u12,
};

const SType = packed struct(u32) {
    opcode: u7,
    imm0: u5,
    funct3: u3,
    rs1: u5,
    rs2: u5,
    imm1: u7,
};

const RType = packed struct(u32) {
    opcode: u7,
    rd: u5,
    funct3: u3,
    rs1: u5,
    rs2: u5,
    funct7: u7,
};

const UType = packed struct(u32) {
    opcode: u7,
    rd: u5,
    imm: u20,
};

verbose_inst: if (enable_verbose_instructions) std.ArrayListUnmanaged([:0]const u8) else void,

program_memory: []u8,
pm_ptr: [*]u8,
registers: [32]u64,
pc: u64,
code: []u8,
gpa: Allocator,

pub fn init(gpa: Allocator, code: []u8) !Emulator {
    const stack = try gpa.alignedAlloc(u8, 128, stack_size);
    var registers = [_]u64{0} ** 32;
    registers[2] = stack.len;

    var new_code = try gpa.alloc(u8, code.len + 2 * 4);
    // addi a7, x0, 93
    std.mem.writeInt(u32, new_code[0..4], 0b1011101_00000_000_10001_0010011, .little);
    // ecall
    std.mem.writeInt(u32, new_code[4..8], 0b1110011, .little);
    @memcpy(new_code[4 * 2 ..], code);

    return .{
        .gpa = gpa,
        .program_memory = stack,
        .registers = registers,
        .pc = 4 * 2,
        .code = new_code,
        .pm_ptr = stack.ptr,
        .verbose_inst = std.ArrayListUnmanaged([:0]const u8){},
    };
}

pub fn deinit(self: *Emulator) void {
    self.gpa.free(self.program_memory);
    self.gpa.free(self.code);
    if (enable_verbose_instructions) {
        for (self.verbose_inst.items) |str| {
            self.gpa.free(str);
        }
        self.verbose_inst.deinit(self.gpa);
    }
}

pub fn next(self: *Emulator) !bool {
    self.registers[0] = 0;
    const instruction = std.mem.readInt(u32, self.code[self.pc..][0..4], .little);
    std.debug.print("Instruction is {b}\n", .{instruction});
    const opcode: InstType = @enumFromInt(instruction & 0x7F);

    switch (opcode) {
        .i_type => {
            const inst: IType = @bitCast(instruction);
            switch (inst.funct3) {
                // addi
                0b000 => {
                    const imm = signExtend(i64, u12, inst.imm);
                    const rs1: i64 = @bitCast(self.registers[inst.rs1]);
                    // TODO: ignore overflow.
                    self.registers[inst.rd] = @bitCast(rs1 + imm);
                    self.logInst("addi x{d}, x{d}, {d}", .{ inst.rd, inst.rs1, imm });
                },
                // slli
                0b001 => {
                    const shift: u6 = @truncate((instruction >> 20) & 0b111111);
                    self.registers[inst.rd] = self.registers[inst.rs1] << shift;
                    self.logInst("slli x{d}, x{d}, {d}", .{ inst.rd, inst.rs1, shift });
                },
                // srli/srai
                0b101 => {
                    if (instruction & (1 << 30) != 0) {
                        const shift: u6 = @truncate((instruction >> 20) & 0b111111);
                        self.registers[inst.rd] = @bitCast(@as(i64, @bitCast(self.registers[inst.rs1])) >> shift);
                        self.logInst("srai x{d}, x{d}, {d}", .{ inst.rd, inst.rs1, shift });
                    } else {
                        const shift: u6 = @truncate((instruction >> 20) & 0b111111);
                        self.registers[inst.rd] = self.registers[inst.rs1] >> shift;
                        self.logInst("srli x{d}, x{d}, {d}", .{ inst.rd, inst.rs1, shift });
                    }
                },
                // stli
                0b010 => {
                    const imm = signExtend(i64, u12, inst.imm);
                    const rs1: i64 = @bitCast(self.registers[inst.rs1]);
                    self.registers[inst.rd] = @intFromBool(rs1 < imm);
                    self.logInst("stli x{d}, x{d}, {d}", .{ inst.rd, inst.rs1, imm });
                },
                // stliu
                0b011 => {
                    const imm = signExtend(u64, u12, inst.imm);
                    const rs1: u64 = @bitCast(self.registers[inst.rs1]);
                    self.registers[inst.rd] = @intFromBool(rs1 < imm);
                    self.logInst("stliu x{d}, x{d}, {d}", .{ inst.rd, inst.rs1, imm });
                },
                // xori
                0b100 => {
                    const imm = signExtend(u64, u12, inst.imm);
                    const rs1 = self.registers[inst.rs1];
                    self.registers[inst.rd] = @bitCast(rs1 ^ imm);
                    self.logInst("xori x{d}, x{d}, {d}", .{ inst.rd, inst.rs1, imm });
                },
                // ori
                0b110 => {
                    const imm = signExtend(u64, u12, inst.imm);
                    const rs1 = self.registers[inst.rs1];
                    self.registers[inst.rd] = @bitCast(rs1 | imm);
                    self.logInst("ori x{d}, x{d}, {d}", .{ inst.rd, inst.rs1, imm });
                },
                // andi
                0b111 => {
                    const imm = signExtend(u64, u12, inst.imm);
                    const rs1 = self.registers[inst.rs1];
                    self.registers[inst.rd] = @bitCast(rs1 & imm);
                    self.logInst("andi x{d}, x{d}, {d}", .{ inst.rd, inst.rs1, imm });
                },
            }
            self.pc += 4;
        },
        .s_type => {
            const inst: SType = @bitCast(instruction);
            std.debug.print("Inst is {}\n", .{inst});
            switch (inst.funct3) {
                // sb
                0b000 => {
                    const imm0: u12 = @as(u12, inst.imm0);
                    const imm1: u12 = @as(u12, inst.imm1) << 5;
                    const offset = signExtend(i64, u12, imm0 | imm1);
                    const base: i64 = @bitCast(self.registers[inst.rs1]);
                    const address: u64 = @bitCast(base + offset);

                    const ptr = &self.program_memory[address];
                    ptr.* = @truncate(self.registers[inst.rs2]);

                    self.logInst("sb x{d}, {d}(x{d})", .{ inst.rs2, offset, inst.rs1 });
                    log.debug("Wrote x{d} with value {d} to memory address 0x{x}", .{ inst.rs2, self.registers[inst.rs2], address });
                },
                // sw
                0b010 => {
                    const imm0: u12 = @as(u12, inst.imm0);
                    const imm1: u12 = @as(u12, inst.imm1) << 5;
                    const offset = signExtend(i64, u12, imm0 | imm1);
                    const base: i64 = @bitCast(self.registers[inst.rs1]);
                    const address: u64 = @bitCast(base + offset);

                    if (enable_exceptions) {
                        if (address & 0b11 != 0) {
                            log.err("Instruction SW can only store on 4-byte aligned addresses", .{});
                            return error.DecodeError;
                        }
                    }

                    const ptr: *u32 = @ptrCast(@alignCast(&self.program_memory[address]));
                    ptr.* = @truncate(self.registers[inst.rs2]);

                    self.logInst("sw x{d}, {d}(x{d})", .{ inst.rs2, offset, inst.rs1 });
                    log.debug("Wrote x{d} with value {d} to memory address 0x{x}", .{ inst.rs2, self.registers[inst.rs2], address });
                },
                // sd
                0b011 => {
                    const imm0: u12 = inst.imm0;
                    const imm1: u12 = inst.imm1;
                    const o = imm0 | (imm1 << 5);
                    const offset = signExtend(i64, u12, o);

                    const base: i64 = @bitCast(self.registers[inst.rs1]);
                    const address: u64 = @bitCast(base + offset);

                    if (enable_exceptions) {
                        if (address & 0b111 != 0) {
                            log.err("Instruction SD can only store on 8-byte aligned addresses", .{});
                            return error.DecodeError;
                        }
                    }

                    const ptr: *u64 = @ptrCast(@alignCast(&self.program_memory[address]));
                    ptr.* = self.registers[inst.rs2];
                    self.logInst("sd x{d}, {d}(x{d})", .{ inst.rs2, offset, inst.rs1 });

                    log.debug("Wrote x{d} with value {d} to memory address 0x{x}", .{ inst.rs2, self.registers[inst.rs2], address });
                    log.debug("Offset is {d}", .{offset});
                },
                else => std.debug.panic("Invalid funct3: {d}\n", .{inst.funct3}),
            }
            self.pc += 4;
        },
        .rv64_type => {
            const inst: RType = @bitCast(instruction);
            switch (inst.funct7) {
                // addw
                0b000 => {
                    const rs1: i32 = @bitCast(@as(u32, @truncate(self.registers[inst.rs1])));
                    const rs2: i32 = @bitCast(@as(u32, @truncate(self.registers[inst.rs2])));

                    // TODO: Ignore overflow.
                    const result = signExtend(u64, i32, rs1 + rs2);
                    self.registers[inst.rd] = result;
                    self.logInst("addw x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                },
                else => std.debug.panic("Invalid funct3", .{}),
            }
            self.pc += 4;
        },
        .rv64_i_type => {
            const funct3: IType = @bitCast(instruction);
            switch (funct3.funct3) {
                // addiw
                0b000 => {
                    const inst: IType = @bitCast(instruction);
                    const imm = signExtend(i32, u12, inst.imm);
                    const rs1: i64 = @bitCast(self.registers[inst.rs1]);
                    const result: u32 = @bitCast(@as(i32, @truncate(rs1 + imm)));
                    self.registers[inst.rd] = @bitCast(signExtend(i64, u32, result));
                    self.logInst("addiw x{d}, x{d}, {d}", .{ inst.rd, inst.rs1, imm });
                },
                else => std.debug.panic("Invalid funct3", .{}),
            }

            self.pc += 4;
        },
        .load => {
            const inst: IType = @bitCast(instruction);
            std.debug.print("Inst is {}\n", .{inst});
            switch (inst.funct3) {
                // lw
                0b010 => {
                    const offset: i64 = @as(i12, @bitCast(inst.imm));
                    const base: i64 = @bitCast(self.registers[inst.rs1]);
                    const address: u64 = @bitCast(base + offset);

                    if (enable_exceptions) {
                        if (address & 0b11 != 0) {
                            log.err("Instruction LW can only load from 4-byte aligned addresses", .{});
                            return error.DecodeError;
                        }
                    }

                    const ptr: *u32 = @ptrCast(@alignCast(&self.program_memory[address]));
                    self.registers[inst.rd] = signExtend(u64, u32, ptr.*);

                    self.logInst("lw x{d}, {d}(x{d})", .{ inst.rd, offset, inst.rs1 });
                    log.debug("Loaded value {d} from address 0x{x} to x{d}", .{ self.registers[inst.rd], address, inst.rd });
                    log.debug("Offset is {d}", .{offset});
                },
                0b011 => {
                    const offset = signExtend(i64, u12, inst.imm);
                    const base: i64 = @bitCast(self.registers[inst.rs1]);
                    const address: u64 = @bitCast(base + offset);

                    if (enable_exceptions) {
                        if (address & 0b111 != 0) {
                            log.err("Instruction LD can only load from 8-byte aligned addresses", .{});
                            return error.DecodeError;
                        }
                    }

                    const ptr: *u64 = @ptrCast(@alignCast(&self.program_memory[address]));
                    self.registers[inst.rd] = ptr.*;
                    self.logInst("ld x{d}, {d}(x{d})", .{ inst.rd, offset, inst.rs1 });

                    log.debug("Loaded value {d} from address 0x{x} to x{d}", .{ self.registers[inst.rd], address, inst.rd });
                    log.debug("Offset is {d}", .{offset});
                },
                // lwu
                0b110 => {
                    const offset = signExtend(i64, u12, inst.imm);
                    const base: i64 = @bitCast(self.registers[inst.rs1]);
                    const address: u64 = @bitCast(base + offset);

                    if (enable_exceptions) {
                        if (address & 0b11 != 0) {
                            log.err("Instruction LWU can only load from 4-byte aligned addresses", .{});
                            return error.DecodeError;
                        }
                    }

                    const ptr: *u32 = @ptrCast(@alignCast(&self.program_memory[address]));
                    self.registers[inst.rd] = ptr.*;
                    self.logInst("lwu x{d}, {d}(x{d})", .{ inst.rd, offset, inst.rs1 });

                    log.debug("Loaded value {d} from address 0x{x} to x{d}", .{ self.registers[inst.rd], address, inst.rd });
                    log.debug("Offset is {d}", .{offset});
                },
                else => std.debug.panic("Invalid funct3: {d}\n", .{inst.funct3}),
            }
            self.pc += 4;
        },
        .jalr => {
            const inst: IType = @bitCast(instruction);
            std.debug.print("Inst is {}\n", .{inst});
            self.registers[inst.rd] = self.pc + 4;
            const offset = signExtend(i64, u12, inst.imm);
            const base: i64 = @bitCast(self.registers[inst.rs1]);
            const address: u64 = @bitCast(base + offset);

            if (enable_exceptions) {
                if (address & 0b011 != 0) {
                    log.err("Instruction JALR can only jump to 4-byte aligned addresses", .{});
                    return error.DecodeError;
                }
            }
            self.pc = address & ~@as(u64, 1);
            self.logInst("jalr x{d}, x{d}, {d}", .{ inst.rd, inst.rs1, offset });

            log.debug("Program counter after jump is {d}", .{self.pc});
        },
        .sys_type => {
            const is_break = instruction >> 20 != 0;
            if (!is_break) {
                self.logInst("ecall", .{});
                if (self.registers[17] == 93) {
                    log.info("Program returned with exit code: {d}\n", .{self.registers[10]});
                    return true;
                } else {
                    std.debug.panic("Unknown syscall", .{});
                }
            } else {
                std.debug.panic("ebreak not implemented", .{});
            }
            self.pc += 4;
        },
        .lui => {
            const inst: UType = @bitCast(instruction);
            const imm = signExtend(u32, u20, inst.imm);
            self.registers[inst.rd] = imm << 12;
            self.logInst("lui x{d}, {d}", .{ inst.rd, @as(i32, @bitCast(imm)) });
            self.pc += 4;
        },
        .auipc => {
            log.warn("auipc instruction untested, double check that it is correct if you see this!", .{});
            const inst: UType = @bitCast(instruction);
            const imm: i32 = signExtend(i32, u20, inst.imm << 12);
            self.pc += imm << 12;
            self.registers[inst.rd] = self.pc;
            self.logInst("auipc x{d}, {d}", .{ inst.rd, @as(i32, @bitCast(imm)) });
        },
    }

    return false;
}

inline fn logInst(self: *Emulator, comptime fmt: []const u8, args: anytype) void {
    if (enable_verbose_instructions) {
        // This will only occur when running with some kind of debug support enabled so it is fine
        // to just panic on OOM.
        self.verbose_inst.append(self.gpa, std.fmt.allocPrintZ(self.gpa, fmt, args) catch @panic("OOM")) catch @panic("OOM");
    }
}

inline fn signExtend(comptime To: type, comptime From: type, val: From) To {
    const from_info = @typeInfo(From);
    const to_info = @typeInfo(To);
    if (to_info.int.bits < from_info.int.bits) {
        @compileError("\"ToType\" must have more bits then \"FromType\"");
    }

    const FromSigned = @Type(.{
        .int = .{
            .bits = from_info.int.bits,
            .signedness = .signed,
        },
    });

    const ToSigned = @Type(.{
        .int = .{
            .bits = to_info.int.bits,
            .signedness = .signed,
        },
    });

    const r: ToSigned = @as(FromSigned, @bitCast(val));
    return @bitCast(r);
}

test "arithmetic?" {
    var shifting: i8 = -16;
    try std.testing.expectEqual(0b1111_0000, @as(u8, @bitCast(shifting)));
    shifting >>= 1;
    try std.testing.expectEqual(0b1111_1000, @as(u8, @bitCast(shifting)));
}
