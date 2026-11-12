// Gate core: the lease, fence and interlock logic of the final gate, with no HAL.
// Portable C (also valid C++). The same file is meant to be compiled into the gate MCU firmware
// and into the SIL test (../sil/test_fence.cpp, section X3).
//
// Mirrors FencedFinality.lean: switch -> fresh node id + unconfirmed; readback confirms the
// session; LEASE_OK = holder's lease live AND session confirmed. Revocation is non-renewal.
//
// Not here (obligations on the firmware around this core):
//  - token authentication and challenge freshness (C16): call gate_grant only after verifying;
//  - `session` and `used` must be stored non-volatile before LEASE_OK may rise (C24);
//  - gate_flush may be called only after a verified flush: TX abort + drive reset (C14);
//  - `now` must come from the gate's own monotonic clock.
// ponytail: single protected effect, no make-before-break (`prev`); add when handover overlap
// is measured on hardware.
#ifndef GATE_H
#define GATE_H
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum { GATE_CMD_SET_NODE_ID = 0x006, GATE_CMD_SET_INPUT_VEL = 0x00D };  // ODrive CANSimple

typedef struct { uint32_t id; uint8_t len; uint8_t data[8]; } gate_frame;

typedef struct {
    // Persistent: must survive a gate reset.
    uint32_t session;   // monotonic count of holder changes
    uint64_t used;      // node ids unusable until the next verified flush (bit i = id i)
    // Volatile: lost on reset, rebuilt by gate_boot.
    int holder;         // origin id of the current grant, -1 = none
    uint8_t node;       // the drive's current node id
    uint32_t expiry;    // gate tick at which the holder's lease ends
    bool confirmed;     // readback matched this session's tag
} gate;

static inline gate_frame gate_mk(uint8_t node, uint32_t cmd, const void* p, uint8_t n) {
    gate_frame f;
    memset(&f, 0, sizeof f);
    f.id = ((uint32_t)node << 5) | cmd;
    f.len = n;
    memcpy(f.data, p, n);
    return f;
}

// Boot or reset. `drive_node` is the id the drive answers to now; `reserved` are ids of other
// nodes on the downstream bus. Persistent fields are kept; nobody holds a lease after boot.
static inline void gate_boot(gate* g, uint8_t drive_node, uint64_t reserved) {
    g->used |= reserved | (1ull << drive_node);
    g->holder = -1;
    g->node = drive_node;
    g->expiry = 0;
    g->confirmed = false;
}

// After a verified flush nothing addressed to an old id can still arrive, so ids are free again.
static inline void gate_flush(gate* g, uint8_t drive_node, uint64_t reserved) {
    g->used = 0;
    gate_boot(g, drive_node, reserved);
}

// A verified token for `origin` arrived at gate time `now`; the lease runs for `T` ticks.
// Returns true when `rot` must be sent downstream (a holder change rotates the node id).
// With no fresh id left the gate fails closed until gate_flush.
static inline bool gate_grant(gate* g, int origin, uint32_t now, uint32_t T, gate_frame* rot) {
    if (origin == g->holder) { g->expiry = now + T; return false; }
    g->holder = -1;
    g->confirmed = false;
    for (uint8_t id = 0; id < 64; ++id) {
        if (g->used & (1ull << id)) continue;
        uint32_t v = id;
        *rot = gate_mk(g->node, GATE_CMD_SET_NODE_ID, &v, 4);
        g->used |= 1ull << id;
        g->node = id;
        g->session++;
        g->holder = origin;
        g->expiry = now + T;
        return true;
    }
    return false;
}

// A command from `origin` arrived upstream. Returns true when `out` must be sent downstream.
// The session tag (node id + 1) and the value travel in one frame, so the drive installs both
// or neither.
static inline bool gate_forward(const gate* g, int origin, float torque, gate_frame* out) {
    if (origin != g->holder || g->holder < 0) return false;
    float pair[2] = {(float)(g->node + 1), torque};
    *out = gate_mk(g->node, GATE_CMD_SET_INPUT_VEL, pair, 8);
    return true;
}

// `tag_ascii` is the drive's answer to `r axis0.controller.input_vel` over UART.
static inline void gate_readback(gate* g, const char* tag_ascii) {
    g->confirmed = g->holder >= 0 && strtof(tag_ascii, NULL) == (float)(g->node + 1);
}

// Drives EN_GATE. False once the lease runs out, with no message needed.
static inline bool gate_lease_ok(const gate* g, uint32_t now) {
    return g->holder >= 0 && g->confirmed && (int32_t)(g->expiry - now) > 0;
}
#endif
