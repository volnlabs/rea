#!/usr/bin/env bash
# Re-run every proof, model check and software test in this repo. Exits non-zero on any failure.
# Needs: elan (Lean toolchain from ./lean-toolchain), python3, gcc, g++, git, network on first run.
# Optional: clang with an ARM target (Cortex-M compile check).
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
# Compile-only check that the gate firmware loop builds for Cortex-M with no host dependencies.
# Skipped when clang has no ARM target. Nothing is linked or run: there is no STM32 port yet.
echo "== gate firmware, Cortex-M compile check"
tmp=$(mktemp -d)
if echo 'int x;' | clang --target=arm-none-eabi -mcpu=cortex-m4 -x c -c - -o "$tmp/probe.o" 2>/dev/null; then
  for cpu in cortex-m4 cortex-m0plus; do
    clang --target=arm-none-eabi -mcpu=$cpu -mthumb -ffreestanding -Os -std=c11 -Wall -Wextra -Werror \
      -I odrive/sil/stubs/arm -I odrive/gate -c odrive/gate/gate_fw.c -o "$tmp/gate_fw.o"
    echo "$cpu: $(llvm-size "$tmp/gate_fw.o" | awk 'NR==2 {print $1 " bytes code, " $2 + $3 " bytes RAM"}')"
  done
else
  echo "skipped: clang has no ARM target"
fi
echo "all checks passed"
