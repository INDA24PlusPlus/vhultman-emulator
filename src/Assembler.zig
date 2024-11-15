const std = @import("std");
const Allocator = std.mem.Allocator;
const Assembler = @This();
const Emulator = @import("Emulator.zig");

const log = std.log.scoped(.assembler);

src: [:0]const u8,
tokenizer: Tokenizer,
next_token: Tokenizer.Token,
curr_token: Tokenizer.Token,

pub fn init(src: [:0]const u8) Assembler {
    var tokenizer = Tokenizer.init(src);
    return .{
        .src = src,
        .curr_token = undefined,
        .next_token = tokenizer.next().?,
        .tokenizer = tokenizer,
    };
}

pub fn run(self: *Assembler, writer: anytype) !void {
    while (self.next_token.kind != .eof) {
        try self.encodeInstruction(writer);
    }
}

fn encodeInstruction(self: *Assembler, writer: anytype) !void {
    const instruction: u32 = switch (self.next_token.kind) {
        // i-type
        .addi, .slti, .sltiu, .xori, .ori, .andi => blk: {
            self.advanceTokenStream();
            var inst: Emulator.IType = undefined;
            inst.funct3 = self.curr_token.kind.funct3().?;
            inst.opcode = .i;
            inst.rd = try self.expectRegister();
            try self.expectNext(.@",");
            inst.rs1 = try self.expectRegister();
            try self.expectNext(.@",");
            inst.imm = @bitCast(try self.expectImmediate(12));
            break :blk @bitCast(inst);
        },
        .srli, .srai, .slli => blk: {
            self.advanceTokenStream();
            const is_arithmetic = self.curr_token.kind == .srai;

            var inst: Emulator.IType = undefined;
            inst.funct3 = self.curr_token.kind.funct3().?;
            inst.opcode = .i;
            inst.rd = try self.expectRegister();
            try self.expectNext(.@",");
            inst.rs1 = try self.expectRegister();
            try self.expectNext(.@",");
            inst.imm = try self.expectImmediate(6);
            inst.imm |= (1 << 10) * @as(u12, @intFromBool(is_arithmetic));
            break :blk @bitCast(inst);
        },
        // r-type
        .add, .sub, .sll, .srl, .sra, .sltu, .slt, .@"or", .xor => blk: {
            self.advanceTokenStream();
            var inst: Emulator.RType = undefined;
            inst.funct3 = self.curr_token.kind.funct3().?;
            inst.funct7 = self.curr_token.kind.funct7().?;
            inst.opcode = .r;
            inst.rd = try self.expectRegister();
            try self.expectNext(.@",");
            inst.rs1 = try self.expectRegister();
            try self.expectNext(.@",");
            inst.rs2 = try self.expectRegister();
            break :blk @bitCast(inst);
        },
        .addiw => blk: {
            self.advanceTokenStream();
            var inst: Emulator.IType = undefined;
            inst.funct3 = self.curr_token.kind.funct3().?;
            inst.opcode = .ri64;
            inst.rd = try self.expectRegister();
            try self.expectNext(.@",");
            inst.rs1 = try self.expectRegister();
            try self.expectNext(.@",");
            inst.imm = @bitCast(try self.expectImmediate(12));
            break :blk @bitCast(inst);
        },
        .slliw, .srliw, .sraiw => blk: {
            self.advanceTokenStream();
            const is_arithmetic = self.curr_token.kind == .sraiw;

            var inst: Emulator.IType = undefined;
            inst.funct3 = self.curr_token.kind.funct3().?;
            inst.opcode = .ri64;
            inst.rd = try self.expectRegister();
            try self.expectNext(.@",");
            inst.rs1 = try self.expectRegister();
            try self.expectNext(.@",");
            inst.imm = try self.expectImmediate(5);
            inst.imm |= (1 << 10) * @as(u12, @intFromBool(is_arithmetic));

            break :blk @bitCast(inst);
        },
        // r-type
        .addw, .subw, .sllw, .srlw, .sraw => blk: {
            self.advanceTokenStream();
            var inst: Emulator.RType = undefined;
            inst.funct3 = self.curr_token.kind.funct3().?;
            inst.funct7 = self.curr_token.kind.funct7().?;
            inst.opcode = .r64;
            inst.rd = try self.expectRegister();
            try self.expectNext(.@",");
            inst.rs1 = try self.expectRegister();
            try self.expectNext(.@",");
            inst.rs2 = try self.expectRegister();
            break :blk @bitCast(inst);
        },
        .sb, .sh, .sw, .sd => blk: {
            self.advanceTokenStream();
            var inst: Emulator.SType = undefined;
            inst.funct3 = self.curr_token.kind.funct3().?;
            inst.opcode = .s;
            inst.rs1 = try self.expectRegister();
            try self.expectNext(.@",");
            inst.rs2 = try self.expectRegister();
            try self.expectNext(.@",");
            const imm = try self.expectImmediate(12);
            inst.imm0 = @truncate(imm);
            inst.imm1 = @truncate(imm >> 5);
            break :blk @bitCast(inst);
        },
        // l-type
        .lb,
        .lbu,
        .lh,
        .lhu,
        .lw,
        .lwu,
        .ld,
        => blk: {
            self.advanceTokenStream();
            var inst: Emulator.IType = undefined;
            inst.funct3 = self.curr_token.kind.funct3().?;
            inst.opcode = .l;
            inst.rd = try self.expectRegister();
            try self.expectNext(.@",");
            inst.rs1 = try self.expectRegister();
            try self.expectNext(.@",");
            inst.imm = @bitCast(try self.expectImmediate(12));
            break :blk @bitCast(inst);
        },
        .auipc => blk: {
            self.advanceTokenStream();
            var inst: Emulator.UType = undefined;
            inst.opcode = .auipc;
            inst.rd = try self.expectRegister();
            try self.expectNext(.@",");
            inst.imm = @bitCast(try self.expectImmediate(20));
            break :blk @bitCast(inst);
        },
        .lui => blk: {
            self.advanceTokenStream();
            var inst: Emulator.UType = undefined;
            inst.opcode = .lui;
            inst.rd = try self.expectRegister();
            try self.expectNext(.@",");
            inst.imm = @bitCast(try self.expectImmediate(20));
            break :blk @bitCast(inst);
        },
        // s-type
        .ecall => blk: {
            log.debug("Ecall", .{});
            var inst: Emulator.SType = @bitCast(@as(u32, 0));
            inst.opcode = .ecall;
            self.advanceTokenStream();
            break :blk @bitCast(inst);
        },
        else => {
            log.err("Expected mnemonic but instead got {s}", .{self.src[self.next_token.start..self.next_token.end]});
            return error.ExpectedInstruction;
        },
    };

    log.debug("Instruction is {b:0>32}: {x}", .{ instruction, instruction });

    // RISC-V are little endian by spec.
    try writer.writeInt(u32, instruction, .little);
}

fn expectImmediate(self: *Assembler, comptime num_bits: comptime_int) !@Type(.{ .int = .{
    .signedness = .unsigned,
    .bits = num_bits,
} }) {
    try self.expectNext(.immediate);
    const slice = self.src[self.curr_token.start..self.curr_token.end];
    const ReturnType = @Type(.{ .int = .{
        .signedness = .unsigned,
        .bits = num_bits,
    } });

    const imm: i32 = @bitCast(try std.fmt.parseInt(i32, slice, 10));
    if (imm < -1 and @abs(imm) > std.math.maxInt(ReturnType) - 1 << num_bits) {
        log.err("Exptected {d} bit immediate but found {s}", .{ num_bits, slice });
        return error.ImmediateTooLarge;
    }
    if (imm > std.math.maxInt(ReturnType)) {
        log.err("Exptected {d} bit immediate but found {s}", .{ num_bits, slice });
        return error.ImmediateTooLarge;
    }

    return @truncate(@as(u32, @bitCast(imm)));
}

fn expectRegister(self: *Assembler) !u5 {
    try self.expectNext(.register);
    return std.fmt.parseUnsigned(u5, self.src[self.curr_token.start + 1 .. self.curr_token.end], 10) catch unreachable;
}

fn expectNext(self: *Assembler, k: Tokenizer.Token.Kind) !void {
    if (k != self.next_token.kind) {
        log.err("Expected token {s} but found {s}", .{ @tagName(k), @tagName(self.next_token.kind) });
        return error.ParseError;
    }

    self.advanceTokenStream();
}

fn advanceTokenStream(self: *Assembler) void {
    self.curr_token = self.next_token;

    if (self.tokenizer.next()) |token| {
        self.next_token = token;
    } else {
        @branchHint(.unlikely);
        self.next_token = .{
            .end = @intCast(self.src.len - 1),
            .start = @intCast(self.src.len - 1),
            .kind = .eof,
        };
    }
}

pub const Tokenizer = struct {
    const Token = struct {
        kind: Kind,
        start: u32,
        end: u32,

        const keywords = std.StaticStringMap(Kind).initComptime(.{
            .{ "addi", .addi },
            .{ "slli", .slli },
            .{ "srli", .srli },
            .{ "srai", .srai },
            .{ "slti", .slti },
            .{ "sltiu", .sltiu },
            .{ "xori", .xori },
            .{ "ori", .ori },
            .{ "andi", .andi },

            .{ "add", .add },
            .{ "sub", .sub },
            .{ "sll", .sll },
            .{ "srl", .srl },
            .{ "sra", .sra },
            .{ "sltu", .sltu },
            .{ "slt", .slt },
            .{ "or", .@"or" },
            .{ "xor", .xor },

            .{ "addiw", .addiw },
            .{ "slliw", .slliw },
            .{ "sraiw", .sraiw },
            .{ "srliw", .srliw },

            .{ "addw", .addw },
            .{ "sllw", .sllw },
            .{ "srlw", .srlw },
            .{ "sraw", .sraw },
            .{ "subw", .subw },

            .{ "sb", .sb },
            .{ "sh", .sh },
            .{ "sw", .sw },
            .{ "sd", .sd },

            .{ "lb", .lb },
            .{ "lbu", .lbu },
            .{ "lh", .lh },
            .{ "lhu", .lhu },
            .{ "lw", .lw },
            .{ "lwu", .lwu },
            .{ "ld", .ld },

            .{ "lui", .lui },
            .{ "auipc", .auipc },
            .{ "ecall", .ecall },

            .{ "x0", .register },
            .{ "x1", .register },
            .{ "x2", .register },
            .{ "x3", .register },
            .{ "x4", .register },
            .{ "x5", .register },
            .{ "x6", .register },
            .{ "x7", .register },
            .{ "x8", .register },
            .{ "x9", .register },
            .{ "x10", .register },
            .{ "x11", .register },
            .{ "x12", .register },
            .{ "x13", .register },
            .{ "x14", .register },
            .{ "x15", .register },
            .{ "x16", .register },
            .{ "x17", .register },
            .{ "x18", .register },
            .{ "x19", .register },
            .{ "x20", .register },
            .{ "x21", .register },
            .{ "x22", .register },
            .{ "x23", .register },
            .{ "x24", .register },
            .{ "x25", .register },
            .{ "x26", .register },
            .{ "x27", .register },
            .{ "x28", .register },
            .{ "x29", .register },
            .{ "x30", .register },
            .{ "x31", .register },
        });

        const Kind = enum {
            @":",
            @",",

            immediate,

            addi,
            slli,
            srli,
            srai,
            slti,
            sltiu,
            xori,
            ori,
            andi,

            add,
            sub,
            sll,
            srl,
            sra,
            slt,
            sltu,
            @"or",
            xor,

            addiw,
            slliw,
            sraiw,
            srliw,

            addw,
            sllw,
            srlw,
            sraw,
            subw,

            sb,
            sh,
            sw,
            sd,

            lb,
            lbu,
            lh,
            lhu,
            lw,
            lwu,
            ld,

            lui,
            auipc,
            ecall,

            label,
            register,
            invalid,
            eof,

            pub fn funct3(self: Kind) ?u3 {
                return switch (self) {
                    .addi,
                    .addiw,
                    .add,
                    .addw,
                    .sub,
                    .subw,
                    .sb,
                    .lb,
                    => 0b000,
                    .slli,
                    .sll,
                    .slliw,
                    .sllw,
                    .sh,
                    .lh,
                    => 0b001,
                    .slti,
                    .slt,
                    .sw,
                    .lw,
                    => 0b010,
                    .sltiu,
                    .sltu,
                    .sd,
                    .ld,
                    => 0b011,
                    .xori,
                    .xor,
                    .lbu,
                    => 0b100,
                    .srli,
                    .srliw,
                    .srlw,
                    .srl,
                    .srai,
                    .sra,
                    .sraiw,
                    .sraw,
                    .lhu,
                    => 0b101,
                    .ori,
                    .@"or",
                    .lwu,
                    => 0b110,
                    .andi => 0b111,
                    else => null,
                };
            }

            pub fn funct7(self: Kind) ?u7 {
                return switch (self) {
                    .add, .sll, .srl, .sltu, .slt, .@"or", .xor, .addw, .sllw, .srlw => 0b0000000,
                    .sub, .sra, .subw, .sraw => 0b0100000,
                    else => null,
                };
            }
        };
    };

    src: [:0]const u8,
    index: u32,

    pub fn init(src: [:0]const u8) Tokenizer {
        return .{ .src = src, .index = 0 };
    }

    const State = enum {
        start,
        label,
        immediate,
    };

    pub fn next(self: *Tokenizer) ?Token {
        var result: Token = .{
            .kind = undefined,
            .start = self.index,
            .end = undefined,
        };

        state: switch (State.start) {
            .start => switch (self.src[self.index]) {
                '\n', '\t', ' ', '\r' => {
                    self.index += 1;
                    result.start = self.index;
                    continue :state .start;
                },
                'a'...'z', 'A'...'Z', '_' => {
                    result.kind = .label;
                    continue :state .label;
                },
                '0'...'9' => {
                    result.kind = .immediate;
                    continue :state .immediate;
                },
                ':' => {
                    self.index += 1;
                    result.kind = .@":";
                },
                ',' => {
                    self.index += 1;
                    result.kind = .@",";
                },
                '-' => {
                    result.kind = .immediate;
                    continue :state .immediate;
                },
                0 => {
                    if (self.index >= self.src.len) {
                        return null;
                    } else {
                        result.kind = .invalid;
                    }

                    self.index += 1;
                },
                else => {
                    result.kind = .invalid;
                    self.index += 1;
                },
            },
            .immediate => {
                self.index += 1;
                switch (self.src[self.index]) {
                    '0'...'9' => {
                        continue :state .immediate;
                    },
                    else => {},
                }
            },
            .label => {
                self.index += 1;
                switch (self.src[self.index]) {
                    // Still going
                    'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :state .label,

                    // Hit end.
                    else => {
                        const identifier_string = self.src[result.start..self.index];
                        if (Token.keywords.get(identifier_string)) |t| {
                            result.kind = t;
                        }
                    },
                }
            },
        }

        result.end = self.index;
        return result;
    }
};
