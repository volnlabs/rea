# RP1 actuation authority: who can drive a Pi 5 output (Investigations A, E)

Target: RP1 Cortex-M3 firmware from `pieeprom-2026-09-23.bin` (image `rp1c0fw.bin`,
sha256 `7b32461d…bf0165`, base `0x20000000`), RP1 datasheet (2023-11-07, sha256
`87fb7b24…6c3d`, "DS"), Raspberry Pi kernel at `~/Work/proc/.pi-kernel/linux` ("KSRC").

Labels:
- **V** verified: read from bytes, disassembly, datasheet text or source.
- **I** inferred: a reasoned conclusion from V facts.
- **U** unknown.

All firmware evidence is static. Nothing here was observed on a running board.
Disassembly is `llvm-objdump` on `out/rp1c0fw.elf`. Hopper via REA produced the
function list (Evidence `ev_d50593f7…342c`); its pseudocode was unreliable for
hand-written code. Ghidra was not configured.

## A1. Registers that determine pin output

Per pin, the output is a function of four blocks:

| Stage | Register | Effect | Evidence |
|---|---|---|---|
| Function mux | io_bank`n` GPIO`k`_CTRL `0x400d{0,4,8}000 + 8k + 4`, FUNCSEL[4:0] | selects peripheral source; 31 = NULL | **V** DS GPIO CTRL table; KSRC `pinctrl-rp1.c` `rp1_gpio_fields` |
| Overrides | same CTRL, OUTOVER[13:12], OEOVER[15:14] | source / inverse / force low / force high | **V** DS; `pinctrl-rp1.c` enums |
| Registered IO | sys_rio`n` `0x400e{0,4,8}000`: OUT `+0`, OE `+4` (SET/CLR/XOR aliases) | data/enable when FUNCSEL = 5 | **V** DS §3.3 |
| Pad | pads_bank`n` `0x400f{0,4,8}000 + 4 + 4k`: OD bit 7, IE bit 6 | OD "has priority over output enable"; reset OD=1, IE=0 | **V** DS PADS table |
| Peripheral | pwm0/pwm1 `0x40098000`/`0x4009c000`; PIO `0x40178000`; others | drive the pin only when selected by FUNCSEL | **V** DS Table 2, §3.4 |

Atomic aliases are `+0x1000` XOR, `+0x2000` SET and `+0x3000` CLR for every APB block
with "Atomic Access Y" (io_bank, sys_rio, pads, pwm, timer…). **V** DS Table 2;
KSRC `rp1-mailbox.c` `HW_SET_BITS 0x2000` / `HW_CLR_BITS 0x3000`.

## A2. Who can write them

| Writer | Path | Evidence |
|---|---|---|
| BCM2712 host | PCIe BAR1 → all peripheral registers | **V** DS §2.3.1 "AP accesses Peripherals … BAR1"; KSRC `drivers/misc/rp1/rp1_pci.c` maps BAR1 |
| RP1 M3 core 0 / core 1 | 32-bit proc view `0x40000000…` | **V** DS §2 "local processors can also access peripheral … registers"; firmware writes io_bank/pads (`0x20001a8c`, `0x20001dd4`) |
| RP1 DMA controller | internal 40-bit master | **V** DS §2.2: "Bus masters other than the DMA controller cannot access peripheral registers" |
| Other bus masters (USB, Ethernet, MIPI…) | none to peripheral registers | **V** same sentence |
| Host userspace | `/dev/pio*` ioctl → firmware RPC → M3 writes CTRL/pads, any pin 0–53 | **V** KSRC `rp1-pio.c:1829-1832`; fw `0x20000b24` passes u8 `fn` as whole CTRL to `0x20001a8c` |

## A3. Can the M3 override host-written output state?

- **V** The M3 and host write the same registers. No arbitration, lock, ownership,
  privilege or access-protection mechanism appears anywhere in the datasheet text
  (bounded search over all 93 pages for lock/secure/protect/arbitrat/privilege/exclusive).
- **I** Last writer wins at register granularity. SET/CLR aliases make concurrent
  bit-level updates race-free, but they do not establish ownership.
- **V** The shipped firmware overrides host state only on request
  (`GPIO_SET_FUNCTION`/`OUTOVER`/`OEOVER`… RPCs, dispatcher `0x20000548`).
  Autonomously it writes:
  - io_bank1/pads1 for GPIO29 at boot (`main 0x20000d08` → `0x20001a8c(29, 0x1f)`)
  - parks GPIO30, 31 and 49–52 in cold init (`0x20000378` → `0x20001dd4`)
  - pwm1 CHAN2_PHASE/RANGE from the timer IRQ (`0x1000080c`)
- **V (bounded)** No boot or IRQ path writes io_bank0 (GPIO0–27, the 40-pin
  header) or pwm0. The scan covered PC-relative literals, movw/movt and decoded
  fixed bank bases; fully computed addresses could be missed.

## A4. Ownership changes at init, reset and link recovery

- **V** Cold init `0x20000378` is skipped if RESETS (`0x40014000`) bit 26 is clear
  *and* pcie `+0x1a4` bit 20 (RDLH_LINK_UP) is set (`0x2000037a…0x20000388` →
  return `0x20000462`).
  - **I** The firmware expects to be restarted without an RP1 chip reset, and
    then leaves existing pin state alone.
- **V** Cold init parks GPIO30, 31, 49, 50, 51, 52 with CTRL = `0x1f` (NULL),
  ending with pad OD=0, IE=0 (`0x20001dd4`). It also sets RESETS (`0x40014000`)
  `+0x4` bit 18 (`0x200003a8`).
  - **U** What that RESETS write means; RESETS is undocumented.
- **V** No PCIe link-event handler writes GPIO/PWM/pad/RIO/PIO or asserts a RESETS
  bit (see `RP1_PCIE_FAILURE_STATE_MACHINE.md`). Ownership never changes on
  link events.
- **V** L2 exit re-runs USB init (GPIO42/43 FUNCSEL 2) (fork decode; see
  `findings-linkloss.md`).

## A5. Hardware locks or arbitration

- **V** None for peripheral registers (A3).
- **V** The firmware uses LDREX/STREX on `0x40400000` (`exac`, AXI) with interrupts
  masked (`0x200022c8`, `0x2000232c`). It identifies the core via `0xe00ff01c`
  and writes trace words to `0x40154010`/`0x40154014`.
  - **I** An inter-processor exclusive-access lock.
  - **V** The host DT maps `0xc0_40400000` (64 KiB) as `mmio-sram` and places the
    firmware mailbox at `+0xff00` (KSRC `rp1.dtsi:1232-1242`). The firmware's
    mailbox buffer is `0x2000ff00` (IRQ57 handler literal `0x100009e4`).
  - **I** `exac` aliases the 64 KiB Shared SRAM, so the host can write the
    firmware image as well.
  - **U** Exact `exac` semantics.

## A6. Cached or shadow peripheral state in firmware

- **V** The tach ISR keeps an edge-timestamp ring at `0x10002160` (32 slots, core-local
  DSRAM) and publishes results into pwm1 registers, not SRAM.
- **V** The GPIO helpers do read-modify-write directly on pad registers and write CTRL
  without shadowing (`0x20001a8c`, `0x20001dd4`).
- **U** Whether RPC handlers cache pin state; no shadow table was identified. Bounded
  to the helpers above.

## A7. Queueing or delay before pins

| Queue/delay | Bound | Evidence |
|---|---|---|
| Host → RP1 PCIe posted writes | "typically 1 µs"; +~2 µs L0s, +~5 µs L1 ASPM wake | **V** DS §3.3.1 (typical, not worst case) |
| Store reordering on host | needs Device_nGnRE mapping + barrier | **V** DS §3.3.1.2 |
| PWM RANGE/DUTY | apply at next counter overflow | **V** DS PWM SET_UPDATE note |
| PWM CTRL/enable/PHASE | apply on SET_UPDATE, synchronized to the PWM clock | **V** same |
| PIO TX FIFO / state machines | drain autonomously at SM clock | **V** DS Table 2 (pio); **I** persists after host loss |
| RP1 DMA | executes queued transfers autonomously | **V** DMA can write peripherals; **U** whether descriptors survive host loss |
| Firmware RPC (`/dev/pio`) | host 1 s timeout; M3 dispatch latency unmeasured | **V** KSRC `rp1-fw.c:90`; **U** latency |
| Pin synchronizer / pad | not documented | **U** |

## E. Authority-boundary table

| Resource | Host authority | M3 authority | Autonomous HW | Reset behavior | Last enforceable command boundary | Physical observation point | Unknowns | Evidence |
|---|---|---|---|---|---|---|---|---|
| io_bank CTRL (mux, overrides) | full via BAR1 | full; also via RPC | none | chip reset → `0x9f` (NULL, F_M 4) **V**; link events: untouched **V** | APB write commit | pin (scope/LA) | sync latency **U** | DS; `0x20001a8c` |
| sys_rio OUT/OE | full via BAR1 | full | none | **U** reset values | APB write | pin | reset value **U** | DS §3.3 |
| pads OD/IE | full via BAR1 | full | none | chip reset → OD=1, IE=0 (undriven, default pulls) **V** | APB write | pin | PERST# effect **U** | DS PADS table |
| pwm0/pwm1 | full via BAR1 | full; fw writes pwm1 CH2 PHASE/RANGE | counter runs indefinitely once enabled | link events: untouched **V**; chip reset → disabled **I** | SET_UPDATE then overflow | pin waveform | clock-parent effects in L2/L3 **U** | DS §3.4; `0x1000080c` |
| PIO | full via BAR1; RPC | full | SMs + FIFOs run autonomously | link events: untouched **V** | FIFO push / SM enable | pin | FIFO drain on host loss **I** | DS; `rp1-fw-pio.h` |
| DMA | configures | can configure | executes autonomously, can write peripherals | **U** | descriptor start | indirect | everything **U** | DS §2.2 |
| Shared SRAM (fw image, mailbox) | write via BAR2/`exac` window | execute/write | none | **U** | n/a | none | write protection **U** | DS Table 1; `rp1.dtsi` |
| M3 core-local TCM | **none** (no system address) | own core only | none | **U** | n/a | none | debug access **U** | **V** DS Table 1 ("local to each proc", system addr n/a) |

### Where authority can be revoked

| Point | Revocable? | Why |
|---|---|---|
| Host software interface (guardian, driver, `/dev/pio`) | only for writers that honour it | **V** BAR1/BAR2/`/dev/pio`/DMA are parallel paths |
| RP1 register interface | no | **V** no ownership or protection; any of host, M3 or DMA can rewrite |
| Peripheral output stage (pad OD) | yes, but by anyone | pad OD defeats any mux/override (**V**), and any writer can clear OD again |
| External hardware gate (MCU/FPGA beyond the RP1 pin) | **yes** | the only point no RP1-side writer can override (**I**, given correct wiring) |
