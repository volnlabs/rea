# Decisive Pi 5 experiments for timed actuation finality (Investigation G)

None of these were run. Experiments marked **[AUTH]** need explicit authorization
before execution, because they load modified RP1 code, disturb PCIe (which takes
down RP1-hosted USB/Ethernet and can hang the host), or power-cycle hardware.
No experiment flashes the EEPROM.

## Common bench

- **Device under test (DUT) pin:** header GPIO12 (pwm0 ch0), into a 1 kΩ resistor
  and LED, or a scope input only. No actuator or motor, and no mains.
- **Gate (P3) experiments:**
  - an external MCU with its own crystal (e.g. RP2040/STM32), lease timer,
    epoch/sequence check, and an output stage whose reset state is low
  - the DUT pin goes to an MCU input; the MCU output goes to the LED
- **Capture:** an independent logic analyzer at ≥ 50 MS/s on:
  - (a) the DUT pin
  - (b) the MCU gate output
  - (c) the cut marker
  - (d) PERST#, where accessible on test pads (**U** availability)

  The analyzer clock is the time reference.
- **Cut marker:** the authority service raises a dedicated marker line at `t_cut`. If the
  marker is an RP1 GPIO, it shares the PCIe latency of the path under test. Use an
  MCU-side timestamp of the cut message, or a separate USB-GPIO device, and record
  the marker's own latency as a measured offset, not a bound.
- **Per run, record:** RP1 firmware hash (`rp1c0fw.bin` 7b32461d…), kernel version,
  `/sys/.../aspm` policy, PWM clock config, and the raw captures with SHA-256.

The stale-authority interval is the time from `t_cut` to the last DUT/gate transition
attributable to the retired authority.

## E1. Revocation after command enqueue

- **Falsifies:** "a guardian-level cut prevents all post-cut output changes" (H1).
- **Setup:** P1. Revoke while a duty change is (a) in the guardian queue,
  (b) issued as a posted write, (c) latched awaiting PWM overflow. Use a long PWM
  period (e.g. 10 ms) to widen window (c).
- **Baseline:** the cut issued with no pending command.
- **Expected (from static evidence):**
  - (a) rejected
  - (b) lands after `t_cut` (~µs)
  - (c) applies at the next overflow after `t_cut` (≤ 1 period)
- **Failure criteria for H1:** any DUT change attributable to the retired authority
  after `t_cut`.
- **Also measure:** the posted-write delay distribution, with ASPM on and off (M only).

## E2. Host crash with a persistent output active

- **Falsifies:** "loss of host execution ends RP1 output" (H2).
- **Setup:** PWM 1 kHz 50% on GPIO12, then `echo c > /proc/sysrq-trigger` (kernel panic).
  Separately, a hang (panic without the watchdog reboot). Then let the watchdog reboot.
- **Baseline:** orderly `pwm` disable before the crash.
- **Expected:**
  - the waveform continues unchanged after panic (**V** no fw path)
  - during reboot: **U**. The firmware warm-restart skip (`0x20000378`) predicts
    persistence until Linux reinitialises pinctrl/pwm, unless the board resets RP1.
- **P3 variant:** the gate output must drop within `R_lease + R_gate` of the last
  heartbeat.
- **Failure criteria:** H2 is falsified if the waveform persists. P3 fails if the gate
  output persists past its bound.

## E3. PCIe link loss during active output **[AUTH]**

- **Falsifies:** "RP1 returns outputs to a safe state on link loss" (H3), and "the
  host can revoke during link loss" (H3b).
- **Setup:** PWM active, then trigger:
  - (a) ASPM L1 entry/exit, the least invasive
  - (b) secondary bus reset on the RP1 root port (hot reset)
  - (c) PERST# assertion via RC driver unbind, if available
  Attempt a revocation write during the outage.
- **Expected:**
  - the output persists in (a–c) (**V** fw paths)
  - the revocation write is lost or blocked
  - firmware log (if a console is captured) shows "RDLH Link down" /
    HOT_RESET_ENTER / "RUDE: perst_n…"
- **Failure criteria:** H3 is falsified if the output persists. If the output stops on
  PERST#, the silicon resets peripherals on PERST#; record it as a new **V**, which
  promotes PERST# to a candidate fence.
- **Capture:** LA on the DUT pin and PERST# (if probeable). Host `dmesg` and the RP1
  UART (**U** availability).

## E4. RP1 reset during active output **[AUTH]**

- **Falsifies:** "an RP1 chip reset leaves outputs undriven" (H4; expected true by DS
  pad reset OD=1).
- **Setup:** PWM active, then (a) a full board power cycle, the only reset known to
  reach RP1. Also try (b) any host-controllable RP1 reset found in E3(c) or board docs.
- **Expected:** on reset entry the DUT pin goes undriven (pull default) within the
  reset assertion time. Logic level depends on the pull and load.
- **Failure criteria:** H4 is falsified if the pin is actively driven after reset
  assertion.
- **Also record:** time from power-good to first RP1 drive (the boot ordering term).

## E5. Independent Cortex-M3 monitoring during host failure **[AUTH, modified RP1 code]**

- **Falsifies:**
  - "a core-1 guardian bounds output after benign host failure" (H5a)
  - "a core-1 guardian resists a running retired domain" (H5b; expected false)
- **Setup:**
  - a guardian on M3 core 1, running from its own TCM
  - host heartbeat via a shared-SRAM counter
  - timeout T, after which it forces pad OD=1 on GPIO12
  - deployment requires a core-0 SEV hook (shipped firmware never wakes core 1)
- **Runs:**
  - (a) host panic
  - (b) link loss
  - (c) the "retired" domain keeps running and rewrites pads/CTRL via BAR1 after the
    guardian acts
- **Expected:** (a)/(b) DUT undriven within T + ε. (c) the retired domain re-enables
  output and the guardian can only contend.
- **Failure criteria:** H5a fails if any (a)/(b) run exceeds T + analysed ε. H5b is
  confirmed false if (c) shows any re-enabled interval.

## E6. Stale command rejection after recovery

- **Falsifies:** "after recovery, no command issued under a retired epoch takes effect"
  (H6).
- **Setup:**
  1. P3 gate with epoch E.
  2. Enqueue a command under E (in the host guardian queue and in flight).
  3. Cut E → E+1.
  4. Crash/reboot the host (E2), or link loss (E3).
  5. After recovery, replay the queued E commands, including verbatim retransmits of
     the last pre-cut command and a non-idempotent toggle.
- **Baseline:** P1 (no gate), where replay is expected to take effect.
- **Expected:** the gate rejects every E-tagged command. A pre-cut non-idempotent
  command whose completion was not acknowledged is reported **uncertain**, not
  re-executed.
- **Failure criteria:** any E-tagged change at the gate output after the cut, or
  automatic re-execution of an uncertain command.

## E7 (baseline). Guardian without sink exclusivity

- **Falsifies:** "a correct host guardian alone gives finality on Pi 5" (kill criterion 1).
- **Setup:** P1 guardian correct, but a retired domain retains one bypass:
  - (a) BAR1 `resource1` write to GPIO12 CTRL/pads
  - (b) `/dev/pio0` `GPIO_SET_OUTOVER`
  - (c) RP1 DMA to the pwm0 registers
- **Expected:** each bypass moves the DUT pin after `t_cut`; none moves the P3 gate output.
- **Failure criteria:** the P1 guardian's claim fails on any bypass movement. The P3 claim
  fails if any bypass moves the gate output.

## Hypothesis → experiment map

| Hypothesis | Static prediction | Experiment |
|---|---|---|
| H1 cut stops in-flight effects | false (posted writes, PWM overflow) | E1 |
| H2 host loss ends output | false | E2 |
| H3 link loss → safe output | false (fw); silicon **U** | E3 |
| H4 RP1 reset → undriven pads | true (DS) | E4 |
| H5a core-1 guardian bounds benign failure | plausible | E5 |
| H5b core-1 guardian resists a running retired domain | false | E5c |
| H6 stale epoch rejected after recovery | true only with a gate | E6 |
| Host guardian sufficient without exclusivity | false | E7 |
