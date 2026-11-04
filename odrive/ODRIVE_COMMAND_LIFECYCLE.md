# ODrive command lifecycle vs. timed actuation finality

Scope:
- **Covered:** ODrive **v3.x hardware, firmware 0.5.x**, public source
  `odriverobotics/ODrive` at `3a2e4dd1` (2026-01-20). Paths below are relative to
  `Firmware/`.
- **Not covered:** ODrive **S1 / Pro / Micro**. The README states their firmware
  "source code is currently not publicly available". Claims about S1 need its binary
  (REA target) or vendor documentation.

Labels: **V** verified in source; **I** inferred; **U** unknown or needs hardware.
Model: `odrive_finality_model.py` (explicit-state, self-checking).

## Recovered contracts

| Contract | Finding | Label | Evidence |
|---|---|---|---|
| Command acceptance | A CAN `Set_Input_Torque` is committed by storing `input_torque_`, with no check of axis state, arming or sender | **V** | `communication/can/can_simple.cpp:286-287`, dispatch `:45-55` |
| Acceptance ≠ execution | stored inputs act only when armed; in passthrough they become the setpoint every tick | **V** | `MotorControl/controller.cpp:187-190` |
| Queue finality | no queue; one level-triggered setpoint register, *persistent* until overwritten | **V** | writers of `input_torque_`: command interfaces, homing, anticogging only |
| Persistent output | a stale setpoint persists indefinitely while armed. The watchdog is the only timeout and is **off by default** | **V** | `MotorControl/axis.hpp:86-87` (`watchdog_timeout = 0`, `enable_watchdog = false`) |
| Watchdog = traffic liveness, not authority | **every** CAN frame to the node feeds the watchdog before dispatch, including reads and heartbeats. ASCII commands feed it; USB/native needs an explicit `watchdog_feed()` | **V** | `can_simple.cpp:58-60`; `ascii_protocol.cpp:151…399`; `odrive-interface.yaml:568` |
| Revocation latency | expiry or error → `motor_.disarm()` in the same control pass (8 kHz, 125 µs). Disarm clears `MOE`. Its `gate_driver_.set_enabled(false)` is a **no-op** on v3 (`Drv8301::set_enabled` returns true), so the DRV8301 stays enabled | **V** | `MotorControl/main.cpp:410-421`; `MotorControl/motor.cpp:268-279`; `Drivers/DRV8301/drv8301.hpp:75-79`; `Board/v3/Inc/board.h:117`, `main.h:69-75` |
| E-stop | the CAN E-stop sets `ERROR_ESTOP_REQUESTED`; the next check disarms | **V** | `can_simple.cpp:170-172`; `axis.hpp:151-153` |
| Recovery / replay | `clear_errors()` and arming reset setpoints and integrators but **not** `input_vel_`/`input_torque_`. Closed-loop entry re-seeds only the *position* input, and only in position mode | **V** | `main.cpp:236-246`; `controller.cpp:12-19, 115-127`; `axis.cpp:257-300` |
| Independent enforcement | the STM32 hardware break input is **disabled** (`BreakState = TIM_BREAK_DISABLE`, `LockLevel = OFF`); shutdown is software-only (MOE clear); IWDG/WWDG are not enabled | **V** | `Board/v3/Src/tim.c:137-143, 346-351`; `Board/v3/Inc/stm32f4xx_hal_conf.h:70,83` |
| Sender authority | CAN frames identify only node ID + command; any bus participant can command or feed | **V** | `can_simple.cpp:45-55` |

## Counterexamples (shortest traces from the model)

`W` = watchdog timeout in ticks; `D = W + 1`. "Violated" means the axis is armed with
nonzero torque whose last writer is the retired controller A, more than D ticks after
the cut.

| # | Configuration | Trace | Lesson |
|---|---|---|---|
| CX1 | default (watchdog off) | A sets torque → A arms → cut → tick… | no bound exists with default config |
| CX2 | watchdog on, telemetry still polling | … → cut → tick ×2 → *telemetry poll* → tick ×3 | a read-only status poll extends the retired command's life indefinitely |
| CX3 | watchdog on, quiet bus, B re-arms without writing | A sets torque (while idle) → cut → B clears errors and arms → tick… | **stale-command replay after recovery**: B's recovery revives A's torque |
| CX4 | watchdog on, A keeps bus access | cut → A sets torque | without sender authentication at the drive, the cut is not enforceable |
| CX5 | guardian sends torque 0 on cut, frame may be lost, polls on | same as CX2 | an unacknowledged fence frame is not a fence |
| OK | watchdog on, no frames to node after cut, A off bus, B writes before arming | — | holds within D |

The exhaustive sweep in the model's self-check covers all 32 combinations of the five
flags. The property holds **iff** the watchdog is enabled, no frame reaches the node
after the cut, A has no bus access, and B writes a setpoint before arming.

**I** These are counterexamples over a model built only from verified code facts.
Each still needs one hardware confirmation run (below) before it is cited as observed
behaviour.

## What the bound looks like when it holds

Under the OK conditions, and with E-stop or watchdog as the fence:

`Delta_final <= R_cut + watchdog_timeout + 125 µs (one control pass) + t_MOE→gate-off + R_drain`

| Term | Class | Basis |
|---|---|---|
| watchdog_timeout | A (configured) | `axis.hpp:164` (ticks = timeout × 8000) |
| one control pass | A if the control ISR runs | **V** check and disarm in the same pass; **U** WCET of preceding work |
| MOE → outputs idle | A (timer hardware, STM32F405 RM) | **V** `OSSR/OSSI = ENABLE` → defined idle levels |
| gate driver disable | not on this path | **V** disarm never lowers EN_GATE (`drv8301.hpp:79`); EN_GATE drops only on DRV reconfiguration (`drv8301.cpp:59-63`) |
| R_drain electrical | A/M | phase L/R decay through the body diodes into the bus |
| R_drain mechanical | M | rotor coasts; no torque does not mean no motion |
| CPU stall without fault | **∞** | **V** no break input and no IWDG: if the control ISR stops while MOE=1, the timer keeps the last duty cycle |

## Implications for AxiomOS

1. **Liveness timeouts are not authority leases.** The ODrive watchdog proves only that
   *someone* talks to the node (CX2). A lease must be fed only by the current authority:
   epoch-tagged, and checked at the gate.
2. **Recovery must not revive inputs** (CX3). Recovery semantics need "re-arm requires
   a fresh setpoint under the new epoch". Stock 0.5.x does not enforce this.
3. **The drive is a sink without sender identity** (CX4). The final gate cannot be the
   drive's CAN interface. It must sit where the retired domain physically cannot
   reach, or the bus must be mediated.
4. **ODrive v3 does not use its hardware break, and on LQFP64 both break-capable pins
   are already taken** (PA6 = VBUS sense, PB12 = EN_GATE). The firmware's peripheral
   resets can also undo the STM32 locks. The finality point should therefore be the
   DRV8301 `EN_GATE` line, gated by an external lease. See `STM32_BREAK_GATE.md`
   (verified against RM0090 Rev 22, DS8626 Rev 12, DRV8301 Rev F).

## Hardware confirmation (not run; needs bench + motor, low-voltage, clamped load)

Capture four timestamps on one independent logic analyzer / CAN sniffer:

| Timestamp | How |
|---|---|
| t_cut | guardian marker line |
| t_last_accept | last A-tagged frame on the bus (CAN sniffer timestamp) |
| t_last_electrical | gate-drive PWM or phase current probe |
| t_last_physical | encoder or torque sensor |

| Run | Reproduces | Expected |
|---|---|---|
| R1 | CX1 (default config) | torque persists after cut |
| R2 | CX2 (watchdog 0.1 s, keep polling encoder estimates) | torque persists as long as polling continues |
| R3 | CX3 (watchdog expiry, then clear errors + closed loop without new setpoint) | A's torque reapplied on re-arm |
| R4 | OK config + E-stop | gate-off ≤ timeout + 125 µs + gate-driver delay |

## Corrections to the proposal

- ODrive **S1** is not covered by the public source. Use v3 hardware to match this
  analysis, or treat S1 as a binary RE target.
- **Not re-checked here:** `canopen-python` `profiles/p402.py` is, to my knowledge,
  a CiA 402 **master** (`BaseNode402` drives a remote node). It shows how a host
  sequences Quick Stop / Disable Voltage, not how a drive implements Fault Reaction
  Active. Drive-side semantics need the CiA 402 spec or a drive implementation.
