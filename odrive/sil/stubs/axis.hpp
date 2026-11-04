// Minimal stand-in for ODrive's MotorControl/axis.hpp: only the members that
// communication/can/can_simple.cpp touches (ODrive 3a2e4dd1). Not ODrive code.
#pragma once
#include <cstdint>
#include <optional>
#include <utility>

#define AXIS_COUNT 2
#define GPIO_COUNT 8
#define MEASURE_TIME(x) if (true)

using float2D = std::pair<float, float>;

struct Source { std::optional<float> v; std::optional<float> any() const { return v; } };

struct Controller {
    enum ControlMode : int32_t { CONTROL_MODE_VOLTAGE_CONTROL = 0 };
    enum InputMode : int32_t { INPUT_MODE_INACTIVE = 0 };
    struct Config {
        ControlMode control_mode{}; InputMode input_mode{};
        float inertia = 0, pos_gain = 0, vel_gain = 0, vel_integrator_gain = 0, vel_limit = 0;
    } config_;
    uint32_t error_ = 0;
    float input_pos_ = 0, input_vel_ = 0, input_torque_ = 0;
    bool trajectory_done_ = false;
    Source pos_estimate_linear_src_, vel_estimate_src_;
    int mode_updates = 0, pos_updates = 0;
    mutable int anticogging_starts = 0;
    bool control_mode_updated() { ++mode_updates; return true; }
    void input_pos_updated() { ++pos_updates; }
    void set_input_pos_and_steps(float p) { input_pos_ = p; }
    void start_anticogging_calibration() const { ++anticogging_starts; }
};

struct Encoder {
    uint32_t error_ = 0;
    int32_t shadow_count_ = 0, count_in_cpr_ = 0, linear_count_ = 0;
    void set_linear_count(int32_t c) { linear_count_ = c; }
};

struct Motor {
    uint32_t error_ = 0;
    struct { float current_lim = 0; } config_;
    struct { std::optional<float2D> Idq_setpoint_; float Iq_measured_ = 0; } current_control_;
};

struct Sensorless {
    uint32_t error_ = 0;
    float pll_pos_ = 0;
    Source vel_estimate_;
};

struct Axis {
    enum Error : uint32_t { ERROR_NONE = 0, ERROR_ESTOP_REQUESTED = 0x00000800 };
    enum AxisState : int32_t { AXIS_STATE_UNDEFINED = 0, AXIS_STATE_IDLE = 1 };
    struct {
        struct {
            uint32_t node_id = 0; bool is_extended = false;
            uint32_t heartbeat_rate_ms = 0, encoder_rate_ms = 0, motor_error_rate_ms = 0,
                     encoder_error_rate_ms = 0, controller_error_rate_ms = 0,
                     sensorless_error_rate_ms = 0, encoder_count_rate_ms = 0, iq_rate_ms = 0,
                     sensorless_rate_ms = 0, bus_vi_rate_ms = 0;
        } can;
    } config_;
    struct {
        uint32_t last_heartbeat = 0, last_encoder = 0, last_motor_error = 0, last_encoder_error = 0,
                 last_controller_error = 0, last_sensorless_error = 0, last_encoder_count = 0,
                 last_iq = 0, last_sensorless = 0, last_bus_vi = 0;
    } can_;
    struct { uint32_t can_heartbeat = 0; } task_times_;
    struct { struct { float vel_limit = 0, accel_limit = 0, decel_limit = 0; } config_; } trap_traj_;
    uint32_t error_ = 0;
    AxisState current_state_ = AXIS_STATE_IDLE, requested_state_ = AXIS_STATE_UNDEFINED;
    Controller controller_;
    Encoder encoder_;
    Motor motor_;
    Sensorless sensorless_estimator_;
    int watchdog_feeds = 0;
    void watchdog_feed() { ++watchdog_feeds; }
};
