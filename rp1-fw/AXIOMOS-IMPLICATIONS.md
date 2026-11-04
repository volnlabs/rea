# What RP1 reverse engineering means for the AxiomOS actuation-authority brief

Input: *AxiomOS Actuation Authority Architecture and Literature Review* (4 Nov 2026).
Evidence: `NOTES.md`, `findings-actuators.md`, `findings-linkloss.md` in this directory, the RP1
datasheet (2023-11-07, sha256 87fb7b24…6c3d), and the Pi kernel at `~/Work/proc/.pi-kernel/linux`.
Labels: [obs] observed in bytes/source/datasheet; [inf] inference; [unk] needs measurement.

Every claim below is static. None of it was observed on a running Pi 5.

## 1. Who can cause physical output on a Pi 5 (Figure 1 trust boundary)

On a Pi 5, RP1 is a programmable coprocessor that sits between any software guardian and the pins.
These principals can drive or reconfigure RP1 outputs without going through a host-side guardian:

| # | Principal | Path | Evidence |
|---|---|---|---|
| A | Any kernel domain mapping BAR1 | direct writes to io_bank/pads/rio/pwm | [obs] `rp1_pci.c` maps BAR1 = all peripherals |
| B | Anything that can write BAR2 | rewrites the *running* M3 firmware, data and core-1 dispatch slot `0x20007168` | [obs] fw runs from Shared SRAM `0x20000000` = BAR2 (datasheet Table 1); [unk] runtime write protection |
| C | Userspace with `/dev/pio*` | firmware RPC `GPIO_SET_FUNCTION/OUTOVER/OEOVER…` on any pin 0–53; bypasses pinctrl/gpiolib ownership | [obs] `rp1-pio.c` ioctl table, fw dispatcher `0x20000548`, no pin whitelist; [unk] node permissions |
| D | RP1 M3 firmware itself | autonomous writes only to pwm1 CHAN2 PHASE/RANGE (fan tach mailbox) | [obs] IRQ `0x1000080c`; no autonomous write to io_bank0/pwm0 (bounded scan) |
| E | RP1 M3 as bus master | 1 GiB outbound ATU window into host memory | [obs] datasheet §2 |

Consequences:
- **Cut soundness and non-escalation fail if any of A–C remain reachable** by a retired or untrusted
  domain. On Pi 5, owning an actuation sink means exclusive control of BAR1, BAR2 and the PIO RPC
  channel, not owning a driver or IPC endpoint. That is the brief's 1.2 principle ("possessing a
  channel is not authority") with concrete bypasses.
- **RP1 cannot be the final gate.** It has no armed watchdog [obs], keeps outputs through host
  failure (§3), and is reprogrammable from the host (B). This is static support for the brief's
  separate MCU/FPGA gate, and it decides **kill criterion 2** for Pi 5: RP1 alone exposes no
  defensible finality point, so the finality point must be the external MCU's output stage.
- **For Phase B, the MCU must generate the PWM itself.** If the actuator pin is an RP1 pin, A–C
  are live bypasses of the device gate.
- E: any Pi 5 isolation or DMA claim must include RP1 as a DMA-capable master (brief §3 warning).

## 2. Terms in Δ_final

- **R_device lower bound** [obs, datasheet §3.3.1]: host→RP1 writes are posted, with ~1 µs link
  latency. ASPM adds ~2 µs (L0s) or ~5 µs (L1) to the first access after idle. A read-back costs
  at least twice the link latency. Disable ASPM in experiments, or carry the wake penalty in the bound.
- **Acceptance ≠ effect, in hardware**: a retired store or accepted MMIO write is not a pin change.
  The guardian log needs separate events for *issued* (store), *confirmed* (write barrier +
  read-back per datasheet), and *captured* (logic analyzer). This is the Multikernel
  ACK-before-park distinction one layer lower.
- **R_physical-drain for PWM**: per-channel RANGE/DUTY changes apply at the next period overflow
  (datasheet §3.4; already modeled in `RP1_PWM.cs`). A "stop" write can take up to one PWM period.
- **RPC path (C)** adds an M3 mailbox round trip plus a firmware dispatch of [unk] latency. Measure
  it if C stays in scope, even as an adversarial baseline.

## 3. Persistence and recovery (invariants, Phase A traces)

- [inf, from obs] **RP1 firmware never resets GPIO/PWM/PIO on PERST#, hot reset, link down or host
  crash.** No link-event path asserts RESETS or writes output blocks. [unk] whether silicon resets
  them on PERST#.
  → Trace "persistent PWM remains energized after controller quiescence" is the *default* on Pi 5.
  Killing or kexec'ing the host domain leaves the last duty cycle running. Quiescence accounting
  needs an explicit output-stop step, or an external gate that drops output when it hears nothing.
- **No device-side dead-man on RP1** [obs]. The watchdog block is used only as scratch/boot magic.
  Liveness must be enforced by the external MCU watchdog.
- **L2/L3 is not a safe stop** [obs/inf]: entry moves system clocks to xosc and powers down PLLs.
  If the PWM clock parent is a PLL (clk-rp1 lists pll_video_sec), the output may freeze or change
  frequency rather than stop. Classify suspend-during-actuation as *uncertain*.
- **Recovery safety**: hot reset re-trains the link without touching peripherals [obs], so a
  recovering host inherits live RP1 output state. Recovery must read back RP1 output state before
  deciding completed / rejected / uncertain. It must not assume reset-to-default.

## 4. Phase B additions grounded in this

Extra fault injections:
1. Host kernel panic / forced domain halt while PWM is active → measure output persistence (§3).
2. PCIe secondary bus reset (hot reset) while active → confirm firmware-path persistence on hardware.
3. ASPM on vs off → measure the R_device wake penalty.
4. Bypass attempts from a "retired" domain via BAR1 (`resource1`), BAR2 (`resource2`) and `/dev/pio0`
   → each must fail to move the *final MCU output*. Any that moves an RP1 pin shows why the gate
   must sit beyond RP1.

Extra baseline (strengthens the novelty claim):
- **Guardian without sink exclusivity**: correct epochs and fences on the guardian path, but A–C
  left open. Expect stale-authority output via bypass. This shows the bound needs device-path
  exclusivity, which an ordinary reference monitor plus sequence numbers (kill criterion 1)
  does not provide.

## 5. axiomos-sim model corrections

- PWM: firmware writes pwm1 CHAN2_PHASE/RANGE as a mailbox, and `RP1_PWM.cs` rejects PHASE. Add
  PHASE storage before running firmware-faithful scenarios.
- GPIO: the M3 uses a per-processor interrupt-enable register at bank `+0x104`; the host uses
  `+0x11c`. Model both.
- Reset semantics: host/PCIe reset must not reset modeled RP1 outputs (§3), or the sim will
  understate stale-output intervals.
- Optional: model the PIO/GPIO RPC channel (path C) as an alternate actuation principal.

## 6. Open questions for hardware measurement

| Question | Why it matters |
|---|---|
| Does silicon reset RP1 peripherals on PERST#? | decides §3 persistence on real hardware |
| RESETS bit 26 identity | completes the reset map |
| Is BAR2 writable from host at runtime? | decides whether principal B is real |
| `/dev/pio*` permissions on the target distro | decides whether principal C is unprivileged |
| PIO RPC round-trip latency | R term for path C |
| PWM clock parent in use | §3 L2/L3 behavior |
