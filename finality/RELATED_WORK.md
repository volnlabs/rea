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
| Das, *The Last Gate Before Motion: Actuation-Bound Execution Finality and a Bounded Prevention Theorem…*, Zenodo 10.5281/zenodo.23756590 (v2, 29 Oct 2026) | self-published disclosure, full text read | An "Actuation Finality Boundary" re-verifies authority, revocation state, generation, replay state and path completeness at output commit. Separate authority to initiate, **continue**, modify, stop, release and reset an effect ("Latched outputs can remain physically effective after authority changes"). Rollback-protected consumption state (A7). Paper theorem under eight assumptions | **Closest work overall.** Final gate at the actuator, continuing-effect authority, path exclusivity (its A8 = our C15), persistent counters (its A7 = our C24) | Assumes the gate "observes the actual pending output and controls the first protected physical effect" (A2) with atomic check-to-output (A6): no untrusted drive, queue or setpoint register *behind* the gate. No time bound from revocation to quiescence (only a hot-path latency budget). No handover protocol, no expiry without notification, no mechanised proof, no counterexamples, no hardware |
| Heydari Shahna et al., *From LLM Plans to Authorized Motion: Execution-Bound Authorization for Excavators*, arXiv 2610.14245 (9 Oct 2026) | preprint, abstract verified | One-use lease bound to the exact motion; atomic dispatch rechecks authority; periodic supervision detects revocation and commands a stop trajectory; simulation only | Leases and revocation on a physical machine | Revocation is detected by polling, not by expiry; no retired controller with upstream access; no bound, no proof, no hardware |
| OMG DDS `OWNERSHIP` (EXCLUSIVE) with `OWNERSHIP_STRENGTH`, `LIVELINESS`, `DEADLINE` | standard (via RTI API docs and OMG issue tracker), partly verified | The **reader** arbitrates: only the strongest live writer may update an instance; ownership fails over on lost liveliness. OMG issue DDS15-332: mismatched lease durations can make ownership toggle | Receiver-side single-owner arbitration with leases, widely deployed in robotics (ROS 2) | No epoch on samples, so no fence against a superseded writer's delayed samples; no energy path; no bound |
| CIP Safety (ODVA) ownership / TUNID / SNN | vendor docs via search summaries (Rockwell page returned 403), **not verified** in primary text | A safety I/O device has a **configuration owner** (originator), identified by safety network number + target unit network id. Re-binding to a new owner requires the CIP **Safety Reset** service or **Reset Ownership** back to out-of-box state | **Closest handover analogue:** ownership ≈ our session holder; reset-and-re-own ≈ our verified flush + fresh id | Handover is a procedural re-commissioning through reset, not a protocol with a stated time bound; I found no statement about a previous owner's in-flight messages or persistent motion setpoints |
| FSoE (Safety over EtherCAT, ETG.5100) | vendor docs, partly verified (Synapticon) | Point-to-point master–slave connection carrying "a connection ID for identifying the connection"; on a missed watchdog "the safe state (STO) is triggered"; safety data runs "in the same EtherCAT frame as the standard process data". Vendor note: re-integration after a master change is implementation-dependent | Connection id + watchdog → STO ≈ fence + lease + energy interlock | Fixed point-to-point connection; master change not specified in what I read |
| openSAFETY (SADR, SCM) | vendor glossary only | Safety node addresses within a safety domain, managed by a safety configuration manager | — | No handover semantics found |
| CAN identifier randomisation / ID-hopping (e.g. Humayed & Luo; Karray et al., 2018) | peer-reviewed (not read in full) | Rotating or randomising CAN message ids against spoofing, replay and reverse engineering | Id rotation as a mechanism | Security against attackers, not authority fencing; does not address stale *legitimate* frames from a retired controller |

## What remains defensible

None of the items below is established yet. Each is a claim to test in the paper.

1. **Persistent physical effects break the "fence the write" model.** Fencing literature fences
   *discrete writes*. An actuator keeps executing an accepted setpoint after acceptance, and the
   energy path is separate from the command path. The setpoint-hijack counterexample (a
   power-only, STO-like gate lets a retired controller's command execute under the new
   authority's lease) and the `Fenced.finality` conclusion are about the **interaction** of
   energy authority and command provenance.
   - **Safety fieldbuses (PROFIsafe, FSoE, CIP Safety)** fence and watchdog the *safety
     channel*, which carries STO and safety I/O.
     - FSoE safety data rides "in the same EtherCAT frame as the standard process data"
       (verified).
     - **Inference, not verified:** the motion setpoints themselves are standard, non-safety
       process data with no authority fencing.
     - If that holds, an industrial drive after controller handover is exactly the hijack
       configuration: energy enabled by the safety channel, setpoint from an unfenced channel.
   - **Not found in:** STO, PROFIsafe (1:1), FSoE (point-to-point), CIP Safety (ownership by
     reset), Spot docs, or the software revocation preprints.
   - **Confidence:** moderate. Checked 2026-11-12: Synapticon's CiA 402 documentation lists
     controlword and target velocity as cyclic PDO data, and Kollmorgen describes FSoE as a
     checked container *inside* the standard process data. That supports the inference; what a
     drive does with a held setpoint on master change is still unverified.
   - **Narrowed by Das (Zenodo, Oct 2026):** the idea that a continuing effect needs
     continuing authority is now published. Our remaining claim is the case his assumptions
     A2 and A6 exclude: the gate is **not** atomic with the effect, because an untrusted drive
     holds the setpoint behind it.
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

**An honest limit on availability claims.** Our protocol also passes through an **energy-off
interval** at every handover: a switch clears confirmation, so LEASE_OK stays low until rotation,
commit and readback complete. It is therefore a bounded *pause-and-replace*, like CIP Safety's
ownership reset and like the brief's own "pause-and-replace controller update" baseline.

Its advantages over reset-based re-ownership are:
- no drive reset while fresh ids remain (K − 1 handovers between flushes);
- a provenance guarantee for the *setpoint* channel, not only the safety channel;
- a machine-checked time bound.

**Update (make-before-break).** `FencedFinality.lean` now keeps LEASE_OK across a handover from
a confirmed holder while both leases are live (`bumpless_handover`), and shows the one-lease
variant is unsafe (`old_lease_alone_breaks`). The claim this supports is narrow: energy can stay
on across a voluntary handover, with the drive running the previous holder's last setpoint until
the new holder confirms. Brief kill criterion 3 ("no tighter bound or better availability than a
safety-MCU baseline") still has to be tested against an ownership-reset baseline on hardware.

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

- **Standards:** IEC 61784-3 normative clauses; ETG.5100 (FSoE) master change; ODVA CIP Safety
  ownership-transfer guarantees for in-flight messages. Searched 2026-11-05: CIP Safety supports
  re-ownership via reset; FSoE leaves master change to the implementation; nothing found for
  openSAFETY.
- **Drive manuals:** whether drives carry motion setpoints only as standard process data (the
  hijack-configuration inference above).
- **Spot:** behaviour of running commands and persistent effort on lease revocation. Searched;
  only business and policy coverage found.
- **Formal methods:** TLA+ or Coq/Lean work on lease + fencing (e.g. verified lock services),
  and Gray & Cheriton (SOSP 1989) leases.
- **Robotics/CPS:** controller-handover or Simplex work with authority semantics (the brief's
  Simplex/runtime-assurance line).
- **Full texts:** of the three 2026 preprints (abstracts only).

**Known bug class we hit ourselves (2026-11-12).** Our first gate core tested lease expiry with
a signed difference on a wrapping 32-bit clock, which revives an ended lease 2^31 ticks later
(`PROOF.md`, `ClockWrap.lean`). This is a known class, not a contribution: TCP's PAWS has the
same hazard with 32-bit timestamps and the same remedy, invalidating the stored timestamp once a
connection has been idle for more than 24 days (RFC 7323 §5.5, read). What we add is only that a
model with unbounded time cannot see it, and that the latch is proved.

## Sources

- RFC 7323 §5.5 (outdated timestamps): <https://www.rfc-editor.org/rfc/rfc7323.txt>

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
- Das, The Last Gate Before Motion: <https://zenodo.org/records/23756590>
- Excavator execution-bound authorization: <https://arxiv.org/abs/2610.14245>
- DDS ownership: <https://community.rti.com/static/documentation/connext-dds/4.5e/ndds.4.5e/doc/html/api_cpp/structDDS__OwnershipQosPolicy.html>, <https://issues.omg.org/issues/DDS15-332>
- Setpoints as standard PDO data: <https://doc.synapticon.com/actilink_s/system_integration/coe_cia_402.html>, <https://www.kollmorgen.com/sites/default/files/KAS%20-%20System%20Safety%20Application%20Note%20-%20ver1c.docx>
- CAN id randomisation: <https://www.ittc.ku.edu/~bluo/pubs/p19-Humayed.pdf>, <https://rd.springer.com/chapter/10.1007/978-3-319-98935-8_11>
- CIP Safety ownership/TUNID (vendor): <https://www.rockwellautomation.com/en-fi/docs/technical/logix5000/_online/1756-rm012/guardlogix-5580-and-compact-guardlogix-5580-safety/safety-i-o/safety-i-o-configuration-variations.html> (403 when fetched), <https://download.sew-eurodrive.com/download/html/31985165/en-EN/4222267303555538347403.html>, <https://download.sew-eurodrive.com/download/html/33955921/en-EN/4222281703563322839947.html>
- FSoE: <https://www.synapticon.com/en/motion-control-academy/fsoe-functional-safety-over-ethercat>, <https://ethercat.org/download/documents/Safety-over-EtherCAT_Introduction.pdf>, <https://webhelp.kollmorgen.com/AKD2G/English/Content/AKD2G-S%20Install/e/fsm/Keywords/AXISx.SAFE.FSOE/AXISx.SAFE.FSOE.LASTERROR.htm>
- openSAFETY glossary: <https://product-help.schneider-electric.com/Machine%20Expert/V2.2/en/SafeLog/SafeLog/D-SE-0068000.html>
