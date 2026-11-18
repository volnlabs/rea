#!/usr/bin/env bash
# Build the STM32F4 gate firmware (blank key, provisioned by the test) and run it in Renode's STM32F4
# model through one whole sequence. Emulation only: not silicon, no timing claims.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=$(mktemp -d)
# The production image (blank key); the test writes the key into flash before boot, as
# provisioning would. Only the stored state self-provisions (GATE_DEMO_PROVISION).
"$here/build.sh" "$out" -DGATE_DEMO_PROVISION -DGATE_TIMER_HZ=10000000u
cat > "$out/test.resc" <<RESC
mach create "gate"
machine LoadPlatformDescription @platforms/cpus/stm32f4.repl
sysbus LoadELF @$out/gate.elf
python "OUT='$out/result.txt'; execfile('$here/renode_test.py')"
quit
RESC
timeout 300 renode --disable-xwt --console --plain -e "include @$out/test.resc" > "$out/renode.log" 2>&1 || true
cat "$out/result.txt" 2>/dev/null || { tail -20 "$out/renode.log"; echo "RENODE FAILED: no result"; exit 1; }
grep -q "^RENODE OK" "$out/result.txt"
