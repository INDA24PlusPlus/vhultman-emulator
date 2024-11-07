
# 1. Integer Register-Immediate Instructions
    [x] ADDI – Add immediate
    [x] SLTI – Set less than immediate (signed)
    [x] SLTIU – Set less than immediate (unsigned)
    [x] ANDI – Bitwise AND immediate
    [x] ORI – Bitwise OR immediate
    [x] XORI – Bitwise XOR immediate
    [x] SLLI – Shift left logical immediate
    [x] SRLI – Shift right logical immediate (unsigned)
    [x] SRAI – Shift right arithmetic immediate (signed)
    [x] LUI – Load upper immediate
    [x] AUIPC – Add upper immediate to PC

# 2. Integer Register-Register Instructions

    [x] ADD – Add
    [x] SUB – Subtract
    [x] SLL – Shift left logical
    [x] SRL – Shift right logical (unsigned)
    [x] SRA – Shift right arithmetic (signed)
    [x] SLT – Set less than (signed)
    [x] SLTU – Set less than (unsigned)
    [x] AND – Bitwise AND
    [x] OR – Bitwise OR
    [x] XOR – Bitwise XOR

# 3. 32-bit Integer Instructions (RV64I)

    [x] ADDIW – Add immediate word (sign-extended 32-bit result)
    [x] SLLIW – Shift left logical immediate word
    [x] SRLIW – Shift right logical immediate word
    [x] SRAIW – Shift right arithmetic immediate word
    [x] ADDW – Add word (sign-extended 32-bit result)
    [x] SUBW – Subtract word (sign-extended 32-bit result)
    [x] SLLW – Shift left logical word
    [x] SRLW – Shift right logical word (unsigned)
    [x] SRAW – Shift right arithmetic word (signed)

# 4. Load and Store Instructions

    [x] LB – Load byte (sign-extended)
    [x] LBU – Load byte unsigned
    [x] LH – Load half-word (16-bit, sign-extended)
    [x] LHU – Load half-word unsigned
    [x] LW – Load word (32-bit, sign-extended)
    [x] LWU – Load word unsigned (RV64I only)
    [x] LD – Load double word (64-bit, RV64I only)
    [x] SB – Store byte
    [x] SH – Store half-word (16-bit)
    [x] SW – Store word (32-bit)
    [x] SD – Store double word (64-bit, RV64I only)

# 5. Control Flow Instructions

    [x] JAL – Jump and link
    [x] JALR – Jump and link register
    [x] BEQ – Branch if equal
    [x] BNE – Branch if not equal
    [x] BLT – Branch if less than (signed)
    [x] BGE – Branch if greater than or equal (signed)
    [x] BLTU – Branch if less than (unsigned)
    [x] BGEU – Branch if greater than or equal (unsigned)

# 6. System Instructions

    [x] ECALL – Environment call (typically for system calls)
    [ ] EBREAK – Environment break (used for debugging)
