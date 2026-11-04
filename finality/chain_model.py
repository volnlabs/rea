#!/usr/bin/env python3
"""Composed actuation chain: guardian queue -> transport (Pi 5/RP1/CAN) -> ODrive v3 -> power stage -> gate.

Property P1 (timed actuation finality): more than D ticks after the cut of epoch 7,
the power stage is never on with a setpoint whose last writer was epoch 7.
Property P2 (recovery safety): a non-idempotent command is never executed twice.

Transitions encode verified facts only:
  RP1: outputs/frames persist across host loss; in-flight writes land after the cut;
       BAR1, /dev/pio and DMA bypass any host guardian    (rp1-fw/RP1_*.md)
  ODrive: setpoint persists; any frame feeds the watchdog; re-arm keeps the old input
                                                           (odrive/ODRIVE_COMMAND_LIFECYCLE.md)
  Gate: EN_GATE AND LEASE_OK; lease renewed only by the current epoch; re-grant only after
        a fresh setpoint; expiry latches off            (odrive/STM32_BREAK_GATE.md, design)
Run: python3 -I chain_model.py
"""
from collections import deque
from itertools import product

W, L = 3, 3              # drive watchdog and gate lease, in ticks
D = max(W, L) + 1        # candidate finality bound
FLAGS = ['gate', 'gate_filters', 'b_writes_first', 'watchdog', 'polls', 'a_bypass', 'bounded_transport']
# gate: power interlock (EN_GATE AND LEASE_OK). gate_filters: the gate is the only path
# to the drive's command bus and drops frames whose epoch is not current.


def step(s, cfg):
    cut, t, q, wire, val, src, armed, wd, lease, lt, bw = s

    def put(**kw):
        d = dict(cut=cut, t=t, q=q, wire=wire, val=val, src=src, armed=armed, wd=wd, lease=lease, lt=lt, bw=bw)
        d.update(kw)
        return tuple(d[k] for k in ('cut', 't', 'q', 'wire', 'val', 'src', 'armed', 'wd', 'lease', 'lt', 'bw'))

    if not cut:
        yield 'A: command accepted by guardian', put(q=7)
        yield 'A: arm', put(armed=True, wd=W)
        yield 'A: lease renew', put(lease=True, lt=L)
        yield 'cut (gate notified)', put(cut=True, t=0, lease=False, lt=0)
        yield 'cut (gate notification lost)', put(cut=True, t=0)
    if q is not None and wire is None:
        if cut:
            yield 'guardian drops stale entry', put(q=None)  # guardian checks epoch at dequeue
        else:
            yield 'guardian sends', put(q=None, wire=q)
    if cut and cfg['a_bypass'] and wire is None:
        yield 'A bypasses guardian (BAR1 / /dev/pio / bus)', put(wire=7)
    if wire is not None:
        if cfg['gate'] and cfg['gate_filters'] and cut and wire == 7:
            yield 'gate drops epoch-7 frame', put(wire=None)
        else:
            yield f'deliver epoch-{wire} frame', put(wire=None, val=1, src=wire, wd=W, bw=bw or wire == 8)
        yield 'frame lost', put(wire=None)
    if cfg['polls']:
        yield 'telemetry poll', put(wd=W)
    if cut and not cfg['b_writes_first']:
        yield 'B: re-arm (no new setpoint)', put(armed=True, wd=W)
    if cut and wire is None:
        yield 'B: send setpoint', put(wire=8)
    if cut and bw:
        # Re-grant rule: B delivered a fresh setpoint since the cut. The gate cannot see
        # who last wrote the drive's register, only that B has written one.
        yield 'B: arm after fresh setpoint', put(armed=True, wd=W)
        yield 'B: lease renew', put(lease=True, lt=L)
    if cfg['bounded_transport'] and wire is not None:
        return  # frames must be delivered or lost before time advances
    nxt = put(wd=max(wd - 1, 0), lt=max(lt - 1, 0), lease=lease and lt > 0)
    if cfg['watchdog'] and armed and wd == 0:
        nxt = put(armed=False, lt=max(lt - 1, 0), lease=lease and lt > 0)
    if cut:
        nxt = nxt[:1] + (min(t + 1, D + 1),) + nxt[2:]
    yield 'tick', nxt


def power_on(s, cfg):
    cut, t, q, wire, val, src, armed, wd, lease, lt, bw = s
    return armed and val == 1 and (lease or not cfg['gate'])


def b_can_actuate(cfg):
    """Liveness guard against vacuous results: after the cut, B must be able to drive the motor."""
    start = (False, 0, None, None, 0, None, False, W, False, 0, False)
    seen, todo = {start}, deque([start])
    while todo:
        s = todo.popleft()
        if s[0] and power_on(s, cfg) and s[5] == 8:
            return True
        for _, n in step(s, cfg):
            if n not in seen:
                seen.add(n)
                todo.append(n)
    return False


def check(cfg):
    start = (False, 0, None, None, 0, None, False, W, False, 0, False)
    seen, todo = {start: None}, deque([start])
    while todo:
        s = todo.popleft()
        if s[0] and s[1] > D and power_on(s, cfg) and s[5] == 7:
            trace = []
            while seen[s]:
                s, label = seen[s]
                trace.append(label)
            return trace[::-1]
        for label, n in step(s, cfg):
            if n not in seen:
                seen[n] = (s, label)
                todo.append(n)
    return None


def recovery(policy, executed_before_crash):
    """P2: guardian crashed after sending a non-idempotent command, before recording completion."""
    count = 1 if executed_before_crash else 0
    if policy == 'replay':
        count += 1
    outcome = 'uncertain' if policy == 'mark-uncertain' else 'replayed'
    return count, outcome


def compress(trace):
    out = []
    for a in trace:
        if out and out[-1][0] == a:
            out[-1][1] += 1
        else:
            out.append([a, 1])
    return ' -> '.join(f'{a} x{n}' if n > 1 else a for a, n in out)


WORST = dict(polls=True, a_bypass=True, bounded_transport=False, watchdog=False)
ARCH = {
    'P1 host guardian, stock ODrive, worst case':
        dict(gate=False, gate_filters=False, b_writes_first=True, **WORST),
    'P1 host guardian, best case (watchdog, quiet, no bypass, bounded, B disciplined)':
        dict(gate=False, gate_filters=False, b_writes_first=True, watchdog=True, polls=False, a_bypass=False, bounded_transport=True),
    'P3a power-only gate, worst case':
        dict(gate=True, gate_filters=False, b_writes_first=True, **WORST),
    'P3b power gate + command filter, worst case, B undisciplined':
        dict(gate=True, gate_filters=True, b_writes_first=False, **WORST),
}


def sufficient(cfg):
    host_only = cfg['watchdog'] and not cfg['polls'] and not cfg['a_bypass'] and cfg['bounded_transport'] and cfg['b_writes_first']
    # ponytail: the single-slot transport is FIFO, so a late pre-cut frame always lands before
    # B's first setpoint. A CAN bus with priority arbitration can reorder; then the
    # power-only gate also needs the command filter.
    power_gate = cfg['gate'] and not cfg['a_bypass']
    full_gate = cfg['gate'] and cfg['gate_filters']
    return host_only or power_gate or full_gate


if __name__ == '__main__':
    for name, cfg in ARCH.items():
        tr = check(cfg)
        print(f'{name}\n  {"P1 HOLDS within D=%d" % D if tr is None else "P1 VIOLATED: " + compress(tr)}')
    for combo in product([False, True], repeat=len(FLAGS)):
        cfg = dict(zip(FLAGS, combo))
        assert b_can_actuate(cfg), ('vacuous', cfg)
        assert (check(cfg) is None) == sufficient(cfg), cfg
    print('self-check ok over all %d configurations (none vacuous): P1 holds iff' % 2 ** len(FLAGS))
    print('  gate + command filter, OR power gate with no bypass path (FIFO transport),')
    print('  OR (no gate) watchdog + no polls + no bypass + bounded transport + B writes before arming')
    for policy, ex in product(['replay', 'mark-uncertain'], [False, True]):
        n, outcome = recovery(policy, ex)
        print(f'P2 recovery={policy:14s} executed_before_crash={ex!s:5s} -> executions={n} outcome={outcome}')
    assert recovery('replay', True)[0] == 2 and recovery('mark-uncertain', True)[0] == 1
