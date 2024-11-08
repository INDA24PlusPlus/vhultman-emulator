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
