#!/usr/bin/env python3
"""Mutation check for the gate core: each broken variant of gate.h must fail the SIL test.

Works on a temporary copy (GATE_DIR), never on the real files. Exit 1 if any mutant survives.
Usage: python3 -I mutate.py
"""
import os, shutil, subprocess, sys, tempfile

here = os.path.dirname(os.path.abspath(__file__))
gate = os.path.join(here, "..", "gate")

MUTANTS = [
    ("readback always confirms",
     "g->holder >= 0 && strtof(tag_ascii, NULL) == (float)(g->node + 1);", "g->holder >= 0;"),
    ("node ids reused", "if (g->used & (1ull << id)) continue;", "if (id == g->node) continue;"),
    ("holder's lease never expires",
     "return g->holder >= 0 && gate_live(g->expiry, now) &&", "return g->holder >= 0 &&"),
    ("commands forwarded from any origin",
     "if (origin != g->holder || g->holder < 0) return false;", "if (g->holder < 0) return false;"),
    ("reset forgets used ids",
     "g->used |= reserved | (1ull << drive_node);", "g->used = reserved | (1ull << drive_node);"),
    ("reset leaves the challenge open", "    g->chal_open = false;\n    g->bad = 0;", "    g->bad = 0;"),
    ("token for any challenge", "chal != g->chal || ", ""),
    ("token with no freshness window", " || now - g->chal_at >= W", ""),
    ("token tag not checked", "if (!gate_eq(mac, want, 8)) return GATE_REJECT;", ""),
    ("token redeemable twice", "    g->chal_open = false;\n    if (!gate_grant", "    if (!gate_grant"),
    ("command tag not checked", "if (!gate_eq(d + 4, want, 4)) continue;", ""),
    ("command sequence not advanced", "g->seq += k + 1;", ""),
    ("no failed-tag budget", "if (++g->bad >= GATE_MAX_BAD) gate_drop(g);", ""),
    ("old lease alone keeps energy on",
     "return g->holder >= 0 && gate_live(g->expiry, now) &&\n           (g->confirmed ||",
     "return g->holder >= 0 &&\n           ((g->confirmed && gate_live(g->expiry, now)) ||"),
    ("overlap from an unconfirmed holder", "g->holder >= 0 && g->confirmed && gate_live(g->expiry, now) ?",
     "g->holder >= 0 && gate_live(g->expiry, now) ?"),
    ("overlap from an expired holder", "g->confirmed && gate_live(g->expiry, now) ? g->holder", "g->confirmed ? g->holder"),
    ("previous lease never expires", "(g->prev >= 0 && gate_live(g->prev_expiry, now))", "(g->prev >= 0)"),
    ("confirmation does not end the overlap", "if (g->confirmed) g->prev = -1;", ""),
]

src = open(os.path.join(gate, "gate.h")).read()
survivors = 0
for name, old, new in MUTANTS:
    assert src.count(old) == 1, f"mutant '{name}': pattern must occur exactly once"
    with tempfile.TemporaryDirectory() as d:
        shutil.copytree(gate, d, dirs_exist_ok=True)
        open(os.path.join(d, "gate.h"), "w").write(src.replace(old, new))
        try:
            r = subprocess.run([os.path.join(here, "run.sh")], env={**os.environ, "GATE_DIR": d, "GATE_CFLAGS": "-Wno-error"},
                               capture_output=True, text=True, timeout=120)
            fails = [l[6:].split()[0] for l in r.stdout.splitlines() if l.startswith("FAIL  ")]
            killed = r.returncode != 0
            how = " ".join(fails) if fails else "build or runtime error"
        except subprocess.TimeoutExpired:
            killed, how = True, "timeout"
    print(f"{'killed  ' if killed else 'SURVIVED'}  {name}" + (f"  [{how}]" if killed else ""))
    survivors += not killed
print(f"{len(MUTANTS) - survivors}/{len(MUTANTS)} mutants killed")
sys.exit(1 if survivors else 0)
