# Paper outline: timed actuation finality across controller replacement

Status: outline and evidence map, not prose. Every claim below points to an artifact in this
repo. Nothing has been run on motor hardware.

## Decision (2026-11-21): stage A first

Stage A is written as `paper/main.tex` (AAAI-27 author kit) for the AAAI-27 AI4Factory workshop
(due 2026-11-25, up to 8 pages, single-blind, OpenReview). Software evidence only. Hardware work
(A+, C) continues on the `hardware` branch and feeds a later full paper.

## Options considered (2026-11-18)

Whether the paper can stand without a drive. Three possible stages, each a complete paper on
its own:

| Stage | What the paper is | Hardware | Status |
|---|---|---|---|
| **A** | A verification paper: the mechanised bound, rule necessity, the gate's C code explored against the bound, SIL on the stock drive's real CAN source, the STM32 image in emulation, and the bugs each layer found that the layer above could not | none | evidence exists |
| **A+ (cheap upgrade)** | A plus measurements on the gate board alone: EN_GATE pulse length, the cut-off with the CPU halted by a debugger, gate-side latencies, flash write times in the handover path. Turns "emulation only" into "measured on silicon, without a drive" | NUCLEO-F446RE (two CAN transceivers only if CAN is exercised; the EN_GATE and halt measurements need none), logic analyzer | not started |
| **C (full)** | The paper as originally planned: X3 on a motor, δ, fence bench | ODrive v3.6 clone, motor, supply | not started |

If stage A were chosen, it would have to state plainly:
- δ (C13) is an **assumption**: the bound is `t_c + W + T + δ` with δ unmeasured, and TI does not
  bound it in the datasheet.
- The setpoint hijack is shown in proofs and on the drive's real CAN source in SIL (C6, C25),
  **not** on a motor (C18 open).
- Likely venue: formal methods or verification, or a workshop. A systems, robotics or safety venue is
  likely to ask for the motor; that is stage C.
- Kill criterion 3 ("no better than a safety-MCU baseline") is answered in proofs and SIL only.

Not checked: whether VESC or moteus firmware would serve as a second stock drive (open
firmware, runtime-changeable CAN id, persistent setpoint, readback). Worth an hour before
buying hardware for stage C.

## Working title

*When the Gate Is Not the Actuator: Mechanised Timed Finality for Controller Handover*

"Energy is not authority" stays as the slogan for contribution 1, but it no longer carries the
title: Das (*The Last Gate Before Motion*, Zenodo, Oct 2026) already states that a continuing
effect needs continuing authority. Our case is the one his theorem assumes away, and the one his
later drafts leave to the implementer ("must separately reconcile already buffered or applied
commands"). Cite the UAS draft for gate-side epoch handover and expiry-bounded exposure.

The earlier title, "Revoked but Still Moving…", collides with IETF
draft-das-finality-bound-revocation ("Revoked but Still Executable"). See
`finality/RELATED_WORK.md`.

## Thesis (one paragraph)

When a controller's authority is revoked, commands it already issued can still reach an
actuator: queued, in flight, stuck in a bus controller, or persisting in the drive's setpoint
register.

- **The gate is not the actuator:** final-gate architectures (Das 2026) assume the gate sees
  the pending output and checks authority atomically with the effect. A gate in front of a
  stock drive cannot: the drive holds the setpoint, and queues behind the gate can hide
  commands. This paper is about that case.
- **Energy is not authority:** device-side fencing (Chubby sequencers, Raft terms, PROFIsafe
  sequence numbers, Spot leases) and energy removal (STO) are known. We show that composing
  them naively is unsafe with persistent setpoints: an energy gate held by the new authority
  can execute the retired authority's command.
- **Protocol and composed theorem:** we give a protocol that binds energy to the provenance of
  the executing command (per-session node-id rotation, session-tagged readback, energy
  interlock, fresh ids with verified flush). We prove a composed timed theorem: after
  `t_c + W + T + δ`, every energized output is free of the retired authority, in energy, in
  committed command, and in any command that can still take effect. This holds with unbounded
  hidden downstream delay, finite ids, clock drift, and a gate that never hears of the
  revocation.
- **Why some fence is unavoidable** (a mechanised form of the known lease-without-fencing
  limitation): no observation-based gate is safe and live across handover without one.
- **Stock hardware:** a stock, non-safety motor drive (ODrive v3, fw 0.5.x) can be retrofitted
  with the needed fence, shown by software-in-the-loop on its unmodified CAN code.

## Contributions

Revised after the related-work check (`finality/RELATED_WORK.md`). The individual mechanisms
(receiver-side epoch/sequence checks, leases-need-fencing, watchdog to safe state, STO,
sink fences) are prior art, so the contributions are the composition and its physical
specifics.

1. **Energy authority is not command authority when the gate is not atomic with the effect.**
   With persistent actuator setpoints held by a device behind the gate, an
   STO-like energy gate lets a retired controller's command execute under the new authority's
   lease (setpoint hijack). The gate must bind energy to the provenance of the command being
   executed (`Product.Counterexamples.command_bypass`, `no_filter`; `GateRefinement`
   commit-boundary counterexamples).
2. **A mechanised, composed timed bound to physical quiescence**, `FencedFinality.lean`:
   - `finality`: energy support, committed command and still-capable pending commands are all
     free of the retired authority after `t_c + W + T + δ`;
   - `Drift.finality_real`: the same in real time with gate clock drift;
   - `recoverable`: no trap states;
   - assumptions: unbounded hidden downstream delay, a finite fence namespace with verified
     flush, a gate that may never hear of the cut.
3. **Minimality.** Every protocol rule has a counterexample when dropped:
   - setpoint hijack,
   - stale token replay,
   - authority rollback,
   - id reuse,
   - unverified flush,
   - value-only readback,
   - power or command bypass.
4. **Retrofit on a stock, non-safety drive.**
   - ODrive's CAN node-id dispatch repurposed as an epoch fence;
   - paired-tag session readback;
   - both executed by SIL on unmodified firmware (mutation-checked).
   - the gate logic as portable C, run against the same firmware code with tokens, authenticated
     commands, make-before-break and a firmware loop (mutation-checked);
   - the firmware loop's C code explored against the finality property itself, exhaustively at
     small bounds, under delay, loss, replay, forgery, resets, crashes and a hung loop (C31);
   - honest negatives: the first code had two finality bugs, both in places where the model
     abstracts (32-bit clock wrap against unbounded time, C30; a predictable challenge against
     "the authority issues only for the current challenge", C35). Found by review, fixed; the
     first fix is proved, the second is checked by exploration with its counterexample.
5. **Supporting result, not a headline:** a mechanised statement of the known
   lease-without-fencing limitation for hidden commits (`Impossibility.lean`). Cite Chubby
   §2.4 lock-delay, Kleppmann 2016, and Santos-Grueiro arXiv 2609.02866 as closest.
6. **Platform evidence:** static RE of the Raspberry Pi 5 RP1 showing why the host platform
   cannot be the finality point.

## Section plan

| § | Content | Main artifacts |
|---|---|---|
| 1 | Problem: revocation vs persistent/queued physical effects; acceptance ≠ effect | brief; `rp1-fw/AXIOMOS-IMPLICATIONS.md` |
| 2 | System model: authority service, gate, downstream, drive, output stage; threat model (retired domain keeps upstream access) | `FencedFinality.lean` `Step` |
| 3 | Why the host platform cannot be the boundary (Pi 5 RP1: no ownership, outputs persist through host/PCIe failure, revocation path = failure path) | `rp1-fw/RP1_*.md` |
| 4 | Why some fence is unavoidable (mechanised lease-without-fencing limitation; cite Chubby, Kleppmann, Santos-Grueiro) | `Impossibility.lean` §Impossible |
| 5 | Fencing protocol and composed theorem; clock drift; recoverability | `FencedFinality.lean` |
| 6 | Necessity of each rule (counterexample table) | `FinalityProduct`, `GateRefinement`, `FiniteFence`, `Impossibility` §Fence |
| 7 | Realisation on ODrive v3: node-id fence, filter-renewal window, paired-tag readback, EN_GATE interlock | `odrive/`, `odrive/sil/` |
| 8 | Evaluation (as it would read under stage A): SIL on the drive's unmodified CAN code (X3 included); exhaustive and random exploration of the gate firmware against the bound (single and paired faults, flush); mutation analysis sorting rules by necessity; STM32 image in Renode; the four bugs found (clock wrap, future challenges, interrupt-counted clock, failed write then reset). Hardware (A+, C) as future work | `odrive/sil/`, `odrive/gate/stm32/`, `finality/PROOF.md` |
| 9 | Related work; limitations; kill criteria | below |

## Claims and evidence

Evidence types:
- **P** proved in Lean (no `sorry`; standard axioms)
- **E** executed on real code (SIL)
- **S** static source or datasheet reading
- **M** finite model check
- **K** proved on the C code by an inductive model check (CBMC; unbounded runs, MACs as free values)
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
| C16 | Authenticated, unforgeable tokens; challenges the authority can tell the gate issued (unpredictable, or tagged by the gate) | A | crypto obligation (abstracted in the proofs; draft MAC scheme in `odrive/gate/`) |
| C17 | Fence holds on real CAN hardware and timing | O | `odrive/bench/fence_bench.py`, needs board |
| C18 | Hijack physically observable with a power-only gate and absent with the full gate | O | X3, needs bench |
| C19 | Multikernel Linux (master `bca8ae161fa6`) can re-lease a PCI function before the retired kernel's CPUs are confirmed stopped, so stale MMIO reaches the device under the new lease; the finality bound does not depend on Multikernel cut latency | S | `finality/MULTIKERNEL.md` (static reading; reference design, no repro planned) |
| C21 | Finality holds across gate resets when the challenge and session counters persist and boot flushes; a reset that restarts either counter breaks it | P | `Fenced.finality`, `forgetful_session_reset`, `forgetful_challenge_reset` |
| C22 | Make-before-break: a handover from a confirmed holder can keep the output energized at every tick while both leases are live; finality still holds | P | `Fenced.bumpless_handover`, `Fenced.finality` (`supp2`) |
| C23 | Keeping energy on the previous holder's lease alone during a handover is unsafe | P | `Fenced.old_lease_alone_breaks` |
| C24 | Persistent monotonic challenge and session counters on the gate MCU | A | hardware obligation |
| C25 | Setpoint hijack in SIL: with a power-only gate, unmodified ODrive CAN code runs the retired controller's setpoint under the new lease; with the gate core (`odrive/gate/gate.h`) it does not, including a lost frame, a stuck frame, lease expiry, gate reset and id exhaustion | E | `odrive/sil` X3a–X3o; `mutate.py` |
| C26 | The gate core accepts a token only for the open challenge, inside W, once, with a valid tag; commands are accepted only under the holder's session key, each sequence number once; a spent failed-tag budget drops the holder | E | `odrive/sil` T1–T9, C1–C6 |
| C27 | Make-before-break in the gate core: enable stays high across a handover only while both leases are live and the old holder was confirmed; confirmation ends the overlap | E | `odrive/sil` H1–H8 (code counterpart of C22, C23) |
| C28 | A firmware loop over a board interface runs the whole sequence (challenge, token, rotation, authenticated command, UART readback, EN_GATE, expiry, reset, storage failure) on a host port against unmodified ODrive CAN code | E | `odrive/gate/gate_fw.c`; `odrive/sil` FW0–FW14 |
| C29 | Every one of 37 mutants of the gate core and firmware loop fails at least one SIL check | E | `odrive/sil/mutate.py` |
| C30 | A deadline test on a wrapping 32-bit clock revives an ended lease 2^31 ticks later (found in our own gate core, reproduced, fixed); latching expiry is sound for any number of wraps if the gate looks at the clock at least once every 2^31 − T ticks | P, E | `ClockWrap.live_iff`, `zombie`, `latch_sound`, `no_latch_unsound`; `odrive/sil` W1–W4 |
| C31 | Timed finality (I1) and attribution (I2) hold for the gate firmware's C code in every reachable state of a bounded adversarial environment: delayed, lost and reordered downstream frames, replayed and forged tokens and commands, stale readback, gate reset, crash after a storage write, failed write, drive reboot, firmware hang | M (on code) | `odrive/sil/explore.c`: exhaustive at small bounds, random walks at larger ones |
| C32 | Which gate rules finality needs: removing one breaks I1 or I2 in the explored space; the rest are hardening, availability or promptness | M (on code) | `mutate.py` against `explore.c`; table in `PROOF.md` |
| C33 | EN_GATE held by a hardware one-shot armed with the time left on the lease: a hung firmware loop cannot extend the output past the lease | M (on code), A | `gate_enable_for`; `explore.c` fault "firmware hangs"; the timer is a hardware obligation |
| C35 | A predictable challenge that the authority cannot verify breaks finality: a token obtained for a future challenge outlives its holder's revocation (found in our own firmware loop; fixed with a gate-tagged challenge, no RNG needed) | M (on code) | `explore.c` with `-DAUTHORITY_UNCHECKED`: 19-step I1 counterexample; mutant "challenge tag not bound to its value" |
| C36 | The firmware loop performs a verified flush when node ids run out (only an authentic token can trigger it; TX abort and drive reset come before the cleared id set is stored), and finality holds across flushes in the explored space | M (on code), E | `odrive/sil` FW15–FW18; `explore.c` flush configuration; mutants "flush stored before the drive is reset", "flush without a drive reset" |
| C37 | Finality holds with any two different fault classes in one run (reset, crash after write, failed write, drive reboot, firmware hang) | M (on code) | `explore.c -DFAULT_PAIRS` (`EXPLORE=deep`) |
| C38 | A complete STM32F4 image of the gate (register-level board layer, no vendor library) links and passes a 16-step end-to-end sequence in Renode's STM32F4 model, including EN_GATE falling by the timer alone with the CPU halted | E (emulation only) | `odrive/gate/stm32/renode_test.sh` |
| C39 | A gate clock counted by an interrupt stretches leases across a firmware stall (found in emulation in our own board layer, fixed with a free-running hardware counter) | E (emulation) | `port_stm32f4.c`; `PROOF.md` |
| C40 | A key slot filled at provisioning but declared `const` lets the compiler delete the whole gate loop from the production image (found in our own board layer; build check and provisioning-style emulation now catch it) | E (build, emulation) | `odrive/gate/stm32/build.sh`, `renode_test.sh`; `PROOF.md` |
| C41 | The firmware loop arms EN_GATE and forwards setpoints only under a live lease, and never past i + W + T (i: when the gate first sent the challenge behind the lease); a token is redeemed only for the challenge sent last, within W; for every T, W < 2^30, every run length, any number of frames per poll, resets, failed writes, and any clock step within the latch obligation | K | `odrive/sil/prove_fw.c` (P1–P3), `prove.sh` |
| C42 | Reading the clock once per poll breaks the bound: a flood of upstream frames keeps one poll running, and EN_GATE is then armed from a stale time past the lease end (found by the proof in our own loop; fixed by a clock read per frame and right before arming) | K, E | `prove_fw.c`; SIL FW19, FW20; mutant "clock read once per poll" |
| C43 | On the STM32F4 image the path from the clock read to arming the one-shot has no loop: about 105 instructions plus at most one 18-instruction UART interrupt, under about 25 µs at 16 MHz. The gate's own share of δ is that gap; the drive's share (EN_GATE to zero phase current) stays an assumption | S | disassembly of `gate.elf`; `PROOF.md` |
| C44 | A 32-bit challenge tag with no failure budget at the authority lets a still-authorized controller guess a future challenge's tag (about 6 days expected at bus rate) and redeem it after revocation; the authority must lock out after a few failures (found by independent review) | S, A | `authority.py` `ChallengeGuard`; `PROOF.md` |
| C34 | The gate firmware loop compiles for Cortex-M4 and Cortex-M0+ with no dependencies beyond the board interface, `memcpy`/`memmove`/`memset` and `strtof` (about 3 kB of code) | E (compile only) | `check.sh` |
| C20 | Multikernel master applies a deferred PCI config write from a halted incarnation to a re-spawned incarnation's lease (instance-id reuse without generation); fixed by `d83cf0024f4f` in open PR multikernel/linux#41, reintroduced by upstream's lease rework | S | `finality/MULTIKERNEL.md`; branch selftests model it |

## Threats to validity (state up front)

- **Model–implementation gap:** no refinement proof from gate firmware to `Fenced.Step`.
  The gate core and firmware loop (`odrive/gate/`) exist, are SIL-tested on a host port and are
  explored against the finality properties, exhaustively only at small bounds (C31). The
  model and the code already differ in listed ways (`PROOF.md`), and one real bug (C30) sat
  in exactly such a difference: unbounded time in the model, a 32-bit clock in the code.
  An STM32F4 board layer exists and passes an end-to-end sequence in Renode emulation (C38).
  It has never run on an MCU, and nothing is timing-verified.
- **Message authentication is a draft:** one shared HMAC key, tags truncated to 64 bits
  (tokens) and 32 bits (commands, with a failed-tag budget) to fit classic CAN. Not reviewed
  cryptography; C16 stays an assumption.
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
| A plain reference monitor + sequence numbers proves the same | **Partly triggered at the mechanism level.** Device-side sequence numbers with a watchdog to a safe state are standard (PROFIsafe), and robot-side rejection of superseded leases exists (Spot). What remains: authority-handover semantics with persistent setpoints and a retired controller that keeps upstream access (C6: an energy-only gate fails), plus the machine-checked composed bound (C3). PROFIsafe's fixed 1:1 host–device binding does not cover handover. **Further narrowed (2026-11-12):** Das's *Last Gate Before Motion* publishes the final-gate architecture and continuing-effect authority as a paper theorem, under the assumption that the gate observes the pending output and checks atomically. Our claim is restricted to the case where that assumption fails. **Narrowed again (2026-11-13):** Das's UAS draft has epoch-fenced transactional handover at the gate and expiry-bounded offline exposure, and his later text names persisting downstream commands as something "the implementation must separately reconcile". We claim only the conjunction that closes that gap for an unmodified drive: id rotation toward the drive, readback before enable, the bound composed to the drive's output, energised handover, mechanised and explored code. See `finality/RELATED_WORK.md` |
| The device cannot expose a defensible finality point | Pi 5 RP1: **triggered**. ODrive v3: **not triggered** (C8, C9), but δ (C13) is unbounded in the datasheet |
| No better than a safety-MCU baseline | **Not triggered in proofs**: C6 (provenance) and C22 (energy stays on across a handover, which pause-and-replace cannot do). Needs X3 (C18) and a measured handover-overlap success rate on hardware |

## Evaluation plan (hardware: stages A+ and C, pending)

Hardware: ODrive v3.6-compatible board on fw 0.5.x, a CAN adapter, UART, a logic analyzer,
and a low-voltage current-limited supply.

| Experiment | Purpose |
|---|---|
| `fence_bench.py` T0–T4 | readback latency, rotation latency, filter-renewal window, stale-frame rejection, post-reset id |
| δ distribution | EN_GATE↓ → gate-drive off, gate discharge |
| X3 | setpoint hijack, baseline vs fenced gate, plus the X3-stuck variant |
| X1, X2, X4, X5 | persistence, lease ≠ traffic, recovery replay, energy removal under livelock |

Stage A+ (gate board only, no drive):

| Experiment | Purpose |
|---|---|
| EN_GATE one-shot | pulse length against the lease; edge jitter |
| Halted CPU | debugger halts the core mid-lease; EN_GATE must fall at the lease end (Renode S11 on silicon) |
| Gate latencies | token to rotation frame; command to forwarded frame; readback to EN_GATE |
| Flash write time | the storage write that sits in the handover path |

Report every measurement as a measured distribution, never as a bound.
