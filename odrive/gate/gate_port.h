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
// The two halves of a verified flush (C14). Each returns true only when it is certain.
bool port_down_abort(void);                       // every downstream TX mailbox is empty, nothing on the wire
// The drive was held in hardware reset (its nRST pin, not a command it could miss), the UART
// receive buffer was emptied while it was held, and it is running again on its boot node id.
bool port_drive_reset(void);
void port_uart_write(const char* s);              // drive UART (ASCII protocol)
bool port_uart_line(char* buf, int n);            // one complete line from the drive, non-blocking
// The EN_GATE interlock output: high for at most `ms` from now, 0 = low now. Must be a hardware
// one-shot (timer output, re-armed by each call) so that EN_GATE falls on time if the firmware hangs.
void port_en_gate(uint32_t ms);
bool port_nv_load(gate_nv* nv);                   // false: not provisioned or corrupt
bool port_nv_store(const gate_nv* nv);            // true only once the write is durable
const uint8_t* port_key(void);                    // 32-byte key shared with the authority service

void gate_fw_init(void);
void gate_fw_poll(void);                          // call from the main loop, as often as possible
const gate* gate_fw_state(void);
#endif
