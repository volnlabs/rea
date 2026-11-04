/-!
# Epoch fencing with a finite node-id namespace (Lean 4, core library only)

`Impossibility.lean`'s `Fence` used unbounded, increasing node ids. Real CAN ids are finite
(6 bits in standard frames). With unbounded downstream delay, a frame addressed to an id can
become valid again when that id is reused.

Model: `K` node ids. Rotation is by direct UART write (`w axis0.config.can.node_id`) on a link
the gate owns, so there are no rotation frames downstream. Setpoint frames go downstream with
unbounded latency, loss and reordering.

Gate protocol:
* each epoch uses a **fresh** id: one not used since the last flush (`dirty`);
* if no fresh id is left, the epoch is **exhausted**: the gate can confirm nothing until it
  flushes. Revocation itself is never blocked;
* **flush** (hardware obligation, *verified*): gate aborts its CAN TX mailboxes and resets the
  drive, after which no downstream frame remains. Dirty ids become reusable;
* LEASE_OK only after readback confirms the drive's node id is the epoch's id and its setpoint
  is the gate's last command.

Results:
* `safe`: whenever confirmed, every pending frame that could still commit is from the current
  epoch, and the committed setpoint is current or value-equal to the last command;
* `exhausted_refuses`: with no fresh id, the gate never confirms;
* `reuse_breaks`: reusing an id without a flush revives a stuck stale frame;
* `unverified_flush_breaks`: a "flush" that does not actually clear downstream frames is unsafe;
* `beyond_K_with_flush`: with flushes, more epochs than ids can be served.

Check with: `lean FiniteFence.lean`.
-/

namespace FiniteFence

structure Frame where
  addr  : Nat   -- node id the frame is addressed to
  epoch : Nat   -- ghost: epoch whose authority issued it
  val   : Nat
deriving DecidableEq

structure Rules where
  reuseGuard  : Bool  -- new epoch ids are fresh (not dirty, not current)
  flushClears : Bool  -- flush really removes every downstream frame
  deriving DecidableEq

def strict : Rules := ⟨true, true⟩

structure St where
  cur     : Nat
  gid     : Option Nat   -- node id the gate uses for the current epoch (none = exhausted)
  dirty   : List Nat     -- ids used since the last flush (may still have stale frames)
  nid     : Nat          -- drive's node id
  drvEp   : Option Nat   -- ghost provenance of the drive's setpoint
  drvVal  : Option Nat   -- drive's setpoint value (readback)
  pend    : List Frame   -- downstream, unbounded latency
  lastSrc : Option Nat
  lastVal : Option Nat
  conf    : Bool

def init : St := ⟨0, some 0, [], 0, none, none, [], none, none, false⟩

/-- Ids the gate has addressed frames to since the last flush. -/
def used (s : St) : List Nat := match s.gid with
  | some g => g :: s.dirty
  | none => s.dirty

inductive Step (K : Nat) (a : Rules) : St → St → Prop
  /-- Revocation with a fresh id for the new epoch. -/
  | cutFresh (s : St) (i : Nat) (hi : i < K) (hf : a.reuseGuard = true → i ∉ used s) :
      Step K a s { s with cur := s.cur + 1, gid := some i, dirty := used s, conf := false }
  /-- Revocation when no fresh id is available (or chosen): the gate cannot confirm. -/
  | cutExhausted (s : St) :
      Step K a s { s with cur := s.cur + 1, gid := none, dirty := used s, conf := false }
  /-- UART write of the drive's node id: direct, on a gate-owned point-to-point link. -/
  | rotate (s : St) (i : Nat) (h : s.gid = some i) : Step K a s { s with nid := i }
  | fwdSet (s : St) (i v : Nat) (h : s.gid = some i) :
      Step K a s { s with pend := ⟨i, s.cur, v⟩ :: s.pend, lastSrc := some s.cur,
                          lastVal := some v, conf := false }
  | commit (s : St) (x : Frame) (hx : x ∈ s.pend) :
      Step K a s (if x.addr = s.nid then
                    { s with drvEp := some x.epoch, drvVal := some x.val, pend := s.pend.erase x }
                  else { s with pend := s.pend.erase x })
  | lose (s : St) (x : Frame) (hx : x ∈ s.pend) : Step K a s { s with pend := s.pend.erase x }
  | readback (s : St) :
      Step K a s { s with conf := (decide (s.gid = some s.nid) && decide (s.drvVal = s.lastVal) &&
                                    decide (s.lastSrc = some s.cur)) }
  /-- Flush: abort gate CAN TX + reset drive. Frees all dirty ids. -/
  | flush (s : St) :
      Step K a s { s with pend := if a.flushClears then [] else s.pend, dirty := [] }

inductive Reach (K : Nat) (a : Rules) : St → Prop
  | init : Reach K a init
  | step {s t : St} : Reach K a s → Step K a s t → Reach K a t

structure Inv (s : St) : Prop where
  addrUsed : ∀ x ∈ s.pend, x.addr ∈ used s
  curAddr  : ∀ x ∈ s.pend, some x.addr = s.gid → x.epoch = s.cur
  confOk   : s.conf = true → s.gid = some s.nid ∧ s.lastSrc = some s.cur ∧
               (s.drvEp = some s.cur ∨ s.drvVal = s.lastVal)

theorem inv_reach {K : Nat} {s : St} (h : Reach K strict s) : Inv s := by
  induction h with
  | init => exact ⟨by simp [init], by simp [init], by simp [init]⟩
  | @step s t _ hst ih =>
    cases hst with
    | cutFresh i hi hf =>
      have hfresh : i ∉ used s := hf rfl
      refine ⟨?_, ?_, by simp⟩
      · intro x hx; simp [used]; right; exact ih.addrUsed x hx
      · intro x hx hxa
        have hu := ih.addrUsed x hx
        simp at hxa; subst hxa
        exact absurd hu hfresh
    | cutExhausted =>
      refine ⟨?_, ?_, by simp⟩
      · intro x hx; simp [used]; exact ih.addrUsed x hx
      · intro x _ hxa; simp at hxa
    | rotate i hg =>
      refine ⟨fun x hx => ih.addrUsed x hx, fun x hx h => ih.curAddr x hx h, ?_⟩
      intro hc
      obtain ⟨h1, h2, h3⟩ := ih.confOk hc
      rw [hg] at h1
      have hi : i = s.nid := by simpa using h1
      exact ⟨by simp [hg, hi], h2, h3⟩
    | fwdSet i v hg =>
      refine ⟨?_, ?_, by simp⟩
      · intro x hx; simp at hx
        rcases hx with rfl | hx
        · simp [used, hg]
        · exact ih.addrUsed x hx
      · intro x hx hxa; simp at hx
        rcases hx with rfl | hx
        · rfl
        · exact ih.curAddr x hx hxa
    | commit x hx =>
      by_cases hn : x.addr = s.nid
      · simp only [hn, ite_true]
        refine ⟨fun y hy => ih.addrUsed y (List.mem_of_mem_erase hy),
          fun y hy h => ih.curAddr y (List.mem_of_mem_erase hy) h, ?_⟩
        intro hc
        obtain ⟨h1, h2, _⟩ := ih.confOk hc
        have hep : x.epoch = s.cur := ih.curAddr x hx (by rw [hn, h1])
        exact ⟨h1, h2, Or.inl (by simp [hep])⟩
      · simp only [hn, ite_false]
        exact ⟨fun y hy => ih.addrUsed y (List.mem_of_mem_erase hy),
          fun y hy h => ih.curAddr y (List.mem_of_mem_erase hy) h, fun hc => ih.confOk hc⟩
    | lose x hx =>
      exact ⟨fun y hy => ih.addrUsed y (List.mem_of_mem_erase hy),
        fun y hy h => ih.curAddr y (List.mem_of_mem_erase hy) h, fun hc => ih.confOk hc⟩
    | readback =>
      refine ⟨fun x hx => ih.addrUsed x hx, fun x hx h => ih.curAddr x hx h, ?_⟩
      intro hc
      simp at hc
      obtain ⟨⟨h1, h2⟩, h3⟩ := hc
      exact ⟨h1, h3, Or.inr h2⟩
    | flush =>
      refine ⟨?_, ?_, fun hc => ih.confOk hc⟩
      · intro x hx; simp [strict] at hx
      · intro x hx; simp [strict] at hx

/-- **Finite-id fence safety.** Under unbounded latency, loss, reordering and stuck frames, with
    only `K` node ids: whenever the gate's readback is confirmed, every pending frame that could
    still commit (addressed to the drive's id) is from the current epoch, and the committed
    setpoint is current or value-equal to the gate's last command. -/
theorem safe {K : Nat} {s : St} (h : Reach K strict s) (hc : s.conf = true) :
    (∀ x ∈ s.pend, x.addr = s.nid → x.epoch = s.cur) ∧
    (s.drvEp = some s.cur ∨ s.drvVal = s.lastVal) := by
  have hi := inv_reach h
  obtain ⟨hg, _, hd⟩ := hi.confOk hc
  exact ⟨fun x hx ha => hi.curAddr x hx (by rw [ha, hg]), hd⟩

/-- **Exhaustion is fail-safe.** With no fresh id, the gate never confirms (no LEASE_OK). -/
theorem exhausted_refuses {K : Nat} {s : St} (h : Reach K strict s) (hg : s.gid = none) :
    s.conf = false := by
  have hi := inv_reach h
  cases hc : s.conf with
  | false => rfl
  | true => have := (hi.confOk hc).1; rw [hg] at this; cases this

def Violation (K : Nat) (a : Rules) : Prop :=
  ∃ s, Reach K a s ∧ s.conf = true ∧ ∃ x ∈ s.pend, x.addr = s.nid ∧ x.epoch ≠ s.cur

/-- Reusing an id without a flush: K = 2, epochs 0 → 1 → 2 reuse id 0, and epoch 0's stuck
    frame becomes capable again behind a confirmed readback. -/
theorem reuse_breaks : Violation 2 { strict with reuseGuard := false } := by
  let a : Rules := { strict with reuseGuard := false }
  have r1 := Reach.step (Reach.init (K := 2) (a := a)) (Step.fwdSet _ 0 5 rfl)
  have r2 := Reach.step r1 (Step.cutFresh _ 1 (by decide) (by intro h; cases h))
  have r3 := Reach.step r2 (Step.rotate _ 1 rfl)
  have r4 := Reach.step r3 (Step.cutFresh _ 0 (by decide) (by intro h; cases h))
  have r5 := Reach.step r4 (Step.rotate _ 0 rfl)
  have r6 := Reach.step r5 (Step.fwdSet _ 0 7 rfl)
  have r7 := Reach.step r6 (Step.commit _ ⟨0, 2, 7⟩ (by decide))
  have r8 := Reach.step r7 (Step.readback _)
  exact ⟨_, r8, by decide, ⟨0, 0, 5⟩, by decide, by decide, by decide⟩

/-- A flush that frees ids without really clearing downstream frames is unsafe. -/
theorem unverified_flush_breaks : Violation 2 { strict with flushClears := false } := by
  let a : Rules := { strict with flushClears := false }
  have r1 := Reach.step (Reach.init (K := 2) (a := a)) (Step.fwdSet _ 0 5 rfl)
  have r2 := Reach.step r1 (Step.cutFresh _ 1 (by decide) (by intro _; decide))
  have r3 := Reach.step r2 (Step.rotate _ 1 rfl)
  have r4 := Reach.step r3 (Step.flush _)
  have r5 := Reach.step r4 (Step.cutFresh _ 0 (by decide) (by intro _; decide))
  have r6 := Reach.step r5 (Step.rotate _ 0 rfl)
  have r7 := Reach.step r6 (Step.fwdSet _ 0 7 rfl)
  have r8 := Reach.step r7 (Step.commit _ ⟨0, 2, 7⟩ (by decide))
  have r9 := Reach.step r8 (Step.readback _)
  exact ⟨_, r9, by decide, ⟨0, 0, 5⟩, by decide, by decide, by decide⟩

/-- Without flush, K = 2 ids serve epochs 0 and 1; epoch 2 is exhausted and refuses. -/
theorem exhaustion_without_flush :
    ∃ s, Reach 2 strict s ∧ s.cur = 2 ∧ s.gid = none ∧ s.conf = false := by
  have r1 := Reach.step (Reach.init (K := 2) (a := strict)) (Step.cutFresh _ 1 (by decide) (by intro _; decide))
  have r2 := Reach.step r1 (Step.cutExhausted _)
  exact ⟨_, r2, rfl, rfl, rfl⟩

/-- With verified flushes, K = 2 ids serve epoch 3 (more epochs than ids), confirmed. -/
theorem beyond_K_with_flush : ∃ s, Reach 2 strict s ∧ s.cur = 3 ∧ s.conf = true := by
  have r1 := Reach.step (Reach.init (K := 2) (a := strict)) (Step.fwdSet _ 0 5 rfl)
  have r2 := Reach.step r1 (Step.cutFresh _ 1 (by decide) (by intro _; decide))
  have r3 := Reach.step r2 (Step.flush _)
  have r4 := Reach.step r3 (Step.cutFresh _ 0 (by decide) (by intro _; decide))
  have r5 := Reach.step r4 (Step.flush _)
  have r6 := Reach.step r5 (Step.cutFresh _ 1 (by decide) (by intro _; decide))
  have r7 := Reach.step r6 (Step.rotate _ 1 rfl)
  have r8 := Reach.step r7 (Step.fwdSet _ 1 9 rfl)
  have r9 := Reach.step r8 (Step.commit _ ⟨1, 3, 9⟩ (by decide))
  have r10 := Reach.step r9 (Step.readback _)
  exact ⟨_, r10, rfl, by decide⟩

end FiniteFence
