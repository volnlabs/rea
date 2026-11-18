// Gate core: the lease, fence, token and interlock logic of the final gate, with no HAL.
// Portable C (also valid C++). The same file is compiled into the gate firmware loop
// (gate_fw.c) and into the SIL test (../sil/test_fence.cpp).
//
// Mirrors FencedFinality.lean:
//  - redeem: a token is accepted only for the open challenge, inside the window W, once;
//  - switch: a holder change takes a fresh node id and clears confirmation;
//  - readback confirms the session;
//  - LEASE_OK = holder's lease live AND (session confirmed OR previous holder's lease live).
// Revocation is non-renewal: no message has to reach the gate.
//
// Obligations on the firmware around this core:
//  - `session`, `used`, `chal` and `node` are stored non-volatile before they take effect (C24);
//  - gate_flush may be called only after a verified flush: TX abort + drive reset (C14);
//  - `now` comes from the gate's own monotonic clock, which must keep running while the firmware
//    is stuck (a hardware counter, not a tick counted by an interrupt). It is 32 bits and wraps. Expiry is
//    therefore latched (gate_tick): the firmware must call gate_lease_ok at least once every
//    2^31 - max(T, W) ticks, and T and W must be below 2^30. Without the latch a lease that
//    ended 2^31 ticks ago compares as live again;
//  - the gate is the only path to the drive's bus and EN_GATE (C15);
//  - EN_GATE is held by a hardware one-shot armed with gate_enable_for, not by a GPIO level.
//
// Message authentication is a draft, not reviewed cryptography (C16): HMAC-SHA-256 with one
// key shared by the authority service and the gate, tags truncated to fit classic CAN frames.
// ponytail: one shared key and 32-bit command tags with a per-session failure budget; move to
// per-controller keys and CAN FD (full tags) before any real deployment.
// Integers in MACs are in host byte order: every party must be little-endian.
#ifndef GATE_H
#define GATE_H
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "gate_mac.h"

enum { GATE_CMD_SET_NODE_ID = 0x006, GATE_CMD_SET_INPUT_VEL = 0x00D };  // ODrive CANSimple
enum { GATE_REJECT = 0, GATE_RENEWED = 1, GATE_ROTATE = 2, GATE_EXHAUSTED = 3 };  // gate_token results
enum { GATE_OVERLAP = 1 };  // token flag: keep energy on the previous holder's lease (handover)
#ifndef GATE_SEQ_WINDOW
#define GATE_SEQ_WINDOW 8   // command sequence numbers accepted ahead of the expected one
#endif
#ifndef GATE_MAX_BAD
#define GATE_MAX_BAD 16     // failed command tags before the holder is dropped
#endif

typedef struct { uint32_t id; uint8_t len; uint8_t data[8]; } gate_frame;

typedef struct {
    // Persistent: must survive a gate reset.
    uint32_t session;   // monotonic count of holder changes
    uint64_t used;      // node ids unusable until the next verified flush (bit i = id i)
    uint32_t chal;      // monotonic challenge counter
    // Volatile: lost on reset, rebuilt by gate_boot.
    int holder;         // origin id of the current grant, -1 = none
    uint8_t node;       // the drive's current node id (also stored non-volatile)
    uint32_t expiry;    // gate tick at which the holder's lease ends
    bool confirmed;     // readback matched this session's tag
    bool lapsed;        // the holder's lease ran out; latched until its next grant
    int prev;           // previous holder whose lease still supports the output, -1 = none
    uint32_t prev_expiry;
    bool chal_open;     // a challenge is outstanding and unused
    uint32_t chal_at;   // gate tick at which it was issued
    uint32_t chal_w;    // its freshness window in ticks
    uint8_t ks[32];     // session key for the holder's commands
    uint32_t seq;       // next expected command sequence number
    uint8_t bad;        // failed command tags this session
} gate;

static inline gate_frame gate_raw(uint32_t id, const void* p, uint8_t n) {
    gate_frame f;
    memset(&f, 0, sizeof f);
    f.id = id;
    f.len = n;
    memcpy(f.data, p, n);
    return f;
}
static inline gate_frame gate_mk(uint8_t node, uint32_t cmd, const void* p, uint8_t n) {
    return gate_raw(((uint32_t)node << 5) | cmd, p, n);
}
static inline bool gate_live(uint32_t expiry, uint32_t now) { return (int32_t)(expiry - now) > 0; }
// End the session. The dead session key and counters are wiped, not left behind.
static inline void gate_drop(gate* g) {
    g->holder = g->prev = -1;
    g->confirmed = g->lapsed = false;
    g->expiry = g->prev_expiry = g->seq = 0;
    g->bad = 0;
    memset(g->ks, 0, sizeof g->ks);
}
static inline void gate_close_challenge(gate* g) { g->chal_open = false; g->chal_at = g->chal_w = 0; }

// Latch what has run out. Comparing against a wrapping clock is only sound while the deadline is
// less than 2^31 ticks away, so an expired lease or challenge is marked the first time it is
// seen expired and can never come back when the clock wraps. A lapsed holder keeps its session
// (node id, key): only a new grant to the same origin revives it, without a rotation.
static inline void gate_tick(gate* g, uint32_t now) {
    if (g->holder >= 0 && !g->lapsed && !gate_live(g->expiry, now)) { g->lapsed = true; g->expiry = 0; g->prev = -1; g->prev_expiry = 0; }
    if (g->prev >= 0 && !gate_live(g->prev_expiry, now)) { g->prev = -1; g->prev_expiry = 0; }
    if (g->chal_open && now - g->chal_at >= g->chal_w) gate_close_challenge(g);
}

// ---- MACs, shared with the authority service and the controllers ----
// The gate's tag on a challenge it announces. The challenge is a counter, so its next value is
// no secret: without this tag a controller could ask the authority for a token for a challenge
// the gate has not issued yet, keep it past its own revocation, and redeem it when the counter
// gets there. The authority must mint only for a challenge that carries this tag.
static inline void gate_chal_mac(const uint8_t key[32], uint32_t chal, uint8_t out[4]) {
    uint8_t m[5] = {'G'}, h[32];
    memcpy(m + 1, &chal, 4);
    gate_hmac(key, 32, m, sizeof m, h);
    memcpy(out, h, 4);
}
static inline void gate_token_mac(const uint8_t key[32], uint8_t origin, uint8_t flags, uint32_t chal, uint8_t out[8]) {
    uint8_t m[7] = {'T', origin, flags}, h[32];
    memcpy(m + 3, &chal, 4);
    gate_hmac(key, 32, m, sizeof m, h);
    memcpy(out, h, 8);
}
// The authority service gives this to the controller it grants; `chal` is the grant's challenge.
static inline void gate_session_key(const uint8_t key[32], uint8_t origin, uint32_t chal, uint8_t out[32]) {
    uint8_t m[6] = {'S', origin};
    memcpy(m + 2, &chal, 4);
    gate_hmac(key, 32, m, sizeof m, out);
}
// Command frame payload: 4 bytes of torque, then this 4-byte tag.
static inline void gate_cmd_mac(const uint8_t ks[32], uint32_t seq, const uint8_t torque[4], uint8_t out[4]) {
    uint8_t m[9] = {'C'}, h[32];
    memcpy(m + 1, &seq, 4);
    memcpy(m + 5, torque, 4);
    gate_hmac(ks, 32, m, sizeof m, h);
    memcpy(out, h, 4);
}

// ---- Lifecycle ----
// Boot or reset. `drive_node` is the id the drive answers to now; `reserved` are ids of other
// nodes on the downstream bus. Persistent fields are kept; nobody holds a lease after boot and
// no challenge is open, so a token issued before the reset cannot be redeemed.
static inline void gate_boot(gate* g, uint8_t drive_node, uint64_t reserved) {
    g->used |= reserved | (1ull << drive_node);
    g->node = drive_node;
    gate_close_challenge(g);
    gate_drop(g);
}

// After a verified flush nothing addressed to an old id can still arrive, so ids are free again.
static inline void gate_flush(gate* g, uint8_t drive_node, uint64_t reserved) {
    g->used = 0;
    gate_boot(g, drive_node, reserved);
}

// ---- Leases ----
// A verified grant for `origin` at gate time `now`; the lease runs for `T` ticks.
// Returns true when `rot` must be sent downstream (a holder change rotates the node id).
// With `overlap`, a confirmed holder whose lease is live keeps supporting the output until the
// new session is confirmed or that lease ends (make-before-break). The old lease is never
// extended, and both leases must be live. With no fresh id left the gate fails closed.
static inline bool gate_grant(gate* g, int origin, uint32_t now, uint32_t T, bool overlap, gate_frame* rot) {
    gate_tick(g, now);
    if (origin == g->holder) { g->lapsed = false; g->expiry = now + T; return false; }
    int old = overlap && g->holder >= 0 && !g->lapsed && g->confirmed ? g->holder : -1;
    uint32_t old_expiry = g->expiry;
    gate_drop(g);
    for (uint8_t id = 0; id < 64; ++id) {
        if (g->used & (1ull << id)) continue;
        uint32_t v = id;
        *rot = gate_mk(g->node, GATE_CMD_SET_NODE_ID, &v, 4);
        g->used |= 1ull << id;
        g->node = id;
        g->session++;
        g->holder = origin;
        g->expiry = now + T;
        g->prev = old;
        g->prev_expiry = old_expiry;
        return true;
    }
    return false;
}

// The challenge to announce: the outstanding one if it is still open, otherwise a fresh one,
// redeemable for `W` ticks. A request therefore cannot cancel a challenge somebody else is about
// to redeem. A fresh value must be covered by non-volatile storage before it is sent.
static inline uint32_t gate_challenge(gate* g, uint32_t now, uint32_t W) {
    gate_tick(g, now);
    if (g->chal_open) return g->chal;
    g->chal_at = now;
    g->chal_w = W;
    g->chal_open = true;
    return ++g->chal;
}

// Redeem a token. Accepted only for the open challenge, within its window, with a
// valid tag, and only once. On GATE_ROTATE send `rot` downstream after storing the new state.
// GATE_EXHAUSTED: the token was good but no fresh node id is left; nobody holds a lease now, and
// only a verified flush makes the gate usable again.
static inline int gate_token(gate* g, const uint8_t key[32], uint8_t origin, uint8_t flags, uint32_t chal,
                             const uint8_t mac[8], uint32_t now, uint32_t T, gate_frame* rot) {
    uint8_t want[8];
    gate_tick(g, now);
    if (!g->chal_open || chal != g->chal) return GATE_REJECT;
    gate_token_mac(key, origin, flags, chal, want);
    if (!gate_eq(mac, want, 8)) return GATE_REJECT;
    gate_close_challenge(g);
    if (!gate_grant(g, origin, now, T, flags & GATE_OVERLAP, rot)) return g->holder < 0 ? GATE_EXHAUSTED : GATE_RENEWED;
    gate_session_key(key, origin, chal, g->ks);
    g->seq = 0;
    g->bad = 0;
    return GATE_ROTATE;
}

// ---- Commands ----
// A command from `origin`. Returns true when `out` must be sent downstream. The session tag
// (node id + 1) and the value travel in one frame, so the drive installs both or neither.
static inline bool gate_forward(const gate* g, int origin, float torque, gate_frame* out) {
    if (origin != g->holder || g->holder < 0 || g->lapsed) return false;
    float pair[2] = {(float)(g->node + 1), torque};
    *out = gate_mk(g->node, GATE_CMD_SET_INPUT_VEL, pair, 8);
    return true;
}

// An authenticated command frame from upstream: d = torque (4 bytes) + tag (4 bytes). The sender
// is whoever holds the session key, not an id in the frame. Each sequence number is accepted
// once; up to GATE_SEQ_WINDOW - 1 lost frames are tolerated. After GATE_MAX_BAD failed tags the
// holder is dropped, which bounds forgery attempts per session (and lets an upstream attacker
// force a re-grant: availability, not safety).
static inline bool gate_command(gate* g, const uint8_t d[8], gate_frame* out) {
    uint8_t want[4];
    float torque;
    if (g->holder < 0) return false;
    for (uint32_t k = 0; k < GATE_SEQ_WINDOW; ++k) {
        gate_cmd_mac(g->ks, g->seq + k, d, want);
        if (!gate_eq(d + 4, want, 4)) continue;
        g->seq += k + 1;
        memcpy(&torque, d, 4);
        return gate_forward(g, g->holder, torque, out);
    }
    if (++g->bad >= GATE_MAX_BAD) gate_drop(g);
    return false;
}

// ---- Interlock ----
// `tag_ascii` is the drive's answer to `r axis0.controller.input_vel` over UART. Once the new
// session is confirmed the previous holder's lease no longer matters.
static inline void gate_readback(gate* g, const char* tag_ascii) {
    g->confirmed = g->holder >= 0 && strtof(tag_ascii, NULL) == (float)(g->node + 1);
    if (g->confirmed) { g->prev = -1; g->prev_expiry = 0; }
}

// Drives EN_GATE. False once the lease runs out, with no message needed.
static inline bool gate_lease_ok(gate* g, uint32_t now) {
    gate_tick(g, now);
    return g->holder >= 0 && !g->lapsed && (g->confirmed || g->prev >= 0);
}

// How long EN_GATE may stay high if the firmware never runs again: 0 = low now, otherwise the
// ticks left on the lease the output rests on. The board arms a hardware one-shot with it, so
// the finality bound does not depend on the main loop being alive.
static inline uint32_t gate_enable_for(gate* g, uint32_t now) {
    if (!gate_lease_ok(g, now)) return 0;
    uint32_t left = g->expiry - now;
    if (!g->confirmed && g->prev_expiry - now < left) left = g->prev_expiry - now;
    return left;
}
#endif
