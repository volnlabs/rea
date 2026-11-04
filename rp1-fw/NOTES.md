# RP1 Cortex-M3 firmware — offline extraction notes (2026-11-04)

Source: `rpi-eeprom/firmware-2712/latest/pieeprom-2026-09-23.bin`
sha256 `4635a1969e23f9e30494753ba8179fa684f4c21d5221231826cabb89160fc1ac`.

Reproduce: `python3 -I extract.py pieeprom-2026-09-23.bin out && bash build-elf.sh out`

Labels: **[obs]** read directly from bytes/disassembly; **[inf]** inference; **[unk]** open.

## Container

- [obs] EEPROM = chain of `55aa xxxx | len(BE32)` records, 8-byte aligned. Magic `0x55aaf44f`
  = named file: 16-byte name, LZ4 frame (content size present), 32-byte SHA-256 of plaintext.
- [obs] Files in this image: `bootmain` (0x23348), `memsys00-03.bin`, `mcb.bin`, `rp1c0fw1.bin`
  (0xa0f88), `rp1c0fw2.bin` (0xa4668), `logo.bin`, `font.bin`, plus `bootsys`, `bootconf.txt`,
  `pubkey.bin`, `cacert.der`, `bootconf.sig`, version/update-time records.
- [obs] Here RP1 fw is a standalone pair of files, not embedded in the bootloader ELF `.rodata`
  (G33KatWork's notes describe older images).

| file | size | sha256 (trailer verified) |
|---|---|---|
| rp1c0fw1.bin | 16384 | 0340e168…893deb |
| rp1c0fw2.bin | 15892 | ad1dbb80…b3beac |
| rp1c0fw.bin (fw1‖fw2) | 32276 | 7b32461d…bf0165 |

## Image layout

- [obs] fw1+fw2 are one linked image split at 16 KiB, base `0x20000000`. Evidence: fw1 vector
  table (SP `0x100029e4`, reset `0x20000215`); 144/162 fw2 string pointers fit base `0x20004000`;
  fw1 reset calls into fw2 (`0x20004631` exit, `0x20004ab8` veneer).
- [obs] Map: `0x20000000` vectors/code (fw1) → `0x20004000–0x20004ac0` newlib (exit, memcpy…)
  → `0x20004ac0–0x20007188` rodata/.data (in-place, copy is src==dst) → `0x20007188–0x20007c30`
  RAM code copied to `0x10000000` → `0x20007c30–0x20007e14` data copied to `0x10002000`.
  `.bss` `0x20006f58–0x20007188`. Stack top `0x100029e4`. VTOR set to `0x20000000`.
- [obs] IRQ1 and IRQ29 vectors point into RAM code (`0x100007dd`, `0x1000080d`); main loop
  is reached via `ldr.w pc` veneer at `0x20004ab8` → `0x1000020d`.
- [obs] Reset: core ID read from `0xe00ff01c`; nonzero core writes `0x5a55aa51` to `0x2000fff8`
  and parks in `wfe`, polling function-pointer slots at `0x20007168[core]`, calling and clearing
  them, then `sev`. Core 0 writes `0x5a55aa55` to `0x2000fffc`. [inf] boot-handshake words;
  they sit inside the host mailbox buffer `0x2000ff00–0x2000ffff` and are not refreshed, so
  they are not liveness markers (see RP1_PCIE_FAILURE_STATE_MACHINE.md).
- [obs] `main` = `0x20000d08`: NVIC_EnableIRQ `0x20000ff4`(59, 1, 29, 57, 57), init `0x20002478`,
  `gpio_init(29, 0x1f)`, GPIO29 CTRL bit20 (falling-edge int) + io_bank1 `+0x104` bit1,
  `0x400ac000` `+0x38|=8`, `+0x1c = now()+100000` [inf: 100 ms timer/watchdog], `0xf8000008|=1`,
  `0x2000399c(100,0)`, then RAM main loop.

## Function: GPIO

- [obs] `0x20001a8c gpio_init(pin, ctrl)`: bank split 0–27/28–33/34–53 (same as kernel
  `rp1_iobanks`). Pad `0x400f{0,4,8}004 + 4n`: clear bits 6–7, set bit 6 (IE=1, OD=0). Then
  writes full `CTRL` at `0x400d{0,4,8}004 + 8n` = `ctrl`. Pin > 53 falls through to RMW at address 0.
- [inf] M3 uses its own interrupt-enable at bank `+0x104`; kernel (host) uses `+0x11c`.
  axiomos-sim GPIO model may need per-processor INTE registers.
- [unk] What RP1 GPIO29 is wired to. The DTS `gpio29` bt_shutdown is BCM2712 pinctrl, not RP1.
  PERST# is a guess from the strings, not established.

## Functionality

- [obs] RAM/fw2 strings: PCIe link FSM (`COLD_RESET`, `PERST_N_DEBOUNCE`, `RX_DETECT`,
  `LINKUP_WAIT`, `HOT_RESET_ENTER`, `L23_READY`…), LTSSM names (`S_DETECT_QUIET`…),
  `RUDE: perst_n asserted during linkup`, `FATAL: core unalived itself`, `Linkup timeout!`.
  [inf] firmware's main job = RP1 PCIe endpoint link bring-up/supervision for the BCM2712 host.
- [obs] MMIO blocks referenced from code (literal-pool scan, rodata excluded):
  `0x40008000` `0x40014000` `0x40018000`(clocks) `0x4009c000` `0x400ac000` `0x400c4000`
  io_bank0–2 `0x400d{0,4,8}000` pads0–2 `0x400f{0,4,8}000` `0x40108000` `0x40150000` `0x40154000`
  `0x40160000` `0x40164000` `0x40170000` `0x40178000` `0x4017c000` `0x40180000` `0x4020c000`
  `0x40240000` `0x402c0000` `0x4030c000` `0x40400000` `0xf0004000` `0xf0007000` `0xf0008000`
  `0xf8000000` `0xe000ed08`(VTOR) `0xe00ff000`. [unk] names for most; only DTS-listed ones named.

## Address map (RP1 datasheet 2023-11-07, sha256 87fb7b24…6c3d, Table 1/2)

- [obs] `0x20000000` = Shared SRAM (64 KiB), host-visible via PCIe **BAR2**. The whole firmware
  image, `.bss`, core-1 dispatch slots `0x20007168` and liveness words `0x2000fff8/fffc` live here.
- [obs] `0x10000000` ISRAM / `0x10002000` DSRAM = 8 KiB per-core TCM (copied code, stack).
  `0x00000000` = shared boot ROM. `0x80000000` = 1 GiB outbound ATU window into host memory.
- [obs] Peripherals named: `0x40008000` syscfg, `0x40014000` resets, `0x40018000` clocks_main,
  `0x40098000/0x4009c000` pwm0/pwm1, `0x400ac000` timer, `0x400c4000` busfabric_axishim,
  `0x400d0000..` io_bank0-2, `0x400e0000..` sys_rio0-2, `0x400f0000..` pads0-2, `0x40108000` pcie,
  `0x40150000` xosc, `0x40154000` watchdog, `0x40160000/4` usbhost0/1_cfg, `0x40170000` vbusctrl,
  `0x40178000` pio, `0x40180000` sdio0, `0x40400000` exac. (Earlier "[inf] timer/watchdog" for
  `0x400ac000`: it is `timer`; the watchdog is `0x40154000`.)
- [obs] Linux `drivers/misc/rp1/rp1_pci.c` maps BAR1 (peripherals) only; BAR2 not mapped by driver.
- [obs] §3.3.1: host→RP1 writes are posted (~1 µs link latency; +2 µs L0s / +5 µs L1 ASPM wake);
  reads ≥ 2× latency; datasheet recommends write barrier then read-back to observe pin state.

## Tooling caveats

- Hopper via REA analysed `rp1c0fw.elf` (sha256 f2d192f3… for the text-only wrap). REA raw-binary
  needs Ghidra (not configured), so the image was ELF-wrapped. Hopper pseudocode for the
  hand-written reset stub was wrong; use `rp1c0fw.dis` (llvm-objdump) for exact semantics.
  Evidence: list_procedures `ev_d50593f7…342c`, pseudocode `ev_c22434e0…2981`.
- Function boundaries from Hopper cover `0x2000xxxx` only; `.ramtext` functions not enumerated.
