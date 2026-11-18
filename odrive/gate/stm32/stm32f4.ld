/* STM32F446RE: 512 kB flash, 128 kB RAM. Sectors 6 and 7 (0x08040000..) hold the gate's stored
   state and are left out of the program region. The key sits at a fixed address in sector 1. */
MEMORY {
  FLASH (rx) : ORIGIN = 0x08000000, LENGTH = 16K
  KEY   (r)  : ORIGIN = 0x08004000, LENGTH = 16K
  CODE  (rx) : ORIGIN = 0x08008000, LENGTH = 224K
  RAM   (rw) : ORIGIN = 0x20000000, LENGTH = 128K
}
_estack = ORIGIN(RAM) + LENGTH(RAM);
ENTRY(Reset_Handler)
SECTIONS {
  .vectors : { KEEP(*(.vectors)) } > FLASH
  .gate_key : { KEEP(*(.gate_key)) } > KEY
  .text : { *(.text*) *(.rodata*) . = ALIGN(4); } > CODE
  _sidata = LOADADDR(.data);
  .data : { _sdata = .; *(.data*) . = ALIGN(4); _edata = .; } > RAM AT > CODE
  .bss : { _sbss = .; *(.bss*) *(COMMON) . = ALIGN(4); _ebss = .; } > RAM
  /DISCARD/ : { *(.ARM.exidx*) *(.ARM.attributes) *(.comment) }
}
