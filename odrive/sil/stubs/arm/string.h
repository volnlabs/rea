// Declarations only, for the Cortex-M compile check in ../../../../check.sh (no libc is linked).
#include <stddef.h>
void* memcpy(void*, const void*, size_t);
void* memmove(void*, const void*, size_t);
void* memset(void*, int, size_t);
