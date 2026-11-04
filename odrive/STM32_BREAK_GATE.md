# Closing the gap: an independent output gate on ODrive v3 (STM32F405 + DRV8301)

Question: can a separately asserted signal force the power stage safe **without CPU
cooperation**, so that a retired controller, or a hung or misbehaving firmware, cannot
keep torque on?

Sources:

| Key | Document | Identity |
|---|---|---|
| SRC | ODrive source `3a2e4dd1` (v3, fw 0.5.x), plus ST HAL/CMSIS vendored in it | — |
| RM | RM0090 Rev 22 (May 2026) | sha256 `f3ff2322…` |
| DS | DS8626 Rev 12 (STM32F405/407 datasheet) | sha256 `1f41b4fa…` |
| TI | DRV8301 SLOS719F (Rev F, Jan 2016) | sha256 `a076588a…` |

Labels: **V** verified in the cited source; **I** inferred; **U** unknown or needs hardware.

## What ODrive v3 does today

| Fact | Label | Evidence |
|---|---|---|
| MCU is STM32F405RGTx, LQFP64 | V | SRC `Board/v3/Odrive.ioc` |
| TIM1 (M0) / TIM8 (M1) drive the 6-PWM bridges | V | SRC `tim.c`, `stm32f4xx_it.c` |
| Break disabled, `LockLevel = OFF`, `AOE` off, `OSSR`/`OSSI` on | V | SRC `tim.c:137-143, 346-351` |
| First BDTR write freezes LOCK until reset, so with today's init **LOCK can never be enabled later without an MCU reset** | V | RM §17.4.18: "The LOCK bits can be written only once after the reset. Once the TIMx_BDTR register has been written, their content is frozen until the next reset." |
| Shutdown = software clears `MOE` | V | SRC `motor.cpp:268-279`; `stm32f4xx_it.c` |
| DRV8301 not disabled on disarm (`set_enabled` no-op) | V | SRC `drv8301.hpp:75-79` |
| One `EN_GATE` (PB12) for both DRV8301s | V | SRC `board.cpp:368-375` |
| No IWDG/WWDG | V | SRC `stm32f4xx_hal_conf.h:70,83` |
| A debug halt disables the outputs "as if the MOE bit was reset" | V | SRC `board.cpp:362-365` sets DBG freeze; RM §17.3.21 |

**I** Every current path to "power stage off" needs the CPU to store to `BDTR`. A
non-faulting stall with MOE=1 keeps the last compare values. A debugger halt does **not**
reproduce that stall, because it is the one stall that is made safe (RM §17.3.21).

## G1: Gate-driver enable interlock (recommended primary)

`EN_GATE_DRV = EN_GATE_MCU AND LEASE_OK`. `LEASE_OK` comes from a separate gate MCU and is
pulled low, so an unpowered or reset gate means disabled.

| Property | Label | Evidence |
|---|---|---|
| EN_GATE high→low "will shut down gate driver block immediately, so gate output can put external FETs in high impedance mode"; other blocks shut down 10 µs later | V | TI §7.4.1 |
| Gates held off in disable mode: "gate driver always has control of the power FETs even in gate disable mode as long as PVDD is within functional region"; standby gate impedance 1.6–2.4 kΩ | V | TI §7.3.5; Electrical Characteristics `Rgate_off` |
| No maximum delay is specified for EN_GATE↓ → gates off | V (absence) | TI §6 tables list `tpd,E-L` = 200 ns for *error events* only |
| Gate discharge time ≈ f(R_gate_off, FET gate charge) | I | analytic, from the FET datasheet plus `Rgate_off` max 2.4 kΩ |
| **A 10–20 µs EN_GATE low pulse "should not be applied"**: it can leave the DRV8301 "unresponsive to external inputs until a full power cycle" | V | TI §7.4.1 |
| A low pulse < 10 µs is only a quick fault reset (charge pump stays up, gates re-enable) | V | TI §7.4.1, `tpd,R_GATE-Quick` |
| Full reset needs > 20 µs low; SPI registers revert to defaults; start-up 5–10 ms after high | V | TI §7.4.1; `tpd,R_GATE-OP`, `tSPI_READY` |
| Re-enable forces ODrive firmware to re-initialise the DRV | V | SRC `board.cpp:369-375`, `drv8301.cpp:75-80` |
| Independent of STM32 state | I | no STM32 output can raise `EN_GATE_DRV` while `LEASE_OK` is low |
| Per-board granularity (both axes) | V | shared PB12 |

**Gate requirements that follow from TI §7.4.1:**

1. Once `LEASE_OK` falls, hold it low for **≥ 20 µs** and until re-grant, so the gate
   never emits a 10–20 µs pulse. Add TI's suggested RC filter on EN_GATE against glitches.
2. The AND gate must not let `EN_GATE_MCU` toggling while `LEASE_OK` is high reach the
   driver as a 10–20 µs pulse. That is already today's firmware behaviour (≥ 40 µs pulses,
   `board.cpp:371-374`); keep it.
3. Treat "DRV unresponsive until power cycle" as a possible state after malformed pulses.
   **U** whether the gates are guaranteed off in that state; TI does not say.

## G2: STM32 advanced-timer break (defence in depth)

Configuration: break on BKIN with BKE=1, AOE=0, LOCK level 3 written in the **first**
BDTR write after reset, and GPIO lock on the BKIN pin and all 12 PWM pins.

| Property | Label | Evidence |
|---|---|---|
| Break clears MOE asynchronously, "even if the MCU oscillator is off"; complementary outputs go to reset/inactive state asynchronously | V | RM §17.3.12 |
| "MOE cannot be set while the break input is active (neither automatically nor by software)" | V | RM §17.3.12 note |
| OCx and OCxN are never both active | V | RM §17.3.12 |
| CSS clock failure is also a break source | V | RM §17.3.12, BDTR bit 12 |
| LOCK L1 freezes DTG, OISx/OISxN, BKE, BKP, AOE; L2 adds CCxP/CCxNP, OSSR, OSSI; L3 adds OCxM, OCxPE; MOE is **not** lockable | V | RM §17.4.18 |
| GPIO lock freezes MODER/OTYPER/OSPEEDR/PUPDR/AFR "until the next MCU or peripheral reset" | V | RM §8.4.8 |
| Firmware can reset the GPIO port (`RCC_AHB1RSTR.GPIOxRST`) and the timers (`RCC_APB2RSTR.TIM1RST/TIM8RST`) | V | RM §6.3.5, §6.3.9 |
| A TIMx peripheral reset makes LOCK writable again | **U** | RM states only "written only once after an MCU reset" and the BDTR reset value `0x0000` |
| BKIN pins on LQFP64: TIM1_BKIN = PA6 (AF1), PB12 (AF1); TIM8_BKIN = PA6 (AF3). PE15/PI4 do not exist on LQFP64 | V | DS pin table: PA6 = pin 22, PB12 = pin 33, PE15/PI4 = "-" |
| Both are used on ODrive v3: PA6 = `VBUS_S` (ADC12_IN6), PB12 = `EN_GATE` | V | SRC `Odrive.ioc` |
| PA6 can select only one AF at a time, so one pin cannot break both TIM1 and TIM8 | I | standard AF mux, DS AF table |

**Consequence (I):** on ODrive v3, G2 needs board rework that moves both bus-voltage
sensing and EN_GATE off PA6/PB12. Even then, G2 only defends against a **stalled or
non-adversarial** controller. Firmware that executes a GPIO or timer peripheral reset can
unlock the pins, and possibly the timer (**U**). G2 cannot be the finality boundary under
the AxiomOS threat model. G1 can.

## G3: Software MOE clear (today)

Not a gate under the AxiomOS threat model.

## Gate controller requirements (drives LEASE_OK for G1, and BKIN for G2 if fitted)

1. Own oscillator and lease timer; no dependency on the Pi 5 / RP1 path.
2. The lease is renewed only by authenticated, epoch- and sequence-checked messages from
   the current authority. Traffic alone does not renew (closes CX2).
3. On cut or expiry: drop LEASE_OK and latch it low for ≥ 20 µs (TI §7.4.1). Re-grant only
   after a new epoch **and** a confirmed fresh setpoint (closes CX3).
4. Reset, brown-out and unpowered all mean LEASE_OK low.
5. Analysed WCET for check → pin.

## Resulting bound (G1)

`Delta_final <= R_cut + T_lease + WCET_gate + t_AND + t_DRV(EN_GATE↓→gate driver off) + t_gate_discharge + R_drain`

| Term | Class | Basis |
|---|---|---|
| T_lease | A | configured |
| WCET_gate | A | static analysis of gate firmware |
| t_AND | A | logic datasheet |
| t_DRV | **M**: TI says "immediately", no maximum given | TI §7.4.1 |
| t_gate_discharge | A (from `Rgate_off` max 2.4 kΩ and the FET's Qg/Ciss) | TI electrical table + FET datasheet |
| R_drain electrical | A/M | motor L/R through the body diodes |
| R_drain mechanical | M | inertia; zero torque is not zero motion |

**I** The only non-analytic term in the safety path is `t_DRV`. To claim a proven bound,
either obtain a worst-case figure from TI or add a second, analysable path:
- G2 break, whose RM text gives asynchronous behaviour but no ns figure either, or
- direct gate-pin pull-downs controlled by the gate.

Until then, report `t_DRV` as measured with a stated margin, not as a bound.

## Experiments

These need a bench with a low-voltage, current-limited supply and a guarded rotor. B1 and
B3 also need custom firmware, and B2–B4 need board rework; **[AUTH]** for both.

| # | Purpose | Method | Pass criteria |
|---|---|---|---|
| B1 | Baseline: livelock leaves PWM on | firmware loop with interrupts disabled, MOE=1. Not a debugger halt (RM §17.3.21 makes that safe) | gate PWM continues |
| B2 | G1 under livelock | B1, then drop LEASE_OK (held ≥ 20 µs) | INH/INL ignored and GH/GL low; phase current → 0. Record the t_DRV distribution |
| B3 | G2 under livelock | B1 + BKIN; LOCK 3 + GPIO lock at boot | outputs off; firmware attempts to set MOE / write BKE fail. Then try `TIM1RST` and `GPIOBRST` to answer the **U** row |
| B4 | Replay after recovery | CX3 sequence with the G1 re-grant rule | no A-attributable torque after re-arm |
| B5 | Lease ≠ traffic | CX2 sequence (telemetry polling continues) | LEASE_OK drops at T_lease despite polling |
| B6 | DRV hazard window | gate firmware fuzzing LEASE_OK pulse widths, scope on GH/GL | no 10–20 µs pulses ever reach EN_GATE |

Capture on one independent logic analyzer:
- t_cut marker
- LEASE_OK and EN_GATE_DRV
- INH/INL and GH/GL
- phase current probe
- encoder
