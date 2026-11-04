# Composed actuation-finality chain: Pi 5 → RP1 → CAN → ODrive v3 → DRV8301 → motor

Step 3 of the AxiomOS reverse-engineering programme. This combines:

| Area | Docs | Evidence |
|---|---|---|
| RP1 | `../rp1-fw/RP1_*.md` | static firmware/datasheet/kernel evidence |
| ODrive v3 | `../odrive/ODRIVE_COMMAND_LIFECYCLE.md` | source at `3a2e4dd1` |
| Gate | `../odrive/STM32_BREAK_GATE.md` | RM0090 Rev 22, DS8626 Rev 12, DRV8301 Rev F |

`chain_model.py` is an explicit-state model of the composed chain (self-checking, 128
configurations, with a liveness guard against vacuous results).

Labels: **V** verified in a cited artifact; **I** inferred; **M** model result (holds for
the model, not yet observed on hardware); **U** unknown. Nothing here was run on hardware.

## 1. The chain and where each stage keeps state

| # | Stage | Holds / queues | Persists after its authority dies? | Can revoke? | Evidence |
|---|---|---|---|---|---|
| 1 | Authority service (Actryn) → epoch | current epoch | — | yes (defines the cut) | design |
| 2 | Host guardian (Pi 5, BCM2712) | command queue | lost on host crash | yes, for traffic it mediates | design |
| 3 | Pi 5 → RP1 (PCIe) → SPI/USB CAN adapter | posted writes, adapter TX mailboxes | in-flight writes land after the cut; outputs persist | **no**: the revocation path is the failing path | **V** RP1 docs §A7, §B |
| 4 | Bypass paths | BAR1, BAR2, `/dev/pio`, RP1 DMA, any bus node | yes | no | **V** RP1 §A2; ODrive F7 (no sender identity) |
| 5 | CAN bus | frames in arbitration | until delivered or lost | no | ODrive F7 |
| 6 | ODrive input register | `input_torque_`/`input_vel_` | **yes**, indefinitely; survives disarm and re-arm | only by overwrite | **V** ODrive F3, F4, F6 |
| 7 | ODrive watchdog | counter | fed by any frame | only as a traffic timeout, off by default | **V** ODrive F1, F2 |
| 8 | STM32 timer (MOE) | PWM compare values | yes, under a non-faulting stall | only if the CPU executes | **V** gate doc G3 |
| 9 | DRV8301 EN_GATE | — | — | **yes**, independent of the STM32 | **V** TI §7.4.1 |
| 10 | Motor | current, momentum | electrical decay plus coasting | physics | — |

## 2. What the composed model shows

`P1` (finality): more than D ticks after the cut, no power-on state has a setpoint last
written by the retired epoch.

**M** (exhaustive, 128 configurations of 7 flags, none vacuous): P1 holds **iff** one of:

| Architecture | Conditions | Why weaker designs fail (shortest counterexample) |
|---|---|---|
| **P3b: gate on the power path *and* the command path** | none of the other flags matter | — |
| P3a: power-only gate | A has **no** bypass path *and* transport is FIFO | **Setpoint hijack**: B sends a fresh setpoint → B renews the lease → A writes the drive via a bypass → torque flows on A's command under B's lease |
| P1: host guardian, no gate | watchdog on, no polls, no bypass, bounded transport, B writes before arming, **all five** | A arms → cut → A bypasses the guardian → stale torque forever |

Consequences:

1. **I/M** The final gate must mediate **both** energy and commands. The
   `../rp1-fw` and brief Figure 1 "MCU/FPGA final gate" sits on the energy path. The model
   shows that is not enough when the retired domain can still reach the drive's command
   interface, because the drive does not check epochs (ODrive F7). Either the gate is
   the drive's only command source and drops stale epochs, or the drive itself checks epochs.
2. **I** Bounded transport is a host-only precondition that Pi 5 cannot meet. RP1
   link loss and CAN outages are unbounded (`RP1_FINALITY_BOUND_ANALYSIS.md`). With the
   P3b gate, transport delay costs only availability (lease expiry causing a false refusal).
3. **M** The P3a "no bypass" result relies on FIFO transport. **I** CAN priority
   arbitration and multiple TX mailboxes can reorder frames, so a late pre-cut frame can
   land after B's first setpoint. On CAN, use P3b.

## 3. The brief's five adversarial traces, under P3b

| Trace (brief §6 Phase A) | Outcome | Mechanism | Evidence |
|---|---|---|---|
| T1 revoked after enqueue, before dequeue | **rejected** | guardian epoch check at dequeue; if it is bypassed, the gate filter drops the frame | M; design |
| T2 controller killed after acceptance, before ack | **completed before the cut, or rejected**; power off ≤ D after the cut | the frame may still land after the cut (RP1/CAN) and the gate drops it; power closes on cut notification or lease expiry | **V** RP1 §A7; M |
| T3 guardian resets after actuation, before recording completion | **uncertain** (non-idempotent op not replayed) | recovery marks the op uncertain; the gate re-grants only to a new epoch with a fresh setpoint | M (P2: replay ⇒ 2 executions; mark-uncertain ⇒ ≤ 1) |
| T4 persistent PWM after controller quiescence | **energy removed ≤ D**; RP1/STM32 PWM registers may still run | RP1 PWM persists (**V**), ODrive setpoint persists (**V**); only EN_GATE removes energy | **V**; M |
| T5 independent authority re-authorizes the same command after the cut | **permitted**, because it is supported by epoch 8 | the model tracks writer epoch, not value; physical capture cannot distinguish equal values, so the gate log must attribute them | M |

## 4. Composed bound (P3b)

`Delta_final <= R_cut + min(R_notify, T_lease) + WCET_gate + t_AND + t_DRV + t_discharge + R_drain`

| Term | Class | Basis |
|---|---|---|
| R_cut | A (authority service implementation) | design |
| R_notify (authority → gate, direct) | A if a dedicated link; otherwise covered by T_lease | design |
| T_lease | A (configured) | design |
| WCET_gate | A (static analysis) | gate firmware |
| t_AND | A | logic datasheet |
| t_DRV (EN_GATE↓ → gate driver off) | **M only**: TI says "immediately", no maximum | **V** TI §7.4.1 |
| t_discharge (gates through `Rgate_off` ≤ 2.4 kΩ) | A with the FET Qg/Ciss | **V** TI table + FET datasheet |
| R_drain electrical | A/M (L/R) | motor |
| R_drain mechanical | M (coasting) | load |

**Terms that drop out of the upper bound** (I): host scheduler, IPC, guardian queue,
PCIe/RP1 (`R_device`), CAN, ODrive firmware, STM32 timer. They affect availability only.

**Still measured, not bounded:** `t_DRV`, mechanical drain, and, if the gate learns of
the cut over a shared bus, `R_notify` (use T_lease instead).

## 5. Assumptions required (all must be stated in the paper)

1. **Single energy choke point:** the motor bridge is enabled only through
   `EN_GATE_DRV = EN_GATE_MCU AND LEASE_OK`. No RP1 pin or other path energizes the
   actuator.
2. **Single command choke point:** the drive's command bus is reachable only through the
   gate, which drops non-current epochs. Otherwise every retired domain must be
   physically off the bus.
3. Gate: own clock; fail-closed `LEASE_OK` (pull-down; reset or unpowered means off).
   Latch low ≥ 20 µs, and never emit a 10–20 µs pulse (**V** TI §7.4.1).
4. Lease renewed only by authenticated, current-epoch messages, never by traffic
   (closes ODrive CX2).
5. Re-grant only after a fresh setpoint under the new epoch (closes ODrive CX3).
6. Recovery marks unacknowledged non-idempotent operations uncertain; it never replays them.
7. Analysed WCET for the gate's check → pin path.
8. The DRV8301 stays within PVDD functional range (**V** TI §7.3.5 condition) and is not
   in the undocumented "unresponsive" state.

## 6. Kill criteria from the brief

| Kill criterion | Status | Evidence |
|---|---|---|
| A reference monitor + sequence numbers + response-time analysis proves the same | **Partly triggered.** The P3b gate *is* a reference monitor with epochs. The contribution must be (a) its placement on both paths, (b) the counterexamples showing weaker placements fail, (c) the composed bound and recovery rule. A host-side monitor alone does not suffice | M (P1 row) |
| The device cannot expose a defensible finality point | RP1: **triggered**. ODrive v3: **not triggered** via EN_GATE, but `t_DRV` has no specified maximum | **V** RP1 docs; **V** TI §7.4.1 |
| Full mechanism no better than a safety-MCU baseline | **Not triggered in the model.** The power-only safety-MCU gate (P3a) allows setpoint hijack under the new authority's lease; P3b does not | M |
| PAC-Bayes promotion | out of scope here | — |

## 7. Minimal decisive experiment set

These merge the RP1 E-series, the ODrive R-series and the gate B-series. All need a bench
(low-voltage supply, current-limited, guarded rotor) and an independent logic analyzer
plus CAN sniffer. Each one needs **[AUTH]**: custom firmware, board rework or a powered motor.

| # | Falsifies | Setup | Pass/fail |
|---|---|---|---|
| X1 | "loss of controller ends torque" (stock) | stock ODrive v3, torque command, then host panic (RP1 E2 + ODrive R1) | torque persists ⇒ the persistence claim is confirmed |
| X2 | "watchdog is a lease" | watchdog 0.1 s plus continued telemetry polling (CX2 / B5) | torque persists with stock firmware; the gate drops LEASE_OK at T_lease |
| X3 | "a power-only safety gate is sufficient" | P3a: B holds the lease, A injects a setpoint via a second CAN node; then P3b with the gate as sole bus bridge | P3a: A's torque flows (hijack); P3b: dropped |
| X4 | "recovery cannot revive stale authority" | CX3: watchdog expiry → clear errors → closed loop without a new setpoint; then with the gate re-grant rule | stock: A's torque returns; gated: no A-attributable torque; the T3 op is reported uncertain |
| X5 | "energy removal is bounded" | firmware livelock with MOE=1 (B1), then drop LEASE_OK (B2) | GH/GL low and phase current → 0; report the t_DRV distribution as M, not as a bound |

Four timestamps per run: `t_cut`, `t_last_accept` (sniffer), `t_last_electrical`
(GH/GL, phase current), `t_last_physical` (encoder).

## 8. Open items

| Item | Blocks |
|---|---|
| A worst-case EN_GATE↓ → gates-off figure from TI, or a second analysable path (e.g. direct gate-pin pull-downs) | a fully analytic bound |
| Whether a TIMx peripheral reset re-opens LOCK (RM0090 silent) | G2's value as defence in depth |
| ODrive S1/Pro (closed firmware) | applying this to S1; needs binary RE |
| Silicon PERST# behaviour on RP1 | only matters if an RP1 pin drives an actuator (assumption 1 excludes it) |
| Gate firmware and its WCET | design work, not RE |
