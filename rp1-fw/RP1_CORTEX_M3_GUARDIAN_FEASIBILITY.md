# Could an RP1 Cortex-M3 core be an independent safety guardian? (Investigation C)

Labels: **V** verified, **I** inferred, **U** unknown. Static evidence only.
A running second core is not evidence of isolation; each property is assessed separately.

## Current state of core 1

- **V** At reset, both cores enter `0x20000214`. The core ID comes from `0xe00ff01c`
  (literal pool `0x200002e4` → `0x200002f0`). A nonzero ID branches to the park loop
  at `0x20000276`.
- **V** The park loop:
  - writes `0x5a55aa51` to `0x2000fff8`, then waits in `wfe` (`0x20000284`)
  - loads the function pointer `0x20007168[core]`
  - if it is nonzero: calls it, clears the slot, executes `sev`, and loops
- **V (bounded)** Only the park loop references the slot table `0x20007168` (literal at
  `0x2000034c`). No core-0 code writes a slot.
- **V** Core 0 executes `sev` once, at the end of cold init (`0x2000045c`). The only other
  `sev` is core 1's own (`0x200002a0`).
- **I** In shipped firmware core 1 runs nothing. After the boot-time event it sleeps
  until a SEV or debug event. Writing a slot from the host is not enough on its own: no
  shipped path generates the event that wakes core 1. Core 1's NVIC is never configured,
  so SEVONPEND interrupts are not a wake path either.
- **I** Running guardian code on core 1 therefore requires modifying the firmware: a
  core-0 hook that issues SEV, or a changed EEPROM image. That needs explicit
  authorization, and may interact with signed boot (`bootconf.sig` and `pubkey.bin`
  are in the EEPROM).

## Resources a core-1 guardian would have

| Need | Available? | Evidence |
|---|---|---|
| Write GPIO/pad/PWM | yes, same registers as everyone | **V** DS §2; A3 |
| Force a safe pin state | yes: pad OD=1 overrides any mux/override | **V** DS PADS ("OD has priority over output enable") |
| Private code/data the host cannot write | yes: per-core ISRAM/DSRAM (8 KiB each) has no system address | **V** DS Table 1 ("local to each proc", system addr n/a) |
| Own timebase | SysTick and NVIC are per-core (PPB internal) | **V** DS Table 1; standard Cortex-M3 |
| Shared timer alarm | timer `0x400ac000`; fw uses alarm 3 (IRQ29) | **V** IRQ29 = RP1_INT_TIMER_3 (KSRC `dt-bindings/mfd/rp1.h`) matches fw; **I** alarms 0–2 free |
| GPIO interrupts | PROC1_INTE/INTS `+0x110/+0x118` per bank | **V** DS io_bank register list |
| Host heartbeat input | Shared SRAM word or syscfg PROC_EVENTS doorbell (IRQ57, shared by both cores) | **V** KSRC `rp1-mailbox.c:27-34`; **I** routing PROC_EVENTS to core 1 needs core-1 NVIC setup |
| Detect link loss / PERST# | pcie `+0x1a4` bits 17 (PERSTN), 20 (RDLH_LINK_UP); `+0x1b4` INTS | **V** fw usage (`0x10000000`, `0x20000382`) |
| Self-supervision (watchdog) | **U.** The watchdog block `0x40154000` is undocumented; fw uses only scratch offsets | **V** fw; **U** reset capability |
| Run without PCIe | yes | **I** cores run from TCM/SRAM on RP1 clocks; L2/L3 moves clk_sys to 50 MHz xosc (`0x200014ec`), does not stop it |

## Independence assessment

| Property | Result | Basis |
|---|---|---|
| Independent of host **execution** (crash, hang) | **achievable** | **I** a core-1 loop with its own SysTick and a host heartbeat timeout does not need the host to run |
| Independent of **PCIe availability** | **achievable** | **I** link status is readable locally; link loss does not stop the M3 |
| Independent of host **writes** (adversarial or buggy host) | **no** | **V** the host keeps BAR1 write access to every output register and can clear OD after the guardian sets it; no protection mechanism exists |
| Code integrity against host | partial | **V** TCM is not host-addressable. **I** the guardian must be loaded via shared SRAM (host-writable) before it copies itself to TCM, so the host is still in the loading chain |
| Independent of core-0 firmware | partial | **V** PRIMASK critical sections are per-core and do not block core 1. **I** shared APB/AXI and the `exac` lock can delay core 1; core 0 can also write the same registers |
| Fate-sharing with RP1 power/clock/reset | **no independence** | **I** same die, supply, clocks and reset domain; RP1 chip reset kills the guardian (but also leaves pads undriven, **V**) |
| Boot/reset ordering | guardian starts only after the host bootloader loads RP1 firmware | **I** the bootloader reloads RP1 firmware every boot; warm restart skips platform init (`0x20000378`) |
| Safe-state recovery | guardian can set OD=1, then hold it by periodic re-assertion | **V** semantics; **I** re-assertion gives a bounded contest window, not exclusion |

## Verdict

**I** A core-1 guardian is technically plausible as a **fail-safe for benign host
failure**: host crash or hang, kernel panic, PCIe link loss. It needs a host heartbeat
(shared-SRAM counter or doorbell) and a timeout, after which it forces OD=1 on
protected pins. Its detection-to-pin latency is analytically boundable under stated
assumptions: heartbeat period + timeout + core-1 loop/ISR latency + one APB write.

It is **not an independent enforcement boundary**:

1. The host can override it at any time (no register ownership).
2. The host is in its loading chain (shared SRAM, bootloader).
3. It shares power, clock and reset fate with the outputs it guards.
4. No verified watchdog supervises it.
5. Deploying it requires modified RP1 firmware.

Under AxiomOS's threat model (a retired or untrusted domain may keep running and
writing), it cannot provide timed actuation finality on its own.
