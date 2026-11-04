/-!
# Fenced timed finality: unbounded downstream delay, finite node ids (Lean 4, core only)

Composes the timed authority/lease/output model (`FinalityProduct`, `GateRefinement`) with the
finite-id node-id fence (`FiniteFence`). `GateRefinement`'s downstream bound `Dd` is gone: time
always advances, and forwarded frames may be lost, reordered, or stuck downstream forever.

Gate protocol:
* the gate serves one grant at a time, in a **session**. Switching grants starts a new session
  with a **fresh** node id (unused since the last flush), or an exhausted session with none;
* the gate forwards only the session holder's commands, only while its lease is live,
  addressed to the session id;
* **rotation** is a direct UART write of the drive's node id to the session id;
* **readback** must confirm the drive's node id is the session id and the committed setpoint was
  issued in the current session (**session-tagged readback**, an implementation obligation,
  e.g. a session number encoded in the setpoint's low mantissa bits);
* LEASE_OK = confirmed ∧ the holder's lease is live;
* **flush** (verified): gate TX abort + drive reset; clears downstream and frees used ids.

Authority side: as in `FinalityProduct`. Tokens are issued only for valid grants, bound to a
challenge and redeemable within `W`; revocation of `r` at `t_c`; the gate may never learn of it.

Theorem `finality`: from `t_c + W + T + δ` on, an energized output has energy support ≠ r,
committed-setpoint provenance ≠ r, and **no pending r-command that can still commit**. Stale
r-frames addressed to retired ids may stay downstream forever; they are harmless.
`reauthorized_with_stuck_frame` shows the theorem is not vacuous.

Check with: `lean FencedFinality.lean`.
-/

namespace Fenced

structure DFrame where
  addr   : Nat   -- node id it is addressed to
  sess   : Nat   -- session it was forwarded in (encoded in the setpoint value)
  origin : Nat   -- ghost: grant that issued it
deriving DecidableEq

structure Token where
  grant : Nat
  nonce : Nat
deriving DecidableEq

structure Params where
  T : Nat
  W : Nat
  δ : Nat
  r : Nat
  K : Nat   -- number of node ids

structure St where
  now     : Nat
  valid   : Nat → Bool
  cutAt   : Option Nat
  issued  : List Token
  chal    : Nat
  chalAt  : Nat
  timer   : Nat → Nat
  queue   : List Nat          -- upstream commands, by issuing grant (adversarial)
  cur     : Nat               -- session number
  holder  : Option Nat        -- grant served in this session
  gid     : Option Nat        -- node id of this session (none = exhausted)
  dirty   : List Nat          -- ids used since the last flush
  nid     : Nat               -- drive's node id
  pend    : List DFrame       -- downstream: unbounded latency, loss, reordering
  drvSrc  : Option Nat        -- ghost: grant that wrote the drive's setpoint
  drvSess : Option Nat        -- session tag of the drive's setpoint (readable)
  conf    : Bool
  armed   : Bool
  out     : Bool
  offFor  : Nat
  supp    : Option Nat

def init : St :=
  { now := 0, valid := fun _ => true, cutAt := none, issued := [], chal := 0, chalAt := 0,
    timer := fun _ => 0, queue := [], cur := 0, holder := none, gid := none, dirty := [], nid := 0,
    pend := [], drvSrc := none, drvSess := none, conf := false, armed := false, out := false,
    offFor := 0, supp := none }

def used (s : St) : List Nat := match s.gid with
  | some g => g :: s.dirty
  | none => s.dirty

def okAfterTick (s : St) : Bool :=
  s.conf && (match s.holder with
             | some g => decide (s.timer g - 1 > 0)
             | none => false)

def tickState (s : St) (o : Bool) : St :=
  { s with now := s.now + 1, timer := fun x => s.timer x - 1,
           offFor := if okAfterTick s then 0 else s.offFor + 1,
           supp := if okAfterTick s then s.holder else s.supp, out := o }

def commitState (s : St) (x : DFrame) : St :=
  if x.addr = s.nid then { s with drvSrc := some x.origin, drvSess := some x.sess, pend := s.pend.erase x }
  else { s with pend := s.pend.erase x }

inductive Step (p : Params) : St → St → Prop
  | reshape (s : St) (q : List Nat) : Step p s { s with queue := q }
  | switch (s : St) (g i : Nat) (hi : i < p.K) (hf : i ∉ used s) :
      Step p s { s with cur := s.cur + 1, holder := some g, gid := some i, dirty := used s, conf := false }
  | switchExhausted (s : St) (g : Nat) :
      Step p s { s with cur := s.cur + 1, holder := some g, gid := none, dirty := used s, conf := false }
  | forward (s : St) (g i : Nat) (hm : g ∈ s.queue) (hh : s.holder = some g) (hl : s.timer g > 0)
      (hg : s.gid = some i) :
      Step p s { s with pend := ⟨i, s.cur, g⟩ :: s.pend }
  | rotate (s : St) (i : Nat) (hg : s.gid = some i) : Step p s { s with nid := i }
  | commit (s : St) (x : DFrame) (hx : x ∈ s.pend) : Step p s (commitState s x)
  | lose (s : St) (x : DFrame) (hx : x ∈ s.pend) : Step p s { s with pend := s.pend.erase x }
  | readback (s : St) :
      Step p s { s with conf := (decide (s.gid = some s.nid) && decide (s.drvSess = some s.cur) &&
                                  decide (s.holder ≠ none)) }
  | flush (s : St) : Step p s { s with pend := [], dirty := [] }
  | issue (s : St) (g : Nat) (hv : s.valid g = true) :
      Step p s { s with issued := ⟨g, s.chal⟩ :: s.issued }
  | redeem (s : St) (tok : Token) (hm : tok ∈ s.issued) (hn : tok.nonce = s.chal)
      (hw : s.now ≤ s.chalAt + p.W) :
      Step p s { s with timer := fun x => if x = tok.grant then p.T else s.timer x,
                        chal := s.chal + 1, chalAt := s.now }
  | rechallenge (s : St) : Step p s { s with chal := s.chal + 1, chalAt := s.now }
  | cut (s : St) (h : s.cutAt = none) :
      Step p s { s with valid := fun x => if x = p.r then false else s.valid x, cutAt := some s.now }
  | notify (s : St) : Step p s { s with timer := fun x => if x = p.r then 0 else s.timer x }
  | arm (s : St) (b : Bool) : Step p s { s with armed := b }
  | tick (s : St) (o : Bool)
      (ho : o = true → (okAfterTick s = true ∧ s.armed = true) ∨
                       (s.out = true ∧ (if okAfterTick s then 0 else s.offFor + 1) < p.δ)) :
      Step p s (tickState s o)

inductive Reach (p : Params) : St → Prop
  | init : Reach p init
  | step {s t : St} : Reach p s → Step p s t → Reach p t

/-- Shorthand for the finality bound relative to the cut. -/
def B (p : Params) (c : Nat) (s : St) : Prop := s.now ≤ c + p.W + p.T + s.offFor

structure Inv (p : Params) (s : St) : Prop where
  nonce    : ∀ tok ∈ s.issued, tok.nonce ≤ s.chal
  chalAt   : s.chalAt ≤ s.now
  tmax     : ∀ g, s.timer g ≤ p.T
  cutNow   : ∀ c, s.cutAt = some c → c ≤ s.now
  revoked  : ∀ c, s.cutAt = some c → s.valid p.r = false
  oldTok   : ∀ c, s.cutAt = some c → ∀ tok ∈ s.issued, tok.grant = p.r → tok.nonce = s.chal → s.chalAt ≤ c
  lease    : ∀ c, s.cutAt = some c → s.timer p.r = 0 ∨ s.timer p.r + s.now ≤ c + p.W + p.T
  outOff   : s.out = true → s.offFor < p.δ
  addrUsed : ∀ x ∈ s.pend, x.addr ∈ used s
  sessGid  : ∀ x ∈ s.pend, some x.addr = s.gid → x.sess = s.cur
  sessLe   : ∀ x ∈ s.pend, x.sess ≤ s.cur
  sessCur  : ∀ x ∈ s.pend, x.sess = s.cur → some x.origin = s.holder
  drvLe    : ∀ k, s.drvSess = some k → k ≤ s.cur
  drvCur   : s.drvSess = some s.cur → s.drvSrc = s.holder
  confOk   : s.conf = true → s.gid = some s.nid ∧ s.drvSess = some s.cur ∧ s.holder ≠ none
  supp     : ∀ c, s.cutAt = some c → s.supp = some p.r → B p c s
  pendR    : ∀ c, s.cutAt = some c → ∀ x ∈ s.pend, x.origin = p.r →
               (x.addr = s.nid ∨ some x.addr = s.gid) → B p c s
  drvR     : ∀ c, s.cutAt = some c → s.drvSrc = some p.r → B p c s

theorem inv_init (p : Params) : Inv p init := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> simp [init]

theorem live_bound {p : Params} {s : St} (hi : Inv p s) {c : Nat} (hc : s.cutAt = some c)
    (h : s.timer p.r > 0) : s.timer p.r + s.now ≤ c + p.W + p.T := by
  rcases hi.lease c hc with h0 | h1
  · omega
  · exact h1

/-- When the gate is confirmed, everything addressed to the drive's id belongs to the holder. -/
theorem conf_capable {p : Params} {s : St} (hi : Inv p s) (hc : s.conf = true) {x : DFrame}
    (hx : x ∈ s.pend) (ha : x.addr = s.nid ∨ some x.addr = s.gid) : some x.origin = s.holder := by
  obtain ⟨hg, _, _⟩ := hi.confOk hc
  have : some x.addr = s.gid := by
    rcases ha with h | h
    · rw [h, hg]
    · exact h
  exact hi.sessCur x hx (hi.sessGid x hx this)

theorem inv_step {p : Params} (hδ : 1 ≤ p.δ) {s t : St} (hi : Inv p s) (h : Step p s t) : Inv p t := by
  cases h with
  | reshape q => exact ⟨hi.nonce, hi.chalAt, hi.tmax, hi.cutNow, hi.revoked, hi.oldTok, hi.lease,
      hi.outOff, hi.addrUsed, hi.sessGid, hi.sessLe, hi.sessCur, hi.drvLe, hi.drvCur, hi.confOk,
      hi.supp, hi.pendR, hi.drvR⟩
  | switch g i hiK hf =>
    refine ⟨hi.nonce, hi.chalAt, hi.tmax, hi.cutNow, hi.revoked, hi.oldTok, hi.lease, hi.outOff,
      ?_, ?_, ?_, ?_, ?_, ?_, by simp, hi.supp, ?_, hi.drvR⟩
    · intro x hx; simp [used]; right; exact hi.addrUsed x hx
    · intro x hx hxa; simp at hxa; subst hxa; exact absurd (hi.addrUsed x hx) hf
    · intro x hx; have := hi.sessLe x hx; simp; omega
    · intro x hx hs; have := hi.sessLe x hx; simp at hs; omega
    · intro k hk; have := hi.drvLe k hk; simp; omega
    · intro hk; have := hi.drvLe _ hk; simp at this; omega
    · intro c hc x hx hxr ha
      simp at ha
      rcases ha with ha | ha
      · exact hi.pendR c hc x hx hxr (Or.inl ha)
      · subst ha; exact absurd (hi.addrUsed x hx) hf
  | switchExhausted g =>
    refine ⟨hi.nonce, hi.chalAt, hi.tmax, hi.cutNow, hi.revoked, hi.oldTok, hi.lease, hi.outOff,
      ?_, ?_, ?_, ?_, ?_, ?_, by simp, hi.supp, ?_, hi.drvR⟩
    · intro x hx; simp [used]; exact hi.addrUsed x hx
    · intro x _ hxa; simp at hxa
    · intro x hx; have := hi.sessLe x hx; simp; omega
    · intro x hx hs; have := hi.sessLe x hx; simp at hs; omega
    · intro k hk; have := hi.drvLe k hk; simp; omega
    · intro hk; have := hi.drvLe _ hk; simp at this; omega
    · intro c hc x hx hxr ha
      simp at ha
      exact hi.pendR c hc x hx hxr (Or.inl ha)
  | forward g i hm hh hl hg =>
    refine ⟨hi.nonce, hi.chalAt, hi.tmax, hi.cutNow, hi.revoked, hi.oldTok, hi.lease, hi.outOff,
      ?_, ?_, ?_, ?_, hi.drvLe, hi.drvCur, hi.confOk, hi.supp, ?_, hi.drvR⟩
    · intro x hx; simp at hx
      rcases hx with rfl | hx
      · simp [used, hg]
      · exact hi.addrUsed x hx
    · intro x hx hxa; simp at hx
      rcases hx with rfl | hx
      · rfl
      · exact hi.sessGid x hx hxa
    · intro x hx; simp at hx
      rcases hx with rfl | hx
      · exact Nat.le_refl _
      · exact hi.sessLe x hx
    · intro x hx hs; simp at hx
      rcases hx with rfl | hx
      · exact hh.symm
      · exact hi.sessCur x hx hs
    · intro c hc x hx hxr ha
      simp at hx
      rcases hx with rfl | hx
      · have := live_bound hi hc (by rw [← hxr]; exact hl); simp [B]; omega
      · exact hi.pendR c hc x hx hxr ha
  | rotate i hg =>
    refine ⟨hi.nonce, hi.chalAt, hi.tmax, hi.cutNow, hi.revoked, hi.oldTok, hi.lease, hi.outOff,
      hi.addrUsed, hi.sessGid, hi.sessLe, hi.sessCur, hi.drvLe, hi.drvCur, ?_, hi.supp, ?_, hi.drvR⟩
    · intro hc
      obtain ⟨h1, h2, h3⟩ := hi.confOk hc
      rw [hg] at h1
      have : i = s.nid := by simpa using h1
      exact ⟨by simp [hg, this], h2, h3⟩
    · intro c hc x hx hxr ha
      simp at ha
      rcases ha with ha | ha
      · exact hi.pendR c hc x hx hxr (Or.inr (by rw [ha, hg]))
      · exact hi.pendR c hc x hx hxr (Or.inr ha)
  | commit x hx =>
    have er : ∀ y ∈ s.pend.erase x, y ∈ s.pend := fun y hy => List.mem_of_mem_erase hy
    unfold commitState
    by_cases hn : x.addr = s.nid
    · simp only [hn, ite_true]
      refine ⟨hi.nonce, hi.chalAt, hi.tmax, hi.cutNow, hi.revoked, hi.oldTok, hi.lease, hi.outOff,
        fun y hy => hi.addrUsed y (er y hy), fun y hy h => hi.sessGid y (er y hy) h,
        fun y hy => hi.sessLe y (er y hy), fun y hy h => hi.sessCur y (er y hy) h, ?_, ?_, ?_,
        hi.supp, fun c hc y hy => hi.pendR c hc y (er y hy), ?_⟩
      · intro k hk; simp at hk; subst hk; exact hi.sessLe x hx
      · intro hk; simp at hk; exact hi.sessCur x hx hk
      · intro hc
        obtain ⟨h1, _, h3⟩ := hi.confOk hc
        have hs : x.sess = s.cur := hi.sessGid x hx (by rw [hn, h1])
        exact ⟨h1, by simp [hs], h3⟩
      · intro c hc hd
        have hxr : x.origin = p.r := by simpa using hd
        exact hi.pendR c hc x hx hxr (Or.inl hn)
    · simp only [hn, ite_false]
      exact ⟨hi.nonce, hi.chalAt, hi.tmax, hi.cutNow, hi.revoked, hi.oldTok, hi.lease, hi.outOff,
        fun y hy => hi.addrUsed y (er y hy), fun y hy h => hi.sessGid y (er y hy) h,
        fun y hy => hi.sessLe y (er y hy), fun y hy h => hi.sessCur y (er y hy) h, hi.drvLe,
        hi.drvCur, fun hc => hi.confOk hc, hi.supp, fun c hc y hy => hi.pendR c hc y (er y hy),
        hi.drvR⟩
  | lose x hx =>
    have er : ∀ y ∈ s.pend.erase x, y ∈ s.pend := fun y hy => List.mem_of_mem_erase hy
    exact ⟨hi.nonce, hi.chalAt, hi.tmax, hi.cutNow, hi.revoked, hi.oldTok, hi.lease, hi.outOff,
      fun y hy => hi.addrUsed y (er y hy), fun y hy h => hi.sessGid y (er y hy) h,
      fun y hy => hi.sessLe y (er y hy), fun y hy h => hi.sessCur y (er y hy) h, hi.drvLe,
      hi.drvCur, fun hc => hi.confOk hc, hi.supp, fun c hc y hy => hi.pendR c hc y (er y hy),
      hi.drvR⟩
  | readback =>
    refine ⟨hi.nonce, hi.chalAt, hi.tmax, hi.cutNow, hi.revoked, hi.oldTok, hi.lease, hi.outOff,
      hi.addrUsed, hi.sessGid, hi.sessLe, hi.sessCur, hi.drvLe, hi.drvCur, ?_, hi.supp, hi.pendR,
      hi.drvR⟩
    intro hc
    simp at hc
    obtain ⟨⟨h1, h2⟩, h3⟩ := hc
    exact ⟨h1, h2, by simpa using h3⟩
  | flush =>
    refine ⟨hi.nonce, hi.chalAt, hi.tmax, hi.cutNow, hi.revoked, hi.oldTok, hi.lease, hi.outOff,
      ?_, ?_, ?_, ?_, hi.drvLe, hi.drvCur, fun hc => hi.confOk hc, hi.supp, ?_, hi.drvR⟩ <;> simp
  | issue g hv =>
    refine ⟨?_, hi.chalAt, hi.tmax, hi.cutNow, hi.revoked, ?_, hi.lease, hi.outOff, hi.addrUsed,
      hi.sessGid, hi.sessLe, hi.sessCur, hi.drvLe, hi.drvCur, hi.confOk, hi.supp, hi.pendR, hi.drvR⟩
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
    refine ⟨?_, by simp, ?_, hi.cutNow, hi.revoked, ?_, ?_, hi.outOff, hi.addrUsed, hi.sessGid,
      hi.sessLe, hi.sessCur, hi.drvLe, hi.drvCur, hi.confOk, hi.supp, hi.pendR, hi.drvR⟩
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
    refine ⟨?_, by simp, hi.tmax, hi.cutNow, hi.revoked, ?_, hi.lease, hi.outOff, hi.addrUsed,
      hi.sessGid, hi.sessLe, hi.sessCur, hi.drvLe, hi.drvCur, hi.confOk, hi.supp, hi.pendR, hi.drvR⟩
    · intro tk htk; have := hi.nonce tk htk; simp; omega
    · intro c hc tk htk hg hn'
      have := hi.nonce tk htk; simp at hn'; omega
  | cut hcut =>
    refine ⟨hi.nonce, hi.chalAt, hi.tmax, ?_, ?_, ?_, ?_, hi.outOff, hi.addrUsed, hi.sessGid,
      hi.sessLe, hi.sessCur, hi.drvLe, hi.drvCur, hi.confOk, ?_, ?_, ?_⟩
    · intro c hc; simp at hc ⊢; omega
    · intro c _; simp
    · intro c hc tk _ _ _; simp at hc ⊢; have := hi.chalAt; omega
    · intro c hc; simp at hc ⊢; right; have := hi.tmax p.r; omega
    · intro c hc _; simp [B] at hc ⊢; omega
    · intro c hc _ _ _ _; simp [B] at hc ⊢; omega
    · intro c hc _; simp [B] at hc ⊢; omega
  | notify =>
    refine ⟨hi.nonce, hi.chalAt, ?_, hi.cutNow, hi.revoked, hi.oldTok, ?_, hi.outOff, hi.addrUsed,
      hi.sessGid, hi.sessLe, hi.sessCur, hi.drvLe, hi.drvCur, hi.confOk, hi.supp, hi.pendR, hi.drvR⟩
    · intro g; by_cases hg : g = p.r <;> simp [hg, hi.tmax g]
    · intro c _; left; simp
  | arm b => exact ⟨hi.nonce, hi.chalAt, hi.tmax, hi.cutNow, hi.revoked, hi.oldTok, hi.lease,
      hi.outOff, hi.addrUsed, hi.sessGid, hi.sessLe, hi.sessCur, hi.drvLe, hi.drvCur, hi.confOk,
      hi.supp, hi.pendR, hi.drvR⟩
  | tick o ho =>
    -- When LEASE_OK is observed at this tick, a retired holder's lease is still live.
    have okBound : ∀ c, s.cutAt = some c → okAfterTick s = true → s.holder = some p.r →
        s.now + 1 ≤ c + p.W + p.T := by
      intro c hc hok hh
      simp [okAfterTick, hh] at hok
      have := live_bound hi hc (by omega)
      omega
    have okConf : okAfterTick s = true → s.conf = true := by
      intro hok; simp [okAfterTick] at hok; exact hok.1
    refine ⟨hi.nonce, by simp [tickState]; have := hi.chalAt; omega, ?_, ?_, hi.revoked, hi.oldTok,
      ?_, ?_, hi.addrUsed, hi.sessGid, hi.sessLe, hi.sessCur, hi.drvLe, hi.drvCur, hi.confOk,
      ?_, ?_, ?_⟩
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
    · intro c hc hs
      simp [tickState] at hc
      by_cases hok : okAfterTick s = true
      · simp [tickState, hok, B] at hs ⊢
        have := okBound c hc hok hs
        omega
      · simp [tickState, hok, B] at hs ⊢
        have := hi.supp c hc hs
        simp [B] at this
        omega
    · intro c hc x hx hxr ha
      simp [tickState] at hc ha hx
      by_cases hok : okAfterTick s = true
      · have hh := conf_capable hi (okConf hok) hx ha
        rw [hxr] at hh
        simp [tickState, hok, B]
        have := okBound c hc hok hh.symm
        omega
      · simp [tickState, hok, B]
        have := hi.pendR c hc x hx hxr ha
        simp [B] at this
        omega
    · intro c hc hd
      simp [tickState] at hc hd
      by_cases hok : okAfterTick s = true
      · obtain ⟨_, hds, _⟩ := hi.confOk (okConf hok)
        have hsrc := hi.drvCur hds
        rw [hd] at hsrc
        simp [tickState, hok, B]
        have := okBound c hc hok hsrc.symm
        omega
      · simp [tickState, hok, B]
        have := hi.drvR c hc hd
        simp [B] at this
        omega

theorem inv_reach {p : Params} (hδ : 1 ≤ p.δ) {s : St} (h : Reach p s) : Inv p s := by
  induction h with
  | init => exact inv_init p
  | step _ hst ih => exact inv_step hδ ih hst

/-- **Fenced timed finality.** With unbounded downstream delay (frames lost, reordered or stuck
    forever), `K` node ids, arbitrary upstream interference, and a gate that may never learn
    of the revocation: from `t_c + W + T + δ` on, an energized output depends on the retired
    grant neither for energy, nor for its committed setpoint, nor through any pending command
    that can still commit. -/
theorem finality {p : Params} (hδ : 1 ≤ p.δ) {s : St} (h : Reach p s) {c : Nat}
    (hc : s.cutAt = some c) (hdl : c + p.W + p.T + p.δ ≤ s.now) (hout : s.out = true) :
    s.supp ≠ some p.r ∧ s.drvSrc ≠ some p.r ∧
      ∀ x ∈ s.pend, x.origin = p.r → x.addr ≠ s.nid := by
  have hi := inv_reach hδ h
  have hoff := hi.outOff hout
  refine ⟨?_, ?_, ?_⟩
  · intro hs; have := hi.supp c hc hs; simp [B] at this; omega
  · intro hd; have := hi.drvR c hc hd; simp [B] at this; omega
  · intro x hx hxr ha; have := hi.pendR c hc x hx hxr (Or.inl ha); simp [B] at this; omega

/-- Non-vacuity: T = 2, W = 0, δ = 1, K = 2, retired grant 0 (cut at time 0, deadline 3).
    Grant 0's frame stays stuck downstream forever, yet grant 1 holds the output energized at
    and after the deadline. -/
def P : Params := ⟨2, 0, 1, 0, 2⟩

theorem reauthorized_with_stuck_frame :
    ∃ s, Reach P s ∧ s.cutAt = some 0 ∧ 3 ≤ s.now ∧ s.out = true ∧ s.supp = some 1 ∧
      (⟨0, 1, 0⟩ : DFrame) ∈ s.pend := by
  have r1 := Reach.step (Reach.init (p := P)) (Step.issue _ 0 rfl)
  have r2 := Reach.step r1 (Step.redeem _ ⟨0, 0⟩ (by decide) rfl (by decide))
  have r3 := Reach.step r2 (Step.switch _ 0 0 (by decide) (by decide))
  have r4 := Reach.step r3 (Step.reshape _ [0, 1])
  have r5 := Reach.step r4 (Step.forward _ 0 0 (by decide) rfl (by decide) rfl)
  have r6 := Reach.step r5 (Step.cut _ rfl)
  have r7 := Reach.step r6 (Step.issue _ 1 rfl)
  have r8 := Reach.step r7 (Step.redeem _ ⟨1, 1⟩ (by decide) rfl (by decide))
  have r9 := Reach.step r8 (Step.switch _ 1 1 (by decide) (by decide))
  have r10 := Reach.step r9 (Step.rotate _ 1 rfl)
  have r11 := Reach.step r10 (Step.forward _ 1 1 (by decide) rfl (by decide) rfl)
  have r12 := Reach.step r11 (Step.commit _ ⟨1, 2, 1⟩ (by decide))
  have r13 := Reach.step r12 (Step.readback _)
  have r14 := Reach.step r13 (Step.arm _ true)
  have r15 := Reach.step r14 (Step.tick _ true (by intro _; left; decide))
  have r16 := Reach.step r15 (Step.rechallenge _)
  have r17 := Reach.step r16 (Step.issue _ 1 rfl)
  have r18 := Reach.step r17 (Step.redeem _ ⟨1, 3⟩ (by decide) rfl (by decide))
  have r19 := Reach.step r18 (Step.tick _ true (by intro _; left; decide))
  have r20 := Reach.step r19 (Step.rechallenge _)
  have r21 := Reach.step r20 (Step.issue _ 1 rfl)
  have r22 := Reach.step r21 (Step.redeem _ ⟨1, 5⟩ (by decide) rfl (by decide))
  have r23 := Reach.step r22 (Step.tick _ true (by intro _; left; decide))
  exact ⟨_, r23, rfl, by decide, rfl, rfl, by decide⟩

end Fenced
