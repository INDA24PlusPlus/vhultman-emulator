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

    [x]ADD – Add
    [ ]SUB – Subtract
    [ ]SLL – Shift left logical
    [ ]SRL – Shift right logical (unsigned)
    [ ]SRA – Shift right arithmetic (signed)
    [ ]SLT – Set less than (signed)
    [ ]SLTU – Set less than (unsigned)
    [ ]AND – Bitwise AND
    [ ]OR – Bitwise OR
    [ ]XOR – Bitwise XOR

# 3. 32-bit Integer Instructions (RV64I)

    [x]ADDIW – Add immediate word (sign-extended 32-bit result)
    [ ]SLLIW – Shift left logical immediate word
    [ ]SRLIW – Shift right logical immediate word
    [ ]SRAIW – Shift right arithmetic immediate word
    [x]ADDW – Add word (sign-extended 32-bit result)
    [ ]SUBW – Subtract word (sign-extended 32-bit result)
    [ ]SLLW – Shift left logical word
    [ ]SRLW – Shift right logical word (unsigned)
    [ ]SRAW – Shift right arithmetic word (signed)

# 4. Load and Store Instructions

    [ ] LB – Load byte (sign-extended)
    [ ] LBU – Load byte unsigned
    [ ] LH – Load half-word (16-bit, sign-extended)
    [ ] LHU – Load half-word unsigned
    [x] LW – Load word (32-bit, sign-extended)
    [x] LWU – Load word unsigned (RV64I only)
    [x] LD – Load double word (64-bit, RV64I only)
    [x] SB – Store byte
    [ ] SH – Store half-word (16-bit)
    [x] SW – Store word (32-bit)
    [x] SD – Store double word (64-bit, RV64I only)

# 5. Control Flow Instructions

    [ ] JAL – Jump and link
    [x] JALR – Jump and link register
    [ ] BEQ – Branch if equal
    [ ] BNE – Branch if not equal
    [ ] BLT – Branch if less than (signed)
    [ ] BGE – Branch if greater than or equal (signed)
    [ ] BLTU – Branch if less than (unsigned)
    [ ] BGEU – Branch if greater than or equal (unsigned)

# 6. System Instructions

    [x] ECALL – Environment call (typically for system calls)
    [ ] EBREAK – Environment break (used for debugging)
