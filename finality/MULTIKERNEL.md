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

**Your branch fixes half of this.** `mk/lifecycle-safety-submit-v44` makes
`mk_instance_settle_halted` return `mk_instance_confirm_parked`'s error and keep resources on failure.
But it is based on `v7.0-mk4` (2026-10-26) and predates `lease.c`, with 49 upstream Multikernel
commits since. On rebase:

- call `mk_instance_fence_devices` only **after** confirmation succeeds;
- make the child force-halt path wait for confirmation instead of settling at once;
- make `mk_lease_grant` refuse while any CPU of the previous holder is unconfirmed (FAILED state).

Status: static reading only. Reproducible on QEMU `virt` (GICv3, ITS) or x86 with two instances, one
virtio/e1000 function, a spinning MMIO writer with IRQs masked, force halt, and a re-grant to the
second instance.

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
