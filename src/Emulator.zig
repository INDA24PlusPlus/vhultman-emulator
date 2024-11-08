const std = @import("std");
const Allocator = std.mem.Allocator;
const Emulator = @This();

const log = std.log.scoped(.emu);

const enable_exceptions = @import("config").enable_exceptions;
const enable_verbose_instructions = @import("config").enable_verbose_instructions;

const Syscall = enum(u64) {
    write = 1,
    alloc = 2,
    exit = 93,
    _,
};

// 2 MB
const stack_size = 2 * (1 << 20) + 16;

const InstType = enum(u7) {
    r_type = 0b0110011,
    i_type = 0b0010011,
    s_type = 0b0100011,
    j_type = 0b1101111,
    b_type = 0b1100011,
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

const BType = packed struct(u32) {
    opcode: u7,
    offset0: u1,
    offset1: u4,
    funct3: u3,
    rs1: u5,
    rs2: u5,
    offset2: u6,
    sign: u1,
};

const UType = packed struct(u32) {
    opcode: u7,
    rd: u5,
    imm: u20,
};

const JType = packed struct(u32) {
    opcode: u7,
    rd: u5,
    imm: u20,
};

verbose_inst: if (enable_verbose_instructions) std.ArrayListUnmanaged([:0]const u8) else void,

program_memory: []u8,
registers: [32]u64,
pc: u64,
code: []u8,
gpa: Allocator,

pub fn init(gpa: Allocator, code: []u8) !Emulator {
    const stack = try gpa.alignedAlloc(u8, 128, stack_size + code.len);
    var registers = [_]u64{0} ** 32;
    registers[2] = stack.len - 16;
    @memcpy(stack[0..code.len], code);

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
        .verbose_inst = if (enable_verbose_instructions) std.ArrayListUnmanaged([:0]const u8){} else {},
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
    log.debug("Instruction is {b}", .{instruction});
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
            log.debug("Inst is {}", .{inst});
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
                },
                // sh
                0b001 => {
                    const imm0: u12 = @as(u12, inst.imm0);
                    const imm1: u12 = @as(u12, inst.imm1) << 5;
                    const offset = signExtend(i64, u12, imm0 | imm1);
                    const base: i64 = @bitCast(self.registers[inst.rs1]);
                    const address: u64 = @bitCast(base + offset);
                    const ptr: *u16 = @ptrCast(@alignCast(&self.program_memory[address]));
                    ptr.* = @truncate(self.registers[inst.rs2]);
                    self.logInst("sh x{d}, {d}(x{d})", .{ inst.rs2, offset, inst.rs1 });
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
                },
                else => std.debug.panic("Invalid funct3: {d}\n", .{inst.funct3}),
            }
            self.pc += 4;
        },
        .r_type => {
            const inst: RType = @bitCast(instruction);
            switch (inst.funct7) {
                0b0000000 => switch (inst.funct3) {
                    // add
                    0b000 => {
                        const rs1: i64 = @bitCast(self.registers[inst.rs1]);
                        const rs2: i64 = @bitCast(self.registers[inst.rs2]);
                        // TODO: Ignore overflow.
                        self.registers[inst.rd] = @bitCast(rs1 + rs2);
                        self.logInst("add x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                    },
                    // sll
                    0b001 => {
                        const rs1: u64 = self.registers[inst.rs1];
                        const rs2: u6 = @truncate(self.registers[inst.rs2]);
                        self.registers[inst.rd] = rs1 << rs2;
                        self.logInst("sll x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                    },
                    // srl
                    0b101 => {
                        const rs1: u64 = self.registers[inst.rs1];
                        const rs2: u6 = @truncate(self.registers[inst.rs2]);
                        self.registers[inst.rd] = rs1 >> rs2;
                        self.logInst("srl x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                    },
                    // slt
                    0b010 => {
                        const rs1: i64 = @bitCast(self.registers[inst.rs1]);
                        const rs2: i64 = @bitCast(self.registers[inst.rs2]);
                        self.registers[inst.rd] = @intFromBool(rs1 < rs2);
                        self.logInst("slt x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                    },
                    // sltu
                    0b011 => {
                        const rs1 = self.registers[inst.rs1];
                        const rs2 = self.registers[inst.rs2];
                        self.registers[inst.rd] = @intFromBool(rs1 < rs2);
                        self.logInst("sltu x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                    },
                    // or
                    0b110 => {
                        const rs1 = self.registers[inst.rs1];
                        const rs2 = self.registers[inst.rs2];
                        self.registers[inst.rd] = rs1 | rs2;
                        self.logInst("or x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                    },
                    // and
                    0b111 => {
                        const rs1 = self.registers[inst.rs1];
                        const rs2 = self.registers[inst.rs2];
                        self.registers[inst.rd] = rs1 & rs2;
                        self.logInst("and x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                    },
                    // xor
                    0b100 => {
                        const rs1 = self.registers[inst.rs1];
                        const rs2 = self.registers[inst.rs2];
                        self.registers[inst.rd] = rs1 ^ rs2;
                        self.logInst("xor x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                    },
                },
                0b0100000 => switch (inst.funct3) {
                    // sub
                    0b000 => {
                        const rs1: i64 = @bitCast(self.registers[inst.rs1]);
                        const rs2: i64 = @bitCast(self.registers[inst.rs2]);
                        // TODO: Ignore overflow.
                        self.registers[inst.rd] = @bitCast(rs1 - rs2);
                        self.logInst("sub x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                    },
                    // sra
                    0b101 => {
                        const rs1: i64 = @bitCast(self.registers[inst.rs1]);
                        const rs2: u6 = @truncate(self.registers[inst.rs2]);
                        self.registers[inst.rd] = @bitCast(rs1 >> rs2);
                        self.logInst("sra x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                    },
                    else => std.debug.panic("Invalid funct3: {b}", .{inst.funct3}),
                },
                else => std.debug.panic("Invalid funct7: {b}", .{inst.funct7}),
            }
            self.pc += 4;
        },
        .rv64_type => {
            const inst: RType = @bitCast(instruction);
            switch (inst.funct7) {
                0b0000000 => switch (inst.funct3) {
                    // addw
                    0b000 => {
                        const rs1: i32 = @bitCast(@as(u32, @truncate(self.registers[inst.rs1])));
                        const rs2: i32 = @bitCast(@as(u32, @truncate(self.registers[inst.rs2])));

                        // TODO: Ignore overflow.
                        const result = signExtend(u64, i32, rs1 + rs2);
                        self.registers[inst.rd] = result;
                        self.logInst("addw x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                    },
                    // sllw
                    0b001 => {
                        const rs1: u32 = @truncate(self.registers[inst.rs1]);
                        const rs2: u5 = @truncate(self.registers[inst.rs2]);
                        const result = signExtend(u64, u32, rs1 << rs2);
                        self.registers[inst.rd] = result;
                        self.logInst("sllw x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                    },
                    // srlw
                    0b101 => {
                        const rs1: u32 = @truncate(self.registers[inst.rs1]);
                        const rs2: u5 = @truncate(self.registers[inst.rs2]);
                        const result = signExtend(u64, u32, rs1 >> rs2);
                        self.registers[inst.rd] = result;
                        self.logInst("srlw x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                    },
                    else => std.debug.panic("Invalid funct3", .{}),
                },
                0b0100000 => if (inst.funct3 == 0b101) {
                    // sraw
                    const rs1: i32 = @bitCast(@as(u32, @truncate(self.registers[inst.rs1])));
                    const rs2: u5 = @truncate(self.registers[inst.rs2]);
                    const result = signExtend(u64, i32, rs1 >> rs2);
                    self.registers[inst.rd] = result;
                    self.logInst("sraw x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                } else {
                    // This else clause should be fine since I think these are the only options.
                    // subw
                    const rs1: i32 = @bitCast(@as(u32, @truncate(self.registers[inst.rs1])));
                    const rs2: i32 = @bitCast(@as(u32, @truncate(self.registers[inst.rs2])));

                    // TODO: Ignore overflow.
                    const result = signExtend(u64, i32, rs1 - rs2);
                    self.registers[inst.rd] = result;
                    self.logInst("subw x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                },

                else => std.debug.panic("Invalid funct7", .{}),
            }
            self.pc += 4;
        },
        .rv64_i_type => {
            const inst: IType = @bitCast(instruction);
            switch (inst.funct3) {
                // addiw
                0b000 => {
                    const imm = signExtend(i32, u12, inst.imm);
                    const rs1: i64 = @bitCast(self.registers[inst.rs1]);
                    const result: u32 = @bitCast(@as(i32, @truncate(rs1 + imm)));
                    self.registers[inst.rd] = @bitCast(signExtend(i64, u32, result));
                    self.logInst("addiw x{d}, x{d}, {d}", .{ inst.rd, inst.rs1, imm });
                },
                // slliw
                0b001 => {
                    const shift: u5 = @truncate((instruction >> 20) & 0b11111);
                    const value: u32 = @truncate(self.registers[inst.rs1]);
                    self.registers[inst.rd] = signExtend(u64, u32, value << shift);
                    self.logInst("slliw x{d}, x{d}, {d}", .{ inst.rd, inst.rs1, shift });
                },
                0b101 => {
                    if (instruction & (1 << 30) != 0) {
                        // sraiw
                        log.warn("instruction sraiw untested", .{});
                        const shift: u5 = @truncate((instruction >> 20) & 0b11111);
                        const value: i32 = @bitCast(@as(u32, @truncate(self.registers[inst.rs1])));
                        self.registers[inst.rd] = signExtend(u64, i32, value >> shift);
                        self.logInst("sraiw x{d}, x{d}, {d}", .{ inst.rd, inst.rs1, shift });
                    } else {
                        // srliw
                        log.warn("instruction srliw untested", .{});
                        const shift: u5 = @truncate((instruction >> 20) & 0b11111);
                        const value: u32 = @truncate(self.registers[inst.rs1]);
                        self.registers[inst.rd] = signExtend(u64, u32, value >> shift);
                        self.logInst("srliw x{d}, x{d}, {d}", .{ inst.rd, inst.rs1, shift });
                    }
                },
                else => std.debug.panic("Invalid funct3", .{}),
            }

            self.pc += 4;
        },
        .load => {
            const inst: IType = @bitCast(instruction);
            log.debug("Inst is {}", .{inst});
            switch (inst.funct3) {
                // lb
                0b000 => {
                    const offset: i64 = signExtend(i64, u12, inst.imm);
                    const base: i64 = @bitCast(self.registers[inst.rs1]);
                    const address: u64 = @bitCast(base + offset);
                    self.registers[inst.rd] = signExtend(u64, u8, self.program_memory[address]);
                    self.logInst("lb x{d}, {d}(x{d})", .{ inst.rd, offset, inst.rs1 });
                },
                // lbu
                0b100 => {
                    const offset: i64 = signExtend(i64, u12, inst.imm);
                    const base: i64 = @bitCast(self.registers[inst.rs1]);
                    const address: u64 = @bitCast(base + offset);
                    self.registers[inst.rd] = self.program_memory[address];
                    self.logInst("lbu x{d}, {d}(x{d})", .{ inst.rd, offset, inst.rs1 });
                },
                // lh
                0b001 => {
                    const offset: i64 = signExtend(i64, u12, inst.imm);
                    const base: i64 = @bitCast(self.registers[inst.rs1]);
                    const address: u64 = @bitCast(base + offset);

                    if (enable_exceptions) {
                        if (address & 0b1 != 0) {
                            log.err("Instruction LH can only load from 2-byte aligned addresses", .{});
                            return error.DecodeError;
                        }
                    }

                    const ptr: *u16 = @ptrCast(@alignCast(&self.program_memory[address]));
                    self.registers[inst.rd] = signExtend(u64, u16, ptr.*);
                    self.logInst("lh x{d}, {d}(x{d})", .{ inst.rd, offset, inst.rs1 });
                },
                // lhu
                0b101 => {
                    const offset: i64 = signExtend(i64, u12, inst.imm);
                    const base: i64 = @bitCast(self.registers[inst.rs1]);
                    const address: u64 = @bitCast(base + offset);

                    if (enable_exceptions) {
                        if (address & 0b1 != 0) {
                            log.err("Instruction LHU can only load from 2-byte aligned addresses", .{});
                            return error.DecodeError;
                        }
                    }

                    const ptr: *u16 = @ptrCast(@alignCast(&self.program_memory[address]));
                    self.registers[inst.rd] = ptr.*;
                    self.logInst("lhu x{d}, {d}(x{d})", .{ inst.rd, offset, inst.rs1 });
                },
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
                },
                else => std.debug.panic("Invalid funct3: {d}\n", .{inst.funct3}),
            }
            self.pc += 4;
        },
        .j_type => {
            const inst: JType = @bitCast(instruction);
            const imm: u12 = @truncate(instruction >> 20);
            const offset = signExtend(u64, u12, imm);

            if (enable_exceptions) {
                if (offset & 0b011 != 0) {
                    log.err("Instruction JAL can only jump to 4-byte aligned addresses", .{});
                    return error.DecodeError;
                }
            }
            self.registers[inst.rd] = self.pc + 4;
            self.pc += offset;
            self.logInst("jal x{d}, {d}", .{ inst.rd, offset });
        },
        .jalr => {
            const inst: IType = @bitCast(instruction);
            const offset = signExtend(i64, u12, inst.imm);
            const base: i64 = @bitCast(self.registers[inst.rs1]);
            const address: u64 = @bitCast(base + offset);
            self.registers[inst.rd] = self.pc + 4;
            if (enable_exceptions) {
                if (address & 0b011 != 0) {
                    log.err("Instruction JALR can only jump to 4-byte aligned addresses", .{});
                    return error.DecodeError;
                }
            }
            self.pc = address & ~@as(u64, 1);
            self.logInst("jalr x{d}, x{d}, {d}", .{ inst.rd, inst.rs1, offset });
        },
        .b_type => {
            const inst: BType = @bitCast(instruction);

            // zig fmt: off
            const offset: i12 = 
            @bitCast((@as(u12, inst.offset1))
            | (@as(u12, inst.offset2) << 4)
            | (@as(u12, inst.offset0) << 10)
            | (@as(u12, inst.sign) << 11));

            log.debug("Sign bit is {b}", .{inst.sign});
            log.debug("bit 11 is {b}", .{inst.offset0});
            log.debug("bits 10-5 is {b}", .{inst.offset2});
            log.debug("bits 4-1 is {b}", .{inst.offset1});
            log.debug("Combined is {b}", .{@as(u12, @bitCast(offset))});
            log.debug("offset is {d}", .{offset});

            // zig fmt: on
            switch (inst.funct3) {
                // beq
                0b000 => {
                    const should_branch = self.registers[inst.rs1] == self.registers[inst.rs2];
                    var effective = signExtend(i64, i12, offset) * @intFromBool(should_branch) + 2 * @as(i64, @intFromBool(!should_branch));
                    effective <<= 1;

                    if (enable_exceptions) {
                        if (effective & 0b011 != 0) {
                            log.err("Instruction BEQ can only jump to 4-byte aligned addresses", .{});
                            return error.DecodeError;
                        }
                    }
                    // TODO: Overflo.. if this overflows we are fucked either way.
                    self.pc = @bitCast(@as(i64, @bitCast(self.pc)) + effective);
                    self.logInst("beq x{d}, x{d}, {d}", .{ inst.rs1, inst.rs2, offset });
                },
                // bne
                0b001 => {
                    const should_branch = self.registers[inst.rs1] != self.registers[inst.rs2];
                    var effective = signExtend(i64, i12, offset) * @intFromBool(should_branch) + 2 * @as(i64, @intFromBool(!should_branch));
                    effective <<= 1;

                    if (enable_exceptions) {
                        if (effective & 0b011 != 0) {
                            log.err("Instruction BNE can only jump to 4-byte aligned addresses", .{});
                            return error.DecodeError;
                        }
                    }
                    // TODO: Overflo.. if this overflows we are fucked either way.
                    self.pc = @bitCast(@as(i64, @bitCast(self.pc)) + effective);
                    self.logInst("bne x{d}, x{d}, {d}", .{ inst.rs1, inst.rs2, offset });
                },
                // blt
                0b100 => {
                    const rs1: i64 = @bitCast(self.registers[inst.rs1]);
                    const rs2: i64 = @bitCast(self.registers[inst.rs2]);
                    const should_branch = rs1 < rs2;
                    const effective = signExtend(i64, i12, offset) * @intFromBool(should_branch) + 4 * @as(i64, @intFromBool(!should_branch));
                    if (enable_exceptions) {
                        if (effective & 0b011 != 0) {
                            log.err("Instruction BLT can only jump to 4-byte aligned addresses", .{});
                            return error.DecodeError;
                        }
                    }
                    self.pc = @bitCast(@as(i64, @bitCast(self.pc)) + effective);
                    self.logInst("blt x{d}, x{d}, {d}", .{ inst.rs1, inst.rs2, offset });
                },
                // bge
                0b101 => {
                    const rs1: i64 = @bitCast(self.registers[inst.rs1]);
                    const rs2: i64 = @bitCast(self.registers[inst.rs2]);
                    const should_branch = rs1 >= rs2;
                    const effective = signExtend(i64, i12, offset) * @intFromBool(should_branch) + 4 * @as(i64, @intFromBool(!should_branch));

                    if (enable_exceptions) {
                        if (effective & 0b011 != 0) {
                            log.err("Instruction BGE can only jump to 4-byte aligned addresses", .{});
                            return error.DecodeError;
                        }
                    }
                    self.pc = @bitCast(@as(i64, @bitCast(self.pc)) + effective);
                    self.logInst("bge x{d}, x{d}, {d}", .{ inst.rs1, inst.rs2, offset });
                },
                // bltu
                0b110 => {
                    const rs1 = self.registers[inst.rs1];
                    const rs2 = self.registers[inst.rs2];
                    const should_branch = rs1 < rs2;
                    const effective = signExtend(i64, i12, offset) * @intFromBool(should_branch) + 4 * @as(i64, @intFromBool(!should_branch));

                    if (enable_exceptions) {
                        if (effective & 0b011 != 0) {
                            log.err("Instruction BLT can only jump to 4-byte aligned addresses", .{});
                            return error.DecodeError;
                        }
                    }
                    self.pc = @bitCast(@as(i64, @bitCast(self.pc)) + effective);
                    self.logInst("bltu x{d}, x{d}, {d}", .{ inst.rs1, inst.rs2, offset });
                },
                // bgeu
                0b111 => {
                    const rs1 = self.registers[inst.rs1];
                    const rs2 = self.registers[inst.rs2];
                    const should_branch = rs1 >= rs2;
                    const effective = signExtend(i64, i12, offset) * @intFromBool(should_branch) + 4 * @as(i64, @intFromBool(!should_branch));

                    if (enable_exceptions) {
                        if (effective & 0b011 != 0) {
                            log.err("Instruction BGE can only jump to 4-byte aligned addresses", .{});
                            return error.DecodeError;
                        }
                    }
                    self.pc = @bitCast(@as(i64, @bitCast(self.pc)) + effective);
                    self.logInst("bgeu x{d}, x{d}, {d}", .{ inst.rs1, inst.rs2, offset });
                },
                else => std.debug.panic("unknown funct3", .{}),
            }
        },
        .sys_type => {
            const is_break = instruction >> 20 != 0;
            if (!is_break) {
                self.logInst("ecall", .{});
                const kind: Syscall = @enumFromInt(self.registers[17]);
                switch (kind) {
                    .write => {
                        const ptr = self.registers[10];
                        const len = self.registers[11];
                        const slice = self.program_memory[ptr .. ptr + len];
                        log.debug("ptr is {d}", .{ptr});
                        log.debug("len is {d}", .{len});
                        log.debug("memory is {d}", .{slice});
                        _ = try std.io.getStdOut().write(slice);
                    },
                    .alloc => {
                        self.registers[10] = 10000;
                    },
                    .exit => {
                        std.io.getStdOut().writer().print("Program returned with exit code: {d} ({d})\n", .{
                            self.registers[10],
                            @as(i64, @bitCast(self.registers[10])),
                        }) catch unreachable;

                        return true;
                    },
                    _ => std.debug.panic("Unknown syscall", .{}),
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
            log.warn("before AUIPC pc is {d}", .{self.pc});
            const inst: UType = @bitCast(instruction);
            const imm: u32 = signExtend(u32, u20, inst.imm) << 12;
            const if_zero = @as(u64, @intFromBool(imm == 0)) * 4;
            self.pc += imm;
            self.registers[inst.rd] = self.pc;
            self.pc += if_zero;
            log.warn("after AUIPC pc is {d}", .{self.pc});
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
