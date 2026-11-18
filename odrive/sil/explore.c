// Bounded exhaustive exploration of the real gate firmware loop (../gate/gate_fw.c, included
// below so its state can be saved and restored) against an adversarial environment.
//
// Every interleaving of the actions below is explored, up to the bounds, with duplicate states
// pruned. After every step two properties are checked:
//   I1 (timed finality)  EN_GATE high and the drive's setpoint was authored by origin o
//                        =>  now < (last time the authority minted a token for o) + W + T
//   I2 (attribution)     EN_GATE high and the setpoint was authored by o
//                        =>  o is the gate's holder, or its previous holder during a handover
// "Authored by" is a ghost label carried from the upstream command frame to the drive; the gate
// code never sees it.
//
// Environment (all choices adversarial):
//   - time advances; the gate is polled after every action;
//   - anyone requests a challenge; the authority mints a token for the latest challenge, for
//     any origin, with or without the overlap flag; any minted token is presented at any time,
//     any number of times; tokens with a made-up tag are presented; a controller asks the
//     authority for a token for the next counter value, which the gate has not issued yet;
//   - a controller sends its next command under any session key it was ever given, replays its
//     last command frame, or sends a frame with a bad tag;
//   - downstream frames (gate -> drive) are delivered in any order, after any delay, or lost;
//   - a UART readback answer arrives late (value from the time of the query) or current, or never;
//   - one fault class per run: the gate resets (clock restarts), crashes right after a storage
//     write, a write fails, the drive reboots to its default node id with a zero setpoint, or the
//     firmware hangs for some ticks (only the EN_GATE hardware one-shot acts).
// With -DNODE_IDS=n the gate has only n node ids, runs out, and flushes (verified flush taken as
// correct hardware). Not modelled: a flush that does not really clear, a second downstream node,
// the one-shot timer itself (taken as correct hardware).
//
// This is a bounded check of the C code, not a proof. Model of the drive: it accepts a frame
// only if addressed to its current node id (checked against real ODrive code in test_fence.cpp).
#include <stdio.h>
#include "gate_mac.h"
// The same few MACs recur millions of times: cache them (exact match on key and message).
static void cached_hmac(const uint8_t* key, size_t klen, const uint8_t* msg, size_t mlen, uint8_t out[32]) {
    static struct { uint8_t used, mlen, key[32], msg[16], out[32]; } c[4096];
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < klen; ++i) h = (h ^ key[i]) * 16777619u;
    for (size_t i = 0; i < mlen; ++i) h = (h ^ msg[i]) * 16777619u;
    h = (h ^ (h >> 12)) & 4095;
    if (klen == 32 && mlen <= 16) {
        if (c[h].used && c[h].mlen == mlen && !memcmp(c[h].key, key, 32) && !memcmp(c[h].msg, msg, mlen)) { memcpy(out, c[h].out, 32); return; }
        gate_hmac(key, klen, msg, mlen, out);
        c[h].used = 1; c[h].mlen = (uint8_t)mlen; memcpy(c[h].key, key, 32); memcpy(c[h].msg, msg, mlen); memcpy(c[h].out, out, 32);
        return;
    }
    gate_hmac(key, klen, msg, mlen, out);
}
#define gate_hmac cached_hmac
#ifndef GATE_W_MS
#define GATE_W_MS 2u
#endif
#ifndef GATE_T_MS
#define GATE_T_MS 3u
#endif
#define GATE_RB_MS 1u
#define GATE_CHAL_CHUNK 2u   // small, so both the reserved and the storing path are explored
#ifdef NODE_IDS              // only ids 0 .. NODE_IDS-1 exist, so the search can run out of ids and flush
#define GATE_RESERVED_IDS (~0ull << NODE_IDS)
#endif
#define GATE_SEQ_WINDOW 2
#define GATE_MAX_BAD 2
#include "gate_fw.c"

#ifndef HORIZON
#define HORIZON 9      // world ticks
#endif
#ifndef NTOK
#define NTOK 3         // tokens minted
#endif
#ifndef MAX_CHAL
#define MAX_CHAL 3     // challenges requested
#endif
#ifndef MAX_BADS
#define MAX_BADS 2     // frames with a bad tag (GATE_MAX_BAD is 2 here)
#endif
#ifndef NORIG
#define NORIG 2        // controllers (origins)
#endif
#ifndef MAX_SEQ
#define MAX_SEQ 2       // commands per session key
#endif
enum { NFL = 2, D0 = 0, NEVER = -1000, PER = NORIG * 2, NSLOT = (MAX_CHAL + 1) * PER };
enum { F_RESET = 1, F_CRASH = 2, F_STORE = 4, F_DRIVE = 8, F_STALL = 16 };   // fault classes
#ifndef MAX_STALL
#define MAX_STALL 3     // ticks the firmware may hang in one run
#endif

#ifdef NO_OVERLAP            // the authority never sets the overlap flag (used where ids are too few for a handover)
#define FLAG_OK(f) (!(f))
#else
#define FLAG_OK(f) 1
#endif
// Token slot = challenge ordinal * PER + origin * 2 + flags, so the order of minting is not state.
typedef struct { uint8_t minted, seq; } tok;
typedef struct { gate_frame f; int8_t src; } flight;
typedef struct {
    // firmware statics
    gate g; uint8_t t1[6]; uint8_t ok, have_t1; uint32_t last_rb, chal_top;
    // world
    uint32_t wt, boot;
    gate_nv nv;
    uint8_t d_node; int8_t d_src; int32_t d_tag;
    flight fl[NFL]; uint8_t nfl;
    int32_t rb; uint8_t rb_have;
    uint8_t en; uint32_t en_until;       // EN_GATE and its hardware one-shot deadline (world time)
    uint32_t chal[MAX_CHAL + 1]; uint8_t n_req, n_issued;   // challenge values the authority accepted as the gate's
    uint8_t n_future, last_tag[4];       // slots the authority minted for (may run one ahead of the gate); last gate tag seen
    tok tk[NSLOT]; uint8_t ntk;
    int32_t lastmint[NORIG];
    uint8_t n_bad, fault_used, fail_store, crash_armed, n_stall;
} World;

static World w;
static int faults;                     // fault classes enabled in this run
static uint32_t base;                  // gate clock value at boot (to cross the 32-bit wrap)
static const uint8_t KEY[32] = {7, 1, 8, 2, 8, 1, 8, 2, 8, 4, 5, 9, 0, 4, 5, 2, 3, 5, 3, 6, 0, 2, 8, 7, 4, 7, 1, 3, 5, 2, 6, 6};

// ---- transient per-step state ----
static gate_frame up[2]; static int nup, iup;
static int cur_src;                    // ghost: author of the upstream frame being processed
static char line[16]; static bool have_line;
static bool crashed, overflow, stalled;
static uint64_t n_flush;

// The authority mints only for a challenge carrying the gate's tag. With -DAUTHORITY_UNCHECKED it
// mints for any value it is shown: the flaw of a predictable, unauthenticated challenge.
static bool authority_accepts(uint32_t c, const uint8_t tag[4]) {
#ifdef AUTHORITY_UNCHECKED
    (void)c; (void)tag;
    return true;
#else
    uint8_t want[4];
    gate_chal_mac(KEY, c, want);
    return gate_eq(tag, want, 4);
#endif
}

// ---- port ----
uint32_t port_now(void) { return base + (w.wt - w.boot); }
bool port_up_recv(gate_frame* f) { if (iup >= nup) return false; *f = up[iup++]; return true; }
void port_up_send(const gate_frame* f) {
    uint32_t c;
    if (crashed || f->id != UP_CHAL) return;
    memcpy(&c, f->data, 4);
    memcpy(w.last_tag, f->data + 4, 4);
    if (!authority_accepts(c, w.last_tag)) return;
    if (!w.n_issued || w.chal[w.n_issued - 1] != c) w.chal[w.n_issued++] = c;   // a re-announcement is not a new challenge
    if (w.n_future < w.n_issued) w.n_future = w.n_issued;
}
void port_down_send(const gate_frame* f) {
    if (crashed) return;
    if (w.nfl == NFL) { overflow = true; return; }
    memset(&w.fl[w.nfl], 0, sizeof w.fl[0]);
    w.fl[w.nfl].f = *f;
    w.fl[w.nfl].src = (int8_t)((f->id & 0x1f) == GATE_CMD_SET_INPUT_VEL ? cur_src : -1);
    w.nfl++;
    // The bus is a multiset (any delivery order is explored), so keep it sorted: order is not state.
    for (int i = w.nfl - 1; i > 0 && memcmp(&w.fl[i - 1], &w.fl[i], sizeof w.fl[0]) > 0; --i) {
        flight t = w.fl[i]; w.fl[i] = w.fl[i - 1]; w.fl[i - 1] = t;
    }
}
void port_uart_write(const char* s) {
    (void)s;
    if (crashed) return;
    w.rb = w.d_tag;
    w.rb_have = 1;
}
bool port_uart_line(char* buf, int n) {
    if (!have_line) return false;
    snprintf(buf, (size_t)n, "%s", line);
    have_line = false;
    return true;
}
void port_en_gate(uint32_t ms) { if (!crashed) { w.en = ms > 0; w.en_until = ms ? w.wt + ms : 0; } }
bool port_nv_load(gate_nv* nv) { *nv = w.nv; return true; }
// Verified flush, as correct hardware does it: nothing left on the bus, drive reset to its boot id
// with no setpoint, no stale UART answer. A flush that only claims this is `FiniteFence.lean`'s
// `unverified_flush_breaks`, not modelled here.
bool port_down_abort(void) {
    if (crashed) return false;
    memset(w.fl, 0, sizeof w.fl);
    w.nfl = 0;
    return true;
}
bool port_drive_reset(void) {
    if (crashed) return false;
    w.d_node = D0; w.d_tag = 0; w.d_src = -1;
    w.rb = 0; w.rb_have = 0;
    n_flush++;
    return true;
}
bool port_nv_store(const gate_nv* nv) {
    if (crashed) return false;
    if (w.fail_store) { w.fail_store = 0; return false; }
    memset(&w.nv, 0, sizeof w.nv);
    w.nv.session = nv->session; w.nv.used = nv->used; w.nv.chal = nv->chal; w.nv.node = nv->node;
    if (w.crash_armed) { w.crash_armed = 0; crashed = true; w.en = 0; w.en_until = 0; }   // MCU reset: EN_GATE pulled low
    return true;
}
const uint8_t* port_key(void) { return KEY; }

static void fw_save(void) { memcpy(&w.g, &g, sizeof g); memcpy(w.t1, t1, 6); w.ok = ok; w.have_t1 = have_t1; w.last_rb = last_rb; w.chal_top = chal_top; }
static void fw_load(void) { memcpy(&g, &w.g, sizeof g); memcpy(t1, w.t1, 6); ok = w.ok; have_t1 = w.have_t1; last_rb = w.last_rb; chal_top = w.chal_top; }
static void reset_gate(void) { w.boot = w.wt; w.en = 0; w.en_until = 0; gate_fw_init(); }
static void poll(void) {
    iup = 0;
    gate_fw_poll();
    nup = 0;
    have_line = false;
    if (crashed) { crashed = false; reset_gate(); }
}

// ---- visited set: 128-bit fingerprints (a collision would hide states; taken as negligible) ----
typedef struct { uint64_t a, b; } fp;
static fp* tab; static uint64_t cap = 1ull << 22, cnt;
static fp fingerprint(void) {
    fp h = {1469598103934665603ull, 0x9e3779b97f4a7c15ull};
    const uint8_t* p = (const uint8_t*)&w;
    for (size_t i = 0; i < sizeof w; ++i) {
        h.a = (h.a ^ p[i]) * 1099511628211ull;
        h.b = (h.b + p[i] + 1) * 0xff51afd7ed558ccdull; h.b ^= h.b >> 29;
    }
    if (!h.a && !h.b) h.a = 1;
    return h;
}
static bool put(fp* t, uint64_t c, fp h) {
    for (uint64_t i = h.a & (c - 1);; i = (i + 1) & (c - 1)) {
        if (!t[i].a && !t[i].b) { t[i] = h; return true; }
        if (t[i].a == h.a && t[i].b == h.b) return false;
    }
}
static bool visit(void) {
    if (cnt * 2 > cap) {
        fp* n = calloc(cap * 2, sizeof *n);
        if (!n) { puts("EXPLORE: out of memory"); exit(2); }
        for (uint64_t i = 0; i < cap; ++i) if (tab[i].a || tab[i].b) put(n, cap * 2, tab[i]);
        free(tab); tab = n; cap *= 2;
    }
    if (!put(tab, cap, fingerprint())) return false;
    cnt++;
    if (getenv("EXPLORE_PROGRESS") && cnt % 2000000 == 0) fprintf(stderr, "%llu states\n", (unsigned long long)cnt);
    return true;
}

// ---- search ----
static char trace[256][96]; static int depth, maxdepth;
static int pick = -2, nact, cw = 1;    // random walk: -2 off (exhaustive), -1 count, >= 0 run the action owning that slot
#define WEIGHT(n) (cw = (n))           // slots per action from here on: productive actions get more
static uint64_t n_en, n_overlap_en, n_blocked, n_pruned, n_rot, total;

static void fail(const char* what) {
    printf("EXPLORE: VIOLATION %s (clock base %#x)\n", what, base);
    for (int i = 0; i < depth; ++i) printf("  %2d %s\n", i + 1, trace[i]);
    printf("  wt=%u en=%d holder=%d prev=%d confirmed=%d gate.node=%d drive.node=%d drive.tag=%d drive.src=%d lastmint[src]=%d\n",
           w.wt, w.en, g.holder, g.prev, g.confirmed, g.node, w.d_node, w.d_tag, w.d_src, w.d_src >= 0 ? w.lastmint[w.d_src] : NEVER);
    exit(1);
}
static void check(void) {
    int o = w.d_src;
    bool stale = o >= 0 && (int32_t)w.wt >= w.lastmint[o] + (int32_t)(GATE_W_MS + GATE_T_MS);
    if (w.en) {
        n_en++;
        if (!g.confirmed) n_overlap_en++;
        if (stale) fail("I1: enabled on a setpoint whose author's authority ran out");
        if (o >= 0 && o != g.holder && o != g.prev) fail("I2: enabled on a setpoint from neither holder nor previous holder");
    } else if (stale) n_blocked++;
}

static void explore(void);
static void step(const char* fmt, int a, int b) {   // called with the action already applied to `w` inputs
    snprintf(trace[depth], sizeof trace[0], fmt, a, b);
    depth++;
    if (depth > maxdepth) maxdepth = depth;
    if (stalled) { stalled = false; nup = 0; if (w.en && w.wt >= w.en_until) { w.en = 0; w.en_until = 0; } }   // only the one-shot acts
    else poll();
    fw_save();
    // A correct gate opens at most one session per token. Cut runs that exceed that by a margin,
    // so a gate broken in that respect still gives a finite search (the property is checked first).
    if (!overflow && g.session > (uint32_t)NTOK + 2) { check(); overflow = true; }
    if (overflow) { overflow = false; n_pruned++; }
    else { check(); if (pick != -2) return; if (visit()) explore(); }
    depth--;
}
static void drop_flight(int i) {
    for (int j = i; j + 1 < w.nfl; ++j) w.fl[j] = w.fl[j + 1];
    w.nfl--;
    memset(&w.fl[w.nfl], 0, sizeof w.fl[0]);
}
static void cmd_frame(int origin, uint32_t chal, uint32_t seq, gate_frame* f) {
    uint8_t ks[32], d[8];
    float torque = 0.5f;
    gate_session_key(KEY, (uint8_t)origin, chal, ks);
    memcpy(d, &torque, 4);
    gate_cmd_mac(ks, seq, d, d + 4);
    *f = gate_raw(UP_CMD, d, 8);
}

static void explore(void) {
    const World s = w;
#define TRY(setup, fmt, a, b) do { \
        if (pick == -2 || (pick >= nact && pick < nact + cw)) { w = s; fw_load(); nup = 0; cur_src = -1; setup; step(fmt, a, b); if (pick != -2) return; } \
        nact += cw; } while (0)
    nact = 0;
    if (pick == -2 && depth >= 250) return;
    WEIGHT(6);
    if (s.wt < HORIZON) TRY(w.wt++, "tick -> %d", (int)s.wt + 1, 0);
    WEIGHT(3);
    if (s.n_req < MAX_CHAL) TRY((w.n_req++, up[nup++] = gate_raw(UP_CHAL_REQ, "", 0)), "challenge request", 0, 0);
    if (s.n_issued && s.ntk < NTOK)
        for (int k = 0; k < PER; ++k) {
            int i = (s.n_issued - 1) * PER + k, o = k >> 1;
            if (!s.tk[i].minted && FLAG_OK(k & 1))
                TRY((w.tk[i].minted = 1, w.ntk++, w.lastmint[o] = (int32_t)s.wt), "authority mints token: origin %d flags %d", o, k & 1);
        }
    // A controller shows the authority the *next* counter value with the last tag it saw, to get
    // a token it can keep past its own revocation. A correct authority check refuses.
    if (s.n_issued && s.n_future == s.n_issued && s.n_issued < MAX_CHAL && s.ntk < NTOK &&
        authority_accepts(s.chal[s.n_issued - 1] + 1, s.last_tag))
        for (int o = 0; o < NORIG; ++o)
            TRY((w.chal[w.n_issued] = s.chal[s.n_issued - 1] + 1, w.n_future = (uint8_t)(s.n_issued + 1),
                 w.tk[s.n_issued * PER + o * 2].minted = 1, w.ntk++, w.lastmint[o] = (int32_t)s.wt),
                "authority mints for a challenge the gate has not issued yet: origin %d", o, 0);
    for (int i = 0; i < NSLOT; ++i) {
        if (!s.tk[i].minted) continue;
        const uint8_t o = (uint8_t)(i % PER >> 1), fl = (uint8_t)(i & 1);
        const uint32_t c = s.chal[i / PER];
        uint8_t a[6] = {o, fl}, mac[8];
        gate_frame f;
        memcpy(a + 2, &c, 4);
        gate_token_mac(KEY, o, fl, c, mac);
        WEIGHT(4);
        TRY((up[nup++] = gate_raw(UP_TOKEN1, a, 6), up[nup++] = gate_raw(UP_TOKEN2, mac, 8)), "token %d presented (origin %d)", i, o);
        if (s.tk[i].seq < MAX_SEQ) {
            cmd_frame(o, c, s.tk[i].seq, &f);
            TRY((w.tk[i].seq++, up[nup++] = f, cur_src = o), "origin %d sends next command under token %d's key", o, i);
        }
        WEIGHT(1);
        if (s.tk[i].seq) {
            cmd_frame(o, c, s.tk[i].seq - 1u, &f);
            TRY((up[nup++] = f, cur_src = o), "origin %d replays its last command (token %d)", o, i);
        }
    }
    if (s.n_issued)
        for (int o = 0; o < NORIG; ++o) {   // a token nobody minted: right challenge, made-up tag
            uint8_t a[6] = {(uint8_t)o, 0};
            memcpy(a + 2, &s.chal[s.n_issued - 1], 4);
            TRY((up[nup++] = gate_raw(UP_TOKEN1, a, 6), up[nup++] = gate_raw(UP_TOKEN2, "forged!", 8)), "forged token presented (origin %d)", o, 0);
        }
    if (MAX_BADS && s.n_bad < MAX_BADS) TRY((w.n_bad++, up[nup++] = gate_raw(UP_CMD, "\1\2\3\4\5\6\7\0", 8), cur_src = 0), "command with a bad tag", 0, 0);
    for (int i = 0; i < s.nfl; ++i) {
        const gate_frame f = s.fl[i].f;
        WEIGHT(12);
        uint32_t v;
        float tag;
        memcpy(&v, f.data, 4);
        memcpy(&tag, f.data, 4);
        TRY(({ drop_flight(i);
               if ((f.id >> 5) == s.d_node) {
                   if ((f.id & 0x1f) == GATE_CMD_SET_NODE_ID) { w.d_node = (uint8_t)v; n_rot++; }
                   else { w.d_tag = (int32_t)tag; w.d_src = s.fl[i].src; }
               } }), "downstream frame %d delivered (addressed to node %d)", i, (int)(f.id >> 5));
        WEIGHT(1);
        TRY(drop_flight(i), "downstream frame %d lost", i, 0);
    }
    WEIGHT(8);
    if (s.rb_have) {
        TRY((snprintf(line, sizeof line, "%d", (int)s.rb), have_line = true, w.rb = 0, w.rb_have = 0), "readback answer, value from query time: %d", (int)s.rb, 0);
        if (s.rb != s.d_tag)
            TRY((snprintf(line, sizeof line, "%d", (int)s.d_tag), have_line = true, w.rb = 0, w.rb_have = 0), "readback answer, current value: %d", (int)s.d_tag, 0);
    }
    WEIGHT(1);
    {   // each enabled fault class at most once per run
        const int can = faults & ~s.fault_used;
        if (can & F_RESET) TRY((w.fault_used |= F_RESET, reset_gate(), fw_save(), fw_load()), "gate reset", 0, 0);
        if (can & F_CRASH) TRY((w.fault_used |= F_CRASH, w.crash_armed = 1), "gate will crash right after its next storage write", 0, 0);
        if (can & F_STORE) TRY((w.fault_used |= F_STORE, w.fail_store = 1), "next storage write will fail", 0, 0);
        if (can & F_DRIVE) TRY((w.fault_used |= F_DRIVE, w.d_node = D0, w.d_tag = 0, w.d_src = -1), "drive reboots", 0, 0);
    }
    if ((faults & F_STALL) && s.n_stall < MAX_STALL && s.wt < HORIZON)
        TRY((w.n_stall++, w.wt++, stalled = true), "firmware hangs for a tick -> %d (no poll)", (int)s.wt + 1, 0);
#undef TRY
    w = s;
}

static void run(int fault_classes, uint32_t clock_base) {
    static const char* const cls[5] = {"gate reset", "crash after write", "write fails", "drive reboot", "firmware hangs"};
    char name[64] = "";
    for (int b = 0; b < 5; ++b)
        if (fault_classes >> b & 1) snprintf(name + strlen(name), sizeof name - strlen(name), "%s%s", *name ? " + " : "", cls[b]);
    if (!*name) snprintf(name, sizeof name, "none");
    faults = fault_classes;
    base = clock_base;
    memset(tab, 0, cap * sizeof *tab);
    cnt = 0;
    maxdepth = 0;
    memset(&w, 0, sizeof w);
    w.nv.node = D0;
    w.d_node = D0; w.d_src = -1;
    for (int o = 0; o < NORIG; ++o) w.lastmint[o] = NEVER;
    depth = 0;
    reset_gate();
    fw_save();
    visit();
    explore();
    printf("explore: fault %-32s clock base %#10x: %9llu states, max depth %d\n", name, clock_base, (unsigned long long)cnt, maxdepth);
    total += cnt;
}

// Seeded random walks: the same actions, far larger bounds, no completeness.
static uint64_t rng = 0x243F6A8885A308D3ull;
static uint32_t rnd(uint32_t n) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return (uint32_t)((rng >> 16) % n); }
static void walks(long steps) {
    long done = 0, nwalk = 0;
    while (done < steps) {
        faults = rnd(3) ? 0 : (1 << rnd(5)) | (1 << rnd(5));   // none, one or two fault classes
        base = rnd(2) ? 0xFFFFFFFFu - rnd(HORIZON) : 0;
        memset(&w, 0, sizeof w);
        w.nv.node = D0;
        w.d_node = D0; w.d_src = -1;
        for (int o = 0; o < NORIG; ++o) w.lastmint[o] = NEVER;
        depth = 0;
        reset_gate();
        fw_save();
        nwalk++;
        for (int i = 0; i < 250; ++i, ++done) {
            pick = -1; explore();           // count the enabled actions
            if (!nact) break;
            pick = (int)rnd((uint32_t)nact);
            explore();
            if (overflow) { overflow = false; break; }
        }
    }
    pick = -2;
    printf("explore: %ld random steps in %ld walks\n", done, nwalk);
    total += (uint64_t)done;
}

int main(void) {
    tab = calloc(cap, sizeof *tab);
    setvbuf(stdout, NULL, _IOLBF, 0);
#ifdef RANDOM_STEPS
    walks(RANDOM_STEPS);
#else
#ifdef AUTHORITY_UNCHECKED
    run(0, 0);                   // expected to end in a violation
#else
#ifdef FAULT_MASK                // one chosen combination of fault classes
    run(FAULT_MASK, 0);
#elif defined(FAULT_PAIRS)       // two different fault classes in one run
    for (int a = 1; a <= 16; a *= 2)
        for (int b = a * 2; b <= 16; b *= 2) run(a | b, 0);
#else
    for (int f = 0; f <= 16; f = f ? f * 2 : 1) run(f, 0);
    run(0, 0xFFFFFFFCu);         // the gate clock wraps during the run
    run(F_RESET, 0xFFFFFFFCu);
#endif
#endif
#endif
    printf("explore: enabled states %llu (of which on the previous holder's lease %llu), "
           "stale setpoint held with EN_GATE low %llu, rotations delivered %llu, pruned (bus or session bound) %llu\n",
           (unsigned long long)n_en, (unsigned long long)n_overlap_en, (unsigned long long)n_blocked,
           (unsigned long long)n_rot, (unsigned long long)n_pruned);
    printf("explore: verified flushes %llu\n", (unsigned long long)n_flush);
#ifdef NODE_IDS      // with so few ids there is no room for a handover; a flush must have happened instead
    if (!n_en || !n_flush || !n_blocked) { puts("EXPLORE: VACUOUS (a tracked situation was never reached)"); return 1; }
#else
    if (!n_en || !n_overlap_en || !n_blocked) { puts("EXPLORE: VACUOUS (a tracked situation was never reached)"); return 1; }
#endif
    printf("EXPLORE OK: I1 and I2 hold in all %llu explored states/steps (W=%u T=%u horizon=%d tokens=%d challenges=%d)\n",
           (unsigned long long)total, GATE_W_MS, GATE_T_MS, HORIZON, NTOK, MAX_CHAL);
    return 0;
}
