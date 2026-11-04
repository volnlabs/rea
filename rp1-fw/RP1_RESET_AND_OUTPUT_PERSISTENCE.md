# RP1 reset and output persistence (Investigation B)

Labels: **V** verified, **I** inferred, **U** unknown. Sources and conventions as in
`RP1_ACTUATION_AUTHORITY.md`. Static evidence only.

## Four layers of an "output"

The answers differ per layer, so each scenario below is split:

1. **Logical acceptance**: a guardian or driver accepts a command (host software).
2. **Register state**: the RP1 register holds the value (CTRL/RIO/pads/PWM).
3. **Pin level**: what the RP1 pad drives (OD, mux, peripheral waveform).
4. **Physical effect**: actuator response downstream of the pin (outside RP1).

**V** (DS §3.3.1) Layer 2 lags layer 1 by at least one posted PCIe write
("typically 1 µs"). The host gets no completion for posted writes, so acceptance
never implies register state without a read-back.

## Scenarios

| Event | Logical | Register | Pin | Basis |
|---|---|---|---|---|
| Controller process exits | Authority ends at the guardian if it revokes. | **Unchanged.** Nothing in RP1 knows about host processes. | Unchanged. | **V** no host-process coupling exists in fw or DS. **I** Linux drivers may change pins on fd close; that is a driver policy, not an RP1 mechanism. |
| Host kernel crash, no reboot | No software can revoke. | **Unchanged.** The firmware never writes PWM/GPIO/pads on link or host events. | **Persists:** PWM keeps its last duty, GPIO its last level. | **V** fw link paths (`RP1_PCIE_FAILURE_STATE_MACHINE.md`). **I** the host stops issuing writes, so nothing changes. |
| Host reboot (watchdog or user) | n/a | **U** whether RP1 is chip-reset. **V** the bootloader reloads RP1 firmware each boot; cold init is skipped when RESETS b26 is clear and the link is up (`0x20000378`). | **I** may persist until Linux pinctrl/pwm reinitialise, if RP1 is not chip-reset. | **V** skip path; **U** board reset wiring |
| PCIe link loss (link down) | Host writes are lost or stall; **revocation also cannot arrive.** | Unchanged. The fw logs "RDLH Link down" only. | **Persists.** | **V** fw ISR/FSM (LINK_BROKEN idle, no peripheral writes) |
| PERST# asserted | n/a | Firmware: no peripheral writes, FSM → COLD_RESET. Silicon: **U**. | **U** (silicon). Firmware does nothing to outputs. | **V** fw; **U** hardware PERST# domain |
| Hot reset (secondary bus reset) | n/a | Unchanged (HOT_RESET_ENTER → LINKUP_WAIT). | Persists. | **V** fw |
| L2/L3 entry | n/a | Registers unchanged; CLK_SYS/CLK_DMA → 50 MHz xosc; PLLs written all-ones at `+0x4` (`0x200014ec`). | **U**: PWM may freeze or change frequency if its clock parent is a PLL. | **V** fw writes; **I** power-down (RP2040-style PLL); **U** PWM clock parent in use |
| M3 core-0 crash (HardFault) | RPC stops (host times out at 1 s, `rp1-fw.c:90`). | Unchanged. | Persists. Tach mailbox in pwm1 CH2 stops updating. | **V** HardFault `0x20000fe4` prints "Bus fault!" then loops on `bkpt` (no recovery, no peripheral writes). **V** no watchdog is armed. |
| M3 hang | Same as crash. | Unchanged. | Persists. | **V** watchdog `0x40154000` is used only as scratch (`+0x0c..+0x20`); CTRL/LOAD never written (literal scan) |
| RP1 chip reset (power-on) | n/a | Reset values. | **Undriven:** pad OD=1, IE=0, default pulls; CTRL `0x9f` = NULL function. | **V** DS PADS table and GPIO CTRL reset; **U** what triggers a chip reset on Pi 5 besides power-up |
| Command accepted just before an authority cut | The guardian may have accepted it. | The posted write may still be in flight (PCIe) and lands ~1 µs later. PWM duty applies at the next overflow. | Changes **after** the cut. | **V** DS §3.3.1, §3.4. **I** a cut at the guardian cannot recall in-flight posted writes. |

## Can an output outlive the authority that enabled it?

**Yes, by default, at every RP1 layer.** **I** from **V**:

- Register and pin state on RP1 have no lease, expiry or heartbeat. **V** no armed
  watchdog, no lease mechanism in the DS, and no firmware path that clears outputs
  on host loss.
- PWM and PIO generate output autonomously once enabled. **V** DS §3.4; PIO SM/FIFO.
- Host failure modes that remove the authority (crash, link loss) also remove the
  only RP1-side revocation path, the host's PCIe writes.
- The only RP1 state that is undriven by construction is the chip-reset state
  (pad OD=1). **V** Nothing on the host side is known to force that reset
  independently of host software. **U** board-level RUN/PMIC wiring.

## Corrections to earlier notes

- `0x20000ff4` is **NVIC_EnableIRQ** (ISER at `0xe000e100`), not a progress marker. `main`
  enables IRQ59, 1, 29, 57. **V** `0x20000ffa` builds `0xe000e000`.
- The marker words `0x5a55aa55` (`0x2000fffc`, core 0) and `0x5a55aa51` (`0x2000fff8`,
  core 1) are written once at reset (`0x20000214`, `0x20000276`). They lie inside the
  256-byte host mailbox buffer `0x2000ff00–0x2000ffff` (KSRC `rp1.dtsi` shmem@ff00).
  **I** They are a boot-time handshake, overwritten by later mailbox traffic.
  They are not liveness signals.

## Unknowns that decide the experiments

| Unknown | Decides |
|---|---|
| Does PERST# reset RP1 peripheral/pad state in silicon? | whether host-driven PERST# is a fence |
| What resets RP1 on host reboot (PMIC/RUN, PERST#, nothing)? | persistence across reboot |
| PWM clock parent in use; L2/L3 effect | suspend behavior |
| RESETS layout (bit 26, `+0x4`, `+0x18`) | whether the host can reset peripherals via BAR1 as a fence |
| sys_rio reset values | chip-reset state of RIO-driven pins |
