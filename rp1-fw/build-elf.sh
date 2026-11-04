#!/usr/bin/env bash
# Wrap rp1c0fw.bin into an ARM ELF with its runtime view:
#   .text    0x20000000  whole image (vectors, code, rodata)
#   .ramtext 0x10000000  copy of image[0x7188:0x7c30] (reset handler copies it there)
#   .ramdata 0x10002000  copy of image[0x7c30:0x7e14]
# Needs clang + ld.lld. Bytes are unchanged; only headers are added.
set -euo pipefail
dir=$(cd "$(dirname "${1:?usage: build-elf.sh OUTDIR}")" && pwd)/$(basename "$1")
img=$dir/rp1c0fw.bin
dd if="$img" of="$dir/ramtext.bin" bs=1 skip=$((0x7188)) count=$((0x7c30 - 0x7188)) status=none
dd if="$img" of="$dir/ramdata.bin" bs=1 skip=$((0x7c30)) count=$((0x7e14 - 0x7c30)) status=none
cat > "$dir/wrap.S" <<EOF
.section .text,"ax",%progbits
.incbin "$img"
.section .ramtext,"ax",%progbits
.incbin "$dir/ramtext.bin"
.section .ramdata,"aw",%progbits
.incbin "$dir/ramdata.bin"
EOF
clang --target=thumbv7m-none-eabi -mcpu=cortex-m3 -c "$dir/wrap.S" -o "$dir/wrap.o"
ld.lld -m armelf --section-start=.text=0x20000000 --section-start=.ramtext=0x10000000 \
  --section-start=.ramdata=0x10002000 --entry=0x20000215 -nostdlib -static -o "$dir/rp1c0fw.elf" "$dir/wrap.o"
llvm-objcopy -O binary -j .text "$dir/rp1c0fw.elf" "$dir/check.bin"
cmp "$dir/check.bin" "$img"
rm "$dir/check.bin" "$dir/wrap.o" "$dir/wrap.S"
llvm-objdump -d --triple=thumbv7m-none-eabi --mcpu=cortex-m3 "$dir/rp1c0fw.elf" > "$dir/rp1c0fw.dis"
echo "ok: $dir/rp1c0fw.elf, $dir/rp1c0fw.dis"
