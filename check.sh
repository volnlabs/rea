#!/usr/bin/env bash
# Re-run every proof, model check and software test in this repo. Exits non-zero on any failure.
# Needs: elan (Lean toolchain from ./lean-toolchain), python3, gcc, g++, git, network on first run.
# Optional: clang with an ARM target and lld (Cortex-M compile check, STM32F4 image); Renode
# (runs that image in emulation); CBMC 6.x (proof of the firmware loop).
set -euo pipefail
cd "$(dirname "$0")"

for f in finality/*.lean; do
  echo "== lean $f"
  out=$(lean "$f" 2>&1)
  if [ -n "$out" ]; then printf '%s\n' "$out"; exit 1; fi
done

echo "== finality/chain_model.py";            python3 -I finality/chain_model.py | tail -1
echo "== odrive/odrive_finality_model.py";    python3 -I odrive/odrive_finality_model.py | tail -1
echo "== odrive/bench/fence_bench.py";        python3 -I odrive/bench/fence_bench.py --selftest
echo "== odrive/gate/authority.py";          python3 -I odrive/gate/authority.py
echo "== odrive/sil (tests, then exploration: about 7 minutes)"
odrive/sil/run.sh | grep -E "^(ALL CHECKS|FAIL|explore: unchecked|EXPLORE|SIL)"
echo "== odrive/sil/mutate.py";                python3 -I odrive/sil/mutate.py | tail -1
# Inductive proof of the firmware loop (P1-P3 in odrive/sil/prove_fw.c): about 3 minutes.
echo "== odrive/sil/prove.sh (CBMC)"
if command -v cbmc >/dev/null; then odrive/sil/prove.sh | grep -E "^\*\* [0-9]|^VERIFICATION"
else echo "skipped: cbmc not installed"; fi
# Compile-only check that the gate firmware loop builds for Cortex-M with no host dependencies.
# Skipped when clang has no ARM target.
echo "== gate firmware, Cortex-M compile check"
tmp=$(mktemp -d)
if echo 'int x;' | clang --target=arm-none-eabi -mcpu=cortex-m4 -x c -c - -o "$tmp/probe.o" 2>/dev/null; then
  for cpu in cortex-m4 cortex-m0plus; do
    clang --target=arm-none-eabi -mcpu=$cpu -mthumb -ffreestanding -Os -std=c11 -Wall -Wextra -Werror \
      -I odrive/sil/stubs/arm -I odrive/gate -c odrive/gate/gate_fw.c -o "$tmp/gate_fw.o"
    echo "$cpu: $(llvm-size "$tmp/gate_fw.o" | awk 'NR==2 {print $1 " bytes code, " $2 + $3 " bytes RAM"}')"
  done
  # Link the real STM32F4 image (board layer + startup, no libc) and run it in Renode's STM32F4
  # model through one whole sequence. Emulation, not silicon.
  echo "== gate firmware, STM32F4 image"
  if command -v ld.lld >/dev/null; then
    odrive/gate/stm32/build.sh "$tmp/stm32"
    if command -v renode >/dev/null; then odrive/gate/stm32/renode_test.sh | tail -1
    else echo "Renode run skipped: renode not installed"; fi
  else
    echo "skipped: no ld.lld"
  fi
else
  echo "skipped: clang has no ARM target"
fi
echo "all checks passed"
