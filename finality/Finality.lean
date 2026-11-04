/-!
# AxiomOS actuation finality: machine-checked core (Lean 4, core library only)

Two separate guarantees, deliberately not conflated:

* `Provenance.provenance`, `Provenance.noninterference` (Theorem A, untimed).
  Whenever the power stage can be energized (LEASE_OK ∧ armed), the drive's setpoint was
  issued by the newest authority epoch the gate has adopted. Every protected state
  reachable while retired controllers inject frames is also reachable when they never do.
* `Energy.cutoff` (Theorem B, timed). With an independently clocked lease of `T` ticks
  and a shutdown path bounded by `δ` ticks, energy is impossible `T + δ` ticks after the
  last renewal.

Assumptions are fields of `Assumptions`. `Counterexamples` shows that dropping any one of
them breaks Theorem A in this model.

Check with: `lean Finality.lean`.
-/

namespace Provenance

structure Frame where
  origin : Nat   -- ghost: the epoch whose authority actually issued this command
  tag    : Nat   -- the epoch carried in the frame and checked by the gate
deriving DecidableEq

structure St where
  epoch : Nat         -- epoch the gate enforces
  hi    : Nat         -- ghost: newest epoch the gate has ever adopted (the effective cut)
  lease : Bool        -- LEASE_OK
  fresh : Bool        -- a current-epoch setpoint was delivered since the last epoch change
  armed : Bool        -- drive armed; untrusted, may change at any time
  src   : Option Nat  -- ghost: provenance of the drive's (persistent) setpoint register
  queue : List Frame  -- everything upstream of the gate: queues, buses, adapters

def init : St := ⟨0, 0, false, false, false, none, []⟩

structure Assumptions where
  authenticated : Bool  -- frames carry their true epoch (tag = origin): no forgery
  filter        : Bool  -- the gate drops frames whose tag ≠ epoch (command-path mediation)
  exclusive     : Bool  -- nothing writes the drive except through the gate
  regrantFresh  : Bool  -- the lease is re-granted only after a fresh current-epoch setpoint
  monotone      : Bool  -- a gate restart never adopts an epoch older than one already adopted

def full : Assumptions := ⟨true, true, true, true, true⟩

inductive Step (a : Assumptions) : St → St → Prop
  /-- Upstream is adversarial: arbitrary contents (injection by retired controllers, loss,
      reordering, duplication, unbounded retries), constrained only by authentication. -/
  | reshape (s : St) (q : List Frame)
      (h : a.authenticated = true → ∀ f ∈ q, f.tag = f.origin) :
      Step a s { s with queue := q }
  /-- Delivery of any pending frame (not consumed: retries are unbounded). -/
  | accept (s : St) (f : Frame) (hm : f ∈ s.queue)
      (hf : a.filter = true → f.tag = s.epoch) :
      Step a s { s with src := some f.origin, fresh := s.fresh || decide (f.tag = s.epoch) }
  | bypass (s : St) (o : Nat) (h : a.exclusive = false) :
      Step a s { s with src := some o }
  /-- Controller replacement: the authority service moves to a newer epoch. -/
  | cut (s : St) (e : Nat) (h : s.hi < e) :
      Step a s { s with epoch := e, hi := e, lease := false, fresh := false }
  | renew (s : St) (h : a.regrantFresh = true → s.fresh = true) :
      Step a s { s with lease := true }
  /-- Independent lease clock expiry, at any time. -/
  | expire (s : St) : Step a s { s with lease := false }
  | restart (s : St) (e : Nat) (h : a.monotone = true → s.hi ≤ e) :
      Step a s { s with epoch := e, hi := max s.hi e, lease := false, fresh := false }
  | arm (s : St) (b : Bool) : Step a s { s with armed := b }

inductive Reach (a : Assumptions) : St → Prop
  | init : Reach a init
  | step {s t : St} : Reach a s → Step a s t → Reach a t

def power (s : St) : Bool := s.lease && s.armed

structure Inv (s : St) : Prop where
  cur   : s.epoch = s.hi
  lease : s.lease = true → s.fresh = true
  fresh : s.fresh = true → s.src = some s.hi
  auth  : ∀ f ∈ s.queue, f.tag = f.origin

theorem inv_init : Inv init :=
  ⟨rfl, by simp [init], by simp [init], by simp [init]⟩

theorem inv_step {s t : St} (hs : Inv s) (h : Step full s t) : Inv t := by
  cases h with
  | reshape q hq =>
    exact ⟨hs.cur, hs.lease, hs.fresh, hq rfl⟩
  | accept f hm hf =>
    have htag : f.tag = s.epoch := hf rfl
    have horig : f.origin = s.hi := by rw [← hs.auth f hm, htag, hs.cur]
    refine ⟨hs.cur, ?_, ?_, hs.auth⟩
    · intro _; simp [htag]
    · intro _; simp [horig]
  | bypass o h => exact absurd h (by decide)
  | cut e he =>
    exact ⟨rfl, by simp, by simp, hs.auth⟩
  | renew h =>
    exact ⟨hs.cur, fun _ => h rfl, hs.fresh, hs.auth⟩
  | expire =>
    exact ⟨hs.cur, by simp, hs.fresh, hs.auth⟩
  | restart e he =>
    have hle : s.hi ≤ e := he rfl
    exact ⟨by simp [Nat.max_eq_right hle], by simp, by simp, hs.auth⟩
  | arm b =>
    exact ⟨hs.cur, hs.lease, hs.fresh, hs.auth⟩

theorem inv_reach {s : St} (h : Reach full s) : Inv s := by
  induction h with
  | init => exact inv_init
  | step _ hst ih => exact inv_step ih hst

/-- **Theorem A (command provenance).** Under all assumptions, whenever the power stage
    can be energized, the drive's setpoint was issued by the newest adopted epoch. -/
theorem provenance {s : St} (h : Reach full s) (hp : power s = true) :
    s.src = some s.hi := by
  have hi := inv_reach h
  have hl : s.lease = true := by simp [power] at hp; exact hp.1
  exact hi.fresh (hi.lease hl)

/-- A frame from a retired epoch can never pass the gate. -/
theorem retired_rejected {s : St} (h : Reach full s) {f : Frame} (hm : f ∈ s.queue)
    (hold : f.origin ≠ s.hi) : f.tag ≠ s.epoch := by
  have hi := inv_reach h
  rw [hi.auth f hm, hi.cur]; exact hold

/-- Remove every upstream frame not issued by the currently adopted epoch. -/
def purge (s : St) : St := { s with queue := s.queue.filter (fun f => decide (f.origin = s.hi)) }

theorem purge_queue (s : St) :
    ∀ f ∈ (purge s).queue, f.origin = s.hi := by
  intro f hf; simp [purge, List.mem_filter] at hf; exact hf.2

/-- **Theorem A' (noninterference across controller replacement).** Every state reachable
    while retired controllers inject arbitrary frames has the same protected projection
    (all fields except `queue`) as a state reachable when upstream only ever holds
    current-epoch frames. -/
theorem noninterference {s : St} (h : Reach full s) :
    Reach full (purge s) ∧ (∀ f ∈ (purge s).queue, f.origin = s.hi) := by
  refine ⟨?_, purge_queue s⟩
  induction h with
  | init => simpa [purge, init] using (Reach.init : Reach full init)
  | @step s t hs hst ih =>
    have hi := inv_reach hs
    cases hst with
    | reshape q hq =>
      exact Reach.step ih (Step.reshape _ _ (by
        intro _ f hf; simp [List.mem_filter] at hf; exact hq rfl f hf.1))
    | accept f hm hf =>
      have htag : f.tag = s.epoch := hf rfl
      have horig : f.origin = s.hi := by rw [← hi.auth f hm, htag, hi.cur]
      have hm' : f ∈ (purge s).queue := by simp [purge, List.mem_filter, hm, horig]
      exact Reach.step ih (Step.accept _ f hm' (fun _ => htag))
    | bypass o h => exact absurd h (by decide)
    | cut e he =>
      have r1 := Reach.step ih (Step.cut (purge s) e he)
      exact Reach.step r1 (Step.reshape _ (s.queue.filter (fun f => decide (f.origin = e))) (by
        intro _ f hf; simp [List.mem_filter] at hf; exact hi.auth f hf.1))
    | renew hr => exact Reach.step ih (Step.renew _ hr)
    | expire => exact Reach.step ih (Step.expire _)
    | restart e he =>
      have r1 := Reach.step ih (Step.restart (purge s) e he)
      exact Reach.step r1 (Step.reshape _ (s.queue.filter (fun f => decide (f.origin = max s.hi e))) (by
        intro _ f hf; simp [List.mem_filter] at hf; exact hi.auth f hf.1))
    | arm b => exact Reach.step ih (Step.arm _ b)

end Provenance

namespace Provenance.Counterexamples
open Provenance

/-- A violation: energizable while the setpoint comes from a retired epoch. -/
def Violation (a : Assumptions) : Prop :=
  ∃ s, Reach a s ∧ power s = true ∧ s.src ≠ some s.hi

/-- Power-only gate (no command filter): the setpoint-hijack counterexample.
    B (epoch 1) delivers a fresh setpoint and the lease is renewed; then retired A's
    epoch-0 frame overwrites the setpoint. -/
theorem hijack_without_filter : Violation { full with filter := false } := by
  let a : Assumptions := { full with filter := false }
  have r1 := Reach.step (Reach.init (a := a)) (Step.cut _ 1 (by decide))
  have r2 := Reach.step r1 (Step.reshape _ [⟨1, 1⟩, ⟨0, 0⟩] (by intro _; decide))
  have r3 := Reach.step r2 (Step.accept _ ⟨1, 1⟩ (by decide) (by intro _; decide))
  have r4 := Reach.step r3 (Step.renew _ (by intro _; decide))
  have r5 := Reach.step r4 (Step.accept _ ⟨0, 0⟩ (by decide) (by intro h; cases h))
  have r6 := Reach.step r5 (Step.arm _ true)
  exact ⟨_, r6, by decide, by decide⟩

theorem bypass_breaks : Violation { full with exclusive := false } := by
  let a : Assumptions := { full with exclusive := false }
  have r1 := Reach.step (Reach.init (a := a)) (Step.cut _ 1 (by decide))
  have r2 := Reach.step r1 (Step.reshape _ [⟨1, 1⟩] (by intro _; decide))
  have r3 := Reach.step r2 (Step.accept _ ⟨1, 1⟩ (by decide) (by intro _; decide))
  have r4 := Reach.step r3 (Step.renew _ (by intro _; decide))
  have r5 := Reach.step r4 (Step.bypass _ 0 rfl)
  have r6 := Reach.step r5 (Step.arm _ true)
  exact ⟨_, r6, by decide, by decide⟩

/-- Forged epoch tag: retired A's command carries the current tag. -/
theorem forgery_breaks : Violation { full with authenticated := false } := by
  let a : Assumptions := { full with authenticated := false }
  have r1 := Reach.step (Reach.init (a := a)) (Step.cut _ 1 (by decide))
  have r2 := Reach.step r1 (Step.reshape _ [⟨0, 1⟩] (by intro h; cases h))
  have r3 := Reach.step r2 (Step.accept _ ⟨0, 1⟩ (by decide) (by intro _; decide))
  have r4 := Reach.step r3 (Step.renew _ (by intro _; decide))
  have r5 := Reach.step r4 (Step.arm _ true)
  exact ⟨_, r5, by decide, by decide⟩

/-- Re-grant without a fresh setpoint: the persistent epoch-0 setpoint is revived (ODrive CX3). -/
theorem stale_regrant_breaks : Violation { full with regrantFresh := false } := by
  let a : Assumptions := { full with regrantFresh := false }
  have r1 := Reach.step (Reach.init (a := a)) (Step.reshape _ [⟨0, 0⟩] (by intro _; decide))
  have r2 := Reach.step r1 (Step.accept _ ⟨0, 0⟩ (by decide) (by intro _; decide))
  have r3 := Reach.step r2 (Step.cut _ 1 (by decide))
  have r4 := Reach.step r3 (Step.renew _ (by intro h; cases h))
  have r5 := Reach.step r4 (Step.arm _ true)
  exact ⟨_, r5, by decide, by decide⟩

/-- Gate restart that rolls back to an older epoch re-admits the retired controller. -/
theorem rollback_breaks : Violation { full with monotone := false } := by
  let a : Assumptions := { full with monotone := false }
  have r1 := Reach.step (Reach.init (a := a)) (Step.cut _ 1 (by decide))
  have r2 := Reach.step r1 (Step.restart _ 0 (by intro h; cases h))
  have r3 := Reach.step r2 (Step.reshape _ [⟨0, 0⟩] (by intro _; decide))
  have r4 := Reach.step r3 (Step.accept _ ⟨0, 0⟩ (by decide) (by intro _; decide))
  have r5 := Reach.step r4 (Step.renew _ (by intro _; decide))
  have r6 := Reach.step r5 (Step.arm _ true)
  exact ⟨_, r6, by decide, by decide⟩

end Provenance.Counterexamples

namespace Energy

/-- Gate-local, independently clocked lease and the shutdown path after LEASE_OK falls. -/
structure St where
  timer  : Nat  -- remaining lease ticks
  offFor : Nat  -- ticks since LEASE_OK fell (0 while LEASE_OK is high)

/-- One tick of the gate's own clock. No renewal happens inside `tick`. -/
def tick (s : St) : St :=
  { timer := s.timer - 1, offFor := if s.timer - 1 > 0 then 0 else s.offFor + 1 }

def ticks : Nat → St → St
  | 0, s => s
  | n + 1, s => ticks n (tick s)

/-- Physical energy can only be present while LEASE_OK is high, or for fewer than `δ`
    ticks after it falls (a bounded shutdown path: AND gate + driver + gate discharge). -/
def EnergyPossible (δ : Nat) (s : St) : Prop := s.timer > 0 ∨ s.offFor < δ

theorem ticks_add (m n : Nat) (s : St) : ticks (m + n) s = ticks n (ticks m s) := by
  induction m generalizing s with
  | zero => simp [ticks]
  | succ m ih =>
    rw [Nat.succ_add]
    exact ih (tick s)

theorem ticks_timer (k : Nat) (s : St) : (ticks k s).timer = s.timer - k := by
  induction k generalizing s with
  | zero => simp [ticks]
  | succ k ih => simp [ticks, ih, tick]; omega

theorem ticks_off (k : Nat) (s : St) (h0 : s.timer = 0) :
    (ticks k s).offFor = s.offFor + k := by
  induction k generalizing s with
  | zero => simp [ticks]
  | succ k ih =>
    simp only [ticks]
    rw [ih (tick s) (by simp [tick, h0])]
    simp [tick, h0]; omega

/-- **Theorem B (energy cutoff).** From any gate state whose lease timer is at most `T`
    (true after any renewal, which sets it to `T`), `T + δ` ticks without renewal leave no
    possibility of energy. -/
theorem cutoff (T δ k : Nat) (s : St) (hT : s.timer ≤ T) (hk : T + δ ≤ k) :
    ¬ EnergyPossible δ (ticks k s) := by
  have hsplit : k = s.timer + (k - s.timer) := by omega
  have hz : (ticks s.timer s).timer = 0 := by rw [ticks_timer]; omega
  have hoff := ticks_off (k - s.timer) (ticks s.timer s) hz
  rw [hsplit, ticks_add]
  intro hE
  rcases hE with hE | hE
  · rw [ticks_timer, hz] at hE; omega
  · rw [hoff] at hE; omega

end Energy
