/*
 * Adapted from SP1 v6.4.0 zkevm/zkvm.ld.
 * SP1 owns _start; Zig exports main and shares SP1's platform heap.
 */
OUTPUT_FORMAT("elf64-littleriscv")
OUTPUT_ARCH(riscv)
ENTRY(_start)

PROVIDE(__sp1_stack_top    = 0x78000000);
PROVIDE(__sp1_max_memory   = 0x2000000000);
PROVIDE(__sp1_input_region = 0x0400000000);

MEMORY
{
    RAM (rwx) : ORIGIN = 0x78000000, LENGTH = 0x1B88000000
}

SECTIONS
{
    . = ORIGIN(RAM);

    .text : ALIGN(16)
    {
        KEEP(*(.text._start))
        *(.text .text.*)
    } > RAM

    .rodata : ALIGN(16)
    {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > RAM

    .data : ALIGN(16)
    {
        __data_start = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        __data_end = .;
    } > RAM
    __data_load = LOADADDR(.data);

    .bss (NOLOAD) : ALIGN(16)
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    } > RAM

    . = ALIGN(16);
    _end = .;
    __stack_top = __sp1_stack_top;
    PROVIDE(__global_pointer$ = __data_start + 0x800);

    __input_start = __sp1_max_memory - __sp1_input_region;
    __input_end = __sp1_max_memory;
    _heap_start = _end;
    _heap_end = __input_start;

    ASSERT(_heap_start < _heap_end, "evmz image leaves no SP1 heap")

    /* Non-loaded ISA metadata consumed by check-guest-elf. */
    .riscv.attributes 0 :
    {
        KEEP(*(.riscv.attributes))
    }

    /DISCARD/ :
    {
        *(.comment)
        *(.note .note.*)
        *(.eh_frame .eh_frame.*)
    }
}
