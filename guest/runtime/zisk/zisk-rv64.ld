ENTRY(_start)

MEMORY {
  rom (xa) : ORIGIN = 0x80000000, LENGTH = 0x08000000
  ram (wxa) : ORIGIN = 0xA0030000, LENGTH = 0x2000000
}

PHDRS {
  text PT_LOAD FLAGS(5);
  rodata PT_LOAD FLAGS(4);
  data PT_LOAD FLAGS(6);
  bss PT_LOAD FLAGS(6);
}

_evmz_payload_heap_size = 0x1000000; /* 16 MiB */
_stack_size = 0x100000;              /* 1 MiB */

SECTIONS
{
  .text : {
    *(.text.start)
    *(.text .text.*)
  } >rom AT>rom :text

  . = ALIGN(8);
  PROVIDE(_global_pointer = .);

  .rodata : {
    *(.srodata .srodata.*)
    *(.rodata .rodata.*)
  } >rom AT>rom :rodata

  .eh_frame : {
    *(.eh_frame .eh_frame.*)
  } >rom AT>rom :rodata

  .data : {
    *(.sdata .sdata.*)
    *(.data .data.*)
  } >ram AT>ram :data

  . = ALIGN(8);
  .bss : {
    PROVIDE(_bss_start = .);
    *(.sbss .sbss.*)
    *(.bss .bss.*)
    *(COMMON)
    PROVIDE(_bss_end = .);
  } >ram AT>ram :bss

  . = ALIGN(16);
  PROVIDE(_evmz_heap_bottom = .);
  . = . + _evmz_payload_heap_size;
  PROVIDE(_evmz_heap_top = .);
  PROVIDE(_evmz_heap_size = _evmz_heap_top - _evmz_heap_bottom);
  ASSERT(_evmz_heap_top <= ORIGIN(ram) + LENGTH(ram), "evmz heap exceeds RAM")

  . = ALIGN(8);
  PROVIDE(_init_stack_top = . + _stack_size);
  PROVIDE(_kernel_heap_bottom = _init_stack_top);
  PROVIDE(_kernel_heap_top = ORIGIN(ram) + LENGTH(ram));
  PROVIDE(_kernel_heap_size = _kernel_heap_top - _kernel_heap_bottom);
  ASSERT(_kernel_heap_size >= 0x800000, "ziskos heap too small")

  . = ALIGN(8);
  _end = .;

  /DISCARD/ : {
    *(.comment)
    *(.note.GNU-stack)
  }
}
