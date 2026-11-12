// Gate firmware loop: glue between the board (gate_port.h) and the gate core (gate.h).
// Run in SIL against unmodified ODrive CAN code (../sil/test_fence.cpp, section FW). Never run
// on an MCU: the STM32 port does not exist yet, and nothing here is timing-verified.
//
// Upstream CAN protocol (classic CAN, 11-bit ids):
//   0x010 CHAL_REQ  any -> gate   (empty)
//   0x011 CHAL      gate -> all   chal u32
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
#ifndef GATE_RB_MS
#define GATE_RB_MS 5u     // readback poll period
#endif

static gate g;
static bool ok;           // false: fail closed until the next reset
static uint8_t t1[6];
static bool have_t1;
static uint32_t last_rb;

const gate* gate_fw_state(void) { return &g; }

// State that must be durable before it takes effect. A failed write disables the gate.
static bool persist(void) {
    gate_nv nv = {g.session, g.used, g.chal, g.node};
    ok = ok && port_nv_store(&nv);
    return ok;
}

void gate_fw_init(void) {
    gate_nv nv;
    port_en_gate(false);
    memset(&g, 0, sizeof g);
    gate_drop(&g);
    have_t1 = false;
    ok = port_nv_load(&nv);
    if (!ok) return;
    g.session = nv.session;
    g.used = nv.used;
    g.chal = nv.chal;
    gate_boot(&g, nv.node, 0);
    last_rb = port_now();
}

void gate_fw_poll(void) {
    gate_frame f, out;
    char line[32];
    uint32_t now = port_now(), c;

    while (ok && port_up_recv(&f)) {
        switch (f.id) {
        case UP_CHAL_REQ:
            c = gate_challenge(&g, now);
            if (persist()) { out = gate_raw(UP_CHAL, &c, 4); port_up_send(&out); }
            break;
        case UP_TOKEN1:
            have_t1 = f.len == 6;
            if (have_t1) memcpy(t1, f.data, 6);
            break;
        case UP_TOKEN2:
            if (!have_t1 || f.len != 8) break;
            have_t1 = false;
            memcpy(&c, t1 + 2, 4);
            // Store the new node id before the rotation leaves: after a crash in between, the
            // gate cannot reach the drive and stays disabled until a verified flush.
            if (gate_token(&g, port_key(), t1[0], t1[1], c, f.data, now, GATE_W_MS, GATE_T_MS, &out) == GATE_ROTATE &&
                persist())
                port_down_send(&out);
            break;
        case UP_CMD:
            if (f.len == 8 && gate_command(&g, f.data, &out)) port_down_send(&out);
            break;
        }
    }
    if (port_uart_line(line, sizeof line)) gate_readback(&g, line);
    if (now - last_rb >= GATE_RB_MS) {
        port_uart_write("r axis0.controller.input_vel\n");
        last_rb = now;
    }
    port_en_gate(ok && gate_lease_ok(&g, now));
}
