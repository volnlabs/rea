# Bench hardware for Phase B

What to buy and why. Nothing here has been ordered or tested. No prices: they vary by seller and
date. Check each listing against the "must have" column, because clone boards differ.

## Parts

| Part | Must have | Used for |
|---|---|---|
| ODrive v3.6-compatible board (56 V or 24 V) | STM32F405, DRV8301 gate drivers, CAN transceiver fitted, SWD header reachable, able to run open firmware **0.5.x** (not S1/Pro, which are closed) | Device under test: `fence_bench.py`, δ, X3 |
| ST-Link V2 (or clone) | SWD | Flash fw 0.5.6 at the pinned commit `3a2e4dd1`; recover a bricked clone |
| USB-CAN adapter | Linux SocketCAN support (`gs_usb`/candleLight firmware or PCAN); 250 kbit/s | Command path; second adapter optional as the "retired controller" |
| USB-UART adapter, 3.3 V | 115200 baud; **3.3 V logic only** | ODrive ASCII protocol: node-id rotation and readback |
| Gate MCU dev board | **Two CAN controllers** (upstream and downstream buses are separate) + one UART, a hardware timer with a one-shot output for EN_GATE (`port_en_gate` in `../gate/gate_port.h`), non-volatile storage. A NUCLEO-F446RE fits (CAN1 + CAN2, one-pulse timers); it needs **two** external transceivers. An RP2040 has no CAN controller and does not fit the firmware loop as written | The final gate: `../gate/gate_fw.c` (C24: persistent counters) |
| 2 × CAN transceiver breakout (the Nucleo has none) | 3.3 V, e.g. SN65HVD230 class | Gate ↔ upstream bus, gate ↔ drive |
| Logic analyzer | ≥ 8 channels, ≥ 24 MS/s; sigrok support | Independent capture: EN_GATE, gate-driver outputs (GH/GL), CAN RX/TX, UART, a cut marker |
| Bench supply | 12–24 V, adjustable **current limit** (start at 1 A) | Safe power; never a battery for first tests |
| Small BLDC motor + encoder | Low power (gimbal or small outrunner), encoder ODrive supports | X3 only. `fence_bench.py` and δ need **no motor** |
| 2 × 120 Ω resistors, jumper wires, breadboard | — | CAN termination and wiring |
| Brake resistor | The one matched to the board (usually included) | Required once a motor is attached |

## Order of use

1. **No motor, no gate MCU:** flash 0.5.x, run `fence_bench.py --selftest`, then T0–T4 with the
   axis IDLE. Needs board, ST-Link, CAN adapter, UART adapter, supply.
2. **δ measurement, no motor:** logic analyzer on EN_GATE and the gate-driver outputs; pull
   EN_GATE low from a GPIO and record the turn-off distribution. TI gives no maximum, so report
   the distribution, not a bound.
3. **Gate MCU:** leases, node-id rotation, paired-tag readback, EN_GATE interlock. Add the EN_GATE
   wire (this is a hardware modification of the board: EN_GATE is driven by the STM32 on stock
   boards; see `../STM32_BREAK_GATE.md`).
4. **X3 with a motor:** power-only gate versus full gate, plus the pause-and-replace baseline and
   the handover-overlap measurement (rotation + commit + readback latency against the lease `T`).

## Safety

- Clamp or enclose the motor; no load on the shaft for first runs.
- Current limit on the supply before every power-up; raise it only as far as the test needs.
- EN_GATE rewiring and any motor test are the steps the brief marks as needing explicit
  authorization. Steps 1 and 2 do not spin anything.

## Open choices

- **Clone quality:** some v3.6 clones ship with locked or modified bootloaders, or omit the CAN
  transceiver. Confirm SWD access and the transceiver in the listing photos before buying.
- **Gate MCU family:** an STM32 with two CAN controllers and a one-pulse timer output matches
  `../gate/gate_fw.c` and `../STM32_BREAK_GATE.md`. The STM32 port of the board interface is
  not written.
- **Gate storage endurance:** the firmware writes storage once per holder change and once per
  `GATE_CHAL_CHUNK` challenges (default 1024). MCU flash is rated around 10,000 erase cycles per
  sector, so the port needs wear levelling across a sector, or FRAM. Measure the write time: it
  sits inside the handover path.
