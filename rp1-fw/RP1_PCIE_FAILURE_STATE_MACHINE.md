# RP1 firmware runtime and PCIe failure state machine (Investigation D)

Labels:
- **V** verified, re-checked in this pass
- **V(f)** verified by the parallel fork decode (`findings-linkloss.md`), spot-checked as noted
- **I** inferred
- **U** unknown

Static evidence only.

## Memory and execution layout

| Region | Proc addr | Contents | Evidence |
|---|---|---|---|
| Shared SRAM (64 KiB) | `0x20000000` | vectors, code, rodata, `.bss` `0x20006f58–0x20007188`, mailbox `0x2000ff00–0x2000ffff` | **V** DS Table 1; reset handler literals |
| Core ISRAM (8 KiB/core) | `0x10000000` | copy of image `0x20007188–0x20007c30`: ISRs, FSM, main loop | **V** `0x200002a4` copy loop |
| Core DSRAM (8 KiB/core) | `0x10002000` | copy of `0x20007c30–0x20007e14`: FSM state; tach ring `0x10002160`; stack top `0x100029e4` | **V** |
| VTOR | `0x20000000` | set by core 0 (`0x200002be`) | **V** |

## Interrupts

IRQ numbering matches the kernel's RP1 list (KSRC `include/dt-bindings/mfd/rp1.h`).
That is **I**, supported by two independent matches: IRQ1 = IO_BANK1 is the GPIO29 edge
ISR, and IRQ29 = TIMER_3 is the alarm ISR.

| IRQ | Source | Handler | Enabled at | Role | Evidence |
|---|---|---|---|---|---|
| 1 | IO_BANK1 | `0x100007dc` | `main` NVIC_EnableIRQ(1) | GPIO29 falling-edge timestamp → ring `0x10002160` (fan tach) | **V** |
| 29 | TIMER_3 | `0x1000080c` | `main` (29) | every 100000 ticks: RPM → pwm1 CHAN2_PHASE `0x4009c03c`; peak → CHAN2_RANGE | **V** |
| 53 | PCIE_OUT | `0x10000000` | RAM loop, re-enabled at `0x10000290` | reads pcie `+0x1b4` INTS / `+0x1a4` MONITOR2, posts next FSM state | **V** vector, mask/unmask at `0x10000240`/`0x10000290`; **V(f)** register decode |
| 57 | PROC_MISC | `0x100008d0` | `main` (57, twice) | host mailbox: reads/clears syscfg PROC_EVENTS `0x40008008`, message at `0x2000ff00`, service table `0x20005cc8`, replies via HOST_EVENTS | **V** literals `0x40008000`, `0x2000ff00`, `0x20005cc8`; KSRC `rp1-mailbox.c` |
| 59 | CLOCKS_DEFAULT | `0x20000cfc` | `main` (59) | logs "CRIT: clocks resuscitated!" and returns (`0x20003904` is a print routine) | **V** |
| HardFault | — | `0x20000fe4` | — | prints "Bus fault!", then `bkpt` loop: no recovery | **V** |
| all others | — | `bkpt` stubs `0x20000188…` | — | — | **V** vector dump |

NVIC helpers: `0x20000ff4` Enable (ISER `0xe000e100`), `0x20001018` Disable (ICER).
RAM code reaches them through veneers `0x10000a70`/`0x10000a18`. **V**

## Main loop and FSM

- **V** `main` (`0x20000d08`) ends in the veneer `0x20004ab8` → `0x1000020c` (RAM loop).
- **V** The loop masks IRQ53, copies the requested next state (`+0xc` → current), then
  unmasks IRQ53 and dispatches through `tbh` at `0x100002ea`. Idle states `wfe`.
- **V(f)** State struct at `0x10002000`: `+0` current, `+0xc` ISR-requested, `+0x18`
  handler-requested. Name table at `0x20007d4c`. Handlers:

| # | State | Handler | # | State | Handler |
|---|---|---|---|---|---|
| 1 | COLD_RESET | `0x10000562` | 8 | ACTIVE2 | `0x1000035a` |
| 2 | PERST_N_RESET | `0x1000035e` | 9 | LINK_BROKEN | `0x1000035a` |
| 3 | PERST_N_DEBOUNCE | `0x1000051c` | 10 | HOT_RESET_ENTER | `0x1000063e` |
| 4 | WAIT_CORE_ALIVE | `0x100004cc` | 11 | EP_CONFIG_WAIT | `0x10000614` |
| 5 | RX_DETECT | `0x10000386` | 12 | PME_OFF_ENTER | `0x100005ea` |
| 6 | LINKUP_WAIT | `0x10000362` | 13 | L23_READY | `0x100005d2` |
| 7 | ACTIVE1 | `0x10000494` | 14 | L2IDLE | `0x100005b0` |

### Transitions on failure events (V(f) unless marked)

| Event (pcie MONITOR2 / INTS) | Action | Touches outputs? |
|---|---|---|
| PERST# assert (b17) in states 4–8, 10 | prints "RUDE: perst_n asserted…" → COLD_RESET | no |
| PERST# assert in 13/14 | COLD_RESET | no |
| PERST# deassert | DEBOUNCE (50 ticks) → WAIT_CORE_ALIVE | no |
| CORE_ALIVE drop (b16) | "FATAL: core unalived itself" → COLD_RESET (PCIe core, not M3) | no |
| LINK_RESET_REQ (hot reset) | HOT_RESET_ENTER → LINKUP_WAIT | no |
| RDLH link down (b20) | "RDLH Link down" logged, no state change | no |
| PME_TURN_OFF | PME_OFF_ENTER → L23_READY → L2IDLE | clocks only (`0x200014ec`) |
| Reset escalation | releases RESETS b26 and polls RESET_DONE `+0x18` b26 with **no timeout** (`0x10000738–0x10000746`) | no (**V**) |

**V** No transition writes io_bank, pads, sys_rio, pwm0/pwm1 or PIO, and no transition
asserts a RESETS bit. **I** A link failure can never leave a protected output in a safer
state than before. It can only stop new host writes.

## Host ↔ firmware communication

- **V** Doorbell host→M3: the host writes syscfg PROC_EVENTS SET alias (`0x40008008 + 0x2000`);
  the M3 takes IRQ57. M3→host: HOST_EVENTS `+0xc`, with host IRQ enable at `+0x10`.
  KSRC `rp1-mailbox.c:31-34,64-101`.
- **V** Payload: 256-byte buffer at shared-SRAM offset `0xff00` (host `rp1_fw_shmem`;
  fw `0x2000ff00`). The host copies in with `memcpy_toio` and waits up to `HZ` (1 s).
  KSRC `rp1-fw.c:77-104`.
- **V** Services are looked up via `GET_FEATURE` (FOURCC → op base). The "PIO " service
  has 38 ops (`rp1-fw-pio.h`) dispatched at `0x20000548`; GPIO ops call `0x20001a8c`.
- **V** Separately, platform init skips itself when RESETS b26 is clear and the link is up
  (`0x20000378`).

## Marker words

- **V** Core 0 writes `0x5a55aa55` → `0x2000fffc` (`0x20000214`). Core 1 writes
  `0x5a55aa51` → `0x2000fff8` (`0x20000276`). No other code references them (literal scan).
- **I** They are boot-handshake markers for the host bootloader. They sit inside the
  mailbox buffer and are not refreshed, so they are not liveness signals.

## Timing-sensitive paths

| Path | Timeout | Evidence |
|---|---|---|
| PERST# debounce | 50 ticks | **V(f)** |
| Tach no-edge | 500 ms → RPM 0 | **V(f)** |
| Timer IRQ period | 100000 ticks (**I** µs) | **V** `main` `+0x1c = now + 0x186a0` |
| RESETS b26 RESET_DONE poll | **none**: could hang core 0 | **V** `0x10000742` loop |
| Linkup / configure | timeouts exist ("Linkup timeout!", "Configure timeout!") | **V** strings; **U** values |
| Host RPC | 1 s (host side) | **V** KSRC |
