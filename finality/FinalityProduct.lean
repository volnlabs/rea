/-!
# AxiomOS composed timed finality (Lean 4, core library only)

One transition system composes:
* the **authority service**: which grants are valid for the protected effect, plus the
  revocation time `cutAt` of the retired grant `r` (ghost);
* the **gate**: per-grant lease timers on its own tick, renewal by authority-issued tokens
  bound to (grant, challenge nonce), redeemable within `W` ticks of the challenge, and
  command forwarding to the drive. The gate may learn of the cut late or never (`notify`);
* the **output stage**: `out` changes only at ticks, can rise only while LEASE_OK ∧ armed,
  and must fall within `δ` ticks after LEASE_OK is observed low;
* an **adversarial upstream**: arbitrary, unreliable delivery (loss, delay, reordering,
  duplication, replay of frames and tokens). Retired controllers keep full upstream access.

LEASE_OK means "the grant whose command the gate last forwarded holds a live lease".
Energy is therefore always bound to the authority that issued the setpoint it executes.

Main theorem `finality`: for every reachable state with `now ≥ t_c + W + T + δ`, an energized
output has neither its energy support (`supp`) nor its setpoint provenance (`drvSrc`) from
the retired grant. Counterexamples show that each rule is needed, and a witness shows that
an independently valid authority may legitimately continue the same effect.

Check with: `lean FinalityProduct.lean`.
-/

namespace Product

structure Frame where
  origin : Nat   -- authenticated grant whose holder issued this command
deriving DecidableEq

structure Token where
  grant : Nat
  nonce : Nat
deriving DecidableEq

structure Params where
  T : Nat   -- lease length, gate ticks
  W : Nat   -- challenge freshness window, gate ticks
  δ : Nat   -- shutdown obligation: output off within δ ticks of LEASE_OK observed low
  r : Nat   -- the grant being retired

/-- Each rule can be switched off to obtain a counterexample. -/
structure Rules where
  issueOnlyValid : Bool  -- authority issues renewal tokens only for currently valid grants
  freshWindow    : Bool  -- gate redeems a token only within W ticks of its challenge
  noRollback     : Bool  -- authority state is never rolled back to re-validate r
  filter         : Bool  -- gate forwards a command only if its grant holds a live lease
  exclusiveCmd   : Bool  -- the drive's setpoint is written only through the gate
  exclusivePower : Bool  -- the output energizes only through LEASE_OK

def strict : Rules := ⟨true, true, true, true, true, true⟩

structure St where
  now     : Nat
  valid   : Nat → Bool   -- authority service: grants valid for the protected effect
  cutAt   : Option Nat   -- ghost: authority-service time at which r was revoked
  issued  : List Token   -- every token the authority has ever issued
  chal    : Nat          -- gate: outstanding challenge nonce
  chalAt  : Nat          -- gate: tick at which that challenge was issued
  timer   : Nat → Nat    -- gate: remaining lease per grant
  lastSrc : Option Nat   -- gate: grant whose command it last forwarded
  drvSrc  : Option Nat   -- ghost: provenance of the drive's persistent setpoint register
  queue   : List Frame   -- upstream of the gate (adversarial)
  armed   : Bool         -- drive armed (untrusted)
  out     : Bool         -- physical output energized
  offFor  : Nat          -- ticks since LEASE_OK was last observed high
  supp    : Option Nat   -- ghost: grant whose lease last enabled the output

def init : St :=
  { now := 0, valid := fun _ => true, cutAt := none, issued := [], chal := 0, chalAt := 0,
    timer := fun _ => 0, lastSrc := none, drvSrc := none, queue := [], armed := false,
    out := false, offFor := 0, supp := none }

/-- LEASE_OK as observed at the next tick (after every timer decrements). -/
def okAfterTick (s : St) : Bool :=
  match s.lastSrc with
  | some g => decide (s.timer g - 1 > 0)
  | none => false

def tickState (s : St) (o : Bool) : St :=
  { s with now := s.now + 1, timer := fun x => s.timer x - 1,
           offFor := if okAfterTick s then 0 else s.offFor + 1,
           supp := if okAfterTick s then s.lastSrc else s.supp, out := o }

inductive Step (p : Params) (a : Rules) : St → St → Prop
  | reshape (s : St) (q : List Frame) : Step p a s { s with queue := q }
  | accept (s : St) (f : Frame) (hm : f ∈ s.queue) (hf : a.filter = true → s.timer f.origin > 0) :
      Step p a s { s with lastSrc := some f.origin, drvSrc := some f.origin }
  | cmdBypass (s : St) (o : Nat) (h : a.exclusiveCmd = false) :
      Step p a s { s with drvSrc := some o }
  | issue (s : St) (g : Nat) (hv : a.issueOnlyValid = true → s.valid g = true) :
      Step p a s { s with issued := ⟨g, s.chal⟩ :: s.issued }
  | redeem (s : St) (tok : Token) (hm : tok ∈ s.issued) (hn : tok.nonce = s.chal)
      (hw : a.freshWindow = true → s.now ≤ s.chalAt + p.W) :
      Step p a s { s with timer := fun x => if x = tok.grant then p.T else s.timer x,
                          chal := s.chal + 1, chalAt := s.now }
  | rechallenge (s : St) : Step p a s { s with chal := s.chal + 1, chalAt := s.now }
  | cut (s : St) (h : s.cutAt = none) :
      Step p a s { s with valid := fun x => if x = p.r then false else s.valid x, cutAt := some s.now }
  | revalidate (s : St) (h : a.noRollback = false) :
      Step p a s { s with valid := fun x => if x = p.r then true else s.valid x }
  /-- The gate learns of the revocation. Optional: it may happen late or never. -/
  | notify (s : St) : Step p a s { s with timer := fun x => if x = p.r then 0 else s.timer x }
  | arm (s : St) (b : Bool) : Step p a s { s with armed := b }
  | tick (s : St) (o : Bool)
      (ho : o = true → (okAfterTick s = true ∧ s.armed = true) ∨
                       (s.out = true ∧ (if okAfterTick s then 0 else s.offFor + 1) < p.δ)) :
      Step p a s (tickState s o)
  | powerBypass (s : St) (h : a.exclusivePower = false) : Step p a s { s with out := true }

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
  sync    : s.drvSrc = s.lastSrc

theorem inv_init (p : Params) : Inv p init := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> simp [init]

/-- A live lease of the retired grant after the cut bounds the current time. -/
theorem live_bound {p : Params} {s : St} (hi : Inv p s) {c : Nat} (hc : s.cutAt = some c)
    (h : s.timer p.r > 0) : s.timer p.r + s.now ≤ c + p.W + p.T := by
  rcases hi.lease c hc with h0 | h1
  · omega
  · exact h1

theorem inv_step {p : Params} (hδ : 1 ≤ p.δ) {s t : St} (hi : Inv p s) (h : Step p strict s t) :
    Inv p t := by
  cases h with
  | reshape q => exact ⟨hi.nonce, hi.chalAt, hi.tmax, hi.cutNow, hi.revoked, hi.oldTok, hi.lease,
      hi.outOff, hi.supp, hi.src, hi.sync⟩
  | accept f hm hf =>
    have hlive : s.timer f.origin > 0 := hf rfl
    refine ⟨hi.nonce, hi.chalAt, hi.tmax, hi.cutNow, hi.revoked, hi.oldTok, hi.lease,
      hi.outOff, hi.supp, ?_, rfl⟩
    intro c hc hsrc
    have horig : f.origin = p.r := by simpa using hsrc
    rw [horig] at hlive
    have := live_bound hi hc hlive
    simp; omega
  | cmdBypass o h => exact absurd h (by decide)
  | issue g hv =>
    refine ⟨?_, hi.chalAt, hi.tmax, hi.cutNow, hi.revoked, ?_, hi.lease, hi.outOff, hi.supp,
      hi.src, hi.sync⟩
    · intro tok htok
      simp at htok
      rcases htok with rfl | htok
      · simp
      · exact hi.nonce tok htok
    · intro c hc tok htok hg hn
      simp at htok
      rcases htok with rfl | htok
      · have hval : s.valid g = true := hv rfl
        have hrev := hi.revoked c hc
        simp at hg; subst hg; rw [hval] at hrev; cases hrev
      · exact hi.oldTok c hc tok htok hg hn
  | redeem tok hm hn hw =>
    have hwin : s.now ≤ s.chalAt + p.W := hw rfl
    refine ⟨?_, by simp, ?_, hi.cutNow, hi.revoked, ?_, ?_, hi.outOff, hi.supp, hi.src, hi.sync⟩
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
      hi.sync⟩
    · intro tk htk; have := hi.nonce tk htk; simp; omega
    · intro c hc tk htk hg hn'
      have := hi.nonce tk htk; simp at hn'; omega
  | cut hcut =>
    refine ⟨hi.nonce, hi.chalAt, hi.tmax, ?_, ?_, ?_, ?_, hi.outOff, ?_, ?_, hi.sync⟩
    · intro c hc; simp at hc ⊢; omega
    · intro c _; simp
    · intro c hc tk _ _ _; simp at hc ⊢; have := hi.chalAt; omega
    · intro c hc; simp at hc ⊢; right; have := hi.tmax p.r; omega
    · intro c hc _; simp at hc ⊢; omega
    · intro c hc _; simp at hc ⊢; omega
  | revalidate h => exact absurd h (by decide)
  | notify =>
    refine ⟨hi.nonce, hi.chalAt, ?_, hi.cutNow, hi.revoked, hi.oldTok, ?_, hi.outOff, hi.supp,
      hi.src, hi.sync⟩
    · intro g; by_cases hg : g = p.r <;> simp [hg, hi.tmax g]
    · intro c _; left; simp
  | arm b => exact ⟨hi.nonce, hi.chalAt, hi.tmax, hi.cutNow, hi.revoked, hi.oldTok, hi.lease,
      hi.outOff, hi.supp, hi.src, hi.sync⟩
  | tick o ho =>
    -- facts about the tick when the retired grant's lease is observed live
    have okBound : ∀ c, s.cutAt = some c → s.lastSrc = some p.r → okAfterTick s = true →
        s.now + 1 ≤ c + p.W + p.T := by
      intro c hc hl hok
      simp [okAfterTick, hl] at hok
      have := live_bound hi hc (by omega)
      omega
    refine ⟨hi.nonce, by simp [tickState]; have := hi.chalAt; omega, ?_, ?_, hi.revoked, hi.oldTok,
      ?_, ?_, ?_, ?_, hi.sync⟩
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
      by_cases hok : okAfterTick s = true
      · simp [tickState, hok] at hsupp ⊢
        have := okBound c hc hsupp hok
        omega
      · simp [tickState, hok] at hsupp ⊢
        have := hi.supp c hc hsupp
        omega
    · intro c hc hl
      simp [tickState] at hc hl
      by_cases hok : okAfterTick s = true
      · simp [tickState, hok]; have := okBound c hc hl hok; omega
      · simp [tickState, hok]; have := hi.src c hc hl; omega
  | powerBypass h => exact absurd h (by decide)

theorem inv_reach {p : Params} (hδ : 1 ≤ p.δ) {s : St} (h : Reach p strict s) : Inv p s := by
  induction h with
  | init => exact inv_init p
  | step _ hst ih => exact inv_step hδ ih hst

/-- **Composed timed finality.** Under the strict rules, with arbitrary upstream interference,
    unreliable delivery and a gate that may never learn of the revocation: from
    `t_c + W + T + δ` on, an energized output depends on the retired grant neither for its
    energy (`supp`) nor for its command (`drvSrc`). -/
theorem finality {p : Params} (hδ : 1 ≤ p.δ) {s : St} (h : Reach p strict s) {c : Nat}
    (hc : s.cutAt = some c) (hdl : c + p.W + p.T + p.δ ≤ s.now) (hout : s.out = true) :
    s.supp ≠ some p.r ∧ s.drvSrc ≠ some p.r := by
  have hi := inv_reach hδ h
  have hoff := hi.outOff hout
  constructor
  · intro hs; have := hi.supp c hc hs; omega
  · intro hd; rw [hi.sync] at hd; have := hi.src c hc hd; omega

end Product

namespace Product.Counterexamples
open Product

/-- T = 2, W = 0, δ = 1; grant 0 is retired, grant 1 is an independent valid authority.
    The cut happens at time 0, so the deadline is 0 + 0 + 2 + 1 = 3. -/
def P : Params := ⟨2, 0, 1, 0⟩

def Violation (a : Rules) : Prop :=
  ∃ s c, Reach P a s ∧ s.cutAt = some c ∧ c + P.W + P.T + P.δ ≤ s.now ∧ s.out = true ∧
    (s.supp = some P.r ∨ s.drvSrc = some P.r)

/-- Lease renewal after revocation: the authority keeps issuing tokens for retired grant 0. -/
theorem renewal_after_revocation : Violation { strict with issueOnlyValid := false } := by
  let a : Rules := { strict with issueOnlyValid := false }
  have r1 := Reach.step (Reach.init (p := P) (a := a)) (Step.cut _ rfl)
  have r2 := Reach.step r1 (Step.issue _ 0 (by intro h; cases h))
  have r3 := Reach.step r2 (Step.redeem _ ⟨0, 0⟩ (by decide) rfl (by intro _; decide))
  have r4 := Reach.step r3 (Step.reshape _ [⟨0⟩])
  have r5 := Reach.step r4 (Step.accept _ ⟨0⟩ (by decide) (by intro _; decide))
  have r6 := Reach.step r5 (Step.arm _ true)
  have r7 := Reach.step r6 (Step.tick _ true (by intro _; left; decide))
  have r8 := Reach.step r7 (Step.rechallenge _)
  have r9 := Reach.step r8 (Step.issue _ 0 (by intro h; cases h))
  have r10 := Reach.step r9 (Step.redeem _ ⟨0, 2⟩ (by decide) rfl (by intro _; decide))
  have r11 := Reach.step r10 (Step.tick _ true (by intro _; left; decide))
  have r12 := Reach.step r11 (Step.rechallenge _)
  have r13 := Reach.step r12 (Step.issue _ 0 (by intro h; cases h))
  have r14 := Reach.step r13 (Step.redeem _ ⟨0, 4⟩ (by decide) rfl (by intro _; decide))
  have r15 := Reach.step r14 (Step.tick _ true (by intro _; left; decide))
  exact ⟨_, 0, r15, rfl, by decide, rfl, Or.inl rfl⟩

/-- Rollback of authority-service state re-validates grant 0 after its revocation. -/
theorem authority_rollback : Violation { strict with noRollback := false } := by
  let a : Rules := { strict with noRollback := false }
  have r1 := Reach.step (Reach.init (p := P) (a := a)) (Step.cut _ rfl)
  have r1' := Reach.step r1 (Step.revalidate _ rfl)
  have r2 := Reach.step r1' (Step.issue _ 0 (by intro _; decide))
  have r3 := Reach.step r2 (Step.redeem _ ⟨0, 0⟩ (by decide) rfl (by intro _; decide))
  have r4 := Reach.step r3 (Step.reshape _ [⟨0⟩])
  have r5 := Reach.step r4 (Step.accept _ ⟨0⟩ (by decide) (by intro _; decide))
  have r6 := Reach.step r5 (Step.arm _ true)
  have r7 := Reach.step r6 (Step.tick _ true (by intro _; left; decide))
  have r8 := Reach.step r7 (Step.rechallenge _)
  have r9 := Reach.step r8 (Step.issue _ 0 (by intro _; decide))
  have r10 := Reach.step r9 (Step.redeem _ ⟨0, 2⟩ (by decide) rfl (by intro _; decide))
  have r11 := Reach.step r10 (Step.tick _ true (by intro _; left; decide))
  have r12 := Reach.step r11 (Step.rechallenge _)
  have r13 := Reach.step r12 (Step.issue _ 0 (by intro _; decide))
  have r14 := Reach.step r13 (Step.redeem _ ⟨0, 4⟩ (by decide) rfl (by intro _; decide))
  have r15 := Reach.step r14 (Step.tick _ true (by intro _; left; decide))
  exact ⟨_, 0, r15, rfl, by decide, rfl, Or.inl rfl⟩

/-- No freshness window: a token stockpiled before the cut is redeemed arbitrarily late. -/
theorem stale_token_replay : Violation { strict with freshWindow := false } := by
  let a : Rules := { strict with freshWindow := false }
  have r1 := Reach.step (Reach.init (p := P) (a := a)) (Step.issue _ 0 (by intro _; decide))
  have r2 := Reach.step r1 (Step.cut _ rfl)
  have r3 := Reach.step r2 (Step.tick _ false (by intro h; cases h))
  have r4 := Reach.step r3 (Step.tick _ false (by intro h; cases h))
  have r5 := Reach.step r4 (Step.tick _ false (by intro h; cases h))
  have r6 := Reach.step r5 (Step.redeem _ ⟨0, 0⟩ (by decide) rfl (by intro h; cases h))
  have r7 := Reach.step r6 (Step.reshape _ [⟨0⟩])
  have r8 := Reach.step r7 (Step.accept _ ⟨0⟩ (by decide) (by intro _; decide))
  have r9 := Reach.step r8 (Step.arm _ true)
  have r10 := Reach.step r9 (Step.tick _ true (by intro _; left; decide))
  exact ⟨_, 0, r10, rfl, by decide, rfl, Or.inl rfl⟩

/-- Power-path bypass: the actuator is energized without LEASE_OK (e.g. an RP1 pin wired to it)
    while the drive still holds retired grant 0's setpoint. -/
theorem power_bypass : Violation { strict with exclusivePower := false } := by
  let a : Rules := { strict with exclusivePower := false }
  have r1 := Reach.step (Reach.init (p := P) (a := a)) (Step.issue _ 0 (by intro _; decide))
  have r2 := Reach.step r1 (Step.redeem _ ⟨0, 0⟩ (by decide) rfl (by intro _; decide))
  have r3 := Reach.step r2 (Step.reshape _ [⟨0⟩])
  have r4 := Reach.step r3 (Step.accept _ ⟨0⟩ (by decide) (by intro _; decide))
  have r5 := Reach.step r4 (Step.cut _ rfl)
  have r6 := Reach.step r5 (Step.tick _ false (by intro h; cases h))
  have r7 := Reach.step r6 (Step.tick _ false (by intro h; cases h))
  have r8 := Reach.step r7 (Step.tick _ false (by intro h; cases h))
  have r9 := Reach.step r8 (Step.powerBypass _ rfl)
  exact ⟨_, 0, r9, rfl, by decide, rfl, Or.inr rfl⟩

/-- Command-path bypass (e.g. RP1 BAR1, `/dev/pio`, a second CAN node): authority 1 keeps the
    output legitimately energized past the deadline, then retired grant 0's setpoint is written
    into the drive without passing the gate. -/
theorem command_bypass : Violation { strict with exclusiveCmd := false } := by
  let a : Rules := { strict with exclusiveCmd := false }
  have r1 := Reach.step (Reach.init (p := P) (a := a)) (Step.cut _ rfl)
  have r2 := Reach.step r1 (Step.issue _ 1 (by intro _; decide))
  have r3 := Reach.step r2 (Step.redeem _ ⟨1, 0⟩ (by decide) rfl (by intro _; decide))
  have r4 := Reach.step r3 (Step.reshape _ [⟨1⟩])
  have r5 := Reach.step r4 (Step.accept _ ⟨1⟩ (by decide) (by intro _; decide))
  have r6 := Reach.step r5 (Step.arm _ true)
  have r7 := Reach.step r6 (Step.tick _ true (by intro _; left; decide))
  have r8 := Reach.step r7 (Step.rechallenge _)
  have r9 := Reach.step r8 (Step.issue _ 1 (by intro _; decide))
  have r10 := Reach.step r9 (Step.redeem _ ⟨1, 2⟩ (by decide) rfl (by intro _; decide))
  have r11 := Reach.step r10 (Step.tick _ true (by intro _; left; decide))
  have r12 := Reach.step r11 (Step.rechallenge _)
  have r13 := Reach.step r12 (Step.issue _ 1 (by intro _; decide))
  have r14 := Reach.step r13 (Step.redeem _ ⟨1, 4⟩ (by decide) rfl (by intro _; decide))
  have r15 := Reach.step r14 (Step.tick _ true (by intro _; left; decide))
  have r16 := Reach.step r15 (Step.cmdBypass _ 0 rfl)
  exact ⟨_, 0, r16, rfl, by decide, rfl, Or.inr rfl⟩

/-- No command filter: after the deadline, retired grant 0's frame is forwarded while authority
    1's lease keeps the output energized. -/
theorem no_filter : Violation { strict with filter := false } := by
  let a : Rules := { strict with filter := false }
  have r1 := Reach.step (Reach.init (p := P) (a := a)) (Step.cut _ rfl)
  have r2 := Reach.step r1 (Step.issue _ 1 (by intro _; decide))
  have r3 := Reach.step r2 (Step.redeem _ ⟨1, 0⟩ (by decide) rfl (by intro _; decide))
  have r4 := Reach.step r3 (Step.reshape _ [⟨1⟩, ⟨0⟩])
  have r5 := Reach.step r4 (Step.accept _ ⟨1⟩ (by decide) (by intro h; cases h))
  have r6 := Reach.step r5 (Step.arm _ true)
  have r7 := Reach.step r6 (Step.tick _ true (by intro _; left; decide))
  have r8 := Reach.step r7 (Step.rechallenge _)
  have r9 := Reach.step r8 (Step.issue _ 1 (by intro _; decide))
  have r10 := Reach.step r9 (Step.redeem _ ⟨1, 2⟩ (by decide) rfl (by intro _; decide))
  have r11 := Reach.step r10 (Step.tick _ true (by intro _; left; decide))
  have r12 := Reach.step r11 (Step.rechallenge _)
  have r13 := Reach.step r12 (Step.issue _ 1 (by intro _; decide))
  have r14 := Reach.step r13 (Step.redeem _ ⟨1, 4⟩ (by decide) rfl (by intro _; decide))
  have r15 := Reach.step r14 (Step.tick _ true (by intro _; left; decide))
  have r16 := Reach.step r15 (Step.accept _ ⟨0⟩ (by decide) (by intro h; cases h))
  exact ⟨_, 0, r16, rfl, by decide, rfl, Or.inr rfl⟩

/-- Two independently valid authorities. The naive property "after the deadline the effect
    is off" is false under the strict rules: authority 1 legitimately continues the same
    effect after grant 0 is retired. `finality` correctly permits this, because the
    output's support and setpoint come from grant 1. -/
theorem independent_reauthorization :
    ∃ s c, Reach P strict s ∧ s.cutAt = some c ∧ c + P.W + P.T + P.δ ≤ s.now ∧
      s.out = true ∧ s.supp = some 1 ∧ s.drvSrc = some 1 := by
  have r1 := Reach.step (Reach.init (p := P) (a := strict)) (Step.cut _ rfl)
  have r2 := Reach.step r1 (Step.issue _ 1 (by intro _; decide))
  have r3 := Reach.step r2 (Step.redeem _ ⟨1, 0⟩ (by decide) rfl (by intro _; decide))
  have r4 := Reach.step r3 (Step.reshape _ [⟨1⟩])
  have r5 := Reach.step r4 (Step.accept _ ⟨1⟩ (by decide) (by intro _; decide))
  have r6 := Reach.step r5 (Step.arm _ true)
  have r7 := Reach.step r6 (Step.tick _ true (by intro _; left; decide))
  have r8 := Reach.step r7 (Step.rechallenge _)
  have r9 := Reach.step r8 (Step.issue _ 1 (by intro _; decide))
  have r10 := Reach.step r9 (Step.redeem _ ⟨1, 2⟩ (by decide) rfl (by intro _; decide))
  have r11 := Reach.step r10 (Step.tick _ true (by intro _; left; decide))
  have r12 := Reach.step r11 (Step.rechallenge _)
  have r13 := Reach.step r12 (Step.issue _ 1 (by intro _; decide))
  have r14 := Reach.step r13 (Step.redeem _ ⟨1, 4⟩ (by decide) rfl (by intro _; decide))
  have r15 := Reach.step r14 (Step.tick _ true (by intro _; left; decide))
  exact ⟨_, 0, r15, rfl, by decide, rfl, rfl, rfl⟩

end Product.Counterexamples
