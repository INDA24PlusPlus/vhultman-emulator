#!/bin/bash

input_file=$1
output_name="${input_file%.*}"

cat > link.ld << 'EOF'
SECTIONS
{
    . = 0x0;
    .text : {
        *(.text.init)
        *(.text)
    }
    
    . = ALIGN(8);
    .rodata : {
        *(.rodata)
        *(.rodata.*)
    }
    
    . = ALIGN(8);
    .data : {
        *(.data)
        *(.data.*)
        *(.sdata)
    }
    
    . = ALIGN(8);
    .bss : {
        *(.bss)
        *(.bss.*)
        *(.sbss)
    }
}
EOF

clang --target=riscv64 -march=rv64i -mabi=lp64 \
    -fno-stack-protector -fno-pie -ffreestanding -nostdlib -mno-relax \
    -c "${input_file}" -o "${output_name}.o"

ld.lld -T link.ld "${output_name}.o" -o "${output_name}.elf"
llvm-objcopy -O binary "${output_name}.elf" "${output_name}.bin"
llvm-objdump -h "${output_name}.elf"

rm "${output_name}.o" "${output_name}.elf" link.ld

echo "Generated ${output_name}.bin:"
ls -l "${output_name}.bin"
