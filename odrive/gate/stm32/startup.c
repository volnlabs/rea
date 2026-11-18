// Reset code, vector table and the few C library functions the gate needs. No libc is linked.
#include <stddef.h>
#include <stdint.h>

extern uint32_t _estack, _sidata, _sdata, _edata, _sbss, _ebss;
int main(void);
void USART1_IRQHandler(void);

void Reset_Handler(void) {
    uint32_t *s = &_sidata, *d = &_sdata;
    while (d < &_edata) *d++ = *s++;
    for (d = &_sbss; d < &_ebss;) *d++ = 0;
    *(volatile uint32_t*)0xE000ED88 |= 0xFu << 20;   // enable the FPU (CP10, CP11)
    main();
    for (;;) {}
}
static void Default_Handler(void) { for (;;) {} }   // EN_GATE falls by its one-shot

__attribute__((section(".vectors"), used)) void (*const vectors[16 + 38])(void) = {
    (void (*)(void))&_estack, Reset_Handler,
    [2] = Default_Handler, Default_Handler, Default_Handler, Default_Handler, Default_Handler,
    [11] = Default_Handler, [12] = Default_Handler, [14] = Default_Handler,
    [15] = Default_Handler,
    [16 + 37] = USART1_IRQHandler,
};

void* memcpy(void* d, const void* s, size_t n) {
    uint8_t* a = d; const uint8_t* b = s;
    while (n--) *a++ = *b++;
    return d;
}
void* memmove(void* d, const void* s, size_t n) {
    uint8_t* a = d; const uint8_t* b = s;
    if (a < b) while (n--) *a++ = *b++;
    else while (n--) a[n] = b[n];
    return d;
}
void* memset(void* d, int c, size_t n) {
    uint8_t* a = d;
    while (n--) *a++ = (uint8_t)c;
    return d;
}
int memcmp(const void* x, const void* y, size_t n) {
    const uint8_t *a = x, *b = y;
    for (; n--; ++a, ++b) if (*a != *b) return *a - *b;
    return 0;
}
// Decimal only: [-]digits[.digits]. Enough for the drive's answers; anything else reads as 0,
// which never equals a session tag (tags start at 1).
float strtof(const char* s, char** end) {
    float v = 0, scale = 1;
    int neg = 0;
    while (*s == ' ') ++s;
    if (*s == '-') { neg = 1; ++s; }
    for (; *s >= '0' && *s <= '9'; ++s) v = v * 10 + (float)(*s - '0');
    if (*s == '.')
        for (++s; *s >= '0' && *s <= '9'; ++s) { scale /= 10; v += (float)(*s - '0') * scale; }
    if (end) *end = (char*)s;
    return neg ? -v : v;
}

// ARM run-time ABI helpers the compiler may call instead of the functions above.
void __aeabi_memcpy(void* d, const void* s, size_t n) { memcpy(d, s, n); }
void __aeabi_memcpy4(void* d, const void* s, size_t n) { memcpy(d, s, n); }
void __aeabi_memcpy8(void* d, const void* s, size_t n) { memcpy(d, s, n); }
void __aeabi_memmove(void* d, const void* s, size_t n) { memmove(d, s, n); }
void __aeabi_memset(void* d, size_t n, int c) { memset(d, c, n); }
void __aeabi_memclr(void* d, size_t n) { memset(d, 0, n); }
void __aeabi_memclr4(void* d, size_t n) { memset(d, 0, n); }
void __aeabi_memclr8(void* d, size_t n) { memset(d, 0, n); }
