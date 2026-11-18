// Software-in-the-loop test of the node-id epoch fence against ODrive's real
// communication/can/can_simple.cpp (unmodified, commit 3a2e4dd1).
//
// The CAN controller is emulated: FakeBus applies each subscription's id/mask filter in
// software, standing in for the STM32 bxCAN filter banks. Timing, the hardware filter and
// reset behaviour are therefore NOT tested; only the firmware's dispatch semantics are.
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <variant>
#include <vector>
#include "can_simple.hpp"
#include "odrive_main.h"
#include "protocol.hpp"  // fibre-cpp: the to_string ODrive's ASCII `r` command uses
extern "C" {
#include "gate_port.h"
}

// Exactly what `r <float property>` returns: get_string -> to_string(value, buf, 10, 0)
// (ascii_protocol.cpp:356-357, introspection.hpp:167-168, protocol.hpp:189-191).
static std::string ascii_read(float v) {
    char buf[10];
    to_string(v, buf, sizeof(buf), 0);
    return buf;
}

Axis axes[AXIS_COUNT];
ODriveStub odrv;
float vbus_voltage = 0, ibus_ = 0;
int nvic_resets = 0;
static uint32_t tick = 0;
uint32_t HAL_GetTick() { return tick; }

struct FakeBus : CanBusBase {
    struct Sub { MsgIdFilterSpecs f; on_can_message_cb_t cb; void* ctx; bool live; };
    std::vector<Sub> subs;
    std::vector<can_Message_t> tx;
    CanSubscription tokens[16];
    bool send_message(const can_Message_t& m) override { tx.push_back(m); return true; }
    bool subscribe(const MsgIdFilterSpecs& f, on_can_message_cb_t cb, void* ctx, CanSubscription** h) override {
        subs.push_back({f, cb, ctx, true});
        *h = &tokens[subs.size() - 1];
        return true;
    }
    bool unsubscribe(CanSubscription* h) override { subs[h - tokens].live = false; return true; }
    void inject(const can_Message_t& m) {
        for (auto& s : subs) {
            if (!s.live) continue;
            bool ext = std::holds_alternative<uint32_t>(s.f.id);
            uint32_t id = ext ? std::get<uint32_t>(s.f.id) : std::get<uint16_t>(s.f.id);
            if (ext == m.isExt && (m.id & s.f.mask) == (id & s.f.mask)) s.cb(s.ctx, m);
        }
    }
};

static can_Message_t frame(uint32_t node, uint32_t cmd, const void* p = nullptr, size_t n = 0, bool ext = false) {
    can_Message_t m;
    m.id = (node << 5) | cmd;
    m.isExt = ext;
    if (p) std::memcpy(m.buf, p, n);
    return m;
}

static can_Message_t torque(uint32_t node, float v) { return frame(node, 0x00E, &v, 4); }

static int failures = 0;
static void check(bool ok, const char* what) {
    std::printf("%s  %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok) ++failures;
}

// Every field a CAN command could change, for "nothing happened" comparisons.
struct Snap {
    uint32_t node; bool ext; uint32_t err; int32_t req;
    float ip, iv, it, vl, cl, pg, vg, vig, in, tv, ta, td;
    int32_t cm, im, lin; int feeds, modes, poses, cog, clears, resets;
    bool operator==(const Snap& o) const { return std::memcmp(this, &o, sizeof(Snap)) == 0; }
};
static Snap snap(const Axis& a) {
    Snap s;
    std::memset(&s, 0, sizeof s);
    s = {a.config_.can.node_id, a.config_.can.is_extended, a.error_, a.requested_state_,
         a.controller_.input_pos_, a.controller_.input_vel_, a.controller_.input_torque_,
         a.controller_.config_.vel_limit, a.motor_.config_.current_lim, a.controller_.config_.pos_gain,
         a.controller_.config_.vel_gain, a.controller_.config_.vel_integrator_gain,
         a.controller_.config_.inertia, a.trap_traj_.config_.vel_limit, a.trap_traj_.config_.accel_limit,
         a.trap_traj_.config_.decel_limit, a.controller_.config_.control_mode,
         a.controller_.config_.input_mode, a.encoder_.linear_count_, a.watchdog_feeds,
         a.controller_.mode_updates, a.controller_.pos_updates, a.controller_.anticogging_starts,
         odrv.clear_errors_calls, nvic_resets};
    return s;
}

// Static storage, like the firmware's global CANSimple: its subscription_handles_ array is
// never initialised by the constructor and relies on zero-initialisation.
static FakeBus bus;
static CANSimple cs(&bus);

// ---- X3 in SIL: setpoint hijack, power-only gate versus the real gate core (gate/gate.h) ----
// A = retired controller (origin 0), B = new controller (origin 1). "Energized torque" is
// input_torque_ while the gate's enable is high. Not tested: timing, the EN_GATE wire, the motor.
static void down(const gate_frame& f) {
    can_Message_t m;
    m.id = f.id;
    m.isExt = false;
    std::memcpy(m.buf, f.data, f.len);
    bus.inject(m);
}
static void readback(gate& g) { gate_readback(&g, ascii_read(axes[0].controller_.input_vel_).c_str()); }

static void x3() {
    enum { A = 0, B = 1, T = 100 };
    float& tq = axes[0].controller_.input_torque_;
    const uint64_t other = 1ull << axes[1].config_.can.node_id;

    // P3a, power-only gate: A and B share the drive's bus; the gate only holds B's lease.
    axes[0].config_.can.node_id = 3;
    cs.service_stack();
    bus.inject(torque(3, 0.2f));        // epoch 0: A
    bool en = true;                     // cut: B is granted the lease, enable follows the lease
    check(en && tq == 0.2f, "X3a (expected hazard) power-only: A's persistent setpoint is energized under B's lease");
    bus.inject(torque(3, -0.1f));       // B
    bus.inject(torque(3, 0.3f));        // A, after the cut
    check(en && tq == 0.3f, "X3b (expected hazard) power-only: A's late frame replaces B's setpoint under B's lease");

    // P3b, full gate: sole bridge to the drive.
    gate g;
    std::memset(&g, 0, sizeof g);
    gate_boot(&g, 3, other);
    gate_frame f, stuck;
    check(!gate_lease_ok(&g, 0), "X3c gate boots with no lease");

    check(gate_grant(&g, A, 0, T, false, &f), "X3d grant to A rotates the node id");
    down(f);
    cs.service_stack();
    gate_forward(&g, A, 0.2f, &f);
    down(f);
    readback(g);
    check(gate_lease_ok(&g, 1) && tq == 0.2f, "X3e A confirmed by readback: enabled, torque is A's");
    gate_forward(&g, A, 0.3f, &stuck);  // X3-stuck: held in the gate's TX mailbox, not sent yet

    uint8_t a_node = g.node;
    check(gate_grant(&g, B, 10, T, false, &f) && g.node != a_node, "X3f cut: grant to B rotates to a fresh id");
    down(f);
    readback(g);
    check(tq == 0.2f && !gate_lease_ok(&g, 11),
          "X3g drive still holds A's setpoint, and the gate keeps enable low under B's lease");

    gate_forward(&g, B, -0.1f, &f);
    down(f);                            // lost: the drive has not renewed its filter yet
    readback(g);
    check(tq == 0.2f && !gate_lease_ok(&g, 12), "X3h B's frame lost downstream: readback fails, enable stays low");

    cs.service_stack();
    down(f);                            // resend
    readback(g);
    check(tq == -0.1f && gate_lease_ok(&g, 13), "X3i B's frame installed and read back: enabled, torque is B's");

    check(!gate_forward(&g, A, 0.3f, &f), "X3j gate drops A's command after the cut");
    Snap before = snap(axes[0]);
    down(stuck);                        // the held A frame leaves the mailbox now
    readback(g);
    check(snap(axes[0]) == before && gate_lease_ok(&g, 14),
          "X3k stuck A frame released after confirmation is ignored by the drive (old id)");

    check(gate_lease_ok(&g, 10 + T - 1) && !gate_lease_ok(&g, 10 + T),
          "X3l no renewal: enable drops at lease expiry with no message to the gate");

    // Gate reset: volatile state lost, persistent counters kept.
    uint32_t sess = g.session;
    uint64_t used = g.used;
    gate_boot(&g, g.node, other);
    check(!gate_lease_ok(&g, 15) && g.session == sess && g.used == used,
          "X3m gate reset: no lease, session counter and used ids kept");

    // Finite ids: keep switching until none is fresh. The gate must fail closed, not reuse.
    int switches = 0;
    while (switches < 100 && gate_grant(&g, switches % 2, 20, T, false, &f)) {
        down(f);
        cs.service_stack();
        ++switches;
    }
    readback(g);
    check(switches > 0 && switches < 64 && g.holder < 0 && !gate_lease_ok(&g, 21) && !gate_forward(&g, A, 0.5f, &f),
          "X3n fresh ids exhausted: gate fails closed until a verified flush");
    gate_flush(&g, g.node, other);
    check(gate_grant(&g, B, 30, T, false, &f), "X3o after a verified flush a grant is possible again");
}

// ---- MAC primitives (gate/gate_mac.h) ----
static std::string hex(const uint8_t* p, size_t n) {
    std::string s;
    char b[3];
    for (size_t i = 0; i < n; ++i) { std::snprintf(b, sizeof b, "%02x", p[i]); s += b; }
    return s;
}
static void mac_vectors() {
    uint8_t h[32];
    gate_sha256((const uint8_t*)"abc", 3, h);
    check(hex(h, 32) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "M1 SHA-256(\"abc\") matches FIPS 180-4");
    gate_hmac((const uint8_t*)"Jefe", 4, (const uint8_t*)"what do ya want for nothing?", 28, h);
    check(hex(h, 32) == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", "M2 HMAC-SHA-256 matches RFC 4231 case 2");
}

static const uint8_t KEY[32] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32};

// A controller holding a session key, as the authority service would hand it out.
struct Ctl {
    uint8_t ks[32];
    uint32_t seq = 0;
    Ctl(uint8_t origin, uint32_t chal) { gate_session_key(KEY, origin, chal, ks); }
    gate_frame cmd(float t) {
        uint8_t d[8];
        std::memcpy(d, &t, 4);
        gate_cmd_mac(ks, seq++, d, d + 4);
        return gate_raw(0x030, d, 8);
    }
};

// ---- Tokens and authenticated commands (gate core) ----
static void tokens() {
    enum { A = 0, B = 1, W = 50, T = 100 };
    const uint64_t other = 1ull << axes[1].config_.can.node_id;
    gate g;
    std::memset(&g, 0, sizeof g);
    gate_boot(&g, axes[0].config_.can.node_id, other);
    gate_frame f;
    uint8_t mac[8], bad[8];

    // Vectors produced by Python's hmac (gate/authority.py): both sides agree on layout and byte order.
    uint8_t vt[8], vk[32], vc[8];
    const float quarter = 0.25f;
    gate_token_mac(KEY, 1, GATE_OVERLAP, 0x01020304, vt);
    gate_session_key(KEY, 1, 0x01020304, vk);
    std::memcpy(vc, &quarter, 4);
    gate_cmd_mac(vk, 5, vc, vc + 4);
    uint8_t vg[4];
    gate_chal_mac(KEY, 0x01020304, vg);
    check(hex(vt, 8) == "df76ba38f2d3efbb" && hex(vk, 32) == "449f553da026f01fab96eb03a9b4ffef243dfb6fd51a328e0f6b528d1708e50d" &&
          hex(vc, 8) == "0000803eeffe5bc6" && hex(vg, 4) == "e5981d30",
          "M3 token tag, session key, command tag and challenge tag match gate/authority.py");

    gate_token_mac(KEY, A, 0, 1, mac);
    check(gate_token(&g, KEY, A, 0, 1, mac, 0, T, &f) == GATE_REJECT, "T1 token with no open challenge rejected");

    uint32_t c = gate_challenge(&g, 0, W);
    gate_token_mac(KEY, A, 0, c + 1, mac);
    check(gate_token(&g, KEY, A, 0, c + 1, mac, 1, T, &f) == GATE_REJECT, "T2 token for a different challenge rejected");
    gate_token_mac(KEY, A, 0, c, mac);
    std::memcpy(bad, mac, 8);
    bad[7] ^= 1;
    check(gate_token(&g, KEY, A, 0, c, bad, 1, T, &f) == GATE_REJECT, "T3 token with a wrong tag rejected");
    check(gate_token(&g, KEY, A, GATE_OVERLAP, c, mac, 1, T, &f) == GATE_REJECT, "T4 token with a changed flag rejected");
    check(gate_token(&g, KEY, A, 0, c, mac, W, T, &f) == GATE_REJECT, "T5 token at the end of the window W rejected");
    c = gate_challenge(&g, 51, W);
    gate_token_mac(KEY, A, 0, c, mac);
    check(gate_token(&g, KEY, A, 0, c, mac, 51 + W - 1, T, &f) == GATE_ROTATE, "T6 valid token inside W accepted");
    down(f);
    cs.service_stack();
    check(gate_token(&g, KEY, A, 0, c, mac, 51 + W - 1, T, &f) == GATE_REJECT, "T7 the same token a second time rejected");

    c = gate_challenge(&g, 110, W);
    gate_token_mac(KEY, A, 0, c, mac);
    uint32_t sess = g.session;
    check(gate_token(&g, KEY, A, 0, c, mac, 111, T, &f) == GATE_RENEWED && g.session == sess && g.expiry == 111 + T,
          "T8 renewal by the holder extends the lease without rotating");

    c = gate_challenge(&g, 120, W);
    gate_token_mac(KEY, B, 0, c, mac);
    gate_boot(&g, g.node, other);
    // The gate clock restarts at reset, so "now" is small again and the window check alone would pass.
    check(gate_token(&g, KEY, B, 0, c, mac, 1, T, &f) == GATE_REJECT, "T9 a challenge issued before a gate reset cannot be redeemed");

    // Commands.
    float& tq = axes[0].controller_.input_torque_;
    c = gate_challenge(&g, 80, W);
    gate_token_mac(KEY, A, 0, c, mac);
    gate_token(&g, KEY, A, 0, c, mac, 81, T, &f);
    down(f);
    cs.service_stack();
    Ctl a(A, c);
    gate_frame c0 = a.cmd(0.25f);
    check(gate_command(&g, c0.data, &f), "C1 command with a valid tag forwarded");
    down(f);
    check(tq == 0.25f, "C1b and installed by the drive");
    check(!gate_command(&g, c0.data, &f), "C2 the same command frame replayed is rejected");
    a.seq += GATE_SEQ_WINDOW - 1;
    gate_frame c1 = a.cmd(0.5f);
    check(gate_command(&g, c1.data, &f), "C3 command after 7 lost frames accepted");
    a.seq += GATE_SEQ_WINDOW;
    gate_frame c2 = a.cmd(0.75f);
    check(!gate_command(&g, c2.data, &f), "C4 command 8 frames ahead rejected");
    Ctl wrong(B, c);
    gate_frame c3 = wrong.cmd(0.9f);
    check(!gate_command(&g, c3.data, &f), "C5 command under another origin's session key rejected");
    readback(g);
    bool was_ok = gate_lease_ok(&g, 82);
    for (int i = 0; i < GATE_MAX_BAD; ++i) gate_command(&g, c3.data, &f);
    check(was_ok && g.holder < 0 && !gate_lease_ok(&g, 82), "C6 failed-tag budget spent: holder dropped, enable low");
}

// ---- Make-before-break handover (gate core) ----
static void handover() {
    enum { A = 0, B = 1, T = 100 };
    const uint64_t other = 1ull << axes[1].config_.can.node_id;
    float& tq = axes[0].controller_.input_torque_;
    gate_frame f;
    auto a_confirmed = [&](bool confirm) {  // A granted at 0, lease to 100, commanding 0.2
        gate g;
        std::memset(&g, 0, sizeof g);
        gate_boot(&g, axes[0].config_.can.node_id, other);
        gate_grant(&g, A, 0, T, false, &f);
        down(f);
        cs.service_stack();
        gate_forward(&g, A, 0.2f, &f);
        down(f);
        if (confirm) readback(g);
        return g;
    };

    gate g = a_confirmed(true);
    gate_grant(&g, B, 40, T, true, &f);
    down(f);
    cs.service_stack();
    readback(g);
    bool on = true;
    bool armed = gate_enable_for(&g, 40) == 60;   // A's lease ends at 100, B's at 140: the earlier one
    for (uint32_t t = 40; t < 100; ++t) on = on && gate_lease_ok(&g, t);
    check(on && armed && tq == 0.2f && !g.confirmed, "H1 overlap: enable stays high on A's live lease while B is unconfirmed");
    check(!gate_forward(&g, A, 0.9f, &f), "H2 A's commands are not forwarded during the overlap");
    check(!gate_lease_ok(&g, 100), "H3 A's lease ends before B confirms: enable drops");

    g = a_confirmed(true);
    gate_grant(&g, B, 40, T, true, &f);
    down(f);
    cs.service_stack();
    gate_forward(&g, B, -0.1f, &f);
    down(f);
    on = gate_lease_ok(&g, 59);
    readback(g);
    on = on && g.prev < 0 && gate_enable_for(&g, 60) == 80;  // confirmation ends the overlap at once
    for (uint32_t t = 60; t < 140; ++t) on = on && gate_lease_ok(&g, t);
    check(on && tq == -0.1f && !gate_lease_ok(&g, 140),
          "H4 B confirms during the overlap: no gap, then enable follows B's lease alone");

    g = a_confirmed(true);
    gate_grant(&g, B, 40, 10, true, &f);
    down(f);
    cs.service_stack();
    check(gate_lease_ok(&g, 49) && !gate_lease_ok(&g, 50), "H5 both leases needed: B's lease ends while A's is live, enable drops");

    g = a_confirmed(false);
    gate_grant(&g, B, 40, T, true, &f);
    down(f);
    cs.service_stack();
    check(!gate_lease_ok(&g, 41), "H6 no overlap from an unconfirmed holder");

    g = a_confirmed(true);
    gate_grant(&g, B, 100, T, true, &f);
    down(f);
    cs.service_stack();
    check(g.prev < 0 && !gate_lease_ok(&g, 101), "H7 no overlap from a holder whose lease has ended");

    g = a_confirmed(true);
    gate_grant(&g, B, 40, T, false, &f);
    down(f);
    cs.service_stack();
    check(!gate_lease_ok(&g, 41), "H8 without the overlap flag a switch drops enable (revocation)");
}

// ---- 32-bit clock wrap (gate core) ----
// Found by review, not by the tests above: before gate_tick, an expired lease compared as live
// again 2^31 ticks later, and an unused challenge reopened 2^32 ticks later.
static void wrap() {
    enum { A = 0, B = 1, W = 50, T = 100 };
    const uint64_t other = 1ull << axes[1].config_.can.node_id;
    const uint32_t half = 0x80000000u;
    gate_frame f;
    uint8_t mac[8];
    auto fresh = [&](uint32_t t0) {  // A granted at t0, commanding, confirmed
        gate g;
        std::memset(&g, 0, sizeof g);
        gate_boot(&g, axes[0].config_.can.node_id, other);
        gate_grant(&g, A, t0, T, false, &f);
        down(f);
        cs.service_stack();
        gate_forward(&g, A, 0.2f, &f);
        down(f);
        readback(g);
        return g;
    };

    gate g = fresh(0);
    bool off = !gate_lease_ok(&g, T);
    for (uint32_t t = half; t < half + 2 * T; ++t) off = off && !gate_lease_ok(&g, t);
    check(off && g.lapsed, "W1 an expired lease stays dead 2^31 ticks later");

    g = fresh(0xFFFFFFF0u);
    bool on = true;
    for (uint32_t i = 0; i < T; ++i) on = on && gate_lease_ok(&g, 0xFFFFFFF0u + i);
    check(on && !gate_lease_ok(&g, 0xFFFFFFF0u + T), "W2 a lease that spans the wrap runs its exact length");

    g = fresh(0);
    uint32_t c = gate_challenge(&g, 10, W);
    gate_token_mac(KEY, B, 0, c, mac);
    gate_lease_ok(&g, 10 + W);          // the firmware loop observes the window closing
    check(gate_token(&g, KEY, B, 0, c, mac, 20 /* 2^32 ticks later */, T, &f) == GATE_REJECT,
          "W3 an unused challenge stays dead when the clock comes round again");

    g = fresh(0);
    gate_grant(&g, B, 40, T, true, &f);  // overlap; B never confirms but keeps renewing
    down(f);
    cs.service_stack();
    off = true;
    for (uint32_t t = 90; t < half + 200; t += 50) {
        gate_grant(&g, B, t, T, true, &f);
        if (t >= T) off = off && !gate_lease_ok(&g, t);
    }
    check(off && g.prev < 0 && g.holder == B, "W4 an ended previous lease never supports the output again");
}

// ---- Firmware loop (gate/gate_fw.c) on a host port ----
static uint32_t p_now;
static std::deque<gate_frame> p_up;
static std::vector<gate_frame> p_up_tx;
static std::string p_line;
static bool p_have_line, p_en, p_nv_have, p_nv_ok = true;
static uint32_t p_en_until;   // the one-shot's deadline, for the stalled-firmware check
static gate_nv p_nv;
static uint32_t p_nv_writes, p_flushes;
static bool p_abort_ok = true;
extern "C" {
uint32_t port_now(void) { return p_now; }
bool port_up_recv(gate_frame* f) {
    if (p_up.empty()) return false;
    *f = p_up.front();
    p_up.pop_front();
    return true;
}
void port_up_send(const gate_frame* f) { p_up_tx.push_back(*f); }
void port_down_send(const gate_frame* f) { down(*f); }
void port_uart_write(const char*) { p_line = ascii_read(axes[0].controller_.input_vel_); p_have_line = true; }
bool port_uart_line(char* buf, int n) {
    if (!p_have_line) return false;
    std::snprintf(buf, n, "%s", p_line.c_str());
    p_have_line = false;
    return true;
}
void port_en_gate(uint32_t ms) { p_en = ms > 0; p_en_until = p_now + ms; }
bool port_nv_load(gate_nv* nv) { if (p_nv_have) *nv = p_nv; return p_nv_have; }
bool port_nv_store(const gate_nv* nv) { if (p_nv_ok) { p_nv = *nv; ++p_nv_writes; } return p_nv_ok; }
const uint8_t* port_key(void) { return KEY; }
bool port_down_abort(void) { return p_abort_ok; }
bool port_drive_reset(void) {   // a reset drive: boot node id (run.sh: GATE_DRIVE_BOOT_ID=3), no setpoint
    axes[0].config_.can.node_id = 3;
    axes[0].controller_.input_vel_ = axes[0].controller_.input_torque_ = 0.0f;
    cs.service_stack();
    p_have_line = false;
    ++p_flushes;
    return true;
}
}
static void fw_run(uint32_t ms) {
    for (uint32_t i = 0; i < ms; ++i) { ++p_now; cs.service_stack(); gate_fw_poll(); }
}
static bool fw_chal(uint32_t* c) {
    p_up_tx.clear();
    p_up.push_back(gate_raw(0x010, "", 0));
    gate_fw_poll();
    if (p_up_tx.empty()) return false;
    std::memcpy(c, p_up_tx.back().data, 4);
    uint8_t want[4];   // the authority's check: it mints only for a challenge the gate tagged
    gate_chal_mac(KEY, *c, want);
    return p_up_tx.back().len == 8 && !std::memcmp(p_up_tx.back().data + 4, want, 4);
}
static void fw_token(uint8_t origin, uint8_t flags, uint32_t c, const uint8_t* key = KEY) {
    uint8_t a[6] = {origin, flags}, mac[8];
    std::memcpy(a + 2, &c, 4);
    gate_token_mac(key, origin, flags, c, mac);
    p_up.push_back(gate_raw(0x020, a, 6));
    p_up.push_back(gate_raw(0x021, mac, 8));
    gate_fw_poll();
}

static void firmware() {
    enum { A = 0, B = 1, W_MS = 50, T_MS = 200 };  // gate_fw.c defaults
    float& tq = axes[0].controller_.input_torque_;
    const gate* g = gate_fw_state();
    uint32_t c = 0, c2 = 0;
    uint8_t wrong[32] = {0};

    gate_fw_init();
    check(!fw_chal(&c) && !p_en, "FW0 unprovisioned gate (no stored state) stays disabled and issues nothing");

    p_nv = {0, 1ull << axes[1].config_.can.node_id, 0, (uint8_t)axes[0].config_.can.node_id};
    p_nv_have = true;
    p_now = 1000;
    gate_fw_init();

    check(fw_chal(&c) && p_nv.chal >= c, "FW1 challenge carries the gate's tag and is covered by stored state before it is sent");
    uint32_t again = 0;
    check(fw_chal(&again) && again == c, "FW1a a second request re-announces the open challenge: it cannot cancel it");
    fw_token(B, 0, c, wrong);
    check(g->holder < 0, "FW2 token under the wrong key rejected");
    fw_token(A, 0, c);
    check(g->holder == A && p_nv.node == g->node && p_nv.session == g->session, "FW3 valid token accepted; new node id and session stored");
    Ctl a(A, c);
    fw_run(1);
    p_up.push_back(a.cmd(0.2f));
    fw_run(12);
    check(p_en && tq == 0.2f, "FW4 A's authenticated command installed and read back over UART: EN_GATE high");
    uint32_t sess = g->session;
    fw_token(A, 0, c);
    fw_token(B, 0, c);
    check(g->session == sess && g->holder == A, "FW5 used challenge cannot be redeemed again, by A or for B");

    fw_chal(&c2);
    fw_token(B, 0, c2);
    fw_run(12);
    check(g->holder == B && !p_en && tq == 0.2f, "FW6 cut: drive still holds A's setpoint, EN_GATE low under B's lease");
    p_up.push_back(a.cmd(0.3f));
    fw_run(12);
    check(!p_en && tq == 0.2f, "FW7 A's command under its old session key is not forwarded");
    Ctl b(B, c2);
    p_up.push_back(b.cmd(-0.1f));
    fw_run(12);
    check(p_en && tq == -0.1f, "FW8 B's command installed and read back: EN_GATE high, torque is B's");
    check(p_en_until == p_now + (g->expiry - p_now) && g->expiry - p_now <= T_MS,
          "FW8a EN_GATE one-shot is armed for exactly the time left on the lease (a hung loop cannot hold it)");

    fw_run(T_MS / 2);
    fw_chal(&c);
    fw_token(B, 0, c);
    fw_run(T_MS - 1);
    check(p_en && g->session == sess + 1, "FW8b renewal inside the lease: EN_GATE stays high past the first expiry, no rotation");
    fw_run(T_MS);
    check(!p_en && g->lapsed, "FW9 no renewal: EN_GATE low after the lease, with no message to the gate");
    p_up.push_back(b.cmd(-0.3f));
    fw_run(12);
    check(!p_en && tq == -0.1f, "FW9a a lapsed holder's commands are not forwarded");
    fw_chal(&c);
    fw_token(B, 0, c);
    fw_run(1);
    check(p_en && g->session == sess + 1, "FW10 new token for the lapsed holder: EN_GATE high again, same session, no rotation");

    fw_chal(&c);
    uint32_t expiry = g->expiry;
    fw_run(W_MS);
    fw_token(B, 0, c);
    check(g->expiry == expiry, "FW11 token redeemed after the window W is rejected");

    fw_chal(&c);
    uint32_t chal = g->chal, writes = p_nv_writes;
    for (int i = 0; i < 20; ++i) { fw_run(W_MS); fw_chal(&c2); }
    check(c2 == chal + 20 && p_nv_writes == writes, "FW11a 20 more challenges cost no storage write (reserved ahead)");
    fw_chal(&c);
    gate_fw_init();
    fw_token(B, 0, c);
    check(!p_en && g->holder < 0 && g->chal >= c && g->session == sess + 1 && g->node == p_nv.node,
          "FW12 gate reset: no lease, counters and node id reloaded, pre-reset challenge dead");
    check(fw_chal(&c2) && c2 > c, "FW12a challenges after a reset are above every challenge sent before it");
    fw_run(W_MS);

    p_nv_ok = false;
    bool none = true;
    for (int i = 0; i < 1100 && none; ++i) { fw_run(W_MS); none = !fw_chal(&c) || c <= p_nv.chal; }
    check(none && !fw_chal(&c), "FW13 storage write fails: no challenge above the stored reservation is ever sent");
    p_nv_ok = true;
    fw_run(1);
    check(!fw_chal(&c) && !p_en, "FW14 after a failed write the gate stays disabled until reset");

    // Verified flush: use up the node ids with handovers, and keep going.
    gate_fw_init();
    uint32_t flushes = p_flushes;
    int grants = 0;
    bool off_at_flush = true;
    uint8_t o = A;
    for (int i = 0; i < 80; ++i) {
        o = i & 1;
        fw_run(W_MS);
        if (!fw_chal(&c)) break;
        uint32_t was = p_flushes;
        fw_token(o, 0, c);
        if (p_flushes != was) off_at_flush = off_at_flush && !p_en && g->holder < 0 && tq == 0.0f && p_nv.node == 3 && g->node == 3;
        else if (g->holder == o) ++grants;
    }
    check(p_flushes == flushes + 1 && grants == 79, "FW15 80 handovers: one flush when the node ids ran out, every other token granted");
    check(off_at_flush, "FW16 at the flush: EN_GATE low, no holder, drive reset to its boot id, cleared id set stored");
    Ctl last(o, c);
    p_up.push_back(last.cmd(0.4f));
    fw_run(12);
    check(p_en && tq == 0.4f, "FW17 after the flush the gate reaches the drive again: command installed, read back, EN_GATE high");

    p_abort_ok = false;
    flushes = p_flushes;
    for (int i = 0; i < 80; ++i) {
        fw_run(W_MS);
        if (!fw_chal(&c)) break;
        fw_token(i & 1, 0, c);
    }
    check(p_flushes == flushes && p_nv.used == ~0ull && !p_en && !fw_chal(&c),
          "FW18 TX abort not confirmed: no drive reset, stored id set still full, gate disabled");
    p_abort_ok = true;
}

int main() {
    axes[0].config_.can.node_id = 3;
    axes[1].config_.can.node_id = 40;
    check(cs.init(), "init subscribes both axes");

    bus.inject(torque(3, 0.5f));
    check(axes[0].controller_.input_torque_ == 0.5f, "F1 frame to current id 3 is installed");

    // CAN rotation 3 -> 5, addressed to the current id.
    uint32_t five = 5;
    bus.inject(frame(3, 0x006, &five, 4));
    check(axes[0].config_.can.node_id == 5, "F2 SET_AXIS_NODE_ID takes effect immediately");

    bus.inject(torque(3, 0.7f));
    check(axes[0].controller_.input_torque_ == 0.5f, "F3a stale frame to old id 3 ignored before filter renewal");
    bus.inject(torque(5, 0.9f));
    check(axes[0].controller_.input_torque_ == 0.5f,
          "F3b frame to new id 5 dropped before filter renewal (availability window)");

    cs.service_stack();
    bus.inject(torque(5, 0.9f));
    check(axes[0].controller_.input_torque_ == 0.9f, "F4a frame to new id 5 installed after service_stack()");
    bus.inject(torque(3, 0.1f));
    check(axes[0].controller_.input_torque_ == 0.9f, "F4b stale frame to old id 3 ignored after renewal");

    // Every command id (0..31), with a nonzero payload, to the old id: nothing may change,
    // including watchdog feeding, reset, e-stop, clear-errors, limits, modes and a stale rotation.
    uint8_t pay[8] = {0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x08};
    Snap before = snap(axes[0]);
    size_t tx_before = bus.tx.size();
    for (uint32_t cmd = 0; cmd < 32; ++cmd) {
        bus.inject(frame(3, cmd, pay, 8));
        can_Message_t r = frame(3, cmd); r.rtr = true; r.len = 0;
        bus.inject(r);
    }
    check(snap(axes[0]) == before, "F5 all 32 command ids to the old id leave all axis-0 state unchanged");
    check(bus.tx.size() == tx_before, "F5b no replies sent for old-id requests");

    // A frame with matching numeric id but the wrong frame format is ignored.
    can_Message_t extf = torque(5, 0.3f); extf.isExt = true;
    bus.inject(extf);
    check(axes[0].controller_.input_torque_ == 0.9f, "F6 extended-format frame to id 5 ignored (is_extended=false)");

    // UART-style rotation: direct config write, as `w axis0.config.can.node_id 7` would do.
    axes[0].config_.can.node_id = 7;
    bus.inject(torque(5, 0.2f));
    check(axes[0].controller_.input_torque_ == 0.9f, "F7a after direct (UART) rotation, old id 5 ignored immediately");

    // Same sweep inside the renewal window: the filter still admits old id 5, so only the
    // firmware's dispatch check (can_simple.cpp:51) stands between stale frames and the axis.
    Snap win = snap(axes[0]);
    size_t tx_win = bus.tx.size();
    for (uint32_t cmd = 0; cmd < 32; ++cmd) {
        bus.inject(frame(5, cmd, pay, 8));
        can_Message_t r = frame(5, cmd); r.rtr = true; r.len = 0;
        bus.inject(r);
    }
    check(snap(axes[0]) == win && bus.tx.size() == tx_win,
          "F5w all 32 command ids to the old id inside the renewal window leave state unchanged");
    cs.service_stack();
    bus.inject(torque(7, 0.4f));
    check(axes[0].controller_.input_torque_ == 0.4f, "F7b new id 7 installed after renewal");

    // Axis isolation: frames for axis 1's id do not touch axis 0.
    Snap a0 = snap(axes[0]);
    bus.inject(torque(40, 0.6f));
    check(axes[1].controller_.input_torque_ == 0.6f && snap(axes[0]) == a0, "F8 axis-1 id affects only axis 1");

    // Finite-id reuse hazard: rotate back to a previously used id (3). A frame addressed to 3
    // that was delayed since epoch 0 is accepted again: the fence gives no protection on reuse.
    axes[0].config_.can.node_id = 3;
    cs.service_stack();
    bus.inject(torque(3, 0.7f));
    check(axes[0].controller_.input_torque_ == 0.7f,
          "F9 (expected hazard) after reusing id 3, a stale epoch-0 frame to id 3 is installed");

    // ---- Session-tagged readback (FencedFinality's readback obligation) ----
    // R1: a session tag in the low mantissa bits cannot be read back over ASCII.
    float base = 0.37f, lsb = std::nextafter(base, 1.0f);
    check(ascii_read(base) == ascii_read(lsb), "R1 low-mantissa tag invisible: adjacent floats read back identically");

    // R2: a decimal tag in the 1e-6 digit is lost once the magnitude needs more characters.
    check(ascii_read(0.123456f) != ascii_read(0.123457f), "R2a below 10 the 1e-6 digit is visible");
    check(ascii_read(-123.456701f) == ascii_read(-123.456702f),
          "R2b decimal tag lost at |value| >= 100: readback truncated to 9 characters");

    // R3: paired tag. SET_INPUT_VEL writes input_vel_ (tag) and input_torque_ (value) in one
    // callback. Tag = session node id + 1. Session node id 9, tag 10.
    axes[0].config_.can.node_id = 9;
    cs.service_stack();
    float pair[2] = {10.0f, 0.37f};
    bus.inject(frame(9, 0x00D, pair, 8));
    std::string tag = ascii_read(axes[0].controller_.input_vel_);
    check(axes[0].controller_.input_torque_ == 0.37f && tag == "10.000000" && std::atof(tag.c_str()) == 10.0f,
          "R3 SET_INPUT_VEL installs (tag, value) atomically; ASCII readback recovers tag 10 exactly");

    // A stale frame from an earlier session (old id 7, tag 8) cannot overwrite the tag.
    float stale[2] = {8.0f, 0.99f};
    bus.inject(frame(7, 0x00D, stale, 8));
    check(ascii_read(axes[0].controller_.input_vel_) == "10.000000" && axes[0].controller_.input_torque_ == 0.37f,
          "R3b stale old-session frame to old id leaves tag and value unchanged");

    // R4: every possible tag (node id 0..63 -> tag 1..64) reads back distinctly and exactly.
    bool tags_ok = true;
    for (int id = 0; id < 64; ++id) {
        float t = float(id + 1);
        std::string s = ascii_read(t);
        if (std::atof(s.c_str()) != t) tags_ok = false;
        if (id > 0 && s == ascii_read(float(id))) tags_ok = false;
    }
    check(tags_ok, "R4 all 64 tags (node id + 1) round-trip exactly through the 10-char ASCII readback");

    x3();
    mac_vectors();
    tokens();
    handover();
    wrap();
    firmware();

    std::printf("%s: %d failure(s)\n", failures ? "FAILED" : "ALL CHECKS AS EXPECTED", failures);
    return failures ? 1 : 0;
}
