// Inductive proof of the gate firmware loop (../gate/gate_fw.c, unmodified) with CBMC: ./prove.sh
//
// One step is either a reset (RAM arbitrary, storage as last written) or one poll that handles at
// most one upstream frame. Real time (real_) advances while a frame arrives and is handled, and at
// every clock read; P1 and P2 are checked against real time at the moment EN_GATE is armed or a
// frame leaves, not against the firmware's last reading. A poll with k frames is the same as k one-frame polls that see no
// readback: gate_fw_poll reads the clock and latches expiry before each frame, and the extra latch
// and EN_GATE check at the end of each one-frame poll only latch what the next read would latch
// anyway, and add checks. The proof assumes inv() before the step and asserts it after, so it
// covers every run of any length.
//
// What is proved, for every lease length T and window W in (0, 2^30) and every clock step
// within the obligation of gate.h (at most 2^31 - max(T, W) ticks between clock reads):
//  P1 EN_GATE is armed only while a holder's lease is live, and only up to i + W + T, where i is
//     the time the gate first sent the challenge behind that lease (port_en_gate);
//     while a handover is unconfirmed, the same holds for the previous holder's lease;
//  P2 a setpoint goes downstream only under a live lease, before i + W + T (port_down_send);
//  P3 a token is redeemed only for the challenge the gate sent last (the value in the token's
//     tagged message, not just the gate's open challenge), less than W after it was
//     first sent; a challenge value is never announced twice except while it is still open.
// With the authority's obligation (it mints a token only for a challenge carrying the gate's tag,
// so after the gate sent it, and never after revocation at t_c), i <= t_c and so the gate stops
// supporting the output by t_c + W + T. The drive side (rotation, readback) is not in this proof.
//
// Not modelled: MAC strength. Every tag may verify, i.e. the adversary may hold any token.
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#define GATE_MAC_H  // replace SHA-256 with free values

uint8_t nondet_u8(void);
uint32_t nondet_u32(void);
bool nondet_bool(void);
float nondet_float(void);

static uint32_t tok_chal;  // challenge in the last token message MACed
static void gate_hmac(const uint8_t* key, size_t kn, const uint8_t* m, size_t n, uint8_t out[32]) {
    if (n == 7 && m[0] == 'T') memcpy(&tok_chal, m + 3, 4);
    for (int i = 0; i < 32; ++i) out[i] = nondet_u8();
}
static bool gate_eq(const uint8_t* a, const uint8_t* b, size_t n);
float strtof(const char* s, char** end) { return nondet_float(); }

static uint32_t P_T, P_W;
#define GATE_T_MS P_T
#define GATE_W_MS P_W
#include "gate_fw.c"  // from GATE_DIR (prove.sh)

// ---- Ghost state ----
static uint32_t real_, now_, last_;  // real time; last clock read; last read of the previous step
static uint32_t i_h, i_p;      // first-send time of the challenge behind the holder's / previous holder's lease
static uint32_t sent_c, sent_t;// highest challenge value sent upstream, and when it was first sent
static gate_nv nv_;            // what storage holds
static bool accepted;          // a token tag verified; the grant follows
static uint32_t acc_i, acc_session;
static int frames;
static gate_frame in_;

static void ghost_sync(void) {
    if (!accepted) return;
    accepted = false;
    if (g.session != acc_session && g.prev >= 0) i_p = i_h;  // rotated with overlap: old holder becomes prev
    if (g.holder >= 0) i_h = acc_i;
}

static bool gate_eq(const uint8_t* a, const uint8_t* b, size_t n) {
    bool r = nondet_bool();
    if (n == 8 && r) {  // token tag
        assert(g.chal_open && tok_chal == sent_c && g.chal_at == sent_t);  // P3
        assert(now_ - g.chal_at < P_W);                                  // P3
        accepted = true;
        acc_i = g.chal_at;
        acc_session = g.session;
    }
    return r;
}

// ---- Board ----
static const uint8_t key_[32];
static uint32_t D;  // most ticks between two clock reads (obligation of gate.h)
static void elapse(void) {
    real_ += nondet_u32();
    __CPROVER_assume(real_ - now_ <= D);
}
uint32_t port_now(void) {
    elapse();
    return now_ = real_;
}
bool port_up_recv(gate_frame* f) {
    elapse();
    if (!frames) return false;
    frames--;
    *f = in_;
    return true;
}
void port_up_send(const gate_frame* f) {
    uint32_t c;
    if (f->id != UP_CHAL) return;
    memcpy(&c, f->data, 4);
    if (c > sent_c) { sent_c = c; sent_t = now_; return; }
    assert(c == sent_c && g.chal_open && g.chal == c && g.chal_at == sent_t);  // P3
}
void port_down_send(const gate_frame* f) {
    ghost_sync();
    if ((f->id & 0x1f) != GATE_CMD_SET_INPUT_VEL) return;
    assert(g.holder >= 0 && !g.lapsed && gate_live(g.expiry, real_));  // P2
    assert(real_ - i_h < P_W + P_T);                                     // P2
}
bool port_down_abort(void) { return nondet_bool(); }
bool port_drive_reset(void) { return nondet_bool(); }
void port_uart_write(const char* s) {}
bool port_uart_line(char* buf, int n) { return nondet_bool(); }
void port_en_gate(uint32_t ms) {
    ghost_sync();
    if (!ms) return;
    assert(g.holder >= 0 && !g.lapsed);                                  // P1
    assert((uint64_t)(real_ - i_h) + ms < (uint64_t)P_W + P_T);          // P1
    if (!g.confirmed) {
        assert(g.prev >= 0);                                             // P1
        assert((uint64_t)(real_ - i_p) + ms < (uint64_t)P_W + P_T);      // P1
    }
}
bool port_nv_load(gate_nv* nv) {
    if (nondet_bool()) return false;  // corrupt
    *nv = nv_;
    return true;
}
bool port_nv_store(const gate_nv* nv) {
    bool done = nondet_bool();
    if (done || nondet_bool()) nv_ = *nv;  // a failed write may still have landed
    return done;
}
const uint8_t* port_key(void) { return key_; }

// ---- Invariant ----
static bool inv_storage(void) { return sent_c <= nv_.chal && nv_.chal < UINT32_MAX; }  // node: any value
static bool lease(uint32_t expiry, uint32_t i) {  // live at last_, granted for a challenge sent at i
    uint32_t left = expiry - last_;
    return left > 0 && left <= P_T && last_ - i < P_W + P_T && expiry - i < P_W + P_T;
}
static bool inv(void) {
    if (!inv_storage() || accepted) return false;
    if (!ok) return true;
    if (!(sent_c <= g.chal && g.chal <= chal_top && chal_top == nv_.chal)) return false;
    if (g.holder < 0 && (g.lapsed || g.prev >= 0 || g.confirmed)) return false;
    if (g.holder >= 0 && !g.lapsed && !lease(g.expiry, i_h)) return false;
    if (g.prev >= 0 && (g.holder < 0 || g.lapsed || !lease(g.prev_expiry, i_p))) return false;
    if (g.chal_open && (g.chal_w != P_W || last_ - g.chal_at >= P_W || g.chal != sent_c || g.chal_at != sent_t)) return false;
    return true;
}

gate nondet_gate(void);
gate_frame nondet_frame(void);
gate_nv nondet_nv(void);

int main(void) {
    P_T = nondet_u32();
    P_W = nondet_u32();
    __CPROVER_assume(P_T > 0 && P_T < (1u << 30) && P_W > 0 && P_W < (1u << 30));
    D = (1u << 31) - (P_T > P_W ? P_T : P_W);
    // Arbitrary state.
    g = nondet_gate();
    ok = nondet_bool();
    chal_top = nondet_u32();
    have_t1 = nondet_bool();
    for (int i = 0; i < 6; ++i) t1[i] = nondet_u8();
    last_rb = nondet_u32();
    last_ = nondet_u32();
    i_h = nondet_u32();
    i_p = nondet_u32();
    sent_c = nondet_u32();
    sent_t = nondet_u32();
    nv_ = nondet_nv();
    accepted = false;
    __CPROVER_assume(inv_storage());

    if (nondet_bool()) {  // power-up or reset: RAM is arbitrary, storage is not
        real_ = now_ = nondet_u32();
        gate_fw_init();
    } else {
        __CPROVER_assume(inv());
        real_ = now_ = last_;
        in_ = nondet_frame();
        frames = 1;
        gate_fw_poll();
        ghost_sync();
    }
    last_ = now_;
    assert(inv());
    return 0;
}
