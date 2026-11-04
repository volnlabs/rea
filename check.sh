#!/usr/bin/env bash
# Re-run every proof, model check and software test in this repo. Exits non-zero on any failure.
# Needs: elan (Lean toolchain from ./lean-toolchain), python3, g++, git, network on first run.
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
echo "== odrive/sil";                         odrive/sil/run.sh | tail -1
echo "all checks passed"
