# Paper outline: timed actuation finality across controller replacement

Status: outline and evidence map, not prose. Every claim below points to an artifact in this
repo. Nothing has been run on motor hardware.

## Working title

*Energy Is Not Authority: Mechanised Timed Finality for Actuator Handover*

The earlier title, "Revoked but Still Moving…", collides with IETF
draft-das-finality-bound-revocation ("Revoked but Still Executable"). See
`finality/RELATED_WORK.md`.

## Thesis (one paragraph)

When a controller's authority is revoked, commands it already issued can still reach an
actuator: queued, in flight, stuck in a bus controller, or persisting in the drive's setpoint
register.

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

1. **Energy authority is not command authority.** With persistent actuator setpoints, an
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
| C19 | Multikernel Linux (master `bca8ae161fa6`) can re-lease a PCI function before the retired kernel's CPUs are confirmed stopped, so stale MMIO reaches the device under the new lease; the finality bound does not depend on Multikernel cut latency | S | `finality/MULTIKERNEL.md` (static reading; reference design, no repro planned) |
| C21 | Finality holds across gate resets when the challenge and session counters persist and boot flushes; a reset that restarts either counter breaks it | P | `Fenced.finality`, `forgetful_session_reset`, `forgetful_challenge_reset` |
| C22 | Make-before-break: a handover from a confirmed holder can keep the output energized at every tick while both leases are live; finality still holds | P | `Fenced.bumpless_handover`, `Fenced.finality` (`supp2`) |
| C23 | Keeping energy on the previous holder's lease alone during a handover is unsafe | P | `Fenced.old_lease_alone_breaks` |
| C24 | Persistent monotonic challenge and session counters on the gate MCU | A | hardware obligation |
| C20 | Multikernel master applies a deferred PCI config write from a halted incarnation to a re-spawned incarnation's lease (instance-id reuse without generation); fixed by `d83cf0024f4f` in open PR multikernel/linux#41, reintroduced by upstream's lease rework | S | `finality/MULTIKERNEL.md`; branch selftests model it |

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
| A plain reference monitor + sequence numbers proves the same | **Partly triggered at the mechanism level.** Device-side sequence numbers with a watchdog to a safe state are standard (PROFIsafe), and robot-side rejection of superseded leases exists (Spot). What remains: authority-handover semantics with persistent setpoints and a retired controller that keeps upstream access (C6: an energy-only gate fails), plus the machine-checked composed bound (C3). PROFIsafe's fixed 1:1 host–device binding does not cover handover. See `finality/RELATED_WORK.md` |
| The device cannot expose a defensible finality point | Pi 5 RP1: **triggered**. ODrive v3: **not triggered** (C8, C9), but δ (C13) is unbounded in the datasheet |
| No better than a safety-MCU baseline | **Not triggered in proofs**: C6 (provenance) and C22 (energy stays on across a handover, which pause-and-replace cannot do). Needs X3 (C18) and a measured handover-overlap success rate on hardware |

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
