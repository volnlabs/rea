# Paper outline: timed actuation finality across controller replacement

Status: outline and evidence map, not prose. Every claim below points to an artifact in this
repo. Nothing has been run on motor hardware.

## Working title

*Revoked but Still Moving: Timed Actuation Finality Requires a Drive-Side Fence*

## Thesis (one paragraph)

When a controller's authority is revoked, commands it already issued can still reach an
actuator: queued, in flight, stuck in a bus controller, or persisting in the drive's setpoint
register.

- **Impossibility:** we prove that no gate deciding from what it can observe (forwarded
  commands, readback, time, any other inputs) can be both safe and live across controller
  replacement once a command has been lost, unless downstream delivery is bounded or the drive
  enforces a fence.
- **Protocol and composed theorem:** we give a fencing protocol (per-session node-id rotation,
  session-tagged readback, energy interlock, fresh ids with verified flush) and prove a
  composed timed theorem. After `t_c + W + T + δ`, every energized output is free of the
  retired authority, in energy, in committed command, and in any command that can still take
  effect. This holds with unbounded downstream delay, finite ids, and a gate that never hears
  of the revocation.
- **Stock hardware:** a stock motor drive (ODrive v3, fw 0.5.x) already contains the needed
  fence, shown by software-in-the-loop on its unmodified CAN code.

## Contributions

1. **Impossibility** (`Impossibility.lean`: `stuck_twin`, `lost_frame_blocks`,
   `no_timeout_helps`), with non-vacuity (`singleGrant_safe`).
2. **Fenced timed finality** (`FencedFinality.lean`: `finality`, `Drift.finality_real`,
   `recoverable`). One theorem covers energy support, committed-command provenance and
   capable pending commands.
3. **Minimality.** Every protocol rule has a counterexample when dropped:
   - setpoint hijack under a power-only gate,
   - stale token replay,
   - authority rollback,
   - id reuse,
   - unverified flush,
   - value-only readback,
   - bypass of the power or command path.

   This separates the design from "a safety MCU plus sequence numbers".
4. **Grounding in real artifacts:**
   - ODrive fence semantics executed on unmodified firmware (SIL, mutation-checked);
   - session-tagged readback shown implementable on stock firmware;
   - static RE of the Raspberry Pi 5 RP1 showing why the host platform cannot be the
     finality point.

## Section plan

| § | Content | Main artifacts |
|---|---|---|
| 1 | Problem: revocation vs persistent/queued physical effects; acceptance ≠ effect | brief; `rp1-fw/AXIOMOS-IMPLICATIONS.md` |
| 2 | System model: authority service, gate, downstream, drive, output stage; threat model (retired domain keeps upstream access) | `FencedFinality.lean` `Step` |
| 3 | Why the host platform cannot be the boundary (Pi 5 RP1: no ownership, outputs persist through host/PCIe failure, revocation path = failure path) | `rp1-fw/RP1_*.md` |
| 4 | Impossibility without a downstream bound or fence | `Impossibility.lean` §Impossible |
| 5 | Fencing protocol and composed theorem; clock drift; recoverability | `FencedFinality.lean` |
| 6 | Necessity of each rule (counterexample table) | `FinalityProduct`, `GateRefinement`, `FiniteFence`, `Impossibility` §Fence |
| 7 | Realisation on ODrive v3: node-id fence, filter-renewal window, paired-tag readback, EN_GATE interlock | `odrive/`, `odrive/sil/` |
| 8 | Evaluation: SIL now; hardware (fence bench, δ, X3 hijack) pending | `odrive/bench/`, `finality/PROOF.md` X3 |
| 9 | Related work; limitations; kill criteria | below |

## Claims and evidence

Evidence types:
- **P** proved in Lean (no `sorry`; standard axioms)
- **E** executed on real code (SIL)
- **S** static source or datasheet reading
- **M** finite model check
- **A** assumption
- **O** open

| # | Claim | Type | Where |
|---|---|---|---|
| C1 | No safe gate policy can energize after an authority change once another grant's frame was lost, under unbounded delay and hidden commits | P | `Impossible.lost_frame_blocks`, `no_timeout_helps` |
| C2 | Safe *and* useful policies exist without authority changes | P | `Impossible.singleGrant_safe`, `singleGrant_energizes` |
| C3 | Fenced timed finality (energy, committed command, capable pending commands) after `t_c+W+T+δ`; unbounded delay; finite ids; gate may never be notified | P | `Fenced.finality` |
| C4 | Same in real time with a gate clock slower than real time by ≤ R | P | `Fenced.Drift.finality_real` |
| C5 | From any reachable state a valid grant can regain confirmed control (no trap states) | P | `Fenced.recoverable` |
| C6 | Power-only gating permits setpoint hijack under the new authority's lease | P, M | `Product.Counterexamples.command_bypass`, `no_filter`; `chain_model.py` |
| C7 | Each protocol rule is necessary | P | counterexample theorems, see `PROOF.md` |
| C8 | ODrive 0.5.x ignores *every* CAN command addressed to a stale node id, including inside the filter-renewal window | E | `odrive/sil` F3a, F5, F5w (mutation-checked) |
| C9 | Session-tagged readback is implementable on stock ODrive 0.5.x (paired tag) | E + S | SIL R3/R4; `controller.cpp:187-190, 295, 376, 388-393` |
| C10 | ODrive's watchdog is a traffic timeout, off by default, fed by any frame; disarm leaves the gate driver enabled | S | `ODRIVE_COMMAND_LIFECYCLE.md` |
| C11 | Pi 5 RP1 outputs persist through host crash, PCIe link loss and PERST# (firmware level); no register ownership | S | `rp1-fw/RP1_RESET_AND_OUTPUT_PERSISTENCE.md`, `RP1_ACTUATION_AUTHORITY.md` |
| C12 | RP1 silicon behaviour on PERST# | O | needs hardware |
| C13 | δ (EN_GATE↓ → gates off) is bounded | A / O | TI DRV8301 gives no maximum; measure |
| C14 | Verified flush (gate TX abort + drive reset) clears downstream | A | hardware obligation |
| C15 | Gate exclusivity (sole command and energy path) | A | wiring obligation |
| C16 | Authenticated, unforgeable tokens; unpredictable challenges | A | crypto obligation (abstracted) |
| C17 | Fence holds on real CAN hardware and timing | O | `odrive/bench/fence_bench.py`, needs board |
| C18 | Hijack physically observable with a power-only gate and absent with the full gate | O | X3, needs bench |

## Threats to validity (state up front)

- **Model–implementation gap:** no refinement proof from gate firmware to `Fenced.Step`
  (no gate firmware yet).
- **Ghost provenance:** the theorems use ghost fields (`drvSrc`, `supp`); their placement is
  part of the trust base.
- **Liveness:** only "possible" or "recoverable", not eventual liveness under fairness.
- **Authority granularity:** one protected effect per gate; exact-effect grant sets with
  alternate support are not modelled.
- **SIL fidelity:** SIL emulates the CAN controller filter in software and does not test
  timing, bus-off or reset.
- **ODrive coverage:** ODrive S1/Pro/Micro firmware is closed; results apply to v3.x / 0.5.x.
- **Related work status:** several of the brief's related works are recent preprints (see
  brief's evidence warning).

## Kill criteria (from the brief), current status

| Criterion | Status |
|---|---|
| A plain reference monitor + sequence numbers proves the same | **Not triggered.** C1 shows any observation-based monitor fails without a fence or bound; C6 shows the power-only safety MCU fails |
| The device cannot expose a defensible finality point | Pi 5 RP1: **triggered**. ODrive v3: **not triggered** (C8, C9), but δ (C13) is unbounded in the datasheet |
| No better than a safety-MCU baseline | **Not triggered in proofs** (C6); needs X3 (C18) on hardware |

## Evaluation plan (hardware, pending)

Hardware: ODrive v3.6-compatible board on fw 0.5.x, a CAN adapter, UART, a logic analyzer,
and a low-voltage current-limited supply.

| Experiment | Purpose |
|---|---|
| `fence_bench.py` T0–T4 | readback latency, rotation latency, filter-renewal window, stale-frame rejection, post-reset id |
| δ distribution | EN_GATE↓ → gate-drive off, gate discharge |
| X3 | setpoint hijack, baseline vs fenced gate, plus the X3-stuck variant |
| X1, X2, X4, X5 | persistence, lease ≠ traffic, recovery replay, energy removal under livelock |

Report every measurement as a measured distribution, never as a bound.
