# Does Multikernel Linux help timed actuation finality?

Static reading of `multikernel/linux` master `bca8ae161fa6` (fetched 2026-11-10) and the local
branch `origin/mk/lifecycle-safety-submit-v44`. Nothing below has been executed.

## Short answer

Multikernel Linux is useful for **replacement and availability**: it lets the controller or AI domain
be force-halted and replaced without rebooting. It is **not a finality mechanism**, and on the Pi 5
it cannot run at all. Its role in the paper:

- Multikernel kernel domains are **one possible upstream source of stale commands**.
- `Fenced.finality` already tolerates them: the gate need never hear of the cut, so domain-halt latency
  (30 s graceful timeout, or never for a wedged CPU) does not enter `t_c + W + T + δ`.
- The brief's line "lets the adaptation environment crash … without putting its full Linux or AI stack
  inside the physical safety argument" holds **because** the fence is at the MCU gate, not in
  Multikernel.

## What changed since the brief (4 Nov)

| Brief said | Upstream now |
|---|---|
| No ARM64 directory | `arch/arm64/multikernel/` (34 commits, since 2026-09-20). Requires **PSCI ≥0.2 and GICv3**; PCI MSIs need an **ITS**; platform devices unsupported, INTx unavailable (`Documentation/multikernel/arm64.rst`) |
| Hotplug resource ownership | **PCI function leases** (`kernel/multikernel/lease.c`, 2026-11-03): config access proxied, IOMMU-confined DMA, per-lease MSI routes, function reset when the lease ends |
| Forced halt | Host fencing (CPUs turned off via PSCI; arm64 force halt via SDEI event 0 plus a pseudo-NMI stop IPI); "confirm a fenced host's CPUs parked by asking them" |

## Pi 5: still not usable

- **Interrupt controller:** BCM2712 has `arm,gic-400`, a GICv2 (`bcm2712.dtsi:337`). arm64
  Multikernel requires a GICv3.
- **MSIs:** PCIe MSIs go to `brcm,bcm2712-mip`, not to an ITS, so a lent function gets no interrupts.
- **RP1 granularity:** RP1 is one PCIe function, so all 28 GPIOs and every PWM channel would move
  as a single lease. Pins cannot be split between domains.
- **Reset does not stop outputs:** our RE (`rp1-fw/RP1_RESET_AND_OUTPUT_PERSISTENCE.md`) shows RP1
  outputs persist through PERST# and link loss at the firmware level. A lease-end function reset is
  therefore not physical quiescence, which is the brief's "kernel audit ≠ physical output" point,
  concretely.

The brief's platform split stands: x86 (or an arm64 GICv3 server or QEMU `virt`) for domain
lifecycle, and Pi 5 plus a separate MCU gate for actuation.

## Gap found: a device lease can be re-granted before the old kernel has stopped

This is the same shape as our setpoint hijack (`Product.Counterexamples.command_bypass`), one level
up.

1. `pciback.c:15`: "BARs, DMA and MSIs stay direct." A retired kernel's CPU that is still running
   can write the function's BARs. Nothing on the CPU side revokes that mapping, because there is no
   stage-2 or EPT.
2. On lease end, `mk_lease_end` (`lease.c:77-92`) drops MSI routes and IOMMU access, then calls
   `pci_try_reset_function`. If that fails, it falls back to `pci_clear_master` only, and Memory
   Space Enable stays set.
3. `mk_instance_settle_halted` (`core.c:1709`) ends every lease and clears `holder` **without
   confirming the CPUs stopped**:
   - **Child force halt** (`core.c:2054`): settles right after sending the NMIs.
   - **Graceful halt** (`core.c:1861-1864`): if `mk_instance_confirm_parked` fails, it only warns,
     then settles.
4. `mk_lease_grant` (`lease.c:179`) checks only `holder == NULL`. Another instance can therefore
   lease the function at once. Re-loading the same instance is blocked until its CPUs park; leasing
   to a different instance is not.
5. The new lessee sets Memory Space Enable through `pciback`, which allows it in `MK_PCIBACK_CMD`.
   From then on the old CPU's MMIO writes (e.g. an RT loop spinning with IRQs masked, with no
   pseudo-NMI on arm64) reach the device **under the new lessee's lease**.

Mapping onto our model:

| Our model | Multikernel |
|---|---|
| Energy | Memory Space Enable and the new lease |
| Stale command | Old CPU's MMIO |
| Missing fence | Nothing device-side distinguishes the two kernels' writes; CPU-stop confirmation is the only fence |

A wedged CPU that never confirms is `Impossible.lost_frame_blocks`. The safe policy is never to
re-lease, which is what `arm64.rst` already says for re-loading the same instance ("cannot be started
again until the machine is rebooted"). It should hold for **any** lessee.

**Design lessons for our own domain mechanism:**

- end a domain's device grants only **after** its CPUs are confirmed stopped, on every halt path
  (graceful, forced, voluntary);
- a grant must refuse while any CPU of the previous holder is unconfirmed, for **any** new holder,
  not only for a re-load of the same domain;
- a domain whose stop cannot be confirmed keeps its grants until the machine resets.

Status: static reading only.

## Gap 2: a deferred config write from an old incarnation lands on the new lease

This is the finite-fence id-reuse failure (`FiniteFence.reuse_breaks`) in kernel form.

- **No generation in the identity.** Instance ids are reused across re-spawns (`kernfs.c:281-291`),
  and `struct mk_message` (`multikernel.h:256`) has no generation or epoch field.
  `mk_instance_start` (`core.c:440`) clears the rings, but that does not help with work the host has
  already accepted.
- **A miss defers.** On a fast-path miss, `mk_pciback_request` (`pciback.c:392`) defers the request
  to a workqueue. The fast path misses whenever the lease has already ended.
- **The lookup trusts the payload.** At run time, `mk_pciback_work_fn` (`pciback.c:348`) re-resolves
  the target by the payload's self-asserted `sender_instance_id` and the BDF. The ring-identified
  sender (`from` in `mk_pciback_msg_handler`) is ignored.
- **The trace:**
  1. Incarnation 1 of instance N writes the Command register while halting.
  2. Its lease ends, so the request is deferred.
  3. N re-spawns, and incarnation 2 is lent the function.
  4. The worker runs and applies incarnation 1's write under incarnation 2's lease, then sends the
     ACK to incarnation 2. That ACK can match a pending request with the same `seq`.
- **The window:** workqueue latency (normally milliseconds) against re-spawn latency. That is a
  hidden-delay race and is unbounded under workqueue stalls.

An earlier fix existed (`d83cf0024f4f` in open PR multikernel/linux#41: pin the exact grant at
admission, revoke under the registry lock, serialise against reset). Upstream's lease rework
(3–4 Nov) rewrote `pciback.c` and reintroduced the old shape, which shows the rule is easy to lose
when it is not part of the identity.

**Design lessons for our own domain mechanism:**

- every domain identity carries a generation, and ids are never reused without one;
- accepted work pins the grant it was admitted under and is never re-resolved by id later;
- the sender is whoever the channel identifies, never an id written in the payload;
- ending a grant is serialised against work already admitted under it.

## Could a Multikernel instance be the guardian (replace the MCU)?

No. Every gate obligation fails on shared hardware:

| Gate obligation | Multikernel instance as guardian |
|---|---|
| Exclusive command and energy path (C15) | Actuator outputs (PWM, GPIO) are platform devices, unsupported on arm64; on Pi 5, RP1 is one shared function |
| Integrity against the controller domain | Containment against stray pointers only: pool memory is removed from the host's direct map (`mem.c:708`). Any kernel can still map any physical address; there is no stage-2/EPT |
| δ independent of the replaced domain | The host owns the GIC distributor and the ITS; spawn MSIs are mapped by the host over the ring with a timeout (`its_proxy.c:319`) |
| Survives reset of the controller's machine | Same SoC reset and power domain. RP1 outputs persist through a host reset (`rp1-fw`) while a CPU-side guardian dies |
| Bounded timing | No real-time or latency claims in the docs |

A Multikernel guardian would need the gate to sit in the same failure domain it is meant to contain.
The MCU gate stays.

## Does Multikernel add anything to the theorem?

- **What it gives:** a concrete realisation of the model's `cut` and `flush` for the *gate's own
  upstream*. If the gate's CAN adapter is a PCIe function leased to the controller domain, then
  lease end plus a successful FLR is a verified TX flush of that adapter, which discharges obligation
  C14 for the adapter queue.
  - It does **not** flush the CAN controller already on the bus, or the drive's setpoint.
- **What it does not give:** no time bound (graceful 30 s timeout; force halt unbounded when a CPU
  is wedged), no device-side fence, and no physical-output guarantee.
- The paper should cite it as the **replaceable-domain substrate whose cut latency the theorem does
  not depend on**, not as part of the safety argument.

## Verdict for AxiomOS

Decision (2026-11-12): Multikernel Linux is a **reference design** for the domain mechanism AxiomOS
will build. We do not patch, rebase or upstream it.

| Use | Worth it? |
|---|---|
| Reference for our own replaceable controller or AI domain mechanism | **Yes.** It is a working instance of the brief's "replaceable failure domains", and its gaps are the rules ours must have from the start |
| Platform on Pi 5 | **No.** GICv2, MIP not ITS, RP1 not splittable |
| Guardian or finality point | **No.** See the table above |
| Paper evidence | **Yes, as a second case study.** Both gaps are the paper's failure modes (energy ≠ authority; id reuse without verified flush) occurring independently in a real, actively developed kernel. The fixes are the protocol rules (confirm stop before re-grant; pin the epoch at admission). This strengthens the minimality claim (contribution 3) with a non-robot instance |

## Design lessons for our own domain mechanism

Collected from both gaps and the residual issues below:

1. **Stop before re-grant.** Device grants end only after the retired domain's CPUs are confirmed
   stopped. An unconfirmed stop blocks re-grant to anyone until reset.
2. **Generations in identity.** Domain ids carry a generation; admitted work pins its grant.
3. **Channel-derived sender.** Never trust an id in a message payload, including in "I have halted"
   and device hot-remove acknowledgements.
4. **A timeout is not a revocation.** A hot-add timeout must not free a device the domain may already
   be using; treat it like an unconfirmed stop.
5. **Config proxying is not a fence.** While BARs, DMA and interrupts stay direct, only CPU stop (or
   stage-2 / IOMMU revocation) removes access. Prefer a mechanism that can revoke the mapping.
6. **Reset is not quiescence.** A function reset can fail or leave outputs driven (RP1). The physical
   finality point stays at the MCU gate.
7. **Keep the domain mechanism out of the bound.** None of the above enters `t_c + W + T + δ`; these
   rules buy availability and clean recovery, not safety.

## Fix series (2026-11-11, parked)

Kept as a worked example of lessons 1–3, not as work to continue. Branch `mk/lease-finality-v1` in
`~/Work/linux-multikernel`, three commits on `bca8ae161fa6`. Not pushed, not signed off, not run.

| Commit | Change |
|---|---|
| `11171d855ba1` | `mk_instance_settle_halted()` confirms the CPUs parked before any lease ends; on failure the instance keeps its leases, so no other instance can be granted the function (closes C19) |
| `786e945602b8` | `pciback` serves and answers config requests by the ring-identified sender, not the payload id; a miss is answered directly instead of deferred |
| `808c33ee4692` | a deferred config access pins the lending it was admitted under and is serialised against lease end; queued work for an ended lease does nothing (closes C20) |

Verification of the series found both gaps slightly wider than first read:

- **C19:** a third caller, the voluntary-halt work `mk_halted_work_fn()` (`core.c:1722-1731`), also
  settled on the instance's word alone.
- **C20:** the synchronous fast path (`pciback.c:405`) also looked the lending up by the
  self-asserted id, so any instance could name another's id and reach that instance's functions
  through the config filter.

**Build:** x86_64, `make W=1 kernel/multikernel/`, gcc 16.2.1: 0 compiler warnings, 0 errors. The
log has kernel-doc warnings; `core.c` has 11 on the branch and 11 on upstream, `pciback.c` none on
either, so the series adds none. No full kernel link, no arm64 build, no QEMU run, no lockdep run.

**Left open** (found, not fixed):

- a hot-add timeout or NACK ends the lease although the running instance may already have probed
  the function (`hotplug.c:1773-1790`);
- hot-remove ends the lease on the running instance's acknowledgement (`hotplug.c:1871`);
- `MK_SYS_HALTED` takes the instance id from the payload, not the ring (`core.c:1805`);
- a halt with an unconfirmed CPU now leaves the instance ACTIVE, where it used to become LOADED;
  force halt is the recovery.

**PR #41** (47 commits) was assessed against upstream by per-commit dry-run merges: about 30 need
manual rework. The rebase is not planned.
