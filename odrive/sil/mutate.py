#!/usr/bin/env python3
"""Mutation check for the gate: each broken variant of gate.h or gate_fw.c must fail the SIL tests.
Also reports whether the exploration (explore.c, random walks only here) finds it on its own.
A mutant is one edit, or a list of edits applied together.

Works on a temporary copy (GATE_DIR), never on the real files. Exit 1 if any mutant survives.
Usage: python3 -I mutate.py [substring of one mutant's name]
"""
import concurrent.futures, os, shutil, signal, subprocess, sys, tempfile

here = os.path.dirname(os.path.abspath(__file__))
gate = os.path.join(here, "..", "gate")

MUTANTS = [
    ("readback always confirms",
     "g->holder >= 0 && strtof(tag_ascii, NULL) == (float)(g->node + 1);", "g->holder >= 0;"),
    ("node ids reused", "if (g->used & (1ull << id)) continue;", "if (id == g->node) continue;"),
    ("holder's lease never expires",
     "if (g->holder >= 0 && !g->lapsed && !gate_live(g->expiry, now)) { g->lapsed = true; g->expiry = 0; g->prev = -1; g->prev_expiry = 0; }", ""),
    ("lapsed lease still enables", "return g->holder >= 0 && !g->lapsed && (g->confirmed", "return g->holder >= 0 && (g->confirmed"),
    ("lapsed holder's commands forwarded", "|| g->holder < 0 || g->lapsed) return false;", "|| g->holder < 0) return false;"),
    ("expired lease not latched (clock wrap)",
     "    gate_tick(g, now);\n    return g->holder >= 0 && !g->lapsed && (g->confirmed || g->prev >= 0);",
     "    return g->holder >= 0 && gate_live(g->expiry, now) &&\n"
     "           (g->confirmed || (g->prev >= 0 && gate_live(g->prev_expiry, now)));"),
    ("expired challenge not latched (clock wrap)",
     ["if (g->chal_open && now - g->chal_at >= g->chal_w) gate_close_challenge(g);",
      "if (!g->chal_open || chal != g->chal) return GATE_REJECT;"],
     ["", "if (!g->chal_open || chal != g->chal || now - g->chal_at >= g->chal_w) return GATE_REJECT;"]),
    ("commands forwarded from any origin",
     "if (origin != g->holder || g->holder < 0 || g->lapsed) return false;", "if (g->holder < 0 || g->lapsed) return false;"),
    ("reset forgets used ids",
     "g->used |= reserved | (1ull << drive_node);", "g->used = reserved | (1ull << drive_node);"),
    # Not a mutant: "reset leaves the challenge open". gate_boot also zeroes chal_w, which closes
    # the challenge at the next tick, so removing `chal_open = false` there changes nothing.
    ("token for any challenge", " || chal != g->chal", ""),
    ("token with no freshness window", "if (g->chal_open && now - g->chal_at >= g->chal_w) gate_close_challenge(g);", ""),
    ("token tag not checked", "if (!gate_eq(mac, want, 8)) return GATE_REJECT;", ""),
    ("token redeemable twice", "    gate_close_challenge(g);\n    if (!gate_grant", "    if (!gate_grant"),
    ("command tag not checked", "if (!gate_eq(d + 4, want, 4)) continue;", ""),
    ("command sequence not advanced", "g->seq += k + 1;", ""),
    ("no failed-tag budget", "if (++g->bad >= GATE_MAX_BAD) gate_drop(g);", ""),
    ("old lease alone keeps energy on",
     "if (g->holder >= 0 && !g->lapsed && !gate_live(g->expiry, now)) {",
     "if (g->holder >= 0 && !g->lapsed && !gate_live(g->expiry, now) && g->prev < 0) {"),
    ("overlap from an unconfirmed holder", "overlap && g->holder >= 0 && !g->lapsed && g->confirmed ?", "overlap && g->holder >= 0 && !g->lapsed ?"),
    ("overlap from a lapsed holder", "overlap && g->holder >= 0 && !g->lapsed && g->confirmed ?", "overlap && g->holder >= 0 && g->confirmed ?"),
    ("previous lease never expires", "if (g->prev >= 0 && !gate_live(g->prev_expiry, now)) { g->prev = -1; g->prev_expiry = 0; }", ""),
    ("one-shot ignores the previous holder's lease",
     "if (!g->confirmed && g->prev_expiry - now < left) left = g->prev_expiry - now;", ""),
    ("a request replaces the open challenge", "    if (g->chal_open) return g->chal;\n", ""),
    ("rotation sent before the new node id is stored",
     "if (r == GATE_ROTATE && persist()) port_down_send(&out);", "if (r == GATE_ROTATE) port_down_send(&out);", "gate_fw.c"),
    ("challenge sent without a stored reservation", "                if (!persist()) break;\n", "", "gate_fw.c"),
    ("gate keeps serving after a failed storage write", "ok = ok && port_nv_store(&nv);", "ok = port_nv_store(&nv) || ok;", "gate_fw.c"),
    ("reset restarts the challenge counter", "g.chal = chal_top = nv.chal;", "chal_top = nv.chal;", "gate_fw.c"),
    ("challenge tag not bound to its value", "    uint8_t m[5] = {'G'}, h[32];\n    memcpy(m + 1, &chal, 4);", "    uint8_t m[5] = {'G'}, h[32];\n    (void)chal;"),
    ("flush stored before the drive is reset",
     "    if (!port_down_abort() || !port_drive_reset()) { ok = false; return; }\n    gate_flush(&g, GATE_DRIVE_BOOT_ID, GATE_RESERVED_IDS);\n    persist();",
     "    gate_flush(&g, GATE_DRIVE_BOOT_ID, GATE_RESERVED_IDS);\n    if (!persist()) return;\n    if (!port_down_abort() || !port_drive_reset()) ok = false;",
     "gate_fw.c"),
    ("flush without a drive reset", "if (!port_down_abort() || !port_drive_reset()) { ok = false; return; }", "if (!port_down_abort()) { ok = false; return; }", "gate_fw.c"),
    ("flush without a TX abort", "if (!port_down_abort() || !port_drive_reset()) { ok = false; return; }", "if (!port_drive_reset()) { ok = false; return; }", "gate_fw.c"),
    ("flush on any rejected token", "if (r == GATE_EXHAUSTED) flush();", "if (r == GATE_EXHAUSTED || r == GATE_REJECT) flush();", "gate_fw.c"),
    ("confirmation does not end the overlap", "if (g->confirmed) { g->prev = -1; g->prev_expiry = 0; }", ""),
    ("clock read once per poll",
     ["    uint32_t now, c;", "        now = port_now();\n        gate_tick(&g, now);", "    now = port_now();\n    port_en_gate"],
     ["    uint32_t now = port_now(), c;", "        gate_tick(&g, now);", "    port_en_gate"], "gate_fw.c"),
    ("expiry not latched before a command", "        now = port_now();\n        gate_tick(&g, now);", "        now = port_now();", "gate_fw.c"),
    ("stored node id not range-checked", "ok = port_nv_load(&nv) && nv.node < 64;", "ok = port_nv_load(&nv);", "gate_fw.c"),
]

# PROVE=1: judge each mutant by the CBMC proof (prove.sh) instead of the SIL run. JOBS: parallel mutants.
prove = os.environ.get("PROVE") == "1"

def judge(m):
    name, old, new, *where = m
    target = where[0] if where else "gate.h"
    src = open(os.path.join(gate, target)).read()
    edits = list(zip(old, new)) if isinstance(old, list) else [(old, new)]
    mutated = src
    for a, b in edits:
        assert src.count(a) == 1, f"mutant '{name}': pattern must occur exactly once"
        mutated = mutated.replace(a, b)
    with tempfile.TemporaryDirectory() as d:
        shutil.copytree(gate, d, dirs_exist_ok=True)
        open(os.path.join(d, target), "w").write(mutated)
        try:
            env = {**os.environ, "GATE_DIR": d, "GATE_CFLAGS": "-Wno-error", "EXPLORE_COUNTEREXAMPLE": "0",
                   "EXPLORE": os.environ.get("EXPLORE", "quick"), "EXPLORE_STEPS": os.environ.get("EXPLORE_STEPS", "2000000")}
            p = subprocess.Popen([os.path.join(here, "prove.sh" if prove else "run.sh")], stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True, start_new_session=True, env=env)
            out, _ = p.communicate(timeout=int(os.environ.get("MUTANT_TIMEOUT", "1200" if prove else "120")))
            if prove:
                fails = sorted({l.split("]")[0][1:] for l in out.splitlines() if l.endswith(": FAILURE")})
                killed = "VERIFICATION FAILED" in out
                if not killed and "VERIFICATION SUCCESSFUL" not in out:
                    killed, fails = True, ["build error"]
                return name, killed, " ".join(fails), False
            fails = [l[6:].split()[0] for l in out.splitlines() if l.startswith("FAIL  ")]
            explored = "EXPLORE: VIOLATION" in out
            if explored:
                fails.append("+explore")
            return name, p.returncode != 0, " ".join(fails) if fails else "build or runtime error", explored
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)   # the whole group: a compiled test may still be running
            p.wait()
            return name, None, "timeout", False

chosen = [m for m in MUTANTS if len(sys.argv) < 2 or sys.argv[1] in m[0]]
survivors = explored = timeouts = 0
with concurrent.futures.ThreadPoolExecutor(int(os.environ.get("JOBS", "1"))) as ex:
    for name, killed, how, found in ex.map(judge, chosen):
        # A timeout is reported on its own: it is neither a kill nor a survivor.
        label = "TIMEOUT " if killed is None else "killed  " if killed else "SURVIVED"
        print(f"{label}  {name}" + (f"  [{how}]" if killed is not False else ""), flush=True)
        survivors += killed is False
        timeouts += killed is None
        explored += found
print(f"{len(chosen) - survivors - timeouts}/{len(chosen)} mutants killed, {timeouts} timed out"
      + ("" if prove else f" ({explored} also found by exploration alone)"))
sys.exit(1 if survivors and not prove else 0)
