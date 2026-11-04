/-!
# Why the downstream bound (or a drive-side fence) is necessary (Lean 4, core library only)

`GateRefinement.lean` assumes downstream frames resolve within `Dd` ticks, by refusing to
let time advance otherwise. This file removes that assumption.

## Part 1: `Impossible`: no gate policy can be safe and live without it

Delivery latency is unbounded and loss is possible. The drive does not acknowledge commits
(stock ODrive CAN), so commits and losses are **hidden** from the gate.

The gate's LEASE_OK decision is an **arbitrary function** `π` of its entire observation
history:
* the commands it forwarded,
* readback results,
* clock ticks,
* arbitrary other inputs (tokens, notifications, timers).

* `lost_frame_blocks`: if `π` is safe (whenever it energizes, no other grant's command is
  committed or still pending), then in every run where another grant's frame was lost, `π`
  refuses. Lost and stuck are indistinguishable to the gate.
* `no_timeout_helps`: in the run "A's frame lost, B's frame committed and confirmed by
  readback, then any number of ticks", every safe policy refuses forever. Waiting longer
  never proves a frame is gone.

## Part 2: `Fence`: a drive-side epoch fence restores safety *and* liveness

The drive accepts a setpoint only if it is addressed to its current node id. The gate
rotates the node id to the new epoch and confirms it by readback. On stock ODrive this is
`SET_AXIS_NODE_ID` (`can_simple.cpp:222-224`), matched per frame (`can_simple.cpp:51`), and
readable over UART as `axis0.config.can.node_id`.

* `safe`: under unbounded latency, loss, reordering and stuck frames, whenever LEASE_OK is
  confirmed, every pending command that could still commit is from the current epoch, and
  the committed setpoint is either the current epoch's or value-equal to it.
* `live_despite_stuck_frame`: the gate energizes while a retired frame stays stuck forever.
* `stale_rotation_breaks`, `value_readback_only_breaks`: both fence rules are necessary.

Check with: `lean Impossibility.lean`.
-/

namespace Impossible

inductive Obs
  | fwd (g : Nat)
  | read (v : Option Nat)
  | tick
  | input (k : Nat)
deriving DecidableEq

structure W where
  next    : Nat
  origin  : Nat → Nat     -- origin grant of each forwarded frame, by id
  pending : Nat → Bool    -- ghost: frame still downstream (may commit later)
  lost    : Nat → Bool    -- ghost: frame was lost
  drv     : Option Nat    -- drive's committed setpoint (value = origin abstraction)
  lastSrc : Option Nat
  obs     : List Obs      -- everything the gate has observed, newest first

def init : W := ⟨0, fun _ => 0, fun _ => false, fun _ => false, none, none, []⟩

def upd {α : Type} (f : Nat → α) (i : Nat) (v : α) : Nat → α := fun j => if j = i then v else f j

inductive Step : W → W → Prop
  | fwd (w : W) (g : Nat) :
      Step w { w with next := w.next + 1, origin := upd w.origin w.next g,
                      pending := upd w.pending w.next true, lastSrc := some g,
                      obs := Obs.fwd g :: w.obs }
  /-- hidden: the drive commits a pending frame, at any time and in any order -/
  | commit (w : W) (i : Nat) (h : w.pending i = true) :
      Step w { w with drv := some (w.origin i), pending := upd w.pending i false }
  /-- hidden: a pending frame is lost -/
  | lose (w : W) (i : Nat) (h : w.pending i = true) :
      Step w { w with pending := upd w.pending i false, lost := upd w.lost i true }
  | readback (w : W) : Step w { w with obs := Obs.read w.drv :: w.obs }
  | tick (w : W) : Step w { w with obs := Obs.tick :: w.obs }
  | input (w : W) (k : Nat) : Step w { w with obs := Obs.input k :: w.obs }

inductive Reach : W → Prop
  | init : Reach init
  | step {s t : W} : Reach s → Step s t → Reach t

/-- A policy is safe if, whenever it energizes, the committed setpoint and every pending
    frame (each could still commit) come from the grant the gate last forwarded for. -/
def Safe (π : List Obs → Bool) : Prop :=
  ∀ w, Reach w → π w.obs = true →
    w.drv = w.lastSrc ∧ ∀ j, w.pending j = true → some (w.origin j) = w.lastSrc

structure Inv (w : W) : Prop where
  lostLt   : ∀ j, w.lost j = true → j < w.next
  pendLt   : ∀ j, w.pending j = true → j < w.next
  disjoint : ∀ j, w.pending j = true → w.lost j = false

theorem inv_reach {w : W} (h : Reach w) : Inv w := by
  induction h with
  | init => exact ⟨by simp [init], by simp [init], by simp [init]⟩
  | @step s t _ hst ih =>
    cases hst with
    | fwd g =>
      refine ⟨fun j hj => Nat.lt_succ_of_lt (ih.lostLt j hj), ?_, ?_⟩
      · intro j hj
        by_cases hjn : j = s.next
        · show j < s.next + 1; omega
        · have : s.pending j = true := by simpa [upd, hjn] using hj
          exact Nat.lt_succ_of_lt (ih.pendLt j this)
      · intro j hj
        show s.lost j = false
        by_cases hjn : j = s.next
        · subst hjn
          cases hl : s.lost s.next with
          | false => rfl
          | true => exact absurd (ih.lostLt _ hl) (Nat.lt_irrefl _)
        · have : s.pending j = true := by simpa [upd, hjn] using hj
          exact ih.disjoint j this
    | commit i hi =>
      refine ⟨ih.lostLt, ?_, ?_⟩
      · intro j hj; simp [upd] at hj; exact ih.pendLt j hj.2
      · intro j hj; simp [upd] at hj; exact ih.disjoint j hj.2
    | lose i hi =>
      refine ⟨?_, ?_, ?_⟩
      · intro j hj
        show j < s.next
        by_cases hji : j = i
        · subst hji; exact ih.pendLt j hi
        · have : s.lost j = true := by simpa [upd, hji] using hj
          exact ih.lostLt j this
      · intro j hj; simp [upd] at hj; exact ih.pendLt j hj.2
      · intro j hj
        simp [upd] at hj
        show (if j = i then true else s.lost j) = false
        simp [hj.1]; exact ih.disjoint j hj.2
    | readback => exact ⟨fun j hj => ih.lostLt j hj, fun j hj => ih.pendLt j hj, fun j hj => ih.disjoint j hj⟩
    | tick => exact ⟨fun j hj => ih.lostLt j hj, fun j hj => ih.pendLt j hj, fun j hj => ih.disjoint j hj⟩
    | input k => exact ⟨fun j hj => ih.lostLt j hj, fun j hj => ih.pendLt j hj, fun j hj => ih.disjoint j hj⟩

/-- `u` is `w` with frame `x` still pending instead of lost: same observations. -/
structure Sim (x : Nat) (u w : W) : Prop where
  obs     : u.obs = w.obs
  lastSrc : u.lastSrc = w.lastSrc
  drv     : u.drv = w.drv
  origin  : u.origin = w.origin
  next    : u.next = w.next
  pending : ∀ j, u.pending j = (w.pending j || decide (j = x))

/-- For every run in which frame `x` was lost, there is a run, indistinguishable to the gate,
    in which `x` is still pending (stuck) and may commit later. -/
theorem stuck_twin {w : W} (h : Reach w) {x : Nat} (hl : w.lost x = true) :
    ∃ u, Reach u ∧ Sim x u w := by
  induction h with
  | init => simp [init] at hl
  | @step s t hs hst ih =>
    have hi := inv_reach hs
    cases hst with
    | fwd g =>
      obtain ⟨u, hu, hsim⟩ := ih hl
      refine ⟨_, Reach.step hu (Step.fwd u g), ?_⟩
      refine ⟨by simp [hsim.obs], rfl, hsim.drv, ?_, by simp [hsim.next], ?_⟩
      · simp [hsim.origin, hsim.next]
      · intro j; simp only [upd, hsim.next]; split <;> simp_all [hsim.pending j]
    | commit i hpi =>
      obtain ⟨u, hu, hsim⟩ := ih hl
      have hix : i ≠ x := by
        intro hix; subst hix; have := hi.disjoint i hpi; simp_all
      have hup : u.pending i = true := by rw [hsim.pending i]; simp [hpi]
      refine ⟨_, Reach.step hu (Step.commit u i hup), ?_⟩
      refine ⟨hsim.obs, hsim.lastSrc, by simp [hsim.origin], hsim.origin, hsim.next, ?_⟩
      intro j; simp only [upd]
      by_cases hji : j = i
      · subst hji; simp [hix]
      · simp [hji, hsim.pending j]
    | lose i hpi =>
      by_cases hsx : s.lost x = true
      · obtain ⟨u, hu, hsim⟩ := ih hsx
        have hix : i ≠ x := by
          intro hix; subst hix; have := hi.disjoint i hpi; simp_all
        have hup : u.pending i = true := by rw [hsim.pending i]; simp [hpi]
        refine ⟨_, Reach.step hu (Step.lose u i hup), ?_⟩
        refine ⟨hsim.obs, hsim.lastSrc, hsim.drv, hsim.origin, hsim.next, ?_⟩
        intro j; simp only [upd]
        by_cases hji : j = i
        · subst hji; simp [hix]
        · simp [hji, hsim.pending j]
      · -- this step is the loss of `x` itself: the stuck twin is the state before it
        have hix : i = x := by
          simp [upd] at hl
          by_cases hxi : x = i
          · exact hxi.symm
          · simp [hxi] at hl; exact absurd hl hsx
        subst hix
        refine ⟨s, hs, rfl, rfl, rfl, rfl, rfl, ?_⟩
        intro j; simp only [upd]
        by_cases hji : j = i
        · subst hji; simp [hpi]
        · simp [hji]
    | readback =>
      obtain ⟨u, hu, hsim⟩ := ih hl
      refine ⟨_, Reach.step hu (Step.readback u), ?_⟩
      exact ⟨by simp [hsim.obs, hsim.drv], hsim.lastSrc, hsim.drv, hsim.origin, hsim.next, hsim.pending⟩
    | tick =>
      obtain ⟨u, hu, hsim⟩ := ih hl
      exact ⟨_, Reach.step hu (Step.tick u),
        by simp [hsim.obs], hsim.lastSrc, hsim.drv, hsim.origin, hsim.next, hsim.pending⟩
    | input k =>
      obtain ⟨u, hu, hsim⟩ := ih hl
      exact ⟨_, Reach.step hu (Step.input u k),
        by simp [hsim.obs], hsim.lastSrc, hsim.drv, hsim.origin, hsim.next, hsim.pending⟩

/-- **Impossibility.** A safe policy can never energize in a run where some other grant's
    frame was lost, whatever else it has observed. -/
theorem lost_frame_blocks (π : List Obs → Bool) (hs : Safe π) {w : W} (h : Reach w)
    {x : Nat} (hl : w.lost x = true) (hother : some (w.origin x) ≠ w.lastSrc) :
    π w.obs = false := by
  cases hπ : π w.obs with
  | false => rfl
  | true =>
    obtain ⟨u, hu, hsim⟩ := stuck_twin h hl
    have hπu : π u.obs = true := by rw [hsim.obs]; exact hπ
    have hpend : u.pending x = true := by rw [hsim.pending x]; simp
    have := (hs u hu hπu).2 x hpend
    rw [hsim.origin, hsim.lastSrc] at this
    exact absurd this hother

/-- A's frame (id 0) is lost; B's frame (id 1) commits and is confirmed by readback;
    then `n` ticks pass. -/
def afterLoss : Nat → W
  | 0 =>
    let w1 := { init with next := 1, origin := upd init.origin 0 0, pending := upd init.pending 0 true,
                          lastSrc := some 0, obs := [Obs.fwd 0] }
    let w2 := { w1 with pending := upd w1.pending 0 false, lost := upd w1.lost 0 true }
    let w3 := { w2 with next := 2, origin := upd w2.origin 1 1, pending := upd w2.pending 1 true,
                        lastSrc := some 1, obs := Obs.fwd 1 :: w2.obs }
    let w4 := { w3 with drv := some (w3.origin 1), pending := upd w3.pending 1 false }
    { w4 with obs := Obs.read w4.drv :: w4.obs }
  | n + 1 => { afterLoss n with obs := Obs.tick :: (afterLoss n).obs }

theorem afterLoss_reach (n : Nat) : Reach (afterLoss n) := by
  induction n with
  | zero =>
    have r1 := Reach.step Reach.init (Step.fwd init 0)
    have r2 := Reach.step r1 (Step.lose _ 0 (by decide))
    have r3 := Reach.step r2 (Step.fwd _ 1)
    have r4 := Reach.step r3 (Step.commit _ 1 (by decide))
    have r5 := Reach.step r4 (Step.readback _)
    exact r5
  | succ n ih => exact Reach.step ih (Step.tick _)

theorem afterLoss_lost (n : Nat) : (afterLoss n).lost 0 = true ∧ (afterLoss n).origin 0 = 0 ∧
    (afterLoss n).lastSrc = some 1 ∧ (afterLoss n).drv = some 1 := by
  induction n with
  | zero => decide
  | succ n ih => exact ih

/-- **No timeout helps.** Everything the gate can see says B: its last command is B's, and
    readback confirms the drive holds B's setpoint. Still, every safe policy refuses to
    energize, after any number of ticks. -/
theorem no_timeout_helps (π : List Obs → Bool) (hs : Safe π) (n : Nat) :
    π (afterLoss n).obs = false := by
  obtain ⟨hl, ho, hsrc, _⟩ := afterLoss_lost n
  exact lost_frame_blocks π hs (afterLoss_reach n) hl (by rw [ho, hsrc]; decide)

/-! ### Non-vacuity: `Safe` admits useful policies

A gate serving a single authority `g` can energize safely: energize only if every forwarded
command was `g`'s and the newest readback after the last forward shows `g`'s setpoint. So the
impossibility is specifically about authority **changes** with unresolved frames. -/

def onlyFrom (g : Nat) : List Obs → Bool
  | [] => true
  | Obs.fwd g' :: r => decide (g' = g) && onlyFrom g r
  | _ :: r => onlyFrom g r

def confirmed (g : Nat) : List Obs → Bool
  | [] => false
  | Obs.read v :: _ => decide (v = some g)
  | Obs.fwd _ :: _ => false
  | _ :: r => confirmed g r

def singleGrant (g : Nat) (obs : List Obs) : Bool := onlyFrom g obs && confirmed g obs

structure SInv (g : Nat) (w : W) : Prop where
  origins : onlyFrom g w.obs = true → ∀ j, j < w.next → w.origin j = g
  src     : onlyFrom g w.obs = true → w.lastSrc = none ∨ w.lastSrc = some g
  started : 0 < w.next → w.lastSrc ≠ none
  drvSrc  : w.drv ≠ none → w.lastSrc ≠ none
  conf    : confirmed g w.obs = true → onlyFrom g w.obs = true → w.drv = some g

theorem sinv_reach (g : Nat) {w : W} (h : Reach w) : SInv g w := by
  induction h with
  | init => exact ⟨by simp [init], by simp [init], by simp [init], by simp [init], by simp [init, confirmed]⟩
  | @step s t hs hst ih =>
    have hi := inv_reach hs
    cases hst with
    | fwd g' =>
      refine ⟨?_, ?_, by simp, by simp, by simp [confirmed]⟩
      · intro ho j hj
        simp [onlyFrom] at ho
        simp only [upd]
        by_cases hjn : j = s.next
        · simp [hjn, ho.1]
        · simp [hjn]; exact ih.origins ho.2 j (by have : j < s.next + 1 := hj; omega)
      · intro ho; simp [onlyFrom] at ho; simp [ho.1]
    | commit i hpi =>
      have hlt := hi.pendLt i hpi
      refine ⟨ih.origins, ih.src, ih.started, fun _ => ih.started (by omega), ?_⟩
      intro _ ho; simp [ih.origins ho i hlt]
    | lose i hpi => exact ⟨ih.origins, ih.src, ih.started, ih.drvSrc, ih.conf⟩
    | readback =>
      refine ⟨fun ho => ih.origins (by simpa [onlyFrom] using ho),
        fun ho => ih.src (by simpa [onlyFrom] using ho), ih.started, ih.drvSrc, ?_⟩
      intro hc _; simpa [confirmed] using hc
    | tick =>
      exact ⟨fun ho => ih.origins (by simpa [onlyFrom] using ho),
        fun ho => ih.src (by simpa [onlyFrom] using ho), ih.started, ih.drvSrc,
        fun hc ho => ih.conf (by simpa [confirmed] using hc) (by simpa [onlyFrom] using ho)⟩
    | input k =>
      exact ⟨fun ho => ih.origins (by simpa [onlyFrom] using ho),
        fun ho => ih.src (by simpa [onlyFrom] using ho), ih.started, ih.drvSrc,
        fun hc ho => ih.conf (by simpa [confirmed] using hc) (by simpa [onlyFrom] using ho)⟩

theorem singleGrant_safe (g : Nat) : Safe (singleGrant g) := by
  intro w hw hπ
  have hi := inv_reach hw
  have hs := sinv_reach g hw
  simp [singleGrant] at hπ
  obtain ⟨ho, hc⟩ := hπ
  have hd := hs.conf hc ho
  have hsrc : w.lastSrc = some g := by
    rcases hs.src ho with h0 | h1
    · exact absurd h0 (hs.drvSrc (by simp [hd]))
    · exact h1
  refine ⟨by rw [hd, hsrc], ?_⟩
  intro j hj
  rw [hsrc, hs.origins ho j (hi.pendLt j hj)]

/-- The single-grant policy actually energizes in some run. -/
theorem singleGrant_energizes : ∃ w, Reach w ∧ singleGrant 1 w.obs = true := by
  have r1 := Reach.step Reach.init (Step.fwd init 1)
  have r2 := Reach.step r1 (Step.commit _ 0 (by decide))
  have r3 := Reach.step r2 (Step.readback _)
  exact ⟨_, r3, by decide⟩

end Impossible

namespace Fence

inductive Fr
  | setp (addr epoch val : Nat)   -- setpoint frame addressed to node id `addr`
  | rot (addr new : Nat)          -- node-id rotation frame addressed to `addr`
deriving DecidableEq

structure Rules where
  rotDown  : Bool   -- a rotation frame is addressed only to an id older than the one it installs
  checkNid : Bool   -- readback confirms the drive's node id equals the current epoch

def strict : Rules := ⟨true, true⟩

structure St where
  cur     : Nat           -- gate's current epoch (= node id it addresses)
  nid     : Nat           -- drive's node id
  drvEp   : Option Nat    -- ghost: epoch of the frame that wrote the drive's setpoint
  drvVal  : Option Nat    -- drive's setpoint value (what readback returns)
  pend    : List Fr       -- downstream, unbounded latency
  lastSrc : Option Nat
  lastVal : Option Nat
  conf    : Bool

def init : St := ⟨0, 0, none, none, [], none, none, false⟩

def applyFr (s : St) : Fr → St
  | .setp a e v => if a = s.nid then { s with drvEp := some e, drvVal := some v } else s
  | .rot a n => if a = s.nid then { s with nid := n } else s

inductive Step (a : Rules) : St → St → Prop
  | cut (s : St) : Step a s { s with cur := s.cur + 1, conf := false }
  | fwdSet (s : St) (v : Nat) :
      Step a s { s with pend := Fr.setp s.cur s.cur v :: s.pend, lastSrc := some s.cur,
                        lastVal := some v, conf := false }
  | fwdRot (s : St) (k : Nat) (h : a.rotDown = true → k < s.cur) :
      Step a s { s with pend := Fr.rot k s.cur :: s.pend }
  | commit (s : St) (x : Fr) (hx : x ∈ s.pend) : Step a s { applyFr s x with pend := s.pend.erase x }
  | lose (s : St) (x : Fr) (hx : x ∈ s.pend) : Step a s { s with pend := s.pend.erase x }
  | readback (s : St) :
      Step a s { s with conf := ((if a.checkNid then decide (s.nid = s.cur) else true) &&
        decide (s.drvVal = s.lastVal) && decide (s.lastSrc = some s.cur)) }

inductive Reach (a : Rules) : St → Prop
  | init : Reach a init
  | step {s t : St} : Reach a s → Step a s t → Reach a t

/-- A pending frame that could still change the drive's setpoint or node id. -/
def Capable (s : St) : Fr → Prop
  | .setp a _ _ => a = s.nid
  | .rot a n => a = s.nid ∧ n ≠ s.nid

def FromCur (s : St) : Fr → Prop
  | .setp _ e _ => e = s.cur
  | .rot _ _ => False

structure Inv (s : St) : Prop where
  setpOk : ∀ a e v, Fr.setp a e v ∈ s.pend → a = e ∧ e ≤ s.cur
  rotOk  : ∀ a n, Fr.rot a n ∈ s.pend → a < n ∧ n ≤ s.cur
  nidLe  : s.nid ≤ s.cur
  confOk : s.conf = true → s.nid = s.cur ∧ s.lastSrc = some s.cur ∧
             (s.drvEp = some s.cur ∨ s.drvVal = s.lastVal)

theorem applyFr_setp_hit {s : St} {a e v : Nat} (h : a = s.nid) :
    applyFr s (Fr.setp a e v) = { s with drvEp := some e, drvVal := some v } := by
  simp [applyFr, h]

theorem applyFr_setp_miss {s : St} {a e v : Nat} (h : a ≠ s.nid) : applyFr s (Fr.setp a e v) = s := by
  simp [applyFr, h]

theorem applyFr_rot_hit {s : St} {a n : Nat} (h : a = s.nid) :
    applyFr s (Fr.rot a n) = { s with nid := n } := by
  simp [applyFr, h]

theorem applyFr_rot_miss {s : St} {a n : Nat} (h : a ≠ s.nid) : applyFr s (Fr.rot a n) = s := by
  simp [applyFr, h]

theorem inv_reach {s : St} (h : Reach strict s) : Inv s := by
  induction h with
  | init => exact ⟨by simp [init], by simp [init], by simp [init], by simp [init]⟩
  | @step s t _ hst ih =>
    cases hst with
    | cut =>
      refine ⟨?_, ?_, ?_, ?_⟩
      · intro a e v hm; have := ih.setpOk a e v hm; exact ⟨this.1, Nat.le_succ_of_le this.2⟩
      · intro a n hm; have := ih.rotOk a n hm; exact ⟨this.1, Nat.le_succ_of_le this.2⟩
      · exact Nat.le_succ_of_le ih.nidLe
      · intro hc; simp at hc
    | fwdSet v =>
      refine ⟨?_, ?_, ih.nidLe, ?_⟩
      · intro a e w hm
        simp at hm
        rcases hm with ⟨rfl, rfl, rfl⟩ | hm
        · exact ⟨rfl, Nat.le_refl _⟩
        · exact ih.setpOk a e w hm
      · intro a n hm; simp at hm; exact ih.rotOk a n hm
      · intro hc; simp at hc
    | fwdRot k hk =>
      refine ⟨?_, ?_, ih.nidLe, fun hc => ih.confOk hc⟩
      · intro a e v hm; simp at hm; exact ih.setpOk a e v hm
      · intro a n hm; simp at hm
        rcases hm with ⟨rfl, rfl⟩ | hm
        · exact ⟨hk rfl, Nat.le_refl _⟩
        · exact ih.rotOk a n hm
    | commit x hx =>
      have hsp : ∀ a e v, Fr.setp a e v ∈ s.pend.erase x → a = e ∧ e ≤ s.cur :=
        fun a e v hm => ih.setpOk a e v (List.mem_of_mem_erase hm)
      have hro : ∀ a n, Fr.rot a n ∈ s.pend.erase x → a < n ∧ n ≤ s.cur :=
        fun a n hm => ih.rotOk a n (List.mem_of_mem_erase hm)
      cases x with
      | setp a e v =>
        obtain ⟨hae, _⟩ := ih.setpOk a e v hx
        by_cases hn : a = s.nid
        · rw [applyFr_setp_hit hn]
          refine ⟨hsp, hro, ih.nidLe, ?_⟩
          intro hc
          obtain ⟨h1, h2, _⟩ := ih.confOk hc
          exact ⟨h1, h2, Or.inl (by simp; omega)⟩
        · rw [applyFr_setp_miss hn]
          exact ⟨hsp, hro, ih.nidLe, ih.confOk⟩
      | rot a n =>
        obtain ⟨han, hnc⟩ := ih.rotOk a n hx
        by_cases hn : a = s.nid
        · rw [applyFr_rot_hit hn]
          refine ⟨hsp, hro, hnc, ?_⟩
          intro hc
          obtain ⟨h1, _, _⟩ := ih.confOk hc
          omega
        · rw [applyFr_rot_miss hn]
          exact ⟨hsp, hro, ih.nidLe, ih.confOk⟩
    | lose x hx =>
      exact ⟨fun a e v hm => ih.setpOk a e v (List.mem_of_mem_erase hm),
        fun a n hm => ih.rotOk a n (List.mem_of_mem_erase hm), ih.nidLe, fun hc => ih.confOk hc⟩
    | readback =>
      refine ⟨fun a e v hm => ih.setpOk a e v hm, fun a n hm => ih.rotOk a n hm, ih.nidLe, ?_⟩
      intro hc
      simp [strict] at hc
      obtain ⟨⟨h1, h2⟩, h3⟩ := hc
      exact ⟨h1, h3, Or.inr h2⟩

/-- **Fence safety under unbounded latency.** Whenever the gate's readback is confirmed, every
    pending frame that could still commit is a setpoint from the current epoch, and the
    drive's setpoint is the current epoch's or value-equal to the gate's last command. -/
theorem safe {s : St} (h : Reach strict s) (hc : s.conf = true) :
    (∀ x ∈ s.pend, Capable s x → FromCur s x) ∧ (s.drvEp = some s.cur ∨ s.drvVal = s.lastVal) := by
  have hi := inv_reach h
  obtain ⟨hn, _, hd⟩ := hi.confOk hc
  refine ⟨?_, hd⟩
  intro x hx hcap
  cases x with
  | setp a e v =>
    have ⟨hae, _⟩ := hi.setpOk a e v hx
    simp [Capable] at hcap; simp [FromCur]; omega
  | rot a n =>
    have ⟨han, hnc⟩ := hi.rotOk a n hx
    simp [Capable] at hcap; omega

/-- Liveness despite a stuck frame: A's epoch-0 frame stays pending forever, yet after rotating
    the node id to epoch 1 and confirming B's setpoint, the gate energizes, and A's frame can
    never commit. -/
theorem live_despite_stuck_frame :
    ∃ s, Reach strict s ∧ s.conf = true ∧ Fr.setp 0 0 5 ∈ s.pend ∧ ¬ Capable s (Fr.setp 0 0 5) := by
  have r1 := Reach.step (Reach.init (a := strict)) (Step.fwdSet _ 5)
  have r2 := Reach.step r1 (Step.cut _)
  have r3 := Reach.step r2 (Step.fwdRot _ 0 (by intro _; decide))
  have r4 := Reach.step r3 (Step.commit _ (Fr.rot 0 1) (by decide))
  have r5 := Reach.step r4 (Step.fwdSet _ 7)
  have r6 := Reach.step r5 (Step.commit _ (Fr.setp 1 1 7) (by decide))
  have r7 := Reach.step r6 (Step.readback _)
  exact ⟨_, r7, by decide, by decide, by simp [Capable, init, applyFr]⟩

def Violation (a : Rules) : Prop :=
  ∃ s, Reach a s ∧ s.conf = true ∧ ∃ x ∈ s.pend, Capable s x ∧ ¬ FromCur s x

/-- A rotation frame addressed to a future id re-opens an old epoch after confirmation. -/
theorem stale_rotation_breaks : Violation { strict with rotDown := false } := by
  let a : Rules := { strict with rotDown := false }
  have r1 := Reach.step (Reach.init (a := a)) (Step.fwdRot _ 1 (by intro h; cases h))
  have r2 := Reach.step r1 (Step.fwdSet _ 5)
  have r3 := Reach.step r2 (Step.cut _)
  have r4 := Reach.step r3 (Step.fwdRot _ 0 (by intro h; cases h))
  have r5 := Reach.step r4 (Step.commit _ (Fr.rot 0 1) (by decide))
  have r6 := Reach.step r5 (Step.fwdSet _ 7)
  have r7 := Reach.step r6 (Step.commit _ (Fr.setp 1 1 7) (by decide))
  have r8 := Reach.step r7 (Step.readback _)
  have r9 := Reach.step r8 (Step.commit _ (Fr.rot 1 0) (by decide))
  exact ⟨_, r9, by decide, Fr.setp 0 0 5, by decide, by simp [Capable, init, applyFr], by simp [FromCur, init, applyFr]⟩

/-- Value-only readback: the rotation is lost and A's earlier frame carries the same value as
    B's command, so readback "confirms" B while A's frames can still commit. -/
theorem value_readback_only_breaks : Violation { strict with checkNid := false } := by
  let a : Rules := { strict with checkNid := false }
  have r1 := Reach.step (Reach.init (a := a)) (Step.fwdSet _ 7)
  have r2 := Reach.step r1 (Step.fwdSet _ 7)
  have r3 := Reach.step r2 (Step.commit _ (Fr.setp 0 0 7) (by decide))
  have r4 := Reach.step r3 (Step.cut _)
  have r5 := Reach.step r4 (Step.fwdRot _ 0 (by intro _; decide))
  have r6 := Reach.step r5 (Step.lose _ (Fr.rot 0 1) (by decide))
  have r7 := Reach.step r6 (Step.fwdSet _ 7)
  have r8 := Reach.step r7 (Step.readback _)
  exact ⟨_, r8, by decide, Fr.setp 0 0 7, by decide, by simp [Capable, init, applyFr], by simp [FromCur, init, applyFr]⟩

end Fence
