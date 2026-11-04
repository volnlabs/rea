// Minimal stand-in for ODrive's odrive_main.h, as used by can_simple.cpp. Not ODrive code.
#pragma once
#include <cstdint>
#include "axis.hpp"

extern Axis axes[AXIS_COUNT];
struct ODriveStub { int clear_errors_calls = 0; void clear_errors() { ++clear_errors_calls; } };
extern ODriveStub odrv;
extern float vbus_voltage, ibus_;
extern int nvic_resets;
inline void NVIC_SystemReset() { ++nvic_resets; }
uint32_t HAL_GetTick();
inline int get_gpio(int n) { return n; }
inline float get_adc_voltage(int) { return 0.0f; }
