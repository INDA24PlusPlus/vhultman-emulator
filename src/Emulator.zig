const std = @import("std");
const config = @import("config");
const Emulator = @This();
const Assembler = @import("Assembler.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.emulator);

pub const ECallNumber = enum {
    exit,
};

pub const IType = packed struct(u32) {
    opcode: OPCode,
    rd: u5,
    funct3: u3,
    rs1: u5,
    imm: u12,
};

pub const SType = packed struct(u32) {
    opcode: OPCode,
    imm0: u5,
    funct3: u3,
    rs1: u5,
    rs2: u5,
    imm1: u7,
};

pub const RType = packed struct(u32) {
    opcode: OPCode,
    rd: u5,
    funct3: u3,
    rs1: u5,
    rs2: u5,
    funct7: u7,
};

pub const BType = packed struct(u32) {
    opcode: OPCode,
    offset0: u1,
    offset1: u4,
    funct3: u3,
    rs1: u5,
    rs2: u5,
    offset2: u6,
    sign: u1,
};

pub const UType = packed struct(u32) {
    opcode: OPCode,
    rd: u5,
    imm: u20,
};

pub const JType = packed struct(u32) {
    opcode: OPCode,
    rd: u5,
    imm19_12: u8,
    imm11: u1,
    imm10_1: u10,
    imm20: u1,
};

pub const OPCode = enum(u7) {
    i = 0b0010011,
    r = 0b0110011,
    s = 0b0100011,
    l = 0b0000011,
    ri64 = 0b0011011,
    r64 = 0b0111011,
    ecall = 0b1110011,
};

pc: u64,
registers: [32]u64,
program_memory: []u8,

inst_log: if (config.log_inst) std.ArrayListUnmanaged([:0]const u8) else void,
gpa: if (config.log_inst) Allocator else void,

pub fn init(gpa: Allocator, program_memory: []align(std.mem.page_size) u8, code_start_pos: u32) Emulator {
    var registers: [32]u64 = @splat(0);
    registers[2] = program_memory.len & ~@as(u64, 0b1111);
    log.info("Stack is starting at {d}\n", .{registers[2]});

    return .{
        .pc = code_start_pos,
        .program_memory = program_memory,
        .registers = registers,
        .inst_log = if (config.log_inst) std.ArrayListUnmanaged([:0]const u8){} else {},
        .gpa = if (config.log_inst) gpa else {},
    };
}

pub fn deinit(self: *Emulator) void {
    if (config.log_inst) {
        for (self.inst_log.items) |inst| {
            self.gpa.free(inst);
        }

        self.inst_log.deinit(self.gpa);
    }

    self.* = undefined;
}

pub fn next(self: *Emulator) !bool {
    // zero register.
    // we do this here since it might be handy to be able to observe if something
    // was written to register zero.
    // If we did this at the end of the function observers would not be able to know.
    self.registers[0] = 0;

    const instruction = std.mem.readInt(u32, self.program_memory[self.pc..][0..4], .little);
    const op_code: OPCode = @enumFromInt(instruction & 0x7F);
    log.debug("Instruction is {b:0>32} and has opcode {s}", .{ instruction, @tagName(op_code) });

    switch (op_code) {
        .i => {
            const inst: IType = @bitCast(instruction);
            switch (inst.funct3) {
                // addi
                0b000 => {
                    const imm = signExtend(i64, u12, inst.imm);
                    const rs1: i64 = @bitCast(self.registers[inst.rs1]);
                    self.registers[inst.rd] = @bitCast(@addWithOverflow(rs1, imm)[0]);
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
                // slti
                0b010 => {
                    const imm = signExtend(i64, u12, inst.imm);
                    const rs1: i64 = @bitCast(self.registers[inst.rs1]);
                    self.registers[inst.rd] = @intFromBool(rs1 < imm);
                    self.logInst("stli x{d}, x{d}, {d}", .{ inst.rd, inst.rs1, imm });
                },
                // sltiu
                0b011 => {
                    const imm = signExtend(u64, u12, inst.imm);
                    const rs1: u64 = @bitCast(self.registers[inst.rs1]);
                    self.registers[inst.rd] = @intFromBool(rs1 < imm);
                    self.logInst("sltiu x{d}, x{d}, {d}", .{ inst.rd, inst.rs1, imm });
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
        .r => {
            const inst: RType = @bitCast(instruction);
            //const fucnt3_and_funct7: u4 = inst.funct3 | @as(u4, @truncate(inst.funct7 >> 2));

            // This versions seems better to better.
            const fucnt3_and_funct7: u4 = inst.funct3 | @as(u4, @intFromBool(inst.funct7 != 0)) << 3;
            switch (fucnt3_and_funct7) {
                // add
                0b0000 => {
                    const rs1: i64 = @bitCast(self.registers[inst.rs1]);
                    const rs2: i64 = @bitCast(self.registers[inst.rs2]);
                    self.registers[inst.rd] = @bitCast(@addWithOverflow(rs1, rs2)[0]);
                    self.logInst("add x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                },
                // sub
                0b1000 => {
                    const rs1: i64 = @bitCast(self.registers[inst.rs1]);
                    const rs2: i64 = @bitCast(self.registers[inst.rs2]);
                    self.registers[inst.rd] = @bitCast(@subWithOverflow(rs1, rs2)[0]);
                    self.logInst("sub x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                },
                // sll
                0b0001 => {
                    const rs1: u64 = self.registers[inst.rs1];
                    const rs2: u6 = @truncate(self.registers[inst.rs2]);
                    self.registers[inst.rd] = rs1 << rs2;
                    self.logInst("sll x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                },
                // srl
                0b0101 => {
                    const rs1: u64 = self.registers[inst.rs1];
                    const rs2: u6 = @truncate(self.registers[inst.rs2]);
                    self.registers[inst.rd] = rs1 >> rs2;
                    self.logInst("srl x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                },
                // sra
                0b1101 => {
                    const rs1: i64 = @bitCast(self.registers[inst.rs1]);
                    const rs2: u6 = @truncate(self.registers[inst.rs2]);
                    self.registers[inst.rd] = @bitCast(rs1 >> rs2);
                    self.logInst("sra x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                },
                // slt
                0b0010 => {
                    const rs1: i64 = @bitCast(self.registers[inst.rs1]);
                    const rs2: i64 = @bitCast(self.registers[inst.rs2]);
                    self.registers[inst.rd] = @intFromBool(rs1 < rs2);
                    self.logInst("slt x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                },
                // sltu
                0b0011 => {
                    const rs1 = self.registers[inst.rs1];
                    const rs2 = self.registers[inst.rs2];
                    self.registers[inst.rd] = @intFromBool(rs1 < rs2);
                    self.logInst("sltu x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                },
                // or
                0b0110 => {
                    const rs1 = self.registers[inst.rs1];
                    const rs2 = self.registers[inst.rs2];
                    self.registers[inst.rd] = rs1 | rs2;
                    self.logInst("or x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                },
                // and
                0b0111 => {
                    const rs1 = self.registers[inst.rs1];
                    const rs2 = self.registers[inst.rs2];
                    self.registers[inst.rd] = rs1 & rs2;
                    self.logInst("and x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                },
                // xor
                0b0100 => {
                    const rs1 = self.registers[inst.rs1];
                    const rs2 = self.registers[inst.rs2];
                    self.registers[inst.rd] = rs1 ^ rs2;
                    self.logInst("xor x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                },
                else => std.debug.panic("Invalid funct3 and funct7", .{}),
            }
            self.pc += 4;
        },
        // (RV64I) Register-32-bit-immediate.
        .ri64 => {
            const inst: IType = @bitCast(instruction);
            const switch_value = (@as(u4, inst.funct3) << 1) | inst.imm >> 10;
            switch (switch_value) {
                // addiw
                0b0000 => {
                    const imm = signExtend(i32, u12, inst.imm);
                    const rs1: i64 = @bitCast(self.registers[inst.rs1]);
                    const result: u32 = @bitCast(@as(i32, @truncate(@addWithOverflow(rs1, imm)[0])));
                    self.registers[inst.rd] = signExtend(u64, u32, result);
                    self.logInst("addiw x{d}, x{d}, {d}", .{ inst.rd, inst.rs1, imm });
                },
                // slliw
                0b0010 => {
                    const shift: u5 = @truncate((instruction >> 20) & 0b11111);
                    const value: u32 = @truncate(self.registers[inst.rs1]);
                    self.registers[inst.rd] = signExtend(u64, u32, value << shift);
                    self.logInst("slliw x{d}, x{d}, {d}", .{ inst.rd, inst.rs1, shift });
                },
                // sraiw
                0b1011 => {
                    const shift: u5 = @truncate((instruction >> 20) & 0b11111);
                    const value: i32 = @bitCast(@as(u32, @truncate(self.registers[inst.rs1])));
                    self.registers[inst.rd] = signExtend(u64, i32, value >> shift);
                    self.logInst("sraiw x{d}, x{d}, {d}", .{ inst.rd, inst.rs1, shift });
                },
                // srliw
                0b1010 => {
                    const shift: u5 = @truncate((instruction >> 20) & 0b11111);
                    const value: u32 = @truncate(self.registers[inst.rs1]);
                    self.registers[inst.rd] = signExtend(u64, u32, value >> shift);
                    self.logInst("srliw x{d}, x{d}, {d}", .{ inst.rd, inst.rs1, shift });
                },
                else => std.debug.panic("Invalid funct3", .{}),
            }
            self.pc += 4;
        },
        .r64 => {
            const inst: RType = @bitCast(instruction);
            const fucnt3_and_funct7: u4 = inst.funct3 | @as(u4, @intFromBool(inst.funct7 != 0)) << 3;

            switch (fucnt3_and_funct7) {
                // addw
                0b0000 => {
                    const rs1: i32 = @bitCast(@as(u32, @truncate(self.registers[inst.rs1])));
                    const rs2: i32 = @bitCast(@as(u32, @truncate(self.registers[inst.rs2])));
                    self.registers[inst.rd] = signExtend(u64, i32, @addWithOverflow(rs1, rs2)[0]);
                    self.logInst("addw x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                },
                // sllw
                0b0001 => {
                    const rs1: u32 = @truncate(self.registers[inst.rs1]);
                    const rs2: u5 = @truncate(self.registers[inst.rs2]);
                    self.registers[inst.rd] = signExtend(u64, u32, rs1 << rs2);
                    self.logInst("sllw x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                },
                // srlw
                0b0101 => {
                    const rs1: u32 = @truncate(self.registers[inst.rs1]);
                    const rs2: u5 = @truncate(self.registers[inst.rs2]);
                    self.registers[inst.rd] = signExtend(u64, u32, rs1 >> rs2);
                    self.logInst("srlw x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                },
                //sraw
                0b1101 => {
                    const rs1: i32 = @bitCast(@as(u32, @truncate(self.registers[inst.rs1])));
                    const rs2: u5 = @truncate(self.registers[inst.rs2]);
                    self.registers[inst.rd] = signExtend(u64, i32, rs1 >> rs2);
                    self.logInst("sraw x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                },
                // subw
                0b1000 => {
                    const rs1: i32 = @bitCast(@as(u32, @truncate(self.registers[inst.rs1])));
                    const rs2: i32 = @bitCast(@as(u32, @truncate(self.registers[inst.rs2])));
                    self.registers[inst.rd] = signExtend(u64, i32, @subWithOverflow(rs1, rs2)[0]);
                    self.logInst("subw x{d}, x{d}, x{d}", .{ inst.rd, inst.rs1, inst.rs2 });
                },
                else => std.debug.panic("Invalid funct3 and funct7", .{}),
            }
            self.pc += 4;
        },
        .s => {
            const inst: SType = @bitCast(instruction);
            const imm0: u12 = @as(u12, inst.imm0);
            const imm1: u12 = @as(u12, inst.imm1) << 5;
            const offset = signExtend(i64, u12, imm0 | imm1);
            const base: i64 = @bitCast(self.registers[inst.rs1]);
            const address: u64 = @bitCast(base + offset);
            switch (inst.funct3) {
                // sb
                0b000 => {
                    const ptr = &self.program_memory[address];
                    ptr.* = @truncate(self.registers[inst.rs2]);
                    self.logInst("sb x{d}, {d}(x{d})", .{ inst.rs2, offset, inst.rs1 });
                },
                // sh
                0b001 => {
                    if (config.alignment_errors) {
                        if (address & 0b1 != 0) {
                            log.err("Instruction SH can only store on 2-byte aligned addresses", .{});
                            return error.DecodeError;
                        }
                    }

                    const ptr: *u16 = @ptrCast(@alignCast(&self.program_memory[address]));
                    ptr.* = @truncate(self.registers[inst.rs2]);
                    self.logInst("sh x{d}, {d}(x{d})", .{ inst.rs2, offset, inst.rs1 });
                },
                // sw
                0b010 => {
                    if (config.alignment_errors) {
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
                    if (config.alignment_errors) {
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
        .l => {
            const inst: IType = @bitCast(instruction);
            const offset = signExtend(i64, u12, inst.imm);
            const base: i64 = @bitCast(self.registers[inst.rs1]);
            const address: u64 = @bitCast(base + offset);
            switch (inst.funct3) {
                // lb
                0b000 => {
                    self.registers[inst.rd] = signExtend(u64, u8, self.program_memory[address]);
                    self.logInst("lb x{d}, {d}(x{d})", .{ inst.rd, offset, inst.rs1 });
                },
                // lbu
                0b100 => {
                    self.registers[inst.rd] = self.program_memory[address];
                    self.logInst("lbu x{d}, {d}(x{d})", .{ inst.rd, offset, inst.rs1 });
                },
                // lh
                0b001 => {
                    if (config.alignment_errors) {
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
                    if (config.alignment_errors) {
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
                    if (config.alignment_errors) {
                        if (address & 0b11 != 0) {
                            log.err("Instruction LW can only load from 4-byte aligned addresses", .{});
                            return error.DecodeError;
                        }
                    }
                    const ptr: *u32 = @ptrCast(@alignCast(&self.program_memory[address]));
                    self.registers[inst.rd] = signExtend(u64, u32, ptr.*);
                    self.logInst("lw x{d}, {d}(x{d})", .{ inst.rd, offset, inst.rs1 });
                },
                // lwu
                0b110 => {
                    if (config.alignment_errors) {
                        if (address & 0b11 != 0) {
                            log.err("Instruction LWU can only load from 4-byte aligned addresses", .{});
                            return error.DecodeError;
                        }
                    }

                    const ptr: *u32 = @ptrCast(@alignCast(&self.program_memory[address]));
                    self.registers[inst.rd] = ptr.*;
                    self.logInst("lwu x{d}, {d}(x{d})", .{ inst.rd, offset, inst.rs1 });
                },
                // ld
                0b011 => {
                    if (config.alignment_errors) {
                        if (address & 0b111 != 0) {
                            log.err("Instruction LD can only load from 8-byte aligned addresses", .{});
                            return error.DecodeError;
                        }
                    }
                    const ptr: *u64 = @ptrCast(@alignCast(&self.program_memory[address]));
                    self.registers[inst.rd] = ptr.*;
                    self.logInst("ld x{d}, {d}(x{d})", .{ inst.rd, offset, inst.rs1 });
                },
                else => std.debug.panic("Invalid funct3: {d}\n", .{inst.funct3}),
            }
            self.pc += 4;
        },
        .ecall => {
            self.logInst("ecall", .{});
            const number = self.registers[17];
            if (number == 1) {
                return false;
            }
        },
    }

    return true;
}

// This function reliably gets compiled to a single movsxd on x86-64
// and it is also cross-platform so I think it justifies the extra lines of code.
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

fn logInst(self: *Emulator, comptime fmt: []const u8, args: anytype) void {
    if (config.log_inst) {
        // This will only occur when running with some kind of debug support enabled so it is fine
        // to just panic on OOM.
        self.inst_log.append(self.gpa, std.fmt.allocPrintZ(self.gpa, fmt, args) catch @panic("OOM")) catch @panic("OOM");
    }
}

// Register-Immediate
test "addi" {
    const src =
        \\ addi x10, x0, 10
        \\ addi x10, x10, -5
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expectEqual(0, emu.registers[10]);

    _ = try emu.next();
    try std.testing.expectEqual(10, emu.registers[10]);

    _ = try emu.next();
    try std.testing.expectEqual(5, emu.registers[10]);
}

test "addi overflow" {
    const src =
        \\ addi x10, x0, -1
        \\ addi x10, x10, 1
        \\ addi x10, x10, -5
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    _ = try emu.next();
    try std.testing.expectEqual(std.math.maxInt(u64), emu.registers[10]);
    _ = try emu.next();
    try std.testing.expectEqual(0, emu.registers[10]);
    _ = try emu.next();
    try std.testing.expectEqual(-5, @as(i64, @bitCast(emu.registers[10])));
}

test "slli" {
    const src =
        \\ addi x10, x0, 32
        \\ slli x10, x10, 1
        \\ addi x11, x0, 1
        \\ slli x11, x11, 63
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expectEqual(0, emu.registers[10]);
    try std.testing.expectEqual(0, emu.registers[11]);

    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(32, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(64, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1, emu.registers[11]);

    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1 << 63, emu.registers[11]);
}

test "srli" {
    const src =
        \\ addi x10, x0, 32
        \\ srli x10, x10, 1
        \\ addi x11, x0, -32
        \\ srli x11, x11, 4
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expectEqual(0, emu.registers[10]);
    try std.testing.expectEqual(0, emu.registers[11]);

    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(32, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(16, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(-32, @as(i64, @bitCast(emu.registers[11])));

    const expected: u64 = @bitCast(@as(i64, -32));
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(expected >> 4, emu.registers[11]);
    try std.testing.expect(-16 != @as(i64, @bitCast(emu.registers[11])));
}

test "srai" {
    const src =
        \\ addi x10, x0, 1
        \\ slli x10, x10, 63
        \\ srai x10, x10, 1
        \\ addi x11, x0, -32
        \\ srai x11, x11, 4
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expectEqual(0, emu.registers[10]);
    try std.testing.expectEqual(0, emu.registers[11]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1 << 63, emu.registers[10]);

    try std.testing.expect(try emu.next());
    // 0b1000... before
    // 0b1100... after
    try std.testing.expectEqual(1 << 63 | 1 << 62, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(-32, @as(i64, @bitCast(emu.registers[11])));

    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(-2, @as(i64, @bitCast(emu.registers[11])));
}

test "slti" {
    const src =
        \\ addi x10, x0, 10
        \\ slti x10, x10, 11
        \\ slti x10, x10, -10
        \\ slti x10, x10, 0
        \\ slti x10, x10, 1
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expectEqual(0, emu.registers[10]);
    try std.testing.expectEqual(0, emu.registers[11]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(0, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(0, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1, emu.registers[10]);
}

test "sltiu" {
    const src =
        \\ addi x10, x0, 10
        \\ sltiu x10, x10, 11
        \\ sltiu x10, x10, -10
        \\ sltiu x10, x10, 0
        \\ sltiu x10, x10, 1
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expectEqual(0, emu.registers[10]);
    try std.testing.expectEqual(0, emu.registers[11]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1, emu.registers[10]);

    // 1 < -10, true since we are doing unsigned less than.
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(0, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1, emu.registers[10]);
}

test "xori" {
    const src =
        \\ addi x10, x0, 32
        \\ xori x10, x10, 33
        \\ addi x10, x0, 483
        \\ xori x10, x10, 1843
        \\ addi x10, x0, -1
        \\ xori x10, x10, -332
        \\ addi x10, x0, 1370
        \\ xori x10, x10, -1
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expectEqual(0, emu.registers[10]);
    try std.testing.expectEqual(0, emu.registers[11]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(483 ^ 1843, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(-1 ^ -332, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(~@as(u64, 1370), emu.registers[10]);
}

test "ori" {
    const src =
        \\ addi x10, x0, 32
        \\ ori x10, x10, 16
        \\ addi x10, x0, 32
        \\ ori x10, x10, -1
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expectEqual(0, emu.registers[10]);
    try std.testing.expectEqual(0, emu.registers[11]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(32 | 16, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, -1))), emu.registers[10]);
}

test "andi" {
    const src =
        \\ addi x10, x0, 32
        \\ andi x10, x10, 16
        \\ addi x10, x0, 32
        \\ andi x10, x10, -1
        \\ addi x10, x0, -1
        \\ andi x10, x10, -1
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expectEqual(0, emu.registers[10]);
    try std.testing.expectEqual(0, emu.registers[11]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(0, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(32, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(-1, @as(i64, @bitCast(emu.registers[10])));
}

// Register-Register
test "add" {
    const src =
        \\ addi x10, x0, 32
        \\ addi x11, x0, 31
        \\ add x10, x10, x11
        \\ addi x10, x0, -1
        \\ addi x11, x0, 1
        \\ add x10, x11, x10
        \\ addi x10, x0, -1
        \\ addi x11, x0, 5
        \\ add x10, x11, x10
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expectEqual(0, emu.registers[10]);
    try std.testing.expectEqual(0, emu.registers[11]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(63, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(0, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(4, emu.registers[10]);
}

test "addw" {
    const src =
        \\ addi x10, x0, 32
        \\ addi x11, x0, 31
        \\ addw x10, x10, x11
        \\ addi x10, x0, -1
        \\ addi x11, x0, 1
        \\ addw x10, x11, x10
        \\ addi x10, x0, -1
        \\ addi x11, x0, 5
        \\ addw x10, x11, x10
        \\ addi x10, x0, -1
        \\ addi x11, x0, 5
        \\ addw x10, x11, x10
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expectEqual(0, emu.registers[10]);
    try std.testing.expectEqual(0, emu.registers[11]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(63, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(0, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(4, emu.registers[10]);
}

test "sub" {
    const src =
        \\ addi x10, x0, 32
        \\ addi x11, x0, 31
        \\ sub x10, x10, x11
        \\ addi x10, x0, 0
        \\ addi x11, x0, -1
        \\ sub x10, x11, x10
        \\ addi x10, x0, -1
        \\ addi x11, x0, 5
        \\ sub x10, x11, x10
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expectEqual(0, emu.registers[10]);
    try std.testing.expectEqual(0, emu.registers[11]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(std.math.maxInt(u64), emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(6, emu.registers[10]);
}

test "subw" {
    const src =
        \\ addi x10, x0, 32
        \\ addi x11, x0, 31
        \\ subw x10, x10, x11
        \\ addi x10, x0, 0
        \\ addi x11, x0, -1
        \\ subw x10, x11, x10
        \\ addi x10, x0, -1
        \\ addi x11, x0, 5
        \\ subw x10, x11, x10
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expectEqual(0, emu.registers[10]);
    try std.testing.expectEqual(0, emu.registers[11]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(std.math.maxInt(u64), emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(6, emu.registers[10]);
}

test "sll" {
    const src =
        \\ addi x10, x0, 32
        \\ addi x11, x0, 4
        \\ sll x10, x10, x11
        \\ addi x10, x0, 1
        \\ addi x11, x0, 63
        \\ sll x10, x10, x11
        \\ addi x10, x0, 1
        \\ addi x11, x0, 512
        \\ sll x10, x10, x11
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expectEqual(0, emu.registers[10]);
    try std.testing.expectEqual(0, emu.registers[11]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(32 << 4, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1 << 63, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1, emu.registers[10]);
}

test "sllw" {
    const src =
        \\ addi x10, x0, 32
        \\ addi x11, x0, 4
        \\ sllw x10, x10, x11
        \\ addi x10, x0, 1
        \\ addi x11, x0, 63
        \\ sllw x10, x10, x11
        \\ addi x10, x0, 1
        \\ addi x11, x0, 512
        \\ sllw x10, x10, x11
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expectEqual(0, emu.registers[10]);
    try std.testing.expectEqual(0, emu.registers[11]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(32 << 4, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1 << 31, emu.registers[10] & 0xFFFF_FFFF);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1, emu.registers[10]);
}

test "srl" {
    const src =
        \\ addi x10, x0, 32
        \\ addi x11, x0, 4
        \\ srl x10, x10, x11
        \\ addi x10, x0, 1
        \\ addi x11, x0, 63
        \\ srl x10, x10, x11
        \\ addi x10, x0, 1
        \\ addi x11, x0, 512
        \\ srl x10, x10, x11
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expectEqual(0, emu.registers[10]);
    try std.testing.expectEqual(0, emu.registers[11]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(32 >> 4, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1 >> 63, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1, emu.registers[10]);
}

test "srlw" {
    const src =
        \\ addi x10, x0, 32
        \\ addi x11, x0, 4
        \\ srlw x10, x10, x11
        \\ addi x10, x0, 1
        \\ addi x11, x0, 63
        \\ srlw x10, x10, x11
        \\ addi x10, x0, 1
        \\ addi x11, x0, 512
        \\ srlw x10, x10, x11
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expectEqual(0, emu.registers[10]);
    try std.testing.expectEqual(0, emu.registers[11]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(32 >> 4, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1 >> 63, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1, emu.registers[10]);
}

test "sra" {
    const src =
        \\ addi x10, x0, 32
        \\ addi x11, x0, 4
        \\ sra x10, x10, x11
        \\ addi x10, x0, -100
        \\ addi x11, x0, 3
        \\ sra x10, x10, x11
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expectEqual(0, emu.registers[10]);
    try std.testing.expectEqual(0, emu.registers[11]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(32 >> 4, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(-100 >> 3, @as(i64, @bitCast(emu.registers[10])));
}

test "sraw" {
    const src =
        \\ addi x10, x0, 32
        \\ addi x11, x0, 4
        \\ sraw x10, x10, x11
        \\ addi x10, x0, -100
        \\ addi x11, x0, 3
        \\ sraw x10, x10, x11
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expectEqual(0, emu.registers[10]);
    try std.testing.expectEqual(0, emu.registers[11]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(32 >> 4, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());

    try std.testing.expectEqual(-100 >> 3, @as(i64, @bitCast(emu.registers[10])));
}

test "slt" {
    const src =
        \\ addi x10, x0, 32
        \\ addi x11, x0, 64
        \\ slt x10, x10, x11
        \\ addi x10, x0, -32
        \\ addi x11, x0, 4
        \\ slt x10, x10, x11
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expectEqual(0, emu.registers[10]);
    try std.testing.expectEqual(0, emu.registers[11]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1, emu.registers[10]);
}

test "sltu" {
    const src =
        \\ addi x10, x0, 32
        \\ addi x11, x0, 64
        \\ sltu x10, x10, x11
        \\ addi x10, x0, -32
        \\ addi x11, x0, 4
        \\ sltu x10, x10, x11
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expectEqual(0, emu.registers[10]);
    try std.testing.expectEqual(0, emu.registers[11]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(0, emu.registers[10]);
}

test "or" {
    const src =
        \\ addi x10, x0, 32
        \\ addi x11, x0, 64
        \\ or x10, x10, x11
        \\ addi x10, x0, -32
        \\ addi x11, x0, 64
        \\ or x10, x10, x11
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expectEqual(0, emu.registers[10]);
    try std.testing.expectEqual(0, emu.registers[11]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(32 | 64, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, -32))) | 64, emu.registers[10]);
}

test "xor" {
    const src =
        \\ addi x10, x0, 32
        \\ addi x11, x0, 33
        \\ xor x10, x10, x11
        \\ addi x10, x0, 483
        \\ addi x11, x0, 1843
        \\ xor x10, x10, x11
        \\ addi x10, x0, -1
        \\ addi x11, x0, -332
        \\ xor x10, x10, x11
        \\ addi x10, x0, 1370
        \\ addi x11, x0, -1
        \\ xor x10, x10, x11
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expectEqual(0, emu.registers[10]);
    try std.testing.expectEqual(0, emu.registers[11]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(483 ^ 1843, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(-1 ^ -332, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(~@as(u64, 1370), emu.registers[10]);
}

test "addiw" {
    const src =
        \\ addi x10, x0, 10
        \\ addiw x10, x10, 233
        \\ addi x10, x0, -1
        \\ addiw x10, x10, 1
        \\ addi x10, x0, 1
        \\ slli x10, x10, 63
        \\ addiw x10, x10, 1
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expectEqual(0, emu.registers[10]);
    try std.testing.expectEqual(0, emu.registers[11]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(10 + 233, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(@as(i64, -1), @as(i64, @bitCast(emu.registers[10])));
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(0, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1, emu.registers[10]);
}

test "slliw" {
    const src =
        \\ addi x10, x0, 32
        \\ slliw x10, x10, 1
        \\ addi x11, x0, 1
        \\ slliw x11, x11, 31
        \\ addi x10, x0, -32
        \\ slliw x10, x10, 1
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expectEqual(0, emu.registers[10]);
    try std.testing.expectEqual(0, emu.registers[11]);

    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(32, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(64, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1, emu.registers[11]);

    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1 << 31, @as(u32, @truncate(emu.registers[11])));
    try std.testing.expectEqual(0xffffffff, @as(u32, @truncate(emu.registers[11] >> 31)));

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(-64, @as(i64, @bitCast(emu.registers[10])));
}

test "srliw" {
    const src =
        \\ addi x10, x0, 32
        \\ srliw x10, x10, 1
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(16, emu.registers[10]);
}

test "sraiw" {
    const src =
        \\ addi x10, x0, 32
        \\ sraiw x10, x10, 1
        \\ addi x10, x0, -32
        \\ sraiw x10, x10, 1
        \\ sraiw x10, x10, 1
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expectEqual(0, emu.registers[10]);
    try std.testing.expectEqual(0, emu.registers[11]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(16, emu.registers[10]);

    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(-16, @as(i64, @bitCast(emu.registers[10])));

    emu.registers[10] = 0xffff_ffff_8000_0000;
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1 << 31 | 1 << 30, emu.registers[10] & 0xffff_ffff);
    try std.testing.expectEqual(0xffff_ffff, emu.registers[10] >> 32);
}

test "stores" {
    const src =
        // sb
        \\ addi x10, x0, 10
        \\ sb x2, x10, -1
        // sh
        \\ addi x11, x0, 1
        \\ slli x11, x11, 15
        \\ sh x2, x11, -2
        // sw
        \\ addi x11, x0, 1
        \\ slli x11, x11, 31
        \\ sw x2, x11, -4
        // sd
        \\ addi x12, x0, 1
        \\ slli x12, x12, 63
        \\ sw x2, x12, -8
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    // sb
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(10, emu.program_memory[emu.registers[2] - 1]);

    // sh
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    const actual_sh = std.mem.readInt(u16, emu.program_memory[emu.registers[2] - 2 ..][0..2], .little);
    try std.testing.expectEqual(1 << 15, actual_sh);

    // sw
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    const actual_sw = std.mem.readInt(u32, emu.program_memory[emu.registers[2] - 4 ..][0..4], .little);
    try std.testing.expectEqual(1 << 31, actual_sw);

    // sd
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    try std.testing.expect(try emu.next());
    const actual_sd = std.mem.readInt(u64, emu.program_memory[emu.registers[2] - 8 ..][0..8], .little);
    try std.testing.expectEqual(1 << 63, actual_sd);
}

test "ecall exit" {
    const src =
        \\ addi x17, x0, 1
        \\ addi x10, x0, 420
        \\ ecall
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(std.testing.allocator);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(std.testing.allocator, code.items, 0);
    defer emu.deinit();

    try std.testing.expectEqual(0, emu.registers[10]);
    try std.testing.expectEqual(0, emu.registers[17]);

    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(1, emu.registers[17]);

    try std.testing.expect(try emu.next());
    try std.testing.expectEqual(420, emu.registers[10]);

    try std.testing.expect(!try emu.next());
}
