OUTPUT_FORMAT("elf64-littleriscv")
OUTPUT_ARCH(riscv)
ENTRY(_start)

/* OpenVM v2.1 loads text at 0x00200800 and places its downward-growing stack below it. */
SECTIONS
{
    . = 0x00200800;

    .text : ALIGN(16)
    {
        KEEP(*(.text._start))
        *(.text .text.*)
    }

    .rodata : ALIGN(16)
    {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    }

    .data : ALIGN(16)
    {
        __data_start = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        __data_end = .;
    }

    .bss (NOLOAD) : ALIGN(16)
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        __bss_end = .;
    }

    . = ALIGN(16);
    _heap_start = .;
    . = . + _evmz_payload_heap_size;
    _heap_end = .;
    _end = .;

    PROVIDE(__global_pointer$ = __data_start + 0x800);
    ASSERT(_heap_end <= 0x20000000, "evmz heap exceeds OpenVM memory")

    /DISCARD/ :
    {
        *(.comment)
        *(.note .note.*)
        *(.eh_frame .eh_frame.*)
        *(.riscv.attributes)
    }
}
