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
   construction, so the real protocol needs unpredictable nonces, or a challenge the authority
   can verify came from the gate. The gate code does the second (`gate_chal_mac`); its first
   version did neither. See "Finding: tokens for future challenges" below.
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

### Composed theorem: fenced timed finality (`FencedFinality.lean`)

Artifact: `FencedFinality.lean` (sha256 `854750ac…`). `lean FencedFinality.lean` produces no
output. Axioms: `propext`, `Quot.sound`.

This composes the timed authority/lease/output model with the finite-id fence and **removes
`GateRefinement`'s downstream bound `Dd`**. Ticks are unconditional, and forwarded frames may
be lost, reordered or stuck forever. The gate may never learn of the revocation, and upstream
is adversarial.

**Theorem `Fenced.finality`.** From `t_c + W + T + δ` on, an energized output has:
- energy support ≠ r,
- committed-setpoint provenance ≠ r, and
- **no pending r-command addressed to the drive's current id**, i.e. none that can still commit.

Stale r-frames addressed to retired ids may stay downstream forever; they are harmless.
`reauthorized_with_stuck_frame` (non-vacuity): with an r-frame stuck forever, grant 1 holds the
output energized at and after the deadline.

**Protocol modelled:**
- **Sessions:** the gate serves one grant per session. Switching grants starts a session with
  a fresh node id (unused since the last flush), or an exhausted session.
- **Forwarding:** only the holder's commands, only while its lease is live, addressed to the
  session id.
- **Rotation:** a direct UART write of the drive's node id.
- **Verified flush:** clears downstream and frees used ids.
- **LEASE_OK** = confirmed readback ∧ the holder's lease is live.

**New assumption: session-tagged readback.** Readback must identify the *session* of the
committed setpoint, not only its value.
- **Why value readback is not enough here:** value equality alone cannot support the
  provenance conclusion after the deadline (`Fence.value_readback_only_breaks`).
- **Correction: the low-mantissa-bit encoding does *not* work on stock ODrive 0.5.x.** ASCII
  float readback is `snprintf("%f")` into a 10-character buffer (`ascii_protocol.cpp:356-357`,
  `fibre-cpp/protocol.hpp:189-191`). That is at most 6 decimals, truncated further for larger
  magnitudes, so float32 low bits (~1e-8) are invisible.
- **Resolved at code level: paired tag (option b).** Verified in source and SIL; not yet on
  hardware.
  - **Mechanism:** the gate runs the drive in `CONTROL_MODE_TORQUE_CONTROL` +
    `INPUT_MODE_PASSTHROUGH` and sends every setpoint as `SET_INPUT_VEL(input_vel = tag,
    input_torque = value)`, with **tag = session node id + 1**.
  - **Why `input_vel_` is free in this mode (source, not executed):** `vel_setpoint_` feeds
    only `vel_des`, which is used only when `control_mode >= VELOCITY_CONTROL`
    (`controller.cpp:295, 376`). Torque-mode velocity limiting uses the *config* `vel_limit`
    (`:388-393`). Other input modes break this: `VEL_RAMP` derives torque from the velocity
    ramp (`:194-198`).
  - **Why the tag is unique:** node ids are fresh since the last flush, and boot leaves
    `input_vel_ = 0`, which never equals a tag.
  - **Two tags per session, because a frame is two stores.** The drive writes `input_vel_`
    then `input_torque_` (`can_simple.cpp:282-283`), so a readback can see a frame's tag while
    the drive still holds the previous author's torque. The first gate confirmed on that tag
    alone; a claim audit of the paper against the code found it (2026-11-22). The Lean model
    treats a frame as one write and cannot express this; the exploration did too until it was
    changed to deliver a setpoint in two steps.
    - **Rule:** frames carry tag A = node id + 1 until the drive has shown A; then
      B = -(node id + 1). Only B confirms. On each A seen while unconfirmed the gate re-sends the
      holder's last torque under B, so a holder that sent one command is confirmed too.
    - **Why B is enough (from the source, not proved):** the drive handles one CAN frame at a
      time and finishes both stores of a frame before the next. Seeing A means an A frame had
      been handled before the answer; B frames leave the gate only after that answer, so a B
      tag in the drive means that A frame's torque store is done, and every later torque is this
      session's. This holds with frames reordered or lost and with late UART answers, since only
      the order "A observed, then B sent" matters.
    - **A value check was rejected:** the drive prints torque with at most 6 decimals, so an old
      torque close to the new one would pass, and answers to two different queries can be
      misattributed when one is lost.
    - **Checks:** SIL R5a-c (a readback between the two stores does not confirm; the re-send;
      B confirms), FW22 (no re-send once the lease has run out), Renode S10a/S10b, the
      exploration's two-step delivery, and mutants "readback confirms on tag A" (killed by R5 and
      by the exploration alone) and "re-sent setpoint without latching expiry" (FW22).
  - **SIL (real `can_simple.cpp` + real fibre `to_string`):**
    - R1: low-mantissa tags are unreadable.
    - R2a/R2b: a decimal tag works below 10 but is lost at |value| ≥ 100.
    - R3/R3b: the paired tag round-trips; a stale old-session frame to an old id cannot
      overwrite it.
    - R4: all 128 tags (A and B for each node id) round-trip exactly through the 10-character
      readback.
  - **Rejected alternatives:** low-mantissa tags (R1) and the decimal tag (a), which is
    magnitude-limited (R2b). A firmware session register (c) is unnecessary on 0.5.x.

### Recoverability and clock drift (also in `FencedFinality.lean`)

| Theorem | Statement |
|---|---|
| `Fenced.recoverable` | from **any** reachable state (stuck frames, exhausted ids, revoked grants, gate never notified), any currently valid grant can reach confirmed control with a live lease, given K ≥ 2, T > 0 and a cooperative environment for the next frame. No reachable state is a trap |
| `Fenced.Drift.finality_real` | real time is separate from gate ticks; at most R real ticks between gate ticks; the revocation is timestamped in real time. The fenced finality conclusions hold from real time `rcut + R·(W + T + δ + 1)` |

`recoverable` is a universal *possibility* result. It is **not** eventual liveness under
fairness: that would need a trace semantics with fairness assumptions on delivery and is not
proved. `finality_real` covers a gate clock *slower* than real time, by up to factor R. A
faster gate clock only makes the real deadline earlier.

### Gate reset and make-before-break handover (also in `FencedFinality.lean`)

**Gate reset.** `Step.gateReset` models a gate reboot at any time:

- **Lost:** every lease timer, the session holder and id, confirmation, arming, the used-id set.
- **Kept (hardware obligation):** the challenge counter and the session counter, both monotonic
  across resets (non-volatile counter, or boot-time randomness wide enough never to repeat).
- **Boot rule:** the verified flush runs before the gate serves anything, which is why the
  forgotten used-id set may restart empty.

| Theorem | Statement |
|---|---|
| `Fenced.finality` | unchanged conclusion, now over traces with any number of gate resets |
| `Fenced.no_late_lease` | after `t_c + W + T` the retired grant holds no live lease |
| `Fenced.forgetful_session_reset` | a reset that restarts the session counter: the retired grant's setpoint (session tag 1) passes the new grant's session-1 readback and is energized past the deadline |
| `Fenced.forgetful_challenge_reset` | a reset that restarts the challenge counter: a pre-cut token is replayed and the retired grant holds a live lease after `t_c + W + T` |

A reset that forgets the used ids **without** flushing is the id-reuse failure already shown in
`FiniteFence.reuse_breaks`.

**Make-before-break handover.** Before this change every `switch` cleared LEASE_OK until the new
holder was confirmed, a bounded pause-and-replace. Now:

- `switch` away from a **confirmed** holder records it as `prev`;
- LEASE_OK = holder's lease live ∧ (holder confirmed ∨ `prev`'s lease live);
- a successful readback clears `prev`; so do an exhausted switch and a gate reset.

| Theorem | Statement |
|---|---|
| `Fenced.finality` | also concludes `supp2 ≠ r`: neither grant supporting energy during a handover is the retired one after the deadline |
| `Fenced.bumpless_handover` | grant 0 → grant 1 (new session, rotation, commit, readback) with LEASE_OK at every tick (`offTicks = 0`) |
| `Fenced.pause_without_overlap` | with no confirmed holder and no live previous holder, LEASE_OK is false: such a handover still pauses |
| `Fenced.old_lease_alone_breaks` | the variant that keeps energy on the **previous** holder's lease alone: the new holder is revoked, its frame stays downstream, and commits past the deadline under the old holder's energy |

Mutation checks (each makes the file fail to compile): the wrong off-tick count in
`bumpless_handover`; the naive energy rule in place of `okAfterTick`; a session-forgetting
`resetState`.

Limits of the handover result:

- **Energy, not control freshness.** During the overlap the drive runs the previous holder's last
  setpoint; the gate already forwards only the new holder's commands. The window lasts until the
  new holder's first command commits and reads back. It is bumpless in energy, open-loop in
  control.
- **Both leases must be live.** A handover from a revoked holder is bumpless only if it completes
  before that holder's lease runs out (at most `W + T` after the cut); otherwise it pauses.
- **Existence, not a rate.** `bumpless_handover` is one trace. How often real handovers finish
  inside the overlap is a hardware measurement (rotation, commit and readback latency against
  `T`).

### Still not mechanised

- **Exact-effect grant sets** (Actryn): grants are identities for one protected effect. With
  one gate per effect, the theorems apply per effect. Grant sets with alternate support
  across effects are not modelled.
- **Refinement to gate firmware:** the firmware loop (`../odrive/gate/gate_fw.c`) is explored
  exhaustively at small bounds against the two finality properties (see "Bounded exploration"
  below), and its gate-side timing (P1–P3) is proved on the C code for unbounded runs (see
  "Inductive proof of the firmware loop"). There is still no proof that it refines `Fenced.Step`:
  the drive side (rotation, readback) is only explored.
- **Fairness-based liveness:** see above.

**Rule necessity:** this file proves no counterexamples of its own. Each rule's necessity is
shown in the component models:
- fresh ids and verified flush: `FiniteFence`;
- authority-side rules: `FinalityProduct`;
- command filter and exclusivity: `FinalityProduct`, `Refine`;
- a fence or bound at all: `Impossibility`.

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
- `Fence.safe` alone is **not** a timed-finality theorem. The composition is now
  `FencedFinality.finality` (above), under the additional session-tagged readback assumption.
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
- **Refinement to code**: `GateRefinement.lean` models the command-commit boundary. The gate
  firmware loop is checked by bounded exploration and tests, not linked to the model by proof. Dd (downstream bound) is unmeasured and unbounded
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

**SIL version (run, 2026-11-12).** `odrive/sil/test_fence.cpp` section X3 runs this sequence on
ODrive's unmodified `can_simple.cpp` with the portable gate core `odrive/gate/gate.h`:

| Check | Result |
|---|---|
| X3a, X3b power-only gate | hijack: A's persistent setpoint, then A's late frame, are the drive's torque input while B holds the lease |
| X3g full gate, after the cut | the drive still holds A's setpoint, and the gate keeps enable low |
| X3h B's frame lost downstream | readback fails, enable stays low |
| X3i B's frame installed and read back | enable high, torque input is B's |
| X3j, X3k A's late command; A's stuck frame released after confirmation | dropped by the gate; ignored by the drive |
| X3l no renewal | enable drops at expiry with no message |
| X3m, X3n, X3o gate reset; ids exhausted; verified flush | no lease and counters kept; fails closed; usable again |

**Gate core and firmware loop (run, 2026-11-12).** `odrive/gate/` now also holds token redemption,
authenticated commands, make-before-break and a firmware loop over a board interface. The same
SIL binary runs them against the ODrive code:

| Series | What it checks |
|---|---|
| M1, M2 | SHA-256 and HMAC-SHA-256 against FIPS 180-4 and RFC 4231 vectors |
| T1–T9 | token accepted only for the open challenge, inside W, once, with a valid tag and unchanged flags; a pre-reset challenge is dead even though the gate clock restarts |
| C1–C6 | command accepted only under the holder's session key; no replay; 7 lost frames tolerated, 8 not; a spent failed-tag budget drops the holder |
| H1–H8 | make-before-break: enable stays high only while both leases are live and the old holder was confirmed; confirmation ends the overlap; no overlap flag means revocation |
| M3 | token tag, session key, command tag and challenge tag equal those of `gate/authority.py` (Python `hmac`): both sides agree on layout and byte order |
| FW0–FW14 | `gate_fw.c` end to end on a host port: tagged challenge covered by stored state before it is sent, a second request re-announces it, rotation stored before sent, UART readback, EN_GATE one-shot armed for the time left on the lease, expiry without a message, a lapsed holder's commands dropped, renewal with and without a lapse, 20 challenges with no storage write, reset resumes above every earlier challenge, storage failure fails closed |

| W1–W4 | 32-bit clock wrap: an ended lease, challenge or previous lease never comes back; a lease spanning the wrap runs its exact length |

`odrive/sil/mutate.py` applies 37 mutants to `gate.h` and `gate_fw.c`; each fails at least one check.

Differences from `FencedFinality.lean`:
- overlap is opt-in per token (the model always overlaps from a confirmed holder);
- the previous holder cannot renew during the overlap;
- a gate reset closes the open challenge and resumes the counter above everything sent before;
- the used-id set is stored across resets (the model flushes at boot instead);
- rotation is a CAN frame (`SET_AXIS_NODE_ID`) on the downstream bus, so it can be delayed, lost
  or reordered like any other frame (`FiniteFence.lean` rotates over UART). Covered by the
  exploration below, not by a proof;
- time is a wrapping 32-bit counter (the model uses unbounded naturals). Covered by
  `ClockWrap.lean`.

There is no proof that the C code refines the model. The MAC scheme is a draft (one shared key,
truncated tags). Known availability gaps, none affecting the bound: a token is two frames, so a
node on the upstream bus can interleave its own first frame and spoil another's token; a spent
failed-tag budget drops the holder; 62 holder changes use up the node ids until a verified flush,
and the firmware loop has no flush path yet. `odrive/gate/authority.py` is the authority-service and controller side in
Python; test M3 checks that both languages produce the same tags for the same inputs.

**Finding: an ended lease came back when the clock wrapped (fixed, 2026-11-12).** The first gate
core tested a deadline with `(int32_t)(expiry - now) > 0` every time it was asked. That is only
right within 2^31 ticks of the deadline. Reproduced on the code: a lease that ended at tick 200
tested as live again at tick 2^31 + 300 (24.8 days later at 1 ms per tick), with the retired
holder's setpoint still confirmed, so EN_GATE would go high with no token. An unused challenge
reopened the same way after 2^32 ticks. None of the tests or mutants at the time could see it,
and the Lean model cannot express it (unbounded time). Fix: `gate_tick` marks a lease as lapsed, and clears a
previous lease or a challenge, the first time it is seen expired. Only a new grant revives it. `ClockWrap.lean` proves the fix:

| Theorem | Statement |
|---|---|
| `ClockWrap.live_iff` | within 2^31 ticks either side of the deadline, the wrapped test equals the true comparison |
| `ClockWrap.zombie` | from 2^31 + 1 ticks after it ended, a lease tests as live again |
| `ClockWrap.latch_sound` | with the latch, if the gate looks at the clock at least once every 2^31 − T ticks, a lease is held only while truly live, for any number of wraps |
| `ClockWrap.no_latch_unsound` | the same schedule without the latch reports a dead lease as live |

New obligation: the firmware loop must run at least once every 2^31 − max(T, W) ticks. The
EN_GATE one-shot below covers a loop that stops altogether.

**EN_GATE is a hardware one-shot, not a pin level.** `port_en_gate(ms)` arms a timer output for
the time left on the lease the output rests on (`gate_enable_for`: the earlier of the two leases
during an overlap). A firmware loop that hangs therefore cannot hold EN_GATE high past the lease.
The one-shot itself is a hardware obligation (`../odrive/STM32_BREAK_GATE.md`).

**Finding: tokens for future challenges (fixed, 2026-11-12).** The first firmware loop announced
its challenge as a bare counter. The model's rule "the authority issues only for the gate's
current challenge" then rested on nothing: a controller could show the authority the *next*
counter value, receive a token for it while still authorised, and redeem it whenever the counter
got there, long after `t_c + W + T`. This broke assumption 3 above in our own code. Fix: the
challenge frame carries the gate's tag (`gate_chal_mac`, 32 bits of HMAC under the shared key)
and the authority mints only for a tagged challenge (`authority.py: verify_challenge`). No random
number generator is needed. The exploration shows both sides: with an authority that skips the
check it finds a 24-step I1 violation (19 before setpoints became two stores) (run on every `run.sh` as an expected counterexample); with
the check, the same attack step is available to the adversary and never succeeds. A 32-bit tag
can be guessed online with probability 2^-32 per attempt, so the authority must rate-limit
requests; like the rest of the MAC scheme this is a draft.

**Challenge handling (changed, 2026-11-12).** Two more problems in the first firmware loop,
neither a finality violation:
- every challenge caused a storage write. At one challenge per renewal that wears out MCU flash
  within hours. The counter is now stored as a reserved ceiling (`GATE_CHAL_CHUNK` values per
  write); a reset resumes above the ceiling, so values still never repeat;
- every request replaced the open challenge, so a retired controller with upstream access could
  cancel every other controller's token by requesting challenges. A request now re-announces the
  open challenge until it is used or its window ends.

**Bounded exploration of the firmware loop (`../odrive/sil/explore.c`, run).** The real
`gate_fw.c` and `gate.h` are compiled into a search over an adversarial environment. Two
properties are checked after every step:

- **I1 (timed finality):** EN_GATE high and the drive's setpoint was authored by origin `o` ⇒
  now < (last time the authority minted a token for `o`) + W + T;
- **I2 (attribution):** EN_GATE high and the setpoint was authored by `o` ⇒ `o` is the gate's
  holder, or its previous holder during a handover.

"Authored by" is a ghost label carried from the upstream command frame to the drive model. The
gate code never sees it.

Environment, every choice adversarial: time; challenge requests; the authority minting a token
for any origin with or without the overlap flag; a controller asking the authority for a token
for the next, not yet issued, challenge; any minted token presented at any time, any number of
times; tokens with a made-up tag; next command, replayed command or bad-tag command
under any session key ever handed out; downstream frames delivered in any order, after any delay,
or lost, a setpoint stored as two steps (tag, then torque) with any readback in between; UART answers late, current or missing; and one fault class per run: gate reset (clock
restarts), crash right after a storage write, failed storage write, drive reboot to its default
node id, firmware hang (only the one-shot acts).

| Mode | Bounds | Result |
|---|---|---|
| Exhaustive, duplicate states pruned | W=1, T=3, 5 ticks, 2 origins, 2 challenges, 2 tokens, 2 frames on the bus, 2 commands per key; no fault and each of the 5 fault classes; clock started at 0, and 4 ticks before the wrap for no fault and gate reset | I1 and I2 hold in all 197,440,280 states (8 runs, about 30 minutes; 72,065,308 before setpoints were delivered as two stores) |
| Seeded random walks | W=3, T=6, 60 ticks, 3 origins, 8 challenges, 12 tokens, 5,000,000 steps | I1 and I2 hold |

The run is not vacuous: it reports how many states had EN_GATE high, how many of those rested on
the previous holder's lease, and how many held a setpoint whose author's authority had run out
with EN_GATE low (the X3 situation, blocked). It fails if any of the three counts is zero.

What this is and is not:
- it is the firmware's C code, not a model of it. The drive is a model: it accepts a frame only
  if addressed to its current node id, which the F-series checks on real ODrive code;
- it is bounded. It says nothing about longer runs, more controllers, or three frames in flight;
- it does not cover the 2^31-tick wrap (too far for any bounded run; W1–W4 and `ClockWrap.lean`
  do) or a second node on the downstream bus. Verified flushes are explored in the flush
  configuration below;
- states are compared by 128-bit fingerprint; a collision would hide states.

**Verified flush in the firmware loop (added 2026-11-13).** After 62 holder changes the node ids
are used up and the gate could serve nobody. The loop now flushes: when an *authentic* token
finds no fresh id (`GATE_EXHAUSTED`; a forged token cannot trigger a drive reset), it drops
EN_GATE, aborts the downstream TX mailboxes, resets the drive through its reset pin, and only
then stores the cleared id set. That token is spent; the next one is served. The order is the
point: storing first and crashing before the reset leaves a drive holding an old setpoint under
an id the gate believes is fresh. FW15–FW18 test it on the ODrive stub (80 handovers, one
flush). For exploration the gate is given two node ids, so the third token forces a flush:

| Mode | Bounds | Result |
|---|---|---|
| Exhaustive, flush configuration | 2 node ids, W=1, T=3, 5 ticks (4 in `check.sh`), 3 tokens, 3 challenges, 1 command per key, no overlap flag; no fault and each fault class | I1 and I2 hold in all 100,044,895 states, with 5,970,394 verified flushes (46,138,107 and 2,709,994 before two-store setpoints) |
| Exhaustive, two fault classes per run | main configuration; all 10 pairs of the 5 fault classes | I1 and I2 hold in all 617,298,244 states (226,244,970 before two-store setpoints; 93 minutes, 4.2 GB; `EXPLORE=deep`, not part of `check.sh`; pairs with a firmware hang use a 1-tick hang, the reset + hang pair did not finish with 3) |

The flush itself is taken as correct hardware (nothing left on the bus, drive back on its boot
id with no setpoint, no stale UART answer). A flush that only claims this is
`FiniteFence.unverified_flush_breaks`.

**STM32F4 image, built and run in emulation (added 2026-11-13).** `../odrive/gate/stm32/` holds a
register-level board layer for an STM32F4 (written for NUCLEO-F446RE), start-up code and a linker
script. `build.sh` links a complete image with clang and lld, no vendor library and no libc
(about 6.1 kB of code, 324 bytes of RAM). `renode_test.sh` runs that image in Renode's STM32F4
model and drives one whole sequence over the emulated CAN controllers, UART, flash and timers,
starting from the production image with the key written into flash as provisioning would:

| Check | What happens in emulation |
|---|---|
| S1–S3 | boots, polls the drive over UART, EN_GATE one-shot stopped, stored state in flash |
| S4–S5 | tagged challenge on the upstream bus; a token under the wrong key sends nothing downstream |
| S6–S8 | valid token → rotation frame on the downstream bus and the new node id in flash; authenticated command forwarded with the session tag |
| S9–S10 | EN_GATE stays off until the drive's UART answer matches; tag A alone does not enable, the gate re-sends the holder's torque under tag B (S10a), the holder's next command carries B (S10b); on B the one-shot runs for the time left on the lease |
| S11–S12 | CPU halted for 300 ms: the timer stops by itself; the resumed firmware keeps EN_GATE off |
| S13–S14 | after a reset the next challenge is above the earlier one, and the old token is dead |

16/16 pass. **A finding from this run:** the first board layer counted milliseconds in a timer
interrupt. With the CPU halted that clock stood still, so on resuming the gate still saw a live
lease and would have re-armed EN_GATE for time that had already passed. The exploration's
"firmware hangs" fault did not show this because its model clock keeps running by assumption.
The clock is now a free-running hardware timer read directly, and the assumption is written
into the obligations: the gate clock must not depend on the firmware making progress.

**A second finding (2026-11-19):** the production image, built with a blank key slot to be
filled at provisioning, had **no gate loop in it at all**. The key was declared `const`, so the
compiler read "all 0xFF, never keyed" at build time and removed `gate_fw_poll` as dead code; a
provisioned board would never have served. The emulation run missed it because it built with a
demo key compiled in. Fixed by making the key slot non-`const`; `build.sh` now fails if
`gate_fw_poll` is missing, and the Renode run uses the production image with the key written into
flash before boot, as provisioning would. With the old declaration that run fails 7 of 14 checks.

What the emulation does **not** show: anything about real silicon (pin electrical behaviour,
bxCAN bit timing, flash programming times, the one-pulse output on the actual pin), any timing,
or the drive. Renode's peripheral models are the reference here, not the reference manual. The
image has never been flashed.

**Which rules finality needs (mutants against the exhaustive search).** Each of
the first 32 mutants was run against the full exploration (exhaustive, then random walks), with the
unit tests ignored. This sorts the rules by what they are for. It is bounded evidence: "not
found" means no violation inside the bounds above, not that the rule is unnecessary.

| Removing this rule breaks I1 or I2 in the search (20) |
|---|
| the holder's lease expires; a lapsed lease does not enable; expiry is latched |
| node ids are not reused; readback must match the session tag |
| a token needs a valid tag, the open challenge, and the freshness window |
| a command needs a valid tag |
| overlap only from a confirmed holder; the previous lease expires; the EN_GATE one-shot honours the previous lease |
| the challenge reservation is stored before a challenge is sent; a reset resumes above it; the challenge tag is bound to its value |
| the new node id is stored before the rotation is sent |
| a flush aborts downstream TX, resets the drive, and only then stores the cleared id set |
| a failed storage write disables the gate until reset (found only with two fault classes per run: a failed write, then a reset, gives node-id reuse; `EXPLORE=deep`) |

| Not found by the search (11) | Why |
|---|---|
| flush on any rejected token | availability: a forged token would reset the drive needlessly; FW3–FW11 catch it |
| expired challenge not latched | needs 2^32 ticks; caught by W3 |
| reset forgets used ids | needs three sessions and a reset, beyond the exhaustive bounds; caught by X3m |
| old lease alone keeps energy on | in this code the previous holder cannot renew, so its lease ends inside its own bound. `Fenced.old_lease_alone_breaks` shows the rule is needed where it can |
| commands forwarded from any origin | unreachable through the firmware loop, which passes the holder; guards the core's API |
| command sequence not advanced | a replayed command has the same author as the original |
| no failed-tag budget | bounds forgery attempts; forging a tag is not modelled |
| lapsed holder's commands forwarded | changes the setpoint with EN_GATE low, same author |
| overlap from a lapsed holder | second guard: the previous lease is cleared at the next tick anyway |
| a request replaces the open challenge | availability |
| confirmation does not end the overlap | promptness |

One mutant, "token redeemable twice", did not finish: every extra redemption opens a new session,
and the state space outgrew this machine's memory three times. A fourth run on 2026-11-18, with
sessions capped at tokens + 2, hit its 25-minute limit. Random walks did not find a violation;
T7 and FW5 catch it. **Resolved 2026-11-19: it is not a finality rule.** Every redemption of a
token falls within W of its challenge's issue, which precedes the mint, so a second redemption
gives a lease that ends inside the same bound. The CBMC proof below holds with the mutant in
place. The rule limits churn: each extra redemption for another origin burns a node id
(availability).

What this does **not** show: any timing, the EN_GATE wire, phase current or motion. "Energized
torque" here means `input_torque_` while the gate's enable flag is high. P3a is "falsified if A's
value never appears" only on hardware; in SIL the baseline arm shows that the firmware's dispatch
accepts A's frame, which the F-series already established.

### Inductive proof of the firmware loop (`../odrive/sil/prove_fw.c`, CBMC 6.11), run 2026-11-19

The firmware loop `gate_fw.c` and the core `gate.h`, unmodified, are checked with CBMC against
a board model (`prove.sh`, about 2 minutes). The harness starts from **any** state that satisfies
an invariant, takes one step (a reset with arbitrary RAM, or one poll), and asserts the invariant
again. Induction then covers runs of any length. Lease length T and window W are symbolic in
(0, 2^30). The clock may jump by up to 2^31 - max(T, W) between reads, which is the latch
obligation of `gate.h`. Real time advances separately from the firmware's clock reads, so
staleness is visible. Storage writes may fail, and a failed write may still have landed.
Checked properties:

- **P1.** EN_GATE is armed only for a live lease, and only until before i + W + T. Here i is
  when the gate first sent the challenge behind that lease. During an unconfirmed handover the
  same holds for the previous holder's lease.
- **P2.** A setpoint goes downstream only under a live lease, before i + W + T.
- **P3.** A token is redeemed only for the challenge the gate sent last (the value in the
  token's tagged message), within W of its first sending. A challenge value is never announced
  again unless it is still open.

Add the authority's obligation: it mints only for a challenge carrying the gate's tag, so after
the gate sent it, and never after revocation at t_c. Then i ≤ t_c, and the gate's support for the
output ends by t_c + W + T. MACs are free values (any tag may verify), so this part assumes
nothing about the cryptography. CBMC's bounds, pointer and shift checks run on the same code.

A poll with k frames is covered by one-frame polls: the loop reads the clock and latches expiry
before each frame. The extra latch and EN_GATE check at the end of each one-frame poll only latch
what the next read would latch anyway, and add checks.

**Found by the proof in our own code (all fixed, each with a SIL test and a mutant):**

| Finding | Effect | Fix | SIL |
|---|---|---|---|
| The clock was read once per poll | A flood of upstream frames keeps one poll running; EN_GATE is then armed from the stale reading, past the lease end. **Breaks the bound** | Read the clock per frame and right before arming; the UART query moved after arming | FW19 |
| `gate_command` has no clock and no latch ran before it | A command that arrives after the lease ran out, before the next latch, is forwarded (EN_GATE is already low, so this is P2, not output) | Latch expiry before each frame | FW20 |
| The node id loaded from storage was not range-checked | `1ull << node` is undefined for node ≥ 64 | Fail closed on node ≥ 64 | FW21 (UBSan) |

The first version of the harness missed the first finding, because it advanced time only when the
firmware read the clock. The mutant "clock read once per poll" survived it. The harness was fixed
so that real time also advances while a frame is handled.

**Mutants against the proof alone** (`PROVE=1 mutate.py`): 19 of 37 killed (the two readback mutants added 2026-11-22: the re-send without a latch is killed by P2; confirming on tag A is drive side and survives, as expected). The proof kills every
timing rule, and also "token for any challenge" and the storage rules for challenges. As expected,
it does not kill:
- drive-side rules (readback, node ids, flush order, rotation storage);
- MAC rules (tags are free values);
- "token redeemable twice" (not a finality rule, see above);
- "overlap from an unconfirmed holder" and "confirmation does not end the overlap". These are
  about which setpoint the drive holds; the explorer and the SIL tests cover them.

**The gate's share of δ (static, STM32F4 image).** In `gate.elf` the path from the clock read
(`port_now`) to the TIM2 start in `port_en_gate` has no backward branch other than into the call
itself. That is about 105 instructions. The only enabled interrupt is USART1 (18 instructions);
at 115200 baud it fires at most once per 87 µs. At 16 MHz that is under about 400 cycles, or
roughly 25 µs. TIM2 (EN_GATE) and TIM5 (clock) count whole milliseconds. The one-shot is armed
for the time left measured from a TIM5 reading taken before the arm, so tick rounding ends the
pulse early, not late. EN_GATE therefore falls at most that gap after the lease end. This is a
static reading, with the timer hardware taken as correct; it has not been measured. The drive's
share (EN_GATE low to zero phase current) remains assumption C13.

### Independent review of the message authentication (2026-11-19)

A reviewer given only the code and a threat model reported:

- **Critical, fixed.** Nothing limited failed challenge-tag checks at the authority. A controller
  that is still authorized can guess the 32-bit tag of a future counter value (about 2.9·10^7
  tries per hour at bus rate, about 6 days expected). It then holds a token it can redeem after
  its own revocation, which breaks the bound. Fix: `authority.ChallengeGuard` refuses every
  challenge after 16 failed tags until an operator resets it. A guess then succeeds with
  probability at most 16/2^32 per alarm. Anyone on the upstream bus can trigger the lockout,
  which costs availability, not safety.
- **High, open (cryptographic margin).** The 32-bit command tag is checked against 8 sequence
  numbers, which gives 2^-29 per frame and about 2^-25 per session (failure budget 16). An
  attacker who forces re-grants (16 bad frames drop the holder; the next grant rotates and resets
  the budget) gets about R·3600·2^-25 per hour at R grants/s. A success injects one setpoint
  under a live lease: an integrity break, still inside the time bound. The real fix is longer
  tags (CAN FD) or a per-origin budget that survives rotation.
- **High, assumption.** How the session key reaches the controller is not specified. It must
  travel on a confidential channel between authority and controller, never on the gate's bus.
- **Medium, open.** Renewal keeps the first session key, while a re-grant after a drop rotates
  it. The authority cannot tell which happened, so the controller can fall out of sync
  (availability). Held-back commands can be released later while the lease is live (stale but
  authentic setpoints). The 32-bit sequence number would wrap after about 2^32 commands without
  re-keying.
- **Low.** No gate id in the MACs: one key per gate is required. Flash wear from unauthenticated
  challenge requests is about 70 records an hour; with 4096 records per sector and two sectors
  alternating, that is decades.
