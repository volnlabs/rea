// Gate firmware loop: glue between the board (gate_port.h) and the gate core (gate.h).
// Run in SIL against unmodified ODrive CAN code (../sil/test_fence.cpp, section FW), proved with
// CBMC (../sil/prove_fw.c), and run in emulation on the STM32F4 port (stm32/). Never on silicon.
// EN_GATE is re-armed on every poll for the time left on the lease (port_en_gate), so a hung
// loop cannot hold it high past the lease.
//
// Upstream CAN protocol (classic CAN, 11-bit ids):
//   0x010 CHAL_REQ  any -> gate   (empty)
//   0x011 CHAL      gate -> all   chal u32, tag[4]  (the open challenge, or a fresh one; the tag
//                                 proves to the authority that the gate issued it)
//   0x020 TOKEN1    any -> gate   origin u8, flags u8, chal u32
//   0x021 TOKEN2    any -> gate   tag[8]            (completes the last TOKEN1)
//   0x030 CMD       holder -> gate  torque f32, tag[4]
// Nothing upstream is trusted by id or position: tokens and commands are accepted on their tags.
#include "gate_port.h"

enum { UP_CHAL_REQ = 0x010, UP_CHAL = 0x011, UP_TOKEN1 = 0x020, UP_TOKEN2 = 0x021, UP_CMD = 0x030 };

// Calibration knobs. W and T enter the finality bound t_c + W + T + delta directly.
#ifndef GATE_W_MS
#define GATE_W_MS 50u     // challenge freshness window
#endif
#ifndef GATE_T_MS
#define GATE_T_MS 200u    // lease length
#endif
#ifndef GATE_CHAL_CHUNK
#define GATE_CHAL_CHUNK 1024u  // challenge values reserved per storage write (flash endurance)
#endif
#ifndef GATE_DRIVE_BOOT_ID
#define GATE_DRIVE_BOOT_ID 0   // the node id the drive has after a reset (its stored configuration)
#endif
#ifndef GATE_RESERVED_IDS
#define GATE_RESERVED_IDS 0ull // bit i set: node id i is never given to the drive (other nodes downstream)
#endif
#ifndef GATE_RB_MS
#define GATE_RB_MS 5u     // readback poll period
#endif

static gate g;
static bool ok;           // false: fail closed until the next reset
static uint32_t chal_top; // stored: no challenge above this has been sent. Boot resumes above it.
static uint8_t t1[6];
static bool have_t1;
static uint32_t last_rb;

const gate* gate_fw_state(void) { return &g; }

// State that must be durable before it takes effect. A failed write disables the gate.
// The challenge counter is stored as a reserved ceiling, not per challenge: at one challenge per
// renewal a per-challenge write would wear out flash within hours. A reset skips the unused part
// of the reservation, which keeps the counter monotonic.
static bool persist(void) {
    gate_nv nv = {g.session, g.used, chal_top, g.node};
    ok = ok && port_nv_store(&nv);
    return ok;
}

// Verified flush (C14): make every node id usable again. Order matters. The cleared id set is
// stored only after the downstream mailboxes are empty and the drive has been reset: stored
// first, a crash in between would leave a drive that still holds an old setpoint under an id the
// gate believes is fresh. A crash after the reset but before the write just repeats the flush.
static void flush(void) {
    port_en_gate(0);
    gate_drop(&g);
    if (!port_down_abort() || !port_drive_reset()) { ok = false; return; }
    gate_flush(&g, GATE_DRIVE_BOOT_ID, GATE_RESERVED_IDS);
    persist();
}

void gate_fw_init(void) {
    gate_nv nv;
    port_en_gate(0);
    memset(&g, 0, sizeof g);
    gate_drop(&g);
    have_t1 = false;
    memset(t1, 0, sizeof t1);
    ok = port_nv_load(&nv) && nv.node < 64;  // ODrive node ids are 6 bits
    if (!ok) return;
    g.session = nv.session;
    g.used = nv.used;
    g.chal = chal_top = nv.chal;
    gate_boot(&g, nv.node, GATE_RESERVED_IDS);
    last_rb = port_now();
}

void gate_fw_poll(void) {
    gate_frame f, out;
    char line[32];
    uint32_t now, c;
    uint8_t origin, flags, cf[8];
    int r;

    while (ok && port_up_recv(&f)) {
        // The clock is read per frame: a flood of frames can keep this loop running for long.
        // Expiry is latched first because gate_command has no clock of its own.
        now = port_now();
        gate_tick(&g, now);
        switch (f.id) {
        case UP_CHAL_REQ:
            c = gate_challenge(&g, now, GATE_W_MS);
            if (c > chal_top) {
                if (c > UINT32_MAX - GATE_CHAL_CHUNK) { ok = false; break; }   // counter spent: fail closed
                chal_top = c + GATE_CHAL_CHUNK - 1;
                if (!persist()) break;
            }
            memcpy(cf, &c, 4);
            gate_chal_mac(port_key(), c, cf + 4);
            out = gate_raw(UP_CHAL, cf, 8);
            port_up_send(&out);
            break;
        case UP_TOKEN1:
            have_t1 = f.len == 6;
            if (have_t1) memcpy(t1, f.data, 6);
            break;
        case UP_TOKEN2:
            if (!have_t1 || f.len != 8) break;
            have_t1 = false;
            memcpy(&c, t1 + 2, 4);
            origin = t1[0];
            flags = t1[1];
            memset(t1, 0, sizeof t1);
            // Store the new node id before the rotation leaves: after a crash in between, the
            // gate cannot reach the drive and stays disabled until a verified flush.
            r = gate_token(&g, port_key(), origin, flags, c, f.data, now, GATE_T_MS, &out);
            if (r == GATE_ROTATE && persist()) port_down_send(&out);
            // Out of node ids. Only an authentic token gets here, so nobody else can force a
            // drive reset. This token is spent; the next one finds a flushed gate.
            if (r == GATE_EXHAUSTED) flush();
            break;
        case UP_CMD:
            if (f.len == 8 && gate_command(&g, f.data, &out)) port_down_send(&out);
            break;
        }
    }
    if (port_uart_line(line, sizeof line)) gate_readback(&g, line);
    // The one-shot runs for the time left from this read; nothing slow sits between them.
    now = port_now();
    port_en_gate(ok ? gate_enable_for(&g, now) : 0);
    if (now - last_rb >= GATE_RB_MS) {
        port_uart_write("r axis0.controller.input_vel\n");
        last_rb = now;
    }
}
