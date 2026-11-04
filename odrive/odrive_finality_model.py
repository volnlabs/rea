#!/usr/bin/env python3
"""Explicit-state model of ODrive v3 (fw 0.5.x, commit 3a2e4dd1) command lifecycle.

Property (timed actuation finality): once the authority cut happened more than
D control ticks ago, the motor must not be armed with a nonzero torque input
whose last writer is the retired controller A.

Only code facts verified in ODrive source are modeled:
  F1 any CAN frame to the node feeds the watchdog before dispatch  (can_simple.cpp:60)
  F2 watchdog is off by default; expiry sets an error and disarms (axis.hpp:86-87, axis.cpp:171-181, main.cpp:416-419)
  F3 Set_Input_Torque stores input_torque_ in any axis state       (can_simple.cpp:286-287)
  F4 arm/clear_errors do not clear input_torque_                    (controller.cpp:12-19, 115-127, main.cpp:236-246)
  F5 entering closed loop feeds the watchdog                         (axis.cpp:577)
  F6 passthrough applies input_torque_ every tick when armed         (controller.cpp:187-190)
  F7 CAN frames carry no sender identity or epoch                    (can_simple.cpp:45-55)
Run: python3 -I odrive_finality_model.py
"""
from collections import deque
from itertools import product

W = 3          # watchdog timeout in control ticks (1 tick = 125 us on v3)
D = W + 1      # candidate finality bound in ticks


def successors(s, cfg):
    cut, t, armed, err, wd, val, src = s
    feed = W  # F1/F5: any frame or closed-loop entry reloads the counter

    def put(**kw):
        d = dict(cut=cut, t=t, armed=armed, err=err, wd=wd, val=val, src=src)
        d.update(kw)
        return (d['cut'], d['t'], d['armed'], d['err'], d['wd'], d['val'], d['src'])

    if not cut or cfg['a_on_bus_after_cut']:            # F3/F7
        yield 'A sets torque', put(val=1, src='A', wd=feed)
    if not cut and not armed and not err:
        yield 'A arms axis', put(armed=True, wd=feed)
    if cfg['telemetry_polls']:                           # F1: a read request still feeds
        yield 'telemetry poll', put(wd=feed)
    if not cut:
        yield 'cut (fence frame lost)', put(cut=True, t=0)
        if cfg['fence_zero_on_cut']:
            yield 'cut + guardian sends torque 0', put(cut=True, t=0, val=0, src='G', wd=feed)
    if cut:
        yield 'B sets torque', put(val=1, src='B', wd=feed)
        if cfg['b_writes_before_arm']:
            yield 'B: clear, write 0, arm', put(err=0, armed=True, val=0, src='B', wd=feed)
        else:
            yield 'B: clear errors, arm', put(err=0, armed=True, wd=feed)   # F4/F5
    # control tick, F2/F6
    if cfg['watchdog'] and armed and wd == 0:
        nxt = put(armed=False, err=1)
    else:
        nxt = put(wd=max(wd - 1, 0) if cfg['watchdog'] else wd)
    if cut:
        nxt = nxt[:1] + (min(t + 1, D + 1),) + nxt[2:]
    yield 'tick', nxt


def violates(s):
    cut, t, armed, err, wd, val, src = s
    return cut and t > D and armed and val == 1 and src == 'A'


def check(cfg):
    start = (False, 0, False, 0, W, 0, '-')
    seen, q = {start: None}, deque([start])
    while q:
        s = q.popleft()
        if violates(s):
            trace = []
            while seen[s]:
                s, label = seen[s]
                trace.append(label)
            return list(reversed(trace))
        for label, n in successors(s, cfg):
            if n not in seen:
                seen[n] = (s, label)
                q.append(n)
    return None


def compress(trace):
    out = []
    for a in trace:
        if out and out[-1][0] == a:
            out[-1][1] += 1
        else:
            out.append([a, 1])
    return ' -> '.join(f'{a} x{n}' if n > 1 else a for a, n in out)


CASES = {
    'CX1 default config (watchdog off)':
        dict(watchdog=False, telemetry_polls=False, a_on_bus_after_cut=False, fence_zero_on_cut=False, b_writes_before_arm=True),
    'CX2 watchdog on, telemetry polling continues':
        dict(watchdog=True, telemetry_polls=True, a_on_bus_after_cut=False, fence_zero_on_cut=False, b_writes_before_arm=True),
    'CX3 watchdog on, quiet bus, B re-arms without writing':
        dict(watchdog=True, telemetry_polls=False, a_on_bus_after_cut=False, fence_zero_on_cut=False, b_writes_before_arm=False),
    'CX4 watchdog on, quiet bus, A keeps bus access':
        dict(watchdog=True, telemetry_polls=False, a_on_bus_after_cut=True, fence_zero_on_cut=False, b_writes_before_arm=True),
    'CX5 zero fence on cut but frame may be lost, polls on':
        dict(watchdog=True, telemetry_polls=True, a_on_bus_after_cut=False, fence_zero_on_cut=True, b_writes_before_arm=True),
    'OK  watchdog on, quiet bus, A off bus, B writes before arm':
        dict(watchdog=True, telemetry_polls=False, a_on_bus_after_cut=False, fence_zero_on_cut=False, b_writes_before_arm=True),
}

if __name__ == '__main__':
    results = {name: check(cfg) for name, cfg in CASES.items()}
    for name, trace in results.items():
        print(f'{name}\n  {"HOLDS within D=%d ticks" % D if trace is None else "VIOLATED: " + compress(trace)}')
    # Self-check: the verified semantics must produce exactly these outcomes.
    assert all(results[n] for n in CASES if n.startswith('CX')), 'expected counterexamples missing'
    assert results['OK  watchdog on, quiet bus, A off bus, B writes before arm'] is None
    # Exhaustive sweep: the property holds only when all four conditions hold.
    for combo in product([False, True], repeat=5):
        cfg = dict(zip(['watchdog', 'telemetry_polls', 'a_on_bus_after_cut', 'fence_zero_on_cut', 'b_writes_before_arm'], combo))
        holds = check(cfg) is None
        need = cfg['watchdog'] and not cfg['telemetry_polls'] and not cfg['a_on_bus_after_cut'] and cfg['b_writes_before_arm']
        assert holds == need, cfg
    print('self-check ok: property holds iff watchdog on, no traffic to node after cut, A off bus, B writes before arming')
