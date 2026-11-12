// What the gate firmware loop (gate_fw.c) needs from the board. One implementation exists: the
// host port inside ../sil/test_fence.cpp. The STM32 port is not written.
#ifndef GATE_PORT_H
#define GATE_PORT_H
#include "gate.h"

typedef struct { uint32_t session; uint64_t used; uint32_t chal; uint8_t node; } gate_nv;

uint32_t port_now(void);                          // ms, the gate's own monotonic clock
bool port_up_recv(gate_frame* f);                 // upstream CAN, non-blocking
void port_up_send(const gate_frame* f);
void port_down_send(const gate_frame* f);         // downstream CAN: the only path to the drive
void port_uart_write(const char* s);              // drive UART (ASCII protocol)
bool port_uart_line(char* buf, int n);            // one complete line from the drive, non-blocking
void port_en_gate(bool on);                       // the EN_GATE interlock output
bool port_nv_load(gate_nv* nv);                   // false: not provisioned or corrupt
bool port_nv_store(const gate_nv* nv);            // true only once the write is durable
const uint8_t* port_key(void);                    // 32-byte key shared with the authority service

void gate_fw_init(void);
void gate_fw_poll(void);                          // call from the main loop, as often as possible
const gate* gate_fw_state(void);
#endif
