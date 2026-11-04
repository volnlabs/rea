# Finality bound on a Pi 5 actuation path (Investigation F)

Target bound:

`Delta_final <= R_cut + R_IPC + R_scheduler + R_queue + R_guardian + R_device + R_physical_drain`

Labels: **V** verified, **I** inferred, **U** unknown. Classification per term:

- **A** analytically bounded under stated assumptions
- **M** empirically measurable, but measurement is not a bound
- **U** unknown
- **∞** potentially unbounded

Observed maxima are never substituted for worst-case bounds.

## Three architectures evaluated

1. **P1 host-only**: host guardian writes RP1 registers directly (pin driven by RP1).
2. **P2 host + RP1 core-1 guardian**: P1 plus a modified-firmware heartbeat guardian on M3 core 1.
3. **P3 external gate**: RP1 pin → external MCU/FPGA with its own timer; the MCU output
   stage drives the actuator.

## Term-by-term

| Term | RP1 influence | P1 | P2 | P3 | Basis |
|---|---|---|---|---|---|
| R_cut | none (Actryn/host) | A if implemented so | A | A | outside RP1 |
| R_IPC | none | A/M (host) | A/M | A/M | outside RP1 |
| R_scheduler | none on host; on the M3, core-0 PRIMASK sections exist | M | core-1 loop: A with WCET analysis of guardian code | MCU: A | **V** `cpsid`/`msr primask` sites `0x200022ce…0x2000246c` (core 0 only) |
| R_queue (software) | none | A if the guardian queue is bounded | A | A | outside RP1 |
| R_queue (hardware) | PCIe posted-write buffers; PIO FIFOs; DMA descriptors | **∞** for PIO/DMA work already queued unless explicitly stopped; PCIe in-flight: M | same | gate output independent of RP1 queues: A | **V** DS: PIO SM/FIFO, DMA can write peripherals; §3.3.1 posted writes |
| R_guardian | none (host) | A/M | core-1 heartbeat timeout + loop: A | MCU timeout: A | design-dependent |
| R_device | PCIe link + APB + pad | M ("typically 1 µs", +2/+5 µs ASPM). Link loss or retrain: the revocation write cannot arrive → **∞** | detection does not need PCIe: A (heartbeat timeout + APB write). Host contention: **∞** | MCU GPIO: A from MCU datasheet | **V** DS §3.3.1 (typical, not worst case); **V** link paths do not touch outputs |
| R_physical_drain (pin) | PWM applies RANGE/DUTY at next overflow; GPIO immediate | if a stop write lands: ≤ 1 PWM period (A, given clock and RANGE). If it never lands: **∞** | same, once the guardian writes | gate opening time: A | **V** DS PWM SET_UPDATE note |
| R_physical_drain (actuator) | none | M per actuator | M | M | outside RP1 |

## Why P1 and P2 are not finite under the AxiomOS threat model

- **V** RP1 outputs have no lease. They persist through host crash, link loss, PERST#
  (firmware level), hot reset and M3 crash.
- **V** The host's revocation path is the same PCIe link that fails. A link loss
  therefore blocks revocation: `R_device` is unbounded exactly in the failure case
  that matters.
- **V** There is no register ownership. A retired domain that keeps BAR1 access, or
  can drive `/dev/pio` or RP1 DMA, can re-assert output after any revocation.
  - **I** In P1/P2, "no output supported solely by the retired authority" cannot be
    guaranteed unless every BAR1/BAR2/DMA/RPC path is mediated.
  - **U** Whether IOMMU or the PCIe RC can enforce such mediation per domain on Pi 5.
- **I** P2 bounds the benign-crash case: heartbeat stops → guardian sets OD=1
  within a timeout. It does not bound the case where the retired domain still runs,
  because that domain can clear OD again (`RP1_CORTEX_M3_GUARDIAN_FEASIBILITY.md`).

## Assumptions required for a finite bound (P3)

1. **Single physical choke point**: every protected actuator is powered or driven only
   through the external gate's output stage. No RP1 pin reaches the actuator directly.
2. **Gate-local authority state**: the gate holds the authority epoch/lease and a
   watchdog timer clocked independently of RP1 and BCM2712 (own oscillator, or a
   documented tolerance).
3. **Fail-closed default**: on lease expiry, reset, brown-out or loss of input, the gate
   output goes to a defined safe state, and its reset state is safe.
4. **Authenticated, sequence-fenced commands**: the gate rejects commands whose
   epoch/sequence is stale. A retired domain's in-flight commands, which can still
   arrive through RP1 as late as R_device, are rejected at the gate rather than relied
   on to drain.
5. **Bounded gate execution**: WCET of the gate's check-and-switch path is analysed,
   not measured.
6. **Physical drain bounds per actuator**: declared from the actuator datasheet and
   validated by capture. The PWM-period term applies only if the gate passes PWM;
   otherwise the gate's switching time applies.
7. **No RP1-side bypass**: no RP1 pin is wired so that RP1 state can energize the
   actuator when the gate is open (unpowered or reset).

Under 1–7:

`Delta_final <= R_cut + R_lease (gate timeout) + R_gate_WCET + R_gate_switch + R_actuator_drain`

**I** RP1, PCIe and host terms drop out of the *upper* bound. They only affect
availability (false refusals) and the latency of *new* authorized commands.
**U** Each remaining term still needs a datasheet-backed analytical bound for the chosen
MCU/FPGA and actuator.

## What RP1 evidence still contributes

| Use | Evidence |
|---|---|
| Lower-bound / availability modelling of R_device | DS §3.3.1 typical latencies (M) |
| Proof that RP1 cannot be the finality point (impossibility argument) | lease-free persistence (**V**), no ownership (**V**), revocation path = failure path (**V**) |
| Fault-injection targets | PERST#, hot reset, link down, M3 HardFault, host panic |
| Defence in depth (P2) | bounded benign-crash shutdown, not counted in Delta_final |
