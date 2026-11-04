/-!
# AxiomOS gate refinement: the command-commit boundary (Lean 4, core library only)

Refines `FinalityProduct.lean`. There, `accept` updated the gate's record (`lastSrc`) and the
drive's setpoint (`drvSrc`) atomically. Here they are separated by a **downstream stage**
(gate CAN TX, bus, drive RX FIFO), and the drive installs commands by an explicit **commit**
event. Downstream frames may be lost, committed in any order, and outlive a **gate restart**.

Gate rules added by the refinement:
* `confirm`: LEASE_OK also needs a readback confirming the drive's setpoint is the lease
  holder's command. The setpoint value stands in for provenance (equal values are the same
  exact effect);
* `trackCheck`: readback confirms only if no tracked in-flight frame has another origin;
* `quarantine`: after a restart the gate assumes every untracked frame may still be in
  flight, for `Dd` ticks;
* `boundedDown`: hardware obligation that downstream frames commit or are lost within `Dd`
  ticks.

Main results:
* `no_pending_hijack`: whenever LEASE_OK holds, the drive's effective setpoint and every
  command that could still become effective come from the lease holder.
* `finality`: the composed timed finality theorem of `FinalityProduct.lean` re-proved for the
  refined model, now also excluding in-flight retired commands.
* `Counterexamples`: dropping any one refinement rule allows a hijack.

Authority-side rules (issue only for valid grants, freshness window, no rollback, command
and power exclusivity) are fixed as in the strict product model. Their necessity is shown
in `FinalityProduct.lean`. The gate's challenge counter survives restart (persisted).

Check with: `lean GateRefinement.lean`.
-/

namespace Refine

structure Frame where
  origin : Nat
deriving DecidableEq

structure Token where
  grant : Nat
  nonce : Nat
deriving DecidableEq

structure Params where
  T  : Nat   -- lease length
  W  : Nat   -- challenge freshness window
  δ  : Nat   -- output shutdown obligation after LEASE_OK observed low
  r  : Nat   -- retired grant
  Dd : Nat   -- downstream bound: forwarded frames commit or are lost within Dd ticks

structure Rules where
  confirm     : Bool
  trackCheck  : Bool
  quarantine  : Bool
  boundedDown : Bool

def strict : Rules := ⟨true, true, true, true⟩

structure St where
  now     : Nat
  valid   : Nat → Bool
  cutAt   : Option Nat
  issued  : List Token
  chal    : Nat
  chalAt  : Nat
  timer   : Nat → Nat
  lastSrc : Option Nat          -- gate: grant whose command it last forwarded
  drvSrc  : Option Nat          -- ghost: provenance of the drive's committed setpoint
  queue   : List Frame          -- upstream of the gate (adversarial)
  down    : List (Frame × Nat)  -- ghost truth: forwarded, not yet committed or lost (with age)
  track   : List (Frame × Nat)  -- gate: frames it forwarded that may still be downstream
  blind   : Nat                 -- gate: post-restart quarantine remaining
  conf    : Bool                -- gate: readback confirmed drive setpoint = lastSrc's command
  armed   : Bool
  out     : Bool
  offFor  : Nat
  supp    : Option Nat

def init : St :=
  { now := 0, valid := fun _ => true, cutAt := none, issued := [], chal := 0, chalAt := 0,
    timer := fun _ => 0, lastSrc := none, drvSrc := none, queue := [], down := [], track := [],
    blind := 0, conf := false, armed := false, out := false, offFor := 0, supp := none }

def liveAfterTick (s : St) : Bool :=
  match s.lastSrc with
  | some g => decide (s.timer g - 1 > 0)
  | none => false

/-- LEASE_OK at the next tick. Without the `confirm` rule, the readback flag is ignored. -/
def okAfterTick (a : Rules) (s : St) : Bool :=
  (if a.confirm then s.conf else true) && decide (s.blind - 1 = 0) && liveAfterTick s

/-- LEASE_OK now (used to state the hijack property). -/
def leaseNow (a : Rules) (s : St) : Bool :=
  (if a.confirm then s.conf else true) && decide (s.blind = 0) &&
    (match s.lastSrc with
     | some g => decide (s.timer g > 0)
     | none => false)

def tickState (p : Params) (a : Rules) (s : St) (o : Bool) : St :=
  { s with now := s.now + 1, timer := fun x => s.timer x - 1,
           down := s.down.map (fun x => (x.1, x.2 + 1)),
           track := (s.track.map (fun x => (x.1, x.2 + 1))).filter (fun x => decide (x.2 < p.Dd)),
           blind := s.blind - 1,
           offFor := if okAfterTick a s then 0 else s.offFor + 1,
           supp := if okAfterTick a s then s.lastSrc else s.supp, out := o }

inductive Step (p : Params) (a : Rules) : St → St → Prop
  | reshape (s : St) (q : List Frame) : Step p a s { s with queue := q }
  /-- Gate forwards a command downstream; it now awaits confirmation. -/
  | forward (s : St) (f : Frame) (hm : f ∈ s.queue) (hf : s.timer f.origin > 0) :
      Step p a s { s with lastSrc := some f.origin, conf := false,
                          down := (f, 0) :: s.down, track := (f, 0) :: s.track }
  /-- The drive installs a pending command, in any order. -/
  | commit (s : St) (x : Frame × Nat) (hx : x ∈ s.down) :
      Step p a s { s with drvSrc := some x.1.origin, down := s.down.erase x }
  | lose (s : St) (x : Frame × Nat) (hx : x ∈ s.down) :
      Step p a s { s with down := s.down.erase x }
  /-- Gate reads the drive's setpoint back. -/
  | readback (s : St) :
      Step p a s { s with conf := decide (s.drvSrc = s.lastSrc) && decide (s.blind = 0) &&
        (if a.trackCheck then decide (∀ y ∈ s.track, some y.1.origin = s.lastSrc) else true) }
  | issue (s : St) (g : Nat) (hv : s.valid g = true) :
      Step p a s { s with issued := ⟨g, s.chal⟩ :: s.issued }
  | redeem (s : St) (tok : Token) (hm : tok ∈ s.issued) (hn : tok.nonce = s.chal)
      (hw : s.now ≤ s.chalAt + p.W) :
      Step p a s { s with timer := fun x => if x = tok.grant then p.T else s.timer x,
                          chal := s.chal + 1, chalAt := s.now }
  | rechallenge (s : St) : Step p a s { s with chal := s.chal + 1, chalAt := s.now }
  | cut (s : St) (h : s.cutAt = none) :
      Step p a s { s with valid := fun x => if x = p.r then false else s.valid x, cutAt := some s.now }
  | notify (s : St) : Step p a s { s with timer := fun x => if x = p.r then 0 else s.timer x }
  | arm (s : St) (b : Bool) : Step p a s { s with armed := b }
  /-- Gate restart: volatile state is lost. Downstream frames are unaffected. -/
  | restart (s : St) :
      Step p a s { s with track := [], blind := if a.quarantine then p.Dd else 0, conf := false,
                          lastSrc := none, timer := fun _ => 0, chal := s.chal + 1, chalAt := s.now }
  | tick (s : St) (o : Bool)
      (hd : a.boundedDown = true → ∀ x ∈ s.down, x.2 + 1 < p.Dd)
      (ho : o = true → (okAfterTick a s = true ∧ s.armed = true) ∨
                       (s.out = true ∧ (if okAfterTick a s then 0 else s.offFor + 1) < p.δ)) :
      Step p a s (tickState p a s o)

inductive Reach (p : Params) (a : Rules) : St → Prop
  | init : Reach p a init
  | step {s t : St} : Reach p a s → Step p a s t → Reach p a t

structure Inv (p : Params) (s : St) : Prop where
  nonce   : ∀ tok ∈ s.issued, tok.nonce ≤ s.chal
  chalAt  : s.chalAt ≤ s.now
  tmax    : ∀ g, s.timer g ≤ p.T
  cutNow  : ∀ c, s.cutAt = some c → c ≤ s.now
  revoked : ∀ c, s.cutAt = some c → s.valid p.r = false
  oldTok  : ∀ c, s.cutAt = some c → ∀ tok ∈ s.issued, tok.grant = p.r → tok.nonce = s.chal → s.chalAt ≤ c
  lease   : ∀ c, s.cutAt = some c → s.timer p.r = 0 ∨ s.timer p.r + s.now ≤ c + p.W + p.T
  outOff  : s.out = true → s.offFor < p.δ
  supp    : ∀ c, s.cutAt = some c → s.supp = some p.r → s.now ≤ c + p.W + p.T + s.offFor
  src     : ∀ c, s.cutAt = some c → s.lastSrc = some p.r → s.now ≤ c + p.W + p.T + s.offFor
  drv     : ∀ c, s.cutAt = some c → s.drvSrc = some p.r → s.now ≤ c + p.W + p.T + s.offFor
  downR   : ∀ c, s.cutAt = some c → ∀ x ∈ s.down, x.1.origin = p.r → s.now ≤ c + p.W + p.T + s.offFor
  ages    : ∀ x ∈ s.down, x.2 < p.Dd
  tracked : ∀ x ∈ s.down, x ∈ s.track ∨ p.Dd ≤ x.2 + s.blind
  confOk  : s.conf = true → s.drvSrc = s.lastSrc ∧ s.blind = 0 ∧ ∀ y ∈ s.track, some y.1.origin = s.lastSrc

theorem inv_init (p : Params) : Inv p init := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> simp [init]

theorem live_bound {p : Params} {s : St} (hi : Inv p s) {c : Nat} (hc : s.cutAt = some c)
    (h : s.timer p.r > 0) : s.timer p.r + s.now ≤ c + p.W + p.T := by
  rcases hi.lease c hc with h0 | h1
  · omega
  · exact h1

/-- With the gate not blind, every downstream frame is tracked. -/
theorem down_tracked {p : Params} {s : St} (hi : Inv p s) (hb : s.blind = 0) :
    ∀ x ∈ s.down, x ∈ s.track := by
  intro x hx
  rcases hi.tracked x hx with h | h
  · exact h
  · have := hi.ages x hx; omega

/-- Confirmed readback means every pending command is the lease holder's. -/
theorem conf_down {p : Params} {s : St} (hi : Inv p s) (hc : s.conf = true) :
    ∀ x ∈ s.down, some x.1.origin = s.lastSrc := by
  intro x hx
  obtain ⟨_, hb, ht⟩ := hi.confOk hc
  exact ht x (down_tracked hi hb x hx)

theorem inv_step {p : Params} (hδ : 1 ≤ p.δ) (hD : 1 ≤ p.Dd) {s t : St} (hi : Inv p s)
    (h : Step p strict s t) : Inv p t := by
  cases h with
  | reshape q => exact ⟨hi.nonce, hi.chalAt, hi.tmax, hi.cutNow, hi.revoked, hi.oldTok, hi.lease,
      hi.outOff, hi.supp, hi.src, hi.drv, hi.downR, hi.ages, hi.tracked, hi.confOk⟩
  | forward f hm hf =>
    refine ⟨hi.nonce, hi.chalAt, hi.tmax, hi.cutNow, hi.revoked, hi.oldTok, hi.lease, hi.outOff,
      hi.supp, ?_, hi.drv, ?_, ?_, ?_, by simp⟩
    · intro c hc hsrc
      have horig : f.origin = p.r := by simpa using hsrc
      have := live_bound hi hc (by rw [← horig]; exact hf)
      simp; omega
    · intro c hc x hx hxr
      simp at hx
      rcases hx with rfl | hx
      · have := live_bound hi hc (by rw [← hxr]; exact hf); simp; omega
      · exact hi.downR c hc x hx hxr
    · intro x hx; simp at hx
      rcases hx with rfl | hx
      · simp; omega
      · exact hi.ages x hx
    · intro x hx; simp at hx
      rcases hx with rfl | hx
      · left; simp
      · rcases hi.tracked x hx with h | h
        · left; simp [h]
        · right; simpa using h
  | commit x hx =>
    refine ⟨hi.nonce, hi.chalAt, hi.tmax, hi.cutNow, hi.revoked, hi.oldTok, hi.lease, hi.outOff,
      hi.supp, hi.src, ?_, ?_, ?_, ?_, ?_⟩
    · intro c hc hd
      have hxr : x.1.origin = p.r := by simpa using hd
      simpa using hi.downR c hc x hx hxr
    · intro c hc y hy hyr; exact hi.downR c hc y (List.mem_of_mem_erase hy) hyr
    · intro y hy; exact hi.ages y (List.mem_of_mem_erase hy)
    · intro y hy; exact hi.tracked y (List.mem_of_mem_erase hy)
    · intro hcf
      obtain ⟨_, hb, ht⟩ := hi.confOk hcf
      refine ⟨?_, hb, ht⟩
      exact conf_down hi hcf x hx
  | lose x hx =>
    refine ⟨hi.nonce, hi.chalAt, hi.tmax, hi.cutNow, hi.revoked, hi.oldTok, hi.lease, hi.outOff,
      hi.supp, hi.src, hi.drv, ?_, ?_, ?_, hi.confOk⟩
    · intro c hc y hy hyr; exact hi.downR c hc y (List.mem_of_mem_erase hy) hyr
    · intro y hy; exact hi.ages y (List.mem_of_mem_erase hy)
    · intro y hy; exact hi.tracked y (List.mem_of_mem_erase hy)
  | readback =>
    refine ⟨hi.nonce, hi.chalAt, hi.tmax, hi.cutNow, hi.revoked, hi.oldTok, hi.lease, hi.outOff,
      hi.supp, hi.src, hi.drv, hi.downR, hi.ages, hi.tracked, ?_⟩
    intro hcf
    simp [strict] at hcf
    obtain ⟨⟨h1, h2⟩, h3⟩ := hcf
    exact ⟨h1, h2, fun y hy => by simpa using h3 y.1 y.2 (by simpa using hy)⟩
  | issue g hv =>
    refine ⟨?_, hi.chalAt, hi.tmax, hi.cutNow, hi.revoked, ?_, hi.lease, hi.outOff, hi.supp,
      hi.src, hi.drv, hi.downR, hi.ages, hi.tracked, hi.confOk⟩
    · intro tok htok
      simp at htok
      rcases htok with rfl | htok
      · simp
      · exact hi.nonce tok htok
    · intro c hc tok htok hg hn
      simp at htok
      rcases htok with rfl | htok
      · have hrev := hi.revoked c hc
        simp at hg; subst hg; rw [hv] at hrev; cases hrev
      · exact hi.oldTok c hc tok htok hg hn
  | redeem tok hm hn hw =>
    refine ⟨?_, by simp, ?_, hi.cutNow, hi.revoked, ?_, ?_, hi.outOff, hi.supp, hi.src, hi.drv,
      hi.downR, hi.ages, hi.tracked, hi.confOk⟩
    · intro tk htk; have := hi.nonce tk htk; simp; omega
    · intro g; by_cases hg : g = tok.grant <;> simp [hg, hi.tmax g]
    · intro c hc tk htk hg hn'
      have := hi.nonce tk htk; simp at hn'; omega
    · intro c hc
      by_cases hg : p.r = tok.grant
      · right
        have hold := hi.oldTok c hc tok hm hg.symm hn
        simp [hg]; omega
      · simp [hg]; exact hi.lease c hc
  | rechallenge =>
    refine ⟨?_, by simp, hi.tmax, hi.cutNow, hi.revoked, ?_, hi.lease, hi.outOff, hi.supp, hi.src,
      hi.drv, hi.downR, hi.ages, hi.tracked, hi.confOk⟩
    · intro tk htk; have := hi.nonce tk htk; simp; omega
    · intro c hc tk htk hg hn'
      have := hi.nonce tk htk; simp at hn'; omega
  | cut hcut =>
    refine ⟨hi.nonce, hi.chalAt, hi.tmax, ?_, ?_, ?_, ?_, hi.outOff, ?_, ?_, ?_, ?_, hi.ages,
      hi.tracked, hi.confOk⟩
    · intro c hc; simp at hc ⊢; omega
    · intro c _; simp
    · intro c hc tk _ _ _; simp at hc ⊢; have := hi.chalAt; omega
    · intro c hc; simp at hc ⊢; right; have := hi.tmax p.r; omega
    · intro c hc _; simp at hc ⊢; omega
    · intro c hc _; simp at hc ⊢; omega
    · intro c hc _; simp at hc ⊢; omega
    · intro c hc _ _ _; simp at hc ⊢; omega
  | notify =>
    refine ⟨hi.nonce, hi.chalAt, ?_, hi.cutNow, hi.revoked, hi.oldTok, ?_, hi.outOff, hi.supp,
      hi.src, hi.drv, hi.downR, hi.ages, hi.tracked, hi.confOk⟩
    · intro g; by_cases hg : g = p.r <;> simp [hg, hi.tmax g]
    · intro c _; left; simp
  | arm b => exact ⟨hi.nonce, hi.chalAt, hi.tmax, hi.cutNow, hi.revoked, hi.oldTok, hi.lease,
      hi.outOff, hi.supp, hi.src, hi.drv, hi.downR, hi.ages, hi.tracked, hi.confOk⟩
  | restart =>
    refine ⟨?_, by simp, ?_, hi.cutNow, hi.revoked, ?_, ?_, hi.outOff, hi.supp, ?_, hi.drv,
      hi.downR, hi.ages, ?_, by simp⟩
    · intro tk htk; have := hi.nonce tk htk; simp; omega
    · intro g; simp
    · intro c hc tk htk hg hn'
      have := hi.nonce tk htk; simp at hn'; omega
    · intro c _; left; simp
    · intro c _ h; simp at h
    · intro x hx; right; simp [strict] <;> omega
  | tick o hd ho =>
    have hd' : ∀ x ∈ s.down, x.2 + 1 < p.Dd := hd rfl
    -- When LEASE_OK is observed at this tick, everything pending is the lease holder's.
    have okFacts : okAfterTick strict s = true →
        s.conf = true ∧ s.drvSrc = s.lastSrc ∧ (∀ x ∈ s.down, some x.1.origin = s.lastSrc) ∧
        liveAfterTick s = true := by
      intro hok
      simp [okAfterTick, strict] at hok
      obtain ⟨⟨hc, _⟩, hl⟩ := hok
      exact ⟨hc, (hi.confOk hc).1, conf_down hi hc, hl⟩
    have okBound : ∀ c, s.cutAt = some c → s.lastSrc = some p.r → liveAfterTick s = true →
        s.now + 1 ≤ c + p.W + p.T := by
      intro c hc hl hlive
      simp [liveAfterTick, hl] at hlive
      have := live_bound hi hc (by omega)
      omega
    refine ⟨hi.nonce, by simp [tickState]; have := hi.chalAt; omega, ?_, ?_, hi.revoked, hi.oldTok,
      ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
    · intro g; simp [tickState]; have := hi.tmax g; omega
    · intro c hc; simp [tickState] at hc ⊢; have := hi.cutNow c hc; omega
    · intro c hc
      simp [tickState] at hc ⊢
      rcases hi.lease c hc with h0 | h1
      · left; omega
      · by_cases hz : s.timer p.r = 0
        · left; omega
        · right; omega
    · intro hout
      simp [tickState] at hout
      rcases ho hout with ⟨hok, _⟩ | ⟨_, hlt⟩
      · simp [tickState, hok]; omega
      · simpa [tickState] using hlt
    · intro c hc hsupp
      simp [tickState] at hc
      by_cases hok : okAfterTick strict s = true
      · simp [tickState, hok] at hsupp ⊢
        have := okBound c hc hsupp (okFacts hok).2.2.2
        omega
      · simp [tickState, hok] at hsupp ⊢
        have := hi.supp c hc hsupp
        omega
    · intro c hc hl
      simp [tickState] at hc hl
      by_cases hok : okAfterTick strict s = true
      · simp [tickState, hok]; have := okBound c hc hl (okFacts hok).2.2.2; omega
      · simp [tickState, hok]; have := hi.src c hc hl; omega
    · intro c hc hdrv
      simp [tickState] at hc hdrv
      by_cases hok : okAfterTick strict s = true
      · obtain ⟨_, hsync, _, hlive⟩ := okFacts hok
        simp [tickState, hok]
        have := okBound c hc (by rw [← hsync]; exact hdrv) hlive
        omega
      · simp [tickState, hok]; have := hi.drv c hc hdrv; omega
    · intro c hc y hy hyr
      simp [tickState] at hc hy
      obtain ⟨a, b, hab, rfl⟩ := hy
      by_cases hok : okAfterTick strict s = true
      · obtain ⟨_, _, hdown, hlive⟩ := okFacts hok
        have hl : s.lastSrc = some p.r := by rw [← hdown _ hab]; simpa using hyr
        simp [tickState, hok]
        have := okBound c hc hl hlive
        omega
      · simp [tickState, hok]
        have := hi.downR c hc (a, b) hab (by simpa using hyr)
        omega
    · intro y hy
      simp [tickState] at hy
      obtain ⟨a, b, hab, rfl⟩ := hy
      simpa using hd' (a, b) hab
    · intro y hy
      simp [tickState] at hy
      obtain ⟨a, b, hab, rfl⟩ := hy
      have hlt := hd' (a, b) hab
      rcases hi.tracked (a, b) hab with htr | hge
      · left
        simp only [tickState]
        exact List.mem_filter.mpr ⟨List.mem_map.mpr ⟨(a, b), htr, rfl⟩, by simpa using hlt⟩
      · by_cases hb : s.blind = 0
        · have := hi.ages (a, b) hab; simp at hge this; omega
        · right; simp [tickState] at hge ⊢; omega
    · intro hcf
      simp [tickState] at hcf
      obtain ⟨hsync, hb, ht⟩ := hi.confOk hcf
      refine ⟨by simpa [tickState] using hsync, by simp [tickState, hb], ?_⟩
      intro y hy
      simp [tickState, List.mem_filter, List.mem_map] at hy
      obtain ⟨⟨a, b, hab, rfl, rfl⟩, _⟩ := hy
      simpa [tickState] using ht (a, b) hab

theorem inv_reach {p : Params} (hδ : 1 ≤ p.δ) (hD : 1 ≤ p.Dd) {s : St} (h : Reach p strict s) :
    Inv p s := by
  induction h with
  | init => exact inv_init p
  | step _ hst ih => exact inv_step hδ hD ih hst

/-- **No pending hijack.** Whenever the gate asserts LEASE_OK, the drive's effective setpoint
    and every forwarded command that could still become effective come from the lease holder.
    Under B's lease, no A-origin command can be or become the setpoint. -/
theorem no_pending_hijack {p : Params} (hδ : 1 ≤ p.δ) (hD : 1 ≤ p.Dd) {s : St}
    (h : Reach p strict s) (hok : leaseNow strict s = true) :
    s.drvSrc = s.lastSrc ∧ ∀ x ∈ s.down, some x.1.origin = s.lastSrc := by
  have hi := inv_reach hδ hD h
  have hc : s.conf = true := by simp [leaseNow, strict] at hok; exact hok.1.1
  exact ⟨(hi.confOk hc).1, conf_down hi hc⟩

/-- **Refined finality.** From `t_c + W + T + δ` on, an energized output depends on the retired
    grant neither for energy, nor for its committed setpoint, nor through any pending command. -/
theorem finality {p : Params} (hδ : 1 ≤ p.δ) (hD : 1 ≤ p.Dd) {s : St} (h : Reach p strict s)
    {c : Nat} (hc : s.cutAt = some c) (hdl : c + p.W + p.T + p.δ ≤ s.now) (hout : s.out = true) :
    s.supp ≠ some p.r ∧ s.drvSrc ≠ some p.r ∧ ∀ x ∈ s.down, x.1.origin ≠ p.r := by
  have hi := inv_reach hδ hD h
  have hoff := hi.outOff hout
  refine ⟨?_, ?_, ?_⟩
  · intro hs; have := hi.supp c hc hs; omega
  · intro hd; have := hi.drv c hc hd; omega
  · intro x hx hxr; have := hi.downR c hc x hx hxr; omega

end Refine

namespace Refine.Counterexamples
open Refine

/-- T = 3, W = 0, δ = 1, retired grant 0, Dd = 3. Grant 1 is the current authority B. -/
def P : Params := ⟨3, 0, 1, 0, 3⟩

/-- LEASE_OK under some grant while another grant's command is, or can still become, the
    drive's setpoint. -/
def Hijack (a : Rules) : Prop :=
  ∃ s, Reach P a s ∧ leaseNow a s = true ∧
    (s.drvSrc ≠ s.lastSrc ∨ ∃ x ∈ s.down, some x.1.origin ≠ s.lastSrc)

/-- No readback confirmation: B's command is lost, and the drive still holds A's setpoint. -/
theorem lost_command : Hijack { strict with confirm := false } := by
  let a : Rules := { strict with confirm := false }
  have r1 := Reach.step (Reach.init (p := P) (a := a)) (Step.issue _ 0 rfl)
  have r2 := Reach.step r1 (Step.redeem _ ⟨0, 0⟩ (by decide) rfl (by decide))
  have r3 := Reach.step r2 (Step.reshape _ [⟨0⟩, ⟨1⟩])
  have r4 := Reach.step r3 (Step.forward _ ⟨0⟩ (by decide) (by decide))
  have r5 := Reach.step r4 (Step.commit _ (⟨0⟩, 0) (by decide))
  have r6 := Reach.step r5 (Step.issue _ 1 rfl)
  have r7 := Reach.step r6 (Step.redeem _ ⟨1, 1⟩ (by decide) rfl (by decide))
  have r8 := Reach.step r7 (Step.forward _ ⟨1⟩ (by decide) (by decide))
  have r9 := Reach.step r8 (Step.lose _ (⟨1⟩, 0) (by decide))
  exact ⟨_, r9, by decide, Or.inl (by decide)⟩

/-- No in-flight check: an older A frame commits after B's, behind a confirmed readback. -/
theorem reordered_commit : Hijack { strict with trackCheck := false } := by
  let a : Rules := { strict with trackCheck := false }
  have r1 := Reach.step (Reach.init (p := P) (a := a)) (Step.issue _ 0 rfl)
  have r2 := Reach.step r1 (Step.redeem _ ⟨0, 0⟩ (by decide) rfl (by decide))
  have r3 := Reach.step r2 (Step.reshape _ [⟨0⟩, ⟨1⟩])
  have r4 := Reach.step r3 (Step.forward _ ⟨0⟩ (by decide) (by decide))
  have r5 := Reach.step r4 (Step.issue _ 1 rfl)
  have r6 := Reach.step r5 (Step.redeem _ ⟨1, 1⟩ (by decide) rfl (by decide))
  have r7 := Reach.step r6 (Step.forward _ ⟨1⟩ (by decide) (by decide))
  have r8 := Reach.step r7 (Step.commit _ (⟨1⟩, 0) (by decide))
  have r9 := Reach.step r8 (Step.readback _)
  have r10 := Reach.step r9 (Step.commit _ (⟨0⟩, 0) (by decide))
  exact ⟨_, r10, by decide, Or.inl (by decide)⟩

/-- Restart without quarantine: the gate forgets A's in-flight frame, then confirms B. -/
theorem restart_without_quarantine : Hijack { strict with quarantine := false } := by
  let a : Rules := { strict with quarantine := false }
  have r1 := Reach.step (Reach.init (p := P) (a := a)) (Step.issue _ 0 rfl)
  have r2 := Reach.step r1 (Step.redeem _ ⟨0, 0⟩ (by decide) rfl (by decide))
  have r3 := Reach.step r2 (Step.reshape _ [⟨0⟩, ⟨1⟩])
  have r4 := Reach.step r3 (Step.forward _ ⟨0⟩ (by decide) (by decide))
  have r5 := Reach.step r4 (Step.restart _)
  have r6 := Reach.step r5 (Step.issue _ 1 rfl)
  have r7 := Reach.step r6 (Step.redeem _ ⟨1, 2⟩ (by decide) rfl (by decide))
  have r8 := Reach.step r7 (Step.forward _ ⟨1⟩ (by decide) (by decide))
  have r9 := Reach.step r8 (Step.commit _ (⟨1⟩, 0) (by decide))
  have r10 := Reach.step r9 (Step.readback _)
  exact ⟨_, r10, by decide, Or.inr ⟨(⟨0⟩, 0), by decide, by decide⟩⟩

/-- Unbounded downstream latency: A's frame outlives the gate's tracking window. -/
theorem unbounded_downstream : Hijack { strict with boundedDown := false } := by
  let a : Rules := { strict with boundedDown := false }
  have r1 := Reach.step (Reach.init (p := P) (a := a)) (Step.issue _ 0 rfl)
  have r2 := Reach.step r1 (Step.redeem _ ⟨0, 0⟩ (by decide) rfl (by decide))
  have r3 := Reach.step r2 (Step.reshape _ [⟨0⟩, ⟨1⟩])
  have r4 := Reach.step r3 (Step.forward _ ⟨0⟩ (by decide) (by decide))
  have r5 := Reach.step r4 (Step.tick _ false (by intro h; cases h) (by intro h; cases h))
  have r6 := Reach.step r5 (Step.tick _ false (by intro h; cases h) (by intro h; cases h))
  have r7 := Reach.step r6 (Step.tick _ false (by intro h; cases h) (by intro h; cases h))
  have r8 := Reach.step r7 (Step.rechallenge _)
  have r9 := Reach.step r8 (Step.issue _ 1 rfl)
  have r10 := Reach.step r9 (Step.redeem _ ⟨1, 2⟩ (by decide) rfl (by decide))
  have r11 := Reach.step r10 (Step.forward _ ⟨1⟩ (by decide) (by decide))
  have r12 := Reach.step r11 (Step.commit _ (⟨1⟩, 0) (by decide))
  have r13 := Reach.step r12 (Step.readback _)
  exact ⟨_, r13, by decide, Or.inr ⟨(⟨0⟩, 3), by decide, by decide⟩⟩

end Refine.Counterexamples
