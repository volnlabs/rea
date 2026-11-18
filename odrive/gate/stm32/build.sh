#!/usr/bin/env bash
# Build the gate firmware for STM32F4 with clang and lld (no ARM GCC, no vendor library).
# Usage: ./build.sh [out-dir] [extra -D flags]      e.g. ./build.sh /tmp/gate -DGATE_DEMO_KEY
# The result has never run on silicon. See port_stm32f4.c.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/build}; shift || true
mkdir -p "$out"
cc="clang --target=arm-none-eabi -mcpu=cortex-m4 -mthumb -mfpu=fpv4-sp-d16 -mfloat-abi=hard -ffreestanding -fno-builtin
    -Os -std=c11 -Wall -Wextra -Werror -ffunction-sections -fdata-sections -I $here/../../sil/stubs/arm -I $here/.."
for f in "$here/../gate_fw.c" "$here/port_stm32f4.c" "$here/startup.c"; do
  $cc "$@" -c "$f" -o "$out/$(basename "$f" .c).o"
done
ld.lld -T "$here/stm32f4.ld" --gc-sections "$out"/gate_fw.o "$out"/port_stm32f4.o "$out"/startup.o -o "$out/gate.elf"
llvm-objcopy -O binary "$out/gate.elf" "$out/gate.bin"
undef=$(llvm-nm -u "$out/gate.elf" | wc -l)
[ "$undef" = 0 ] || { echo "undefined symbols:"; llvm-nm -u "$out/gate.elf"; exit 1; }
# The gate loop must survive in every build, keyed or blank (a blank key is filled in at provisioning).
llvm-nm "$out/gate.elf" | grep -q " gate_fw_poll$" || { echo "gate_fw_poll missing from the image"; exit 1; }
echo "gate.elf: $(llvm-size "$out/gate.elf" | awk 'NR==2 {print $1 " bytes code, " $2 + $3 " bytes RAM"}')"
