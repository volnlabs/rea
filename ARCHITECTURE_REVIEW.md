# Review: AxiomOS actuation-authority architecture

**Brief reviewed:** *Actuation Authority Across Replaceable Kernel Domains*, prepared 4 November
2026. The file `axiomos-actuation-authority-architecture-review(1).pdf` has text identical to the
original.

**Evidence base:** the proofs, SIL tests and static analyses in this repo. Each claim below names its
artifact. Nothing has run on motor hardware.

## Verdict

The trust-boundary design is good. Three fixes are needed before Phase B:

1. The MCU gate must hold leases that **expire**, not epochs that are **pushed** to it.
2. The MCU must bind energy to the **provenance of the executing command**, not only to the command
   stream.
3. The finality bound must be restated **without pipeline-sum terms**.

The novelty framing should move from "across replaceable kernel domains" to "across controller
replacement". The main open risk is handover availability against the brief's own pause-and-replace
baseline.

## What holds

| Brief element | Evidence |
|---|---|
| Only the guardian and final gate can cause output; the adaptation domain is outside the trust boundary | `Fenced.finality` holds even if the gate is never notified of the cut, so Linux and the AI stack stay out of the safety argument |
| A separate MCU/FPGA is the final gate | A Multikernel instance cannot be the guardian: it shares reset, power, interrupt-controller and physical-memory domains with the domain it must contain (`finality/MULTIKERNEL.md`). Pi 5 RP1 outputs persist through host crash and PCIe loss (`rp1-fw/RP1_RESET_AND_OUTPUT_PERSISTENCE.md`) |
| PAC-Bayes ranks candidates only after hard admission | Unchanged; out of scope for paper 1 |
| Kill criteria and required baselines | Sound. Current status in `PAPER_OUTLINE.md` |
| Phase A: formal counterexamples first | Done in Lean 4 (`finality/`). All five adversarial traces are covered (table below; the gate-reset trace was added after this review) |

### Phase A trace coverage

| Brief trace | Covered by |
|---|---|
| Revoked after enqueue, before dequeue | `Fenced.finality` with hidden downstream queue; `Impossible.lost_frame_blocks` |
| Controller killed after acceptance, before ACK | `GateRefinement` commit boundary; `Refine.no_pending_hijack` |
| Guardian resets after actuation, before recording completion | `Step.gateReset` under `Fenced.finality`; `forgetful_session_reset`, `forgetful_challenge_reset` (added after this review) |
| Persistent PWM energized after controller quiescence | Energy part of `Fenced.finality` (δ obligation); `Finality.lean` Theorem B |
| Independent authority reauthorizes the same command after the root is cut | `Fenced.reauthorized_with_stuck_frame`; `Product.Counterexamples.command_bypass` |

## Required changes

### 1. The bound is not a pipeline sum

The brief proposes
`Δ_final ≤ R_cut + R_IPC + R_scheduler + R_queue + R_guardian + R_device + R_physical-drain`.

**Why the sum fails:**

- When downstream queues can hide a command for an unbounded time, `R_queue` is unbounded too.
- `Impossible.no_timeout_helps` shows that no waiting-based gate policy is safe and live after an
  authority change once a frame can be lost or stuck.
- A sum of stage response times therefore either diverges or assumes away the hard case.

**What the mechanised bound is.** It is `t_c + W + T + δ`:

| Term | Meaning |
|---|---|
| W | Challenge freshness window |
| T | Lease length |
| δ | Output-stage shutdown time |

It has no IPC, scheduler, queue or kernel-quiescence term. The gate does not wait for queues to drain.
It **fences** them (node-id rotation, verified flush). `Drift.finality_real` extends this to a gate
clock that drifts by a factor of up to R.

**Change:** in §2 and §4, replace the sum with the fenced bound. Take "kernel-domain quiescence" out of
the critical-path chain "cut → kernel quiescence → queue fencing → output". Kernel quiescence affects
availability and recovery, not the safety bound.

### 2. Reframe novelty away from kernel domains

"Across replaceable kernel domains" makes Multikernel sound essential, but the theorem does not depend
on it. Multikernel Linux also has the same failure modes, found by static reading of master
`bca8ae161fa6` (`finality/MULTIKERNEL.md`):

- **C19:** a PCI function can be re-leased before the retired kernel's CPUs are confirmed stopped.
  Stale MMIO then reaches the device under the new lease. This is the energy ≠ authority failure.
- **C20:** a deferred config write from a halted incarnation is applied to the re-spawned
  incarnation's lease. This is id reuse without a generation.

**Change:** frame the paper as timed finality **across controller replacement**. Kernel domains become
one source of stale commands, and Multikernel becomes a second case study supporting the minimality
claim, not a dependency.

### 3. The MCU fence must work by expiry, not notification

**The problem.** In Figure 1, the epoch cut reaches the MCU through the software guardian. If the
guardian is compromised, crashed or cut off, the MCU never learns of the cut. Its epoch check then
keeps admitting the retired epoch.

**Change.** The MCU holds **leases that expire** on its own clock. A lease is renewed only by an
**authenticated token bound to a fresh MCU challenge** (W, T in `FencedFinality.lean`; obligation C16).
Revocation is then non-renewal, and no message has to reach the gate.

The brief's MCU "watchdog" must be fed **only** by valid tokens. A watchdog fed by any traffic is a
traffic timeout, not a lease. ODrive v3's watchdog is exactly this, off by default
(`odrive/ODRIVE_COMMAND_LIFECYCLE.md`, C10).

### 4. The MCU checks too little

**(a) Exact-effect checks.** The envelope, grant-scope and effect checks live only in the software
guardian. The MCU repeats only stale-epoch, sequence, watchdog and E-stop checks, so a compromised
guardian removes exact-effect authority entirely.

**Change:** either put compact grant verification on the MCU (effect id, envelope bounds, token MAC),
or state plainly that exact-effect authority is best-effort above the trust root.

**(b) Energy is not command authority.** The fix depends on what generates the output:

- **The MCU drives a stock drive** (ODrive, an industrial servo): an epoch fence on the command stream
  does not reach the setpoint the drive already holds. A power-only gate held by the new authority then
  executes the retired authority's setpoint. This is the setpoint hijack (C6:
  `Product.Counterexamples.command_bypass`, `no_filter`).
  - **Change:** the gate energizes only when the *executing* command is confirmed to belong to the
    current session.
  - Mechanism: per-session node-id rotation, session-tagged readback and an energy interlock. This is
    SIL-tested on unmodified ODrive CAN code (`odrive/sil/`, C8, C9).
- **The MCU generates PWM itself:** the MCU must **reset its output to the safe state on every lease or
  epoch change** and require a fresh command under the new lease. No output state may carry across the
  boundary.

### 5. Close two modelling gaps

**Status (2026-11-11): both are now modelled** in `finality/FencedFinality.lean`; see
`finality/PROOF.md`, "Gate reset and make-before-break handover". The text below is the original
finding.

**Gate reset (trace 3).** `FencedFinality` has no gate-reset step: its used-id set, challenge counter
and lease timers never get lost. A gate that reboots and forgets them breaks the fence:

| What the gate forgets | Resulting break | Counterexample |
|---|---|---|
| Used ids | Id reuse | `FiniteFence.reuse_breaks` |
| Challenge counter | Token replay | Stale-token counterexamples |

**Change:**

- **Requirement:** the MCU keeps a persistent monotonic counter, or boots with every lease expired and
  requires a verified flush before it will energize.
- **Model:** add a `gateReset` step to `FencedFinality.lean` with that recovery rule, and re-prove
  `finality` and `recoverable`.

**Handover availability.** The current protocol de-energizes during every handover. A switch clears
confirmation until rotation, commit and readback complete, which makes it a bounded pause-and-replace.
The brief lists pause-and-replace as a **baseline**, so on availability the mechanism currently only
ties it (kill criterion 3).

**Change:** model make-before-break handover, where both grants support the effect at once. This uses
the brief's "alternate support" and "independent support" invariants, which are not yet modelled
(single protected effect per gate). Until then, claim provenance and bound, not availability.

## Smaller corrections

- **Platform constraint, §5.** Multikernel now has `arch/arm64/multikernel/` (since 2026-09-20).
  The Pi 5 is still excluded: it needs a GICv3 with an ITS, and BCM2712 has a GIC-400 (GICv2) with
  Broadcom MIP MSI controllers. RP1 is a single PCIe function, so its pins cannot be split between
  domains. The x86-for-domains / Pi 5 + MCU-for-actuation split stands.
- **δ.** TI's DRV8301 datasheet gives no maximum EN_GATE turn-off time. "Derived Δ_final" for a drive
  path must use a measured δ distribution, reported as a measurement, not a WCET (brief §5 already warns
  against this).
- **Related work, §3.** Add the fencing prior art (Chubby sequencers and lock-delay, Kleppmann fencing
  tokens, Raft terms, HDFS QJM epochs), safety fieldbuses (PROFIsafe, FSoE, CIP Safety ownership
  reset) and robot leases (Spot). The defensible delta is in `finality/RELATED_WORK.md`.

## Revised Figure 1 annotations (minimal)

| Component | Change |
|---|---|
| Actryn authority service | Issues authenticated, challenge-bound lease tokens; revocation = stop issuing |
| Actuation guardian | Policy and exact-effect checks; **not** required for the finality bound |
| MCU/FPGA final gate | Lease expiry on its own clock; token verification; node-id/session fence; persistent counter across reset; output reset on lease change; energy interlock bound to confirmed session readback |
| Δ_final | `t_c + W + T + δ` (real time: scaled by drift R) |

## Next steps, in order

1. Add `gateReset` to `FencedFinality.lean` (closes trace 3).
2. Model make-before-break with alternate support (decides kill criterion 3 in theory).
3. Phase B hardware: MCU gate with expiring leases, then measure δ and run X3 (setpoint hijack,
   baseline vs fenced), plus a pause-and-replace baseline.
4. Optional: QEMU reproductions of Multikernel C19/C20 for the second case study.
