/-!
# Lease expiry on a wrapping 32-bit clock (Lean 4, core library only)

The other files in this directory count time in `Nat`. The gate firmware (`../odrive/gate/gate.h`)
counts it in a 32-bit register that wraps, and tests a deadline with the signed difference
`(int32_t)(expiry - now) > 0`. That test is only right while the deadline is less than 2^31 ticks
away. A lease that ended 2^31 ticks ago compares as live again: found by review of the C code on
2026-11-12, reproduced, and fixed by latching (`gate_tick`: an expired lease is dropped the first
time it is seen expired).

Results:
* `live_iff`: within 2^31 ticks either side, the wrapped test equals the true comparison;
* `zombie`: outside that range it does not: from 2^31 + 1 ticks after it ended, a lease tests as
  live again;
* `latch_step`, `latch_sound`: with the latch, if the gate looks at the clock at least once every
  `2^31 - T` ticks (`T` = lease length), a lease is held exactly while it is truly live, forever;
* `no_latch_unsound`: the same schedule without the latch enables the output on a dead lease.

Check with: `lean ClockWrap.lean`.
-/

namespace ClockWrap

def M : Nat := 4294967296          -- 2^32
def H : Nat := 2147483648          -- 2^31

/-- The firmware's test: `(int32_t)(expiry - now) > 0`, on the wrapped values of true times. -/
def live (expiry now : Nat) : Bool :=
  decide (0 < (expiry % M + M - now % M) % M ∧ (expiry % M + M - now % M) % M < H)

/-- Within 2^31 ticks either side, the wrapped test is the true comparison. -/
theorem live_iff (e n : Nat) (h1 : e < n + H) (h2 : n < e + H) : live e n = true ↔ n < e := by
  simp only [H] at h1 h2
  unfold live M H
  rw [decide_eq_true_iff]
  omega

/-- Outside that range it is wrong: a lease that ended at 100 tests as dead up to 2^31 ticks
    later, and as live again from the tick after that (for the next 2^31 - 1 ticks). -/
theorem zombie : live 100 100 = false ∧ live 100 (100 + H) = false
    ∧ live 100 (100 + H + 1) = true ∧ live 100 (100 + M - 1) = true := by
  refine ⟨by decide, by decide, by decide, by decide⟩

/-- Gate state for one lease: `some e` = held, with true expiry time `e`. -/
abbrev Lease := Option Nat

/-- `gate_tick` at true time `n`: drop the lease once the wrapped test says it is over. -/
def tick (s : Lease) (n : Nat) : Lease :=
  match s with
  | some e => if live e n then some e else none
  | none => none

/-- A grant at true time `n` for `T` ticks. -/
def grant (n T : Nat) : Lease := some (n + T)

/-- What must hold right after each look at the clock: a held lease is truly live, and its
    expiry is at most `T` ahead. -/
def Good (T : Nat) (s : Lease) (n : Nat) : Prop :=
  ∀ e, s = some e → n < e ∧ e ≤ n + T

theorem grant_good (n T : Nat) (hT : 0 < T) : Good T (grant n T) n := by
  intro e h
  simp only [grant, Option.some.injEq] at h
  omega

/-- One step: if the next look comes less than `2^31 - T` ticks later, the latch keeps `Good`,
    and it decides exactly by the true comparison. -/
theorem latch_step (T : Nat) (s : Lease) (n n' : Nat) (hn : n ≤ n') (gap : n' + T < n + H)
    (g : Good T s n) :
    Good T (tick s n') n' ∧ (∀ e, s = some e → (tick s n' = some e ↔ n' < e)) := by
  cases s with
  | none => exact ⟨by intro e h; simp [tick] at h, by intro e h; cases h⟩
  | some e =>
    have ⟨h1, h2⟩ := g e rfl
    have key : live e n' = true ↔ n' < e := live_iff e n' (by omega) (by omega)
    constructor
    · intro e' h
      simp only [tick] at h
      by_cases hl : live e n' = true
      · simp only [hl, ite_true, Option.some.injEq] at h
        have := key.mp hl
        omega
      · simp [hl] at h
    · intro e' h
      cases h
      simp only [tick]
      by_cases hl : live e n' = true
      · simp [hl, key.mp hl]
      · have : ¬ n' < e := fun c => hl (key.mpr c)
        simp [hl, this]

/-- A schedule of looks at the clock: true times, each less than `2^31 - T` after the last. -/
def Sched (T : Nat) : Nat → List Nat → Prop
  | _, [] => True
  | n, n' :: rest => n ≤ n' ∧ n' + T < n + H ∧ Sched T n' rest

def run (s : Lease) : List Nat → Lease
  | [] => s
  | n :: rest => run (tick s n) rest

/-- With the latch, after any such schedule, however long (the clock may wrap any number of
    times), the lease is held only if it is truly live. -/
theorem latch_sound (T : Nat) :
    ∀ (ts : List Nat) (s : Lease) (n : Nat), Good T s n → Sched T n ts →
      ∀ e, run s ts = some e → (ts.getLast?.getD n) < e := by
  intro ts
  induction ts with
  | nil =>
    intro s n g _ e h
    simpa using (g e h).1
  | cons n' rest ih =>
    intro s n g hs e h
    obtain ⟨h1, h2, h3⟩ := hs
    have g' := (latch_step T s n n' h1 h2 g).1
    have := ih (tick s n') n' g' h3 e h
    cases rest with
    | nil => simpa using this
    | cons a b => simpa [List.getLast?] using this

/-- The same schedule with and without the latch. A lease granted at 0 for 100 ticks, looked at
    three times, each look less than `2^31 - 100` ticks after the last. With the latch it is gone;
    the stateless test at the last look says "live", 2^31 ticks after the lease ended. -/
theorem no_latch_unsound :
    Sched 100 0 [1073741824, 2147483648, 2147483749]
    ∧ run (grant 0 100) [1073741824, 2147483648, 2147483749] = none
    ∧ live 100 2147483749 = true := by
  refine ⟨by simp [Sched, H], by decide, by decide⟩

end ClockWrap
