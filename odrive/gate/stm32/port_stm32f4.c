// Board layer for the gate firmware loop on an STM32F4 (written for NUCLEO-F446RE; the registers
// used are common to F405/F407/F446). Register-level, no vendor library.
//
// STATUS: links, and boots in the Renode STM32F4 model (see renode_test.sh). NEVER RUN ON SILICON.
// Nothing here is timing-verified. Do not flash it onto hardware wired to a drive without the
// bench steps in ../../bench/HARDWARE.md.
//
// Pins:  PA11/PA12  CAN1 RX/TX   upstream bus (controllers, authority service)
//        PB12/PB13  CAN2 RX/TX   downstream bus (the drive, and nothing else)
//        PA9/PA10   USART1 TX/RX drive UART (ODrive ASCII protocol), 115200 8N1
//        PA5        TIM2_CH1     EN_GATE one-shot (also the Nucleo's LED)
//        PB0        open drain   drive nRST
// Clock: HSI 16 MHz, no PLL. CAN 250 kbit/s.
//
// ponytail: no watchdog (a hung loop is safe: the one-shot drops EN_GATE; add IWDG for
// availability), CAN receive is polled (add the FIFO interrupt if frames are lost under load),
// and the key lives in ordinary flash (move to read-protected storage for any real use).
#include "../gate_port.h"

#define R(a) (*(volatile uint32_t*)(a))
enum { RCC = 0x40023800, GPIOA = 0x40020000, GPIOB = 0x40020400, USART1 = 0x40011000, TIM2 = 0x40000000, TIM5 = 0x40000C00,
       CAN1 = 0x40006400, CAN2 = 0x40006800, FLASH = 0x40023C00 };
enum { MODER = 0x00, OTYPER = 0x04, BSRR = 0x18, AFRL = 0x20, AFRH = 0x24 };
enum { CR1 = 0x00, EGR = 0x14, CCMR1 = 0x18, CCER = 0x20, CNT = 0x24, PSC = 0x28, ARR = 0x2C, CCR1 = 0x34 };   // timers
#ifndef GATE_TIMER_HZ
#define GATE_TIMER_HZ 16000000u   // timer input clock (HSI, APB1 prescaler 1)
#endif

#ifndef GATE_DRIVE_BOOT_ID
#define GATE_DRIVE_BOOT_ID 0
#endif
#ifndef GATE_DRIVE_BOOT_MS
#define GATE_DRIVE_BOOT_MS 3000u   // how long to wait for the drive to answer after its reset
#endif

// ---- clock ----
// TIM5 free-running at 1 kHz, read directly. Not a tick counted by an interrupt: that kind of
// clock stands still while the CPU is stuck or interrupts are off, and when the firmware came
// back it would re-arm EN_GATE for lease time that had already passed in the real world.
// (Found in emulation: halting the CPU for 300 ms left the lease "live".)
#define ms R(TIM5 + CNT)
uint32_t port_now(void) { return ms; }

// ---- UART to the drive: interrupt-fed ring buffer, so bytes survive a slow main loop ----
static volatile uint8_t rx[128];
static volatile uint8_t rx_head, rx_tail;
void USART1_IRQHandler(void) {
    uint32_t sr = R(USART1 + 0x00);
    uint8_t c = (uint8_t)R(USART1 + 0x04);          // reading DR also clears an overrun
    if (sr & (1u << 5)) { rx[rx_head & 127] = c; ++rx_head; }
}
void port_uart_write(const char* s) {
    for (; *s; ++s) {
        while (!(R(USART1 + 0x00) & (1u << 7))) {}
        R(USART1 + 0x04) = (uint8_t)*s;
    }
}
bool port_uart_line(char* buf, int n) {
    static char line[32];
    static int len;
    while (rx_tail != rx_head) {
        char c = (char)rx[rx_tail & 127];
        ++rx_tail;
        if (c == '\n' || c == '\r') {
            if (!len) continue;
            if (len >= n) len = n - 1;
            memcpy(buf, line, (size_t)len);
            buf[len] = 0;
            len = 0;
            return true;
        }
        if (len < (int)sizeof line - 1) line[len++] = c;
    }
    return false;
}
static void uart_drain(void) { rx_tail = rx_head; }

// ---- CAN (bxCAN), one transmit mailbox per bus so frames leave in order ----
enum { MCR = 0x00, MSR = 0x04, TSR = 0x08, RF0R = 0x0C, BTR = 0x1C, TI0R = 0x180, RI0R = 0x1B0 };
enum { TME_ALL = 7u << 26, ABRQ_ALL = (1u << 7) | (1u << 15) | (1u << 23) };

static void can_init(uint32_t can) {
    R(can + MCR) = 1;                               // INRQ, leave sleep
    for (uint32_t t = ms; !(R(can + MSR) & 1) && ms - t < 10;) {}
    R(can + BTR) = (1u << 20) | (12u << 16) | 3u;   // 16 MHz / 4 / (1 + 13 + 2) = 250 kbit/s
    R(can + MCR) = 1u << 6;                         // ABOM: recover from bus-off; leave init
    for (uint32_t t = ms; (R(can + MSR) & 1) && ms - t < 10;) {}
}
static bool can_tx(uint32_t can, const gate_frame* f) {
    uint32_t lo, hi;
    for (uint32_t t = ms; !(R(can + TSR) & (1u << 26));)
        if (ms - t > 2) { R(can + TSR) = 1u << 7; return false; }   // still pending: abort it, drop this one
    memcpy(&lo, f->data, 4);
    memcpy(&hi, f->data + 4, 4);
    R(can + TI0R + 4) = f->len & 15u;
    R(can + TI0R + 8) = lo;
    R(can + TI0R + 12) = hi;
    R(can + TI0R) = (f->id << 21) | 1u;             // standard id, data frame, request transmission
    return true;
}
static bool can_rx(uint32_t can, gate_frame* f) {
    uint32_t ri, lo, hi;
    for (;;) {
        if (!(R(can + RF0R) & 3)) return false;
        ri = R(can + RI0R);
        f->len = (uint8_t)(R(can + RI0R + 4) & 15u);
        lo = R(can + RI0R + 8);
        hi = R(can + RI0R + 12);
        R(can + RF0R) = 1u << 5;                    // release the FIFO slot
        if (ri & 6u) continue;                      // extended or remote frame: not ours
        if (f->len > 8) f->len = 8;
        f->id = ri >> 21;
        memcpy(f->data, &lo, 4);
        memcpy(f->data + 4, &hi, 4);
        return true;
    }
}
bool port_up_recv(gate_frame* f) { return can_rx(CAN1, f); }
void port_up_send(const gate_frame* f) { can_tx(CAN1, f); }
void port_down_send(const gate_frame* f) { can_tx(CAN2, f); }
bool port_down_abort(void) {
    R(CAN2 + TSR) = ABRQ_ALL;
    for (uint32_t t = ms; (R(CAN2 + TSR) & TME_ALL) != TME_ALL;)
        if (ms - t > 5) return false;
    return true;
}

// ---- EN_GATE: TIM2 channel 1 as a one-shot, 1 ms per count, 32-bit counter ----
// PWM mode 2 with CCR1 = 1: the pin is low at CNT = 0 and high from CNT = 1 until the counter
// reaches ARR, where one-pulse mode stops it at 0 again. Hardware does that, not this code.
void port_en_gate(uint32_t left) {
    if (left < 2) {                                 // off now (a 1 ms lease is not worth the race)
        R(TIM2 + CR1) = 1u << 3;                    // stop (OPM stays set)
        R(TIM2 + CNT) = 0;
        return;
    }
    if (R(TIM2 + CR1) & 1) {                        // running: move the end, never past 2^31 counts
        uint32_t c = R(TIM2 + CNT);
        if (c && c < 0x80000000u) { R(TIM2 + ARR) = c + left - 1; return; }
        R(TIM2 + CR1) = 1u << 3;
    }
    R(TIM2 + ARR) = left;                           // high for CNT = 1 .. left, at most `left` ms
    R(TIM2 + CNT) = 1;
    R(TIM2 + CR1) = (1u << 3) | 1u;
}

// ---- non-volatile state: append-only records in two flash sectors ----
// A record is valid only with a matching check word, so a write cut short by a reset is ignored
// and the previous record stands. When a sector is full the next record goes to the other one,
// which is erased first; the full sector is never erased while it holds the newest record.
typedef struct { uint32_t magic, count, session, used_lo, used_hi, chal, node, check; } rec;
enum { SEC_A = 0x08040000, SEC_B = 0x08060000, SEC_SIZE = 0x20000, NREC = SEC_SIZE / sizeof(rec), MAGIC = 0x47415445 };
enum { F_SR = 0x0C, F_CR = 0x10, F_KEYR = 0x04 };

static uint32_t rec_check(const rec* r) {
    const uint32_t* w = (const uint32_t*)r;
    uint32_t h = 2166136261u;
    for (int i = 0; i < 7; ++i) h = (h ^ w[i]) * 16777619u;
    return h;
}
static const rec* newest(void) {
    const rec* best = NULL;
    for (uint32_t base = SEC_A; base <= SEC_B; base += SEC_SIZE)
        for (uint32_t i = 0; i < NREC; ++i) {
            const rec* r = (const rec*)(base + i * sizeof(rec));
            if (r->magic == 0xFFFFFFFFu) break;
            if (r->magic == MAGIC && r->check == rec_check(r) && (!best || r->count > best->count)) best = r;
        }
    return best;
}
static bool flash_wait(void) {
    while (R(FLASH + F_SR) & (1u << 16)) {}
    bool ok = !(R(FLASH + F_SR) & 0xF0u);
    R(FLASH + F_SR) = 0xF1u;
    return ok;
}
static void flash_unlock(void) {
    if (R(FLASH + F_CR) & (1u << 31)) { R(FLASH + F_KEYR) = 0x45670123u; R(FLASH + F_KEYR) = 0xCDEF89ABu; }
}
static bool sector_blank(uint32_t base) {
    for (uint32_t a = base; a < base + SEC_SIZE; a += 4)
        if (R(a) != 0xFFFFFFFFu) return false;
    return true;
}
static bool sector_erase(uint32_t base) {
    flash_unlock();
    R(FLASH + F_CR) = (1u << 1) | ((base == SEC_A ? 6u : 7u) << 3) | (2u << 8);
    R(FLASH + F_CR) |= 1u << 16;
    bool ok = flash_wait();
    R(FLASH + F_CR) = 1u << 31;
    return ok && sector_blank(base);
}
static bool rec_write(uint32_t addr, const rec* r) {
    const uint32_t* w = (const uint32_t*)r;
    bool ok = true;
    flash_unlock();
    R(FLASH + F_CR) = 1u | (2u << 8);               // PG, 32-bit programming
    for (int i = 0; i < 8 && ok; ++i) { R(addr + 4u * (uint32_t)i) = w[i]; ok = flash_wait(); }
    R(FLASH + F_CR) = 1u << 31;
    return ok && !memcmp((const void*)addr, r, sizeof *r);
}
bool port_nv_load(gate_nv* nv) {
    const rec* r = newest();
    if (!r) return false;
    nv->session = r->session;
    nv->used = ((uint64_t)r->used_hi << 32) | r->used_lo;
    nv->chal = r->chal;
    nv->node = (uint8_t)r->node;
    return true;
}
bool port_nv_store(const gate_nv* nv) {
    const rec* last = newest();
    rec r = {MAGIC, last ? last->count + 1 : 1, nv->session, (uint32_t)nv->used, (uint32_t)(nv->used >> 32), nv->chal, nv->node, 0};
    uint32_t addr = SEC_A;
    r.check = rec_check(&r);
    if (last) {
        uint32_t base = (uint32_t)last < SEC_B ? SEC_A : SEC_B;
        addr = (uint32_t)last + sizeof(rec);
        // Skip slots a cut-short write may have dirtied.
        while (addr < base + SEC_SIZE && ((const rec*)addr)->magic != 0xFFFFFFFFu) addr += sizeof(rec);
        if (addr >= base + SEC_SIZE) {              // sector full: move to the other one
            addr = base == SEC_A ? SEC_B : SEC_A;
            if (!sector_blank(addr) && !sector_erase(addr)) return false;
        }
    } else if (!sector_blank(SEC_A) && !sector_erase(SEC_A)) return false;
    return rec_write(addr, &r);
}

// ---- key ----
// 32 bytes at a fixed flash address, written at provisioning. Erased flash (all 0xFF) means
// "no key": main() then refuses to run the gate.
// Deliberately not `const`: the contents change after compilation (provisioning), so the compiler
// must not fold them. As `const`, the blank image folded "no key" into "never run the gate" and
// dropped the whole loop, so a provisioned board would never have served (found 2026-11-19).
// The section is in flash, so writes from code would fault; nothing writes it.
__attribute__((section(".gate_key"), used)) uint8_t gate_key[32] = {
#ifdef GATE_DEMO_KEY   // emulation only
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32
#else
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
#endif
};
const uint8_t* port_key(void) { return gate_key; }

// ---- drive reset (second half of a verified flush) ----
bool port_drive_reset(void) {
    char line[32];
    R(GPIOB + BSRR) = 1u << 16;                     // nRST low
    for (uint32_t t = ms; ms - t < 20;) {}
    uart_drain();                                   // nothing the drive said before the reset survives
    R(GPIOB + BSRR) = 1u;                           // release
    // Certain only once the restarted drive answers with its boot node id. Before the reset it
    // was on a rotated id, and the boot id is never handed out, so this answer cannot be stale.
    for (uint32_t t = ms, asked = ms - 100; ms - t < GATE_DRIVE_BOOT_MS;) {
        if (ms - asked >= 100) { port_uart_write("r axis0.config.can.node_id\n"); asked = ms; }
        if (port_uart_line(line, sizeof line) && line[0] >= '0' && line[0] <= '9' &&
            strtof(line, NULL) == (float)GATE_DRIVE_BOOT_ID) { uart_drain(); return true; }
    }
    return false;
}

// ---- bring-up ----
static void pin_af(uint32_t port, int pin, uint32_t af) {
    R(port + MODER) = (R(port + MODER) & ~(3u << (2 * pin))) | (2u << (2 * pin));
    uint32_t reg = port + (pin < 8 ? AFRL : AFRH);
    int sh = 4 * (pin & 7);
    R(reg) = (R(reg) & ~(15u << sh)) | (af << sh);
}
int main(void) {
    bool keyed = false;
    R(RCC + 0x30) |= 3u;                            // GPIOA, GPIOB
    R(RCC + 0x40) |= (1u << 0) | (1u << 3) | (1u << 25) | (1u << 26);   // TIM2, TIM5, CAN1, CAN2
    R(RCC + 0x44) |= 1u << 4;                       // USART1
    R(TIM5 + PSC) = GATE_TIMER_HZ / 1000 - 1;       // the gate's clock: 1 count per ms, 32 bits
    R(TIM5 + EGR) = 1;
    R(TIM5 + CR1) = 1;

    // EN_GATE first, and low: timer stopped at 0, then the pin handed to the timer.
    R(TIM2 + PSC) = GATE_TIMER_HZ / 1000 - 1;
    R(TIM2 + EGR) = 1;                              // load the prescaler
    R(TIM2 + CCR1) = 1;
    R(TIM2 + CCMR1) = 7u << 4;                      // PWM mode 2
    R(TIM2 + CCER) = 1;
    R(TIM2 + CR1) = 1u << 3;                        // one-pulse mode, stopped
    R(TIM2 + CNT) = 0;
    pin_af(GPIOA, 5, 1);

    R(GPIOB + BSRR) = 1u;                           // nRST released, open drain
    R(GPIOB + OTYPER) |= 1u;
    R(GPIOB + MODER) = (R(GPIOB + MODER) & ~3u) | 1u;

    pin_af(GPIOA, 9, 7); pin_af(GPIOA, 10, 7);
    R(USART1 + 0x08) = 139;                         // 16 MHz / 115200
    R(USART1 + 0x0C) = (1u << 13) | (1u << 5) | (1u << 3) | (1u << 2);
    R(0xE000E104) = 1u << 5;                        // NVIC: USART1 (IRQ 37)

    pin_af(GPIOA, 11, 9); pin_af(GPIOA, 12, 9); pin_af(GPIOB, 12, 9); pin_af(GPIOB, 13, 9);
    can_init(CAN1);
    can_init(CAN2);
    R(CAN1 + 0x200) = (14u << 8) | 1u;              // filters: init mode, CAN2 starts at bank 14
    R(CAN1 + 0x20C) = (1u << 0) | (1u << 14);       // banks 0 and 14: one 32-bit filter each
    R(CAN1 + 0x240) = 0; R(CAN1 + 0x244) = 0;       // id 0, mask 0: accept everything into FIFO 0
    R(CAN1 + 0x240 + 8 * 14) = 0; R(CAN1 + 0x244 + 8 * 14) = 0;
    R(CAN1 + 0x21C) = (1u << 0) | (1u << 14);
    R(CAN1 + 0x200) = 14u << 8;

    for (int i = 0; i < 32; ++i) keyed = keyed || gate_key[i] != 0xFF;
#ifdef GATE_DEMO_PROVISION   // emulation only: a blank board provisions itself
    { gate_nv nv; if (!port_nv_load(&nv)) { gate_nv first = {0, 0, 0, GATE_DRIVE_BOOT_ID}; port_nv_store(&first); } }
#endif
    gate_fw_init();
    for (;;)
        if (keyed) gate_fw_poll();
}
