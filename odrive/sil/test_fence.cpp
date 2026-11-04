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
#include <string>
#include <variant>
#include <vector>
#include "can_simple.hpp"
#include "odrive_main.h"
#include "protocol.hpp"  // fibre-cpp: the to_string ODrive's ASCII `r` command uses

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

    std::printf("%s: %d failure(s)\n", failures ? "FAILED" : "ALL CHECKS AS EXPECTED", failures);
    return failures ? 1 : 0;
}
