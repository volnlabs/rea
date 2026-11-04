# Machine-checked core: provenance and energy cutoff

Artifact: `Finality.lean` (Lean 4.35.0, core library only, sha256 `eb6829bb…`).
Check with `lean Finality.lean`: no errors or warnings, no `sorry`. Every theorem depends
only on Lean's standard axioms (`propext`, `Quot.sound`; checked with `#print axioms`).

This replaces the 128-configuration check in `chain_model.py` as the evidence for the
*command-path* claim. The finite model remains as a counterexample finder.

## Two guarantees, proved separately

| | Theorem A: command provenance | Theorem B: energy cutoff |
|---|---|---|
| Lean | `Provenance.provenance`, `Provenance.noninterference`, `Provenance.retired_rejected` | `Energy.cutoff` |
| Statement | In every reachable state where the power stage is energizable (`LEASE_OK ∧ armed`), the drive's setpoint was issued by the newest epoch the gate has adopted. Every reachable state has the same protected projection as a reachable state of a run in which upstream only ever held current-epoch frames | From any gate state with lease timer ≤ T, after T + δ ticks of the gate's own clock with no renewal, energy is impossible |
| Time | untimed (any interleaving) | discrete ticks of the gate clock |
| Says nothing about | how quickly energy disappears | whose command the energy serves |

They are not interchangeable. The ODrive/RP1 counterexamples show that each can hold
while the other fails:
- the power-only gate satisfies B but violates A (setpoint hijack)
- a host-side command filter can satisfy A's check while energy persists indefinitely
  (RP1/ODrive persistence)

## What Theorem A quantifies over

| Your challenge item | Covered? | How |
|---|---|---|
| Multiple pending commands | yes | `queue : List Frame`, arbitrary length |
| Independently operating clocks | yes, for A | A is untimed: every interleaving and relative rate is a valid trace |
| Unbounded retries / duplication / loss / reordering | yes | `reshape` sets upstream to any list; `accept` does not consume frames |
| Arbitrary controller replacement | yes | `cut` to any newer epoch, any number of times |
| Retired controllers keep upstream access | yes | `reshape` may include frames of any origin |
| Gate restarts | yes | `restart` drops lease and freshness; epoch monotone by assumption |
| Untrusted drive arming / re-arm | yes | `arm` at any time; the setpoint register persists (ODrive F3/F4) |
| Conflicting valid authorities | **partly** | several issuers may share the current epoch, so A holds. But authority support is *epoch equality only*: exact-effect grants and independent alternate support (Actryn) are not modelled |
| Explicit physical-output trace | yes, in `FinalityProduct.lean` | A and B alone are separate invariants; the product model has an explicit output stage and one timed semantics (see below) |

## Assumptions, and the hardware or protocol obligation behind each

Each assumption is a field of `Assumptions`. `Provenance.Counterexamples` proves a
reachable violation when any one of them is dropped.

| Assumption | Counterexample if dropped | Obligation |
|---|---|---|
| `filter`: gate drops non-current epochs | `hijack_without_filter` | the gate is on the command path and checks the epoch per frame |
| `exclusive`: no write path to the drive bypasses the gate | `bypass_breaks` | the gate is the sole bridge to the drive's bus; RP1 BAR1, `/dev/pio`, DMA and other CAN nodes cannot reach the drive |
| `authenticated`: tag = true origin | `forgery_breaks` | frames carry a MAC under an epoch key the retired domain does not hold |
| `regrantFresh`: re-grant needs a fresh current-epoch setpoint | `stale_regrant_breaks` | closes ODrive CX3 (persistent input revived on re-arm) |
| `monotone`: gate restart never adopts an older epoch | `rollback_breaks` | epoch kept in non-volatile storage, or re-fetched authenticated, before LEASE_OK may rise |
| Theorem B: δ exists | (B is conditional on δ) | `t_AND + t_DRV + t_discharge ≤ δ`. **t_DRV has no TI maximum** (DRV8301 §7.4.1), so δ is today a measured value, not a proven one |
| Theorem B: renewals stop at the cut | (premise of B) | renewal tokens are issued only by the authority service for the current epoch. A retired controller cannot renew |

## Composed timed theorem: `FinalityProduct.lean` (mechanised)

Artifact: `FinalityProduct.lean` (sha256 `eacd5864…`). `lean FinalityProduct.lean` produces
no output: no errors, warnings or `sorry`. Only `propext`/`Quot.sound` axioms
(`#print axioms` on every theorem).

**Theorem `Product.finality`.** Under the strict rules, for every reachable state `s`, if the
authority service revoked grant `r` at `t_c`, `s.now ≥ t_c + W + T + δ` and the output is
energized, then:
- the grant whose lease last enabled the output is not `r` (energy support), and
- the drive's setpoint register was not written by `r` (command provenance).

One theorem, both guarantees, stated separately in its conclusion.

| Your fix | How the product model addresses it |
|---|---|
| A. history-based, not final-state | `finality` is a safety property over *every* reachable state, so it holds at every step of every trace after the deadline. Provenance is tracked by ghost state (`drvSrc`, `supp`) rather than by a purged comparison trace. A relational two-trace noninterference theorem is still **not** proved |
| B. output not modelled | explicit output stage: `out` changes only at ticks; it may rise only if LEASE_OK ∧ armed; after LEASE_OK is observed low it must fall within δ ticks (the **shutdown obligation**, an assumption on hardware) |
| C. cut adopted instantly | three separate states: authority `valid`/`cutAt`, gate per-grant `timer`, gate challenge. `notify` (gate learns of the cut) is optional, so the theorem holds if it is late or never delivered |
| renewal tokens not assumed away | tokens are created only by the authority (`issue`, for currently valid grants), bound to grant + gate challenge nonce, redeemable within W ticks. Anyone may redeem or replay any issued token |
| unreliable RP1/PCIe/CAN | no delivery or liveness assumption: frames and tokens may be lost, delayed, reordered, duplicated or replayed |

**Counterexamples** (`Product.Counterexamples`, concrete T=2, W=0, δ=1, cut at 0, deadline 3).
Each is a reachable post-deadline state with energized output depending on `r`:

| Rule dropped | Theorem | Mechanism |
|---|---|---|
| authority issues only for valid grants | `renewal_after_revocation` | lease renewed after revocation |
| no authority rollback | `authority_rollback` | `r` re-validated, then renewed |
| freshness window W | `stale_token_replay` | token issued pre-cut, redeemed arbitrarily late |
| power-path exclusivity | `power_bypass` | output energized without LEASE_OK while `r`'s setpoint persists |
| command-path exclusivity | `command_bypass` | `r`'s setpoint written past the gate under authority 1's valid lease (hijack) |
| command filter | `no_filter` | gate forwards `r`'s frame under authority 1's lease |
| — (witness) | `independent_reauthorization` | under the strict rules the effect continues after the deadline, supported and commanded by authority 1. The naive "effect is off after the cut" is false; `finality` correctly permits this |

**Deadline:** `t_c + W + T + δ`. Compared with the separate Theorem B, the extra W is the
price of not trusting the gate to learn of the cut: a token issued just before `t_c` can
still be redeemed up to W ticks later.

**Trust base: the reviewer must check these.**
1. Ghost instrumentation: `drvSrc` changes exactly where the drive register is written
   (`accept`, `cmdBypass`); `supp` changes exactly at ticks where LEASE_OK holds.
2. LEASE_OK is defined as "the lease of the grant whose command was last forwarded". This
   is a **design choice of the gate**: energy follows the setpoint's own authority. It
   replaces the separate "fresh setpoint before re-grant" rule.
3. Challenge unpredictability is abstracted by letting the authority issue tokens only for
   the gate's *current* challenge. Stockpiling tokens for future nonces is excluded by
   construction, so the real protocol needs unpredictable nonces.
4. One global tick: the gate clock is the time base and t_c is read on it. **Clock drift**
   between the authority service and the gate is not modelled; with rate ratio ρ, scale
   the bound accordingly.
5. δ ≥ 1 and the shutdown obligation itself are hardware assumptions. On ODrive v3, δ
   rests on the DRV8301 turn-off delay, which TI does not bound.
6. Single protected effect; grants are not yet exact-effect grant sets.

## Gate refinement: the command-commit boundary (`GateRefinement.lean`)

Artifact: `GateRefinement.lean` (sha256 `35237613…`). `lean GateRefinement.lean` produces no
output. Every theorem uses only `propext`/`Quot.sound`.

`FinalityProduct.lean` updated `lastSrc` (gate record) and `drvSrc` (drive setpoint)
atomically. The refinement separates them:
- `forward` puts a frame into a ghost **downstream** stage (gate CAN TX, bus, drive RX).
- The drive installs it by an explicit **`commit`**, in any order, or the frame is
  **`lost`**.
- A gate **`restart`** clears volatile state (tracking, leases, `lastSrc`) but not
  downstream frames.

**Theorem `Refine.no_pending_hijack`** (the property you asked for). Whenever the gate asserts
LEASE_OK, the drive's committed setpoint **and every forwarded command that could still
commit** come from the lease holder. Under B's lease, no A-origin command is, or can become,
the effective setpoint.

**Theorem `Refine.finality`.** The composed deadline `t_c + W + T + δ` still holds in the
refined model. An energized output depends on the retired grant neither for energy, nor for
its committed setpoint, **nor through any pending downstream command**.

**New gate rules, each shown necessary (`Refine.Counterexamples`, T=3, W=0, δ=1, Dd=3):**

| Rule | Counterexample without it | Hazard |
|---|---|---|
| `confirm`: LEASE_OK requires a readback that the drive's setpoint equals the lease holder's command | `lost_command` | B's frame is lost; the drive still executes A's setpoint under B's lease |
| `trackCheck`: readback confirms only if no tracked in-flight frame has another origin | `reordered_commit` | A's older frame commits after B's, behind a confirmed readback |
| `quarantine`: no LEASE_OK for Dd ticks after gate restart | `restart_without_quarantine` | the restarted gate forgets A's in-flight frame |
| `boundedDown`: downstream frames commit or are lost within Dd ticks (hardware obligation) | `unbounded_downstream` | A's frame outlives the gate's tracking window |

**Implementability on ODrive v3 (verified in source `3a2e4dd1`):**
- **CAN cannot do the readback.** CAN-simple 0.5.x has **no setpoint readback**: no message
  returns `input_torque_`/`input_vel_`/`input_pos_` (`can_simple.cpp:62-158`). `GET_IQ`
  is only an indirect, post-controller quantity.
- **UART can.** The ASCII protocol reads any property (`ascii_protocol.cpp:121, 345`), e.g.
  `r axis0.controller.input_torque`. `confirm` can therefore be implemented over UART on
  stock firmware, which makes UART a **second command-capable path** that the gate must own
  exclusively.
- **Value vs provenance:** readback compares values, not provenance. If A and B command
  the same value, the gate treats it as B's. This is deliberate, exact-effect semantics:
  B authorized that exact effect. The model's `drvSrc = lastSrc` check is the value
  comparison under the abstraction that distinct grants command distinct values.
- **`boundedDown` (Dd) has three parts:**
  - **gate CAN TX:** abortable by the gate; the restart quarantine covers frames it loses
    track of;
  - **bus arbitration and error recovery:** **not bounded by CAN under bus-off**, so the
    gate must hold the bus or treat bus-off as "unknown, quarantine";
  - **ODrive RX processing:** unmeasured.
- **Gate challenge counter** must survive restart (modelled as persisted). A counter reset
  would re-admit old tokens; this is not a separate counterexample here.

**Refinement status:** both files share the authority, lease and output semantics, but there
is no formal simulation proof from `GateRefinement` to `FinalityProduct`. `Refine.finality`
is proved directly on the refined model.

## Impossibility without a downstream bound, and the fence that removes it (`Impossibility.lean`)

Artifact: `Impossibility.lean` (sha256 `36552a1c…`). `lean Impossibility.lean` produces no
output. Axioms: `propext`, `Quot.sound`; `Fence.safe` additionally uses `Classical.choice`,
introduced by tactics.

This answers the vacuity concern about `GateRefinement`'s `boundedDown` premise. There, time
could not advance while a frame was unresolved. Here time always advances, delivery latency
is unbounded, frames may be lost, and the drive never acknowledges a commit.

### Part 1: impossibility (`Impossible`)

The gate's LEASE_OK decision is an **arbitrary function** `π` of its whole observation
history: forwarded commands, readback results, ticks, and any other inputs (tokens,
notifications, timers). Commits and losses are hidden. The model is *generous* to the gate:
readback reveals the committed command's origin, which is more than a value-only ODrive
readback gives. The impossibility therefore holds a fortiori for real readback.

| Theorem | Statement |
|---|---|
| `stuck_twin` | for every run in which a frame was lost, there is a run with **identical gate observations** in which that frame is still pending and can commit later |
| `lost_frame_blocks` | every safe `π` refuses in any run where another grant's frame was lost |
| `no_timeout_helps` | in the run "A's frame lost, B's committed, readback shows B, then n ticks", every safe `π` refuses, for every n. A timeout never proves a frame is gone |
| `singleGrant_safe`, `singleGrant_energizes` | non-vacuity: a useful policy (serve one grant; energize after readback confirms it) is safe and does energize. The impossibility is specifically about **authority changes with unresolved frames** |

**Consequence:** without either a proven downstream bound or a drive-side fence, no gate can be
both safe and live across controller replacement once a frame has been lost. The `Dd`
assumption in `GateRefinement.lean` is therefore not incidental: some such mechanism is
necessary.

### Part 2: the fence (`Fence`)

- **Drive behaviour:** the drive accepts a setpoint only if it is addressed to its current
  node id.
- **Gate protocol on a cut:** rotate the node id to the new epoch, using a rotation frame
  addressed to an *older* id. LEASE_OK only after readback confirms **both** the drive's node
  id and its setpoint value.

| Theorem | Statement |
|---|---|
| `safe` | under unbounded latency, loss, reordering and stuck frames: whenever readback is confirmed, every pending frame that could still commit is a current-epoch setpoint, and the committed setpoint is the current epoch's or **value-equal** to the gate's last command |
| `live_despite_stuck_frame` | A's frame stays pending forever; the gate still energizes, and A's frame can never commit |
| `stale_rotation_breaks` | without "rotate only from an older id", a stale rotation frame re-opens an old epoch after confirmation |
| `value_readback_only_breaks` | without the node-id check, value-equal frames make a lost rotation look confirmed, so retired frames stay capable |

The value-vs-provenance split you asked for is explicit here. *Pending* frames are judged by
provenance: can it commit, and from which epoch. The *committed* setpoint is judged by value
equivalence.

**Stock ODrive v3 implements the fence (verified in source `3a2e4dd1`):**
- `SET_AXIS_NODE_ID` sets `config_.can.node_id` immediately (`can_simple.cpp:222-224`).
- Every incoming frame is matched against it before dispatch (`can_simple.cpp:51`).
- The node id is readable over UART (`r axis0.config.can.node_id`, ASCII `r` at
  `ascii_protocol.cpp:121`).

Limits:
- **Wrap-around:** node ids are finite (6 bits in standard frames, more with extended frames;
  `can_simple.hpp:92-97`). The model's ids are unbounded, so after wrap-around a frame stuck
  for a full rotation cycle could match again. **This directly limits the unbounded-delay
  claim to finitely many replacements without a flush.** `FiniteFence` (not yet done) must
  either never reuse an id while a stale frame is possible, or verify a flush.
- **Coverage (verified):** *every* CAN-simple command passes the node-id check
  (`can_simple.cpp:44-55`) before `do_command`, so stale frames cannot change mode, limits,
  gains, requested state or any other CAN-writable state, not just setpoints.
- **Filter-renewal window (verified):** `SET_AXIS_NODE_ID` changes the id used by the dispatch
  check immediately. The CAN receive filter is renewed later, by polling in `service_stack`
  (`can_simple.cpp:390-399`, marked as a hack). Until then, frames addressed to the **new**
  id are dropped. This is an availability cost only; the gate's retry plus readback covers it.
- **Committed pre-cut configuration persists.** Config that A legitimately wrote before the
  cut (mode, limits, gains) is not undone by the fence. After rotation, the gate must re-assert
  canonical configuration and read it back before LEASE_OK. Equivalently, controllers never
  write config: the gate owns it.

### Finite node ids (`FiniteFence.lean`)

Artifact: `FiniteFence.lean` (sha256 `6362d142…`), clean check, axioms `propext`/`Quot.sound`.

There are `K` node ids. Rotation is a **direct UART write** (`w axis0.config.can.node_id`) on a
gate-owned point-to-point link, so there are no rotation frames downstream and the
stale-rotation hazard of `Fence` disappears. Setpoint frames still have unbounded latency,
loss and reordering.

Gate protocol:
- Each epoch uses a **fresh** id, one not used since the last flush.
- With no fresh id, the epoch is **exhausted**: the cut still happens, but nothing can be
  confirmed.
- A **verified flush** (gate aborts its CAN TX mailboxes and resets the drive; a hardware
  obligation) clears downstream frames and frees the used ids.

| Theorem | Statement |
|---|---|
| `safe` | with only K ids, under unbounded latency and stuck frames: when confirmed, every pending frame addressed to the drive's id is from the current epoch; the committed setpoint is current or value-equal |
| `exhausted_refuses` | no fresh id means no confirmation, so exhaustion fails safe |
| `reuse_breaks` | K = 2: reusing id 0 without a flush revives epoch 0's stuck frame behind a confirmed readback |
| `unverified_flush_breaks` | a flush that frees ids but leaves downstream frames is unsafe |
| `exhaustion_without_flush` | without flush, K = 2 ids serve epochs 0–1; epoch 2 is exhausted |
| `beyond_K_with_flush` | with verified flushes, K = 2 ids serve epoch 3 (more epochs than ids) |

**Consequence:** under unbounded delay, the number of controller replacements between flushes
is at most `K − 1`. Beyond that, safety requires a *verified* flush. That is a hardware
obligation:
- **gate CAN TX:** verifiable locally through the mailbox abort and status registers;
- **ODrive:** `RESET_ODRIVE` calls `NVIC_SystemReset` (`can_simple.cpp:136-137`), which
  clears RAM and the CAN peripheral;
- **topology:** no store-and-forward node between gate and drive.

After a reset ODrive reverts to its **saved** node id, so the gate must rotate again. The
model leaves `nid` unchanged across a flush, which is safe because confirmation needs a
fresh rotation.

### Bench test for the fence (`../odrive/bench/fence_bench.py`), written, not run

This is a no-motor test. It refuses unless `axis0.current_state` is IDLE, never requests a
state, and restores the node id and zero torque on exit. Its frame encodings are checked
against source (`--selftest` passes).

| Test | Measures |
|---|---|
| T0 | UART readback latency |
| T1 | node-id rotation latency, via UART and via CAN `SET_AXIS_NODE_ID` |
| T2 | filter-renewal window (first frame to the new id that takes effect) |
| T3 | **pass/fail**: frames to the old id after rotation never take effect |
| T4 (`--reset`) | node id after `RESET_ODRIVE` |

Bus-off is not covered; it needs manual fault injection.

### Software-in-the-loop check of the fence (`../odrive/sil/`), run

This compiles ODrive's **unmodified** `communication/can/can_simple.cpp` (commit `3a2e4dd1`,
sha256 `474ed3b1…`) on Linux with ASan/UBSan, against stub `axis.hpp`/`odrive_main.h` that
define only the members it touches. The CAN controller is emulated in software. Run with
`ODRIVE_SRC=<checkout> ./run.sh`.

Result: **15/15 checks as expected.**

| Check | Result on real code |
|---|---|
| F2 | `SET_AXIS_NODE_ID` changes the dispatch id immediately |
| F3a / F4b | stale frames to the old id are ignored, both before and after filter renewal |
| F3b | frames to the **new** id are dropped until `service_stack()` renews the filter (availability window confirmed) |
| F5 / F5w | all 32 command ids, data and RTR, to the old id change **no** axis state: no watchdog feed, reset, e-stop, clear-errors, limits, modes or rotation, and send no replies. Checked both after renewal and **inside the renewal window**, where only the dispatch check protects |
| F6 | extended-format frame with the same numeric id ignored |
| F7a / F7b | direct (UART-style) rotation behaves the same as CAN rotation |
| F8 | the other axis's id does not affect axis 0 |
| F9 | **expected hazard:** after reusing an old id, a stale frame to it is installed again (`FiniteFence.reuse_breaks` on real code) |

**Mutation check:** removing the node-id comparison at `can_simple.cpp:51` makes 6 checks
fail, including F5w. The tests can therefore detect a missing fence. The first version of F5
could not: after renewal, the filter alone masked the mutant, which is why F5w was added.

**Harness finding:** `CANSimple`'s constructor leaves `subscription_handles_` uninitialised,
and the firmware relies on static zero-initialisation. A stack-allocated instance can
"unsubscribe" a garbage handle in `init()`. This is harmless in firmware, but any port or test
must use static storage.

**Not covered:** timing, the real bxCAN hardware filter banks (emulated here as id/mask in
software), bus-off, reset and readback behaviour. Those need hardware: an ODrive v3.6 or a
clone running 0.5.x.

### What these results do and do not claim (review corrections)

- `live_despite_stuck_frame` and `singleGrant_energizes` are **existential**: progress is
  *possible*. They are not liveness guarantees. Eventual re-authorization under fair
  executions would need explicit fairness and delivery assumptions for the new authority's
  rotation, setpoint and readback. Not proved.
- `Fence.safe` is **not** a timed-finality theorem. It has no power stage, lease or
  shutdown delay. Composing it with `FinalityProduct`/`GateRefinement`, replacing the `Dd`
  assumption with fence confirmation, is not yet done.
- The `Refine` counterexamples violate the bookkeeping invariant (`Hijack`). They are not
  energized-output violations. The `Product` counterexamples are output-level.

## Earlier composition sketch (superseded by `FinalityProduct.lean`)

Let `t_c` be the time the authority service stops issuing renewals for epoch e.

1. By B, energy supported by any lease granted before `t_c` is impossible after
   `t_c + T + δ`.
2. Any later energy needs a renewal after `t_c`. A renewal needs `fresh`, which after an
   epoch change needs a delivered current-epoch setpoint. By A, while energizable, the
   setpoint is from the newest adopted epoch, which is not e once the gate has adopted
   the cut.

**Correction:** this sketch claimed the not-yet-adopted case "holds by construction" with a
`T + δ` deadline. Mechanising it showed otherwise. Without a challenge freshness window, a
token issued before the cut can be redeemed arbitrarily late (`stale_token_replay`). With
the window, the deadline is `t_c + W + T + δ`.

## What is still not established

- A **physically guaranteed** deadline: δ rests on t_DRV, which TI does not bound.
- **Relational noninterference**: no two-trace theorem; provenance is ghost-tracked (see trust base).
- **Clock drift** between the authority service and the gate.
- **Nonce unpredictability**: abstracted, not modelled cryptographically.
- **Exact-effect authority**: a single protected effect. Grants are identities, not grant
  sets per effect with alternate support.
- **Recovery semantics** (uncertain vs replay): only enumerated in `chain_model.py`.
- **Refinement to code**: `GateRefinement.lean` models the command-commit boundary, but
  nothing links it to gate firmware. Dd (downstream bound) is unmeasured and unbounded
  under CAN bus-off.

## First hardware test: X3 (setpoint hijack) — not run, needs [AUTH]

Purpose: physically distinguish P3b (command + energy gate) from the power-only
safety-MCU baseline. This is the hardware counterpart of `hijack_without_filter`.

| | Baseline P3a (power-only gate) | Treatment P3b (gate = sole CAN bridge + EN_GATE interlock) |
|---|---|---|
| Wiring | gate MCU drives `LEASE_OK` into `EN_GATE` AND; ODrive CAN shared with "A" (a second CAN node) and "B" | ODrive CAN connected **only** to the gate's second CAN port, and ODrive UART **only** to the gate; A and B on the upstream bus. On the cut, the gate rotates the ODrive node id (`SET_AXIS_NODE_ID`). LEASE_OK only after UART readback confirms node id **and** `input_torque` (`Fence` rules). Variant X3-stuck: hold one A frame in the gate's CAN TX mailbox and release it after confirmation; it must be ignored |
| Sequence | 1. epoch 0: A sets torque τ_A. 2. cut → epoch 1. 3. B sends τ_B, gate grants lease. 4. A sends `Set_Input_Torque` τ_A (distinct value and sign from τ_B) | same |
| Expected | torque switches to τ_A while the lease is held: **hijack observed** | the gate drops A's epoch-0 frame; torque stays τ_B |
| Capture | CAN sniffer on the ODrive side (frame source), phase-current probe, encoder/torque, `LEASE_OK`, `EN_GATE_DRV`, `t_cut` marker, all on one independent logic analyzer | same |
| Falsified if | P3a: A's τ_A never appears → the model or the ODrive analysis is wrong. P3b: any A-attributable current after step 4 → Theorem A's obligations are not met by the implementation | |

Safety: low-voltage, current-limited supply; small τ values; rotor guarded or clamped
with torque sensor; independent hardware e-stop on the supply.
