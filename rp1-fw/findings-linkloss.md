# RP1 firmware: PCIe link loss, reset, watchdog (Q2/Q3)

Labels: [obs] bytes/disassembly/source; [inf] inference; [unk] open.

## Link FSM
- [obs] State struct `0x10002000` (`+0` cur, `+0xc` ISR-requested, `+0x18` handler-requested).
  Names table `0x20007d4c`; dispatch `tbh` at `0x100002ea`.
- [obs] Handlers: 1 COLD_RESET `0x10000562`, 2 PERST_N_RESET `0x1000035e`, 3 DEBOUNCE `0x1000051c`,
  4 WAIT_CORE_ALIVE `0x100004cc`, 5 RX_DETECT `0x10000386`, 6 LINKUP_WAIT `0x10000362`,
  7 ACTIVE1 `0x10000494`, 8 ACTIVE2 / 9 LINK_BROKEN `0x1000035a` (idle wfe), 10 HOT_RESET_ENTER
  `0x1000063e`, 11 EP_CONFIG_WAIT `0x10000614`, 12 PME_OFF_ENTER `0x100005ea`, 13 L23_READY
  `0x100005d2`, 14 L2IDLE `0x100005b0`.
- [obs] ISR `0x10000000` reads pcie `+0x1b4` (INTS); `+0x1a4` gives PERSTN b17, CORE_ALIVE b16,
  RDLH_LINK_UP b20.

| Event | Firmware action [obs] |
|---|---|
| PERST# assert in states 4–8,10 | "RUDE…" → COLD_RESET |
| PERST# assert in 13/14 | COLD_RESET silently |
| PERST# deassert | 50-tick debounce → WAIT_CORE_ALIVE |
| PCIe CORE_ALIVE drops | "FATAL: core unalived itself" → COLD_RESET (PCIe core, not M3) |
| Hot reset | HOT_RESET_ENTER → LINKUP_WAIT |
| RDLH link down | logged only |
| PME_TURN_OFF in ACTIVE1/2 | PME_OFF_ENTER (else warning) |

## Peripheral persistence
- [obs] No link-event path *asserts* any RESETS bit. RAM code `0x10000738` only releases
  RESETS b26 (`bic 0x4000000`) and polls RESET_DONE `+0x18`. Cold init `0x20000378` releases all but
  b26. RESETS is undocumented in the datasheet; [unk] b26 identity (likely PCIe core).
- [obs] No link-event path writes pwm0/pwm1, io_bank, pads, sys_rio or pio.
- [inf] **RP1 GPIO/PWM/PIO outputs persist across PERST#, hot reset, link down and host crash**
  as far as firmware is concerned. [unk] whether RP1 hardware resets them on PERST# — measure.
- [obs] L2/L3 entry `0x200014ec`: CLK_SYS/CLK_DMA (`0x40018014`/`0x40018044`) → 50 MHz xosc;
  pll_sys/audio/video (`0x4002{0,4,8}000`) `+0x4 = 0xffffffff` [inf: power-down, RP2040-style PLL].
  [unk] whether a running PWM's selected clock parent dies (clk-rp1.c pwm parents include
  pll_video_sec). L2 exit re-runs USB init (GPIO42/43 FUNCSEL 2).

## Watchdog / timer / fan
- [obs] Watchdog `0x40154000` never armed; only `+0x0c..+0x20` written (scratch-style: lock
  self-test, boot magic `0xb007c0de` + core-1 park entry `0x20000277`). Literal scan; computed
  addresses could be missed.
- [obs] Timer `0x400ac000` ALARM → IRQ29 `0x1000080c` every 100000 ticks [inf: µs].
  IRQ1 `0x100007dc` timestamps GPIO29 falling edges (32-slot ring `0x10002160`).
- [obs] IRQ29 writes fan RPM to pwm1 CHAN2_PHASE `0x4009c03c` (0 if no edge in 500 ms); peak RPM
  in CHAN2_RANGE[27:0]; pulses/rev from CHAN2_RANGE[31:28]. Host `pwm-fan` reads it via
  DT `rpm-regmap=<&rp1_pwm1>; rpm-offset=<0x3c>` and drives the fan on pwm1 ch3 / GPIO45.
  → GPIO29 = fan tach input; PWM1 CHAN2 = register mailbox, not an output [inf: not pinmuxed].
