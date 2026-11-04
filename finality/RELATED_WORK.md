# Related-work check: fencing, leases, device-side safety, authority revocation

Purpose: test the novelty claims in `../PAPER_OUTLINE.md` against the closest prior art before
writing. Done 2026-11-05.

Source quality is marked per item:
- **peer-reviewed** or **standard**: strongest
- **preprint** (unreviewed) or **draft**
- **vendor doc** or **blog**: weakest

"Verified" means I read the claim in the primary source myself, not only in a summary.

## Bottom line

Every *individual mechanism* in our protocol is established prior art:
- receiver-side epoch or sequence checks,
- "leases/timeouts alone are unsafe",
- watchdog to a de-energised safe state at the device,
- hardware energy removal (STO),
- authority epochs with sink fences,
- effect-closure impossibility for hidden provider state.

`Impossibility.lean` is a **mechanised formulation of known folklore**. Chubby already calls
lock-delay, the timeout fallback for servers that cannot check sequencers, "imperfect". It is
not a standalone contribution.

Kill criterion 1 ("a reference monitor plus sequence numbers already proves it") is
**partly triggered at the mechanism level**:
- Device-side sequence numbers with a watchdog to a safe state are standard (PROFIsafe).
- Robot-side rejection of commands carrying an older lease exists (Boston Dynamics Spot).

What survives is the **composition and its physical specifics** (§ "What remains defensible").

## Prior art

| Work | Type | What it establishes | Overlap with us | What it lacks vs. us |
|---|---|---|---|---|
| Kleppmann, *How to do distributed locking* (blog, 8 Feb 2016) | blog, verified | Lease/timeout-based locks are unsafe under process pauses and arbitrary packet delay: "the code above is fundamentally unsafe, no matter what lock service you use"; "You cannot fix this problem by inserting a check on the lock expiry just before writing back to storage." Fix: monotonically increasing **fencing tokens** checked by the storage server | `Impossibility` + fence idea, informally | No proof; no persistent physical effect; no energy path; the resource is storage, not an actuator |
| Burrows, *The Chubby lock service* (OSDI 2006), §2.4 "Locks and sequencers" | peer-reviewed, verified | **Sequencer** (lock name, mode, generation) checked by the recipient server, which "should reject the request" if invalid. **Lock-delay** as "an imperfect but easier mechanism to reduce the risk of delayed or re-ordered requests to servers that do not support sequencers" | Receiver-side fence = our drive-side fence; lock-delay = our "timeout" policy, which we prove insufficient | No formal impossibility; no physical actuation; single lock, not authority composition |
| Ongaro & Ousterhout, Raft (USENIX ATC 2014) | peer-reviewed, verified | Terms act as logical clocks; "If a server receives a request with a stale term number, it rejects the request." | Receiver-side epoch rejection | Consensus replicas, not actuators; no energy or timing to physical quiescence |
| HDFS QJM epoch fencing | vendor/blog, **not verified** in Apache docs | JournalNodes reject writers whose epoch is below the promised epoch; separate fencing still recommended | Receiver-side epoch fencing in production storage | Same as above |
| Boston Dynamics Spot lease service | vendor doc, verified | Robot services accept a command only if its lease is the newest (epoch scopes sequence); a stale holder's command "will be rejected because it is now considered older"; leases go stale without `RetainLease` keep-alives | **Closest robotics prior art:** robot-side rejection of a superseded controller's commands, plus lease staleness | Doc does not say what happens to commands already executing or to persistent effort when ownership changes; no published timing bound or proof; proprietary integrated robot, not a third-party drive behind an untrusted bus |
| PROFIsafe / IEC 61784-3 functional-safety fieldbus profiles | standard (via Wikipedia + vendor manuals), partly verified | The **receiving F-Device** checks a monitoring number (sequence), a time expectation (watchdog/timeout) and a code name (F-Address), on a CRC'd black channel; detects repetition, loss, insertion, resequencing, delay and masquerade. Vendor manuals (ABB, CODESYS): on timeout or error the device outputs fail-safe values, normally de-energised. "The 1:1 communication relationship between F-Host and F-Device" | Device-side sequence check + watchdog to safe state ≈ our fence + lease + energy interlock, industrialised at SIL3 | Fixed **1:1** host–device relationship: no semantics for *authority handover* between controllers or for a retired controller that keeps upstream access; integrity CRC, not cryptographic authentication; no mechanised end-to-end timing theorem in the cited material |
| Safe Torque Off (IEC 61800-5-2), stop categories (IEC 60204-1) | standard (via vendor docs), not normative text | STO removes torque-producing energy from the motor ≈ stop category 0 (coast); prevents unintended start-up but does not itself stop motion | Our EN_GATE interlock is an STO-like energy path | STO is energy-only, with no command-provenance semantics. This is exactly why the setpoint hijack matters |
| Santos-Grueiro, *Temporary Authority, Permanent Effects: Commit-Time Authorization for LLM Agents*, arXiv 2607.10487 (v2 Oct 2026) | preprint, abstract verified | Authority checked at the commit point by a protected sink ("The sink validates it or consumes an expiring, single-use derived grant atomically with the effect") | Check at the sink | Software effects; no physical persistence; no timing bound; no hardware |
| Santos-Grueiro, *When Does Authorization End? Effect Closure at Provider Boundaries*, arXiv 2609.02866 (Sep 2026) | preprint, abstract verified | "Effect closure"; EFFECTBOUND returns a strategy, an **impossibility certificate**, or no verdict for providers with hidden state; Kafka: "all fixed-set brokers had applied the revocation, yet an earlier authorized request could still append" | **Very close in spirit** to `stuck_twin` / `lost_frame_blocks`: impossibility from hidden downstream state | Software providers; per-instance certificates rather than a general theorem over all gate policies; no physical output, energy path or timing bound |
| Zhu & Wang, *Authorization Revocation for Long-Running AI Agents: Root-Scoped Quiescence…*, arXiv 2609.21284 (Sep 2026) | preprint, abstract verified | Root-epoch cuts, fences of "old-root expansion and protected sinks"; late already-scheduled effects rejected with cut-plus-fence but not with cancellation alone | Authority epochs + sink fences + alternate support (the brief already lists this as **not novel** on its own) | No physical actuation, no timing bound |
| Das, *Revoked but Still Executable: … Finality-Bound Revocation*, IETF draft-das-finality-bound-revocation-00 (16 Sep 2026) | individual draft, verified | Revocation bound to the protected commit point, via a monotonic "Revocation Generation"; re-evaluate at dequeue/final commit; "Wall-clock timestamps are not sufficient when revocation and effectuation race." | Commit-point binding, generations, queue re-evaluation | Not a time bound; no physical actuation protocol; no mechanised proof. **Its title collides with our working title.** |
| CAN identifier randomisation / ID-hopping (e.g. Humayed & Luo; Karray et al., 2018) | peer-reviewed (not read in full) | Rotating or randomising CAN message ids against spoofing, replay and reverse engineering | Id rotation as a mechanism | Security against attackers, not authority fencing; does not address stale *legitimate* frames from a retired controller |

## What remains defensible

None of the items below is established yet. Each is a claim to test in the paper.

1. **Persistent physical effects break the "fence the write" model.** Fencing literature fences
   *discrete writes*. An actuator keeps executing an accepted setpoint after acceptance, and the
   energy path is separate from the command path. The setpoint-hijack counterexample (a
   power-only, STO-like gate lets a retired controller's command execute under the new
   authority's lease) and the `Fenced.finality` conclusion are about the **interaction** of
   energy authority and command provenance.
   - **Not found in:** STO, PROFIsafe (1:1, no handover), Spot docs, or the software
     revocation preprints.
   - **Confidence:** moderate. Not checked: FSoE / CIP Safety / openSAFETY and the IEC
     61784-3 normative text.
2. **A mechanised, composed timed bound to physical quiescence.** The bound covers authority
   service → gate → untrusted downstream with hidden commits → finite-namespace fence with
   verified flush → energy interlock → output stage. It holds with clock drift and a gate that
   may never learn of the cut.
   - **Prior art:** the software preprints have commit-point or quiescence notions without time
     bounds; PROFIsafe has timeouts but no published end-to-end theorem in what I read.
   - **Confidence:** moderate.
3. **Retrofit on a stock, non-safety drive.** Repurposing ODrive's CAN node-id dispatch as an
   epoch fence, plus paired-tag session readback, validated by SIL on unmodified firmware.
   Practical and specific, but **an engineering contribution**, not a conceptual one.
4. **Finite fence namespace with verified flush** (`FiniteFence`). The "K − 1 replacements
   between flushes" result is simple; useful for completeness, weak as a headline.

## Consequences for the paper

- **Drop impossibility as a headline contribution.** Present it as a mechanised statement of
  the known lease-without-fencing limitation, specialised to hidden commits. Cite Chubby §2.4,
  Kleppmann 2016, and Santos-Grueiro 2609.02866 as closest.
- **Lead with (1) and (2):** the energy/command composition and the mechanised end-to-end bound.
  Evidence: the hijack counterexample and `Fenced.finality`.
- **Position against PROFIsafe and Spot explicitly.** Show what they do not cover:
  - authority handover with a retired controller that keeps upstream access,
  - persistent setpoints,
  - a published end-to-end bound.
- **Change the working title** (collision with the IETF draft).
- **Re-state kill criterion 1 honestly:** the device-side mechanism is standard; the claimed
  contribution is the authority-handover semantics under persistent effects plus the
  machine-checked composed bound.

## Search gaps (not done)

- **Standards:** IEC 61784-3 normative clauses; FSoE, CIP Safety, openSAFETY handover
  behaviour (do any support re-binding a device to a new controller, and with what
  guarantees?).
- **Spot:** behaviour of running commands and persistent effort on lease revocation.
- **Formal methods:** TLA+ or Coq/Lean work on lease + fencing (e.g. verified lock services),
  and Gray & Cheriton (SOSP 1989) leases.
- **Robotics/CPS:** controller-handover or Simplex work with authority semantics (the brief's
  Simplex/runtime-assurance line).
- **Full texts:** of the three 2026 preprints (abstracts only).

## Sources

- Kleppmann 2016: <https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html>
- Burrows, Chubby (OSDI 2006): <https://static.usenix.org/event/osdi06/tech/full_papers/burrows/burrows_html/>
- Ongaro & Ousterhout, Raft: <https://raft.github.io/raft.pdf>
- HDFS QJM (secondary): <https://blog.cloudera.com/blog/2012/10/quorum-based-journaling-in-cdh4-1>
- Spot lease service: <https://dev.bostondynamics.com/docs/concepts/lease_service>
- PROFIsafe: <https://en.wikipedia.org/wiki/Profisafe>; vendor: <https://help.plc.abb.com/safety_base_profisafe_lib.html>, <https://content.helpme-codesys.com/en/CODESYS%20Safety%20Extension/sil3_fdevice_profisafe_status_diagnosis.html>
- STO (vendor summaries of IEC 61800-5-2): <https://download.sew-eurodrive.com/download/html/31960413/en-EN/28733575051.html>, <https://product-help.schneider-electric.com/Machine%20Expert/V2.2/en/Lx32sDr/Lx32sDr/Definitions-BDDA250D.html>
- Santos-Grueiro, arXiv 2607.10487: <https://arxiv.org/abs/2607.10487>
- Santos-Grueiro, arXiv 2609.02866: <https://arxiv.org/abs/2609.02866>
- Zhu & Wang, arXiv 2609.21284: <https://arxiv.org/abs/2609.21284>
- Das, IETF draft: <https://datatracker.ietf.org/doc/html/draft-das-finality-bound-revocation-00>
- CAN id randomisation: <https://www.ittc.ku.edu/~bluo/pubs/p19-Humayed.pdf>, <https://rd.springer.com/chapter/10.1007/978-3-319-98935-8_11>
