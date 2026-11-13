#!/usr/bin/env bash
# Build and run the fence SIL test against an unmodified ODrive checkout.
# Also builds the gate core and firmware loop from ../gate (GATE_DIR overrides), and explores
# the firmware loop against an adversarial environment (explore.c).
# Usage: ./run.sh                          (fetches the pinned commit into .odrive-src/)
#        ODRIVE_SRC=/path/to/ODrive ./run.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
pin=3a2e4dd1bfbda9e4c534d5c7d8428a99c361e783
odrive=${ODRIVE_SRC:-$here/.odrive-src}
if [ ! -d "$odrive/.git" ]; then
  git init -q "$odrive"
  git -C "$odrive" fetch -q --depth 1 https://github.com/odriverobotics/ODrive.git "$pin"
  git -C "$odrive" checkout -q FETCH_HEAD
fi
rev=$(git -C "$odrive" rev-parse HEAD)
[ "$rev" = "$pin" ] || echo "warning: ODrive at $rev, results recorded for $pin" >&2
src=$odrive/Firmware/communication/can
gate=${GATE_DIR:-$here/../gate}
out=$(mktemp -d)
echo "ODrive $rev"
sha256sum "$src/can_simple.cpp" "$src/can_simple.hpp" "$src/canbus.hpp" "$src/can_helpers.hpp" \
  "$odrive/Firmware/fibre-cpp/protocol.hpp"
san="-fsanitize=address,undefined -fno-sanitize-recover=all"
gcc -std=c11 -Wall -Wextra -Werror ${GATE_CFLAGS:-} $san -I "$gate" -c "$gate/gate_fw.c" -o "$out/gate_fw.o"
g++ -std=c++17 -Wall -Wno-unused-parameter $san \
  -I "$here/stubs" -I "$gate" -I "$src" -I "$odrive/Firmware/fibre-cpp" -I "$odrive/Firmware/fibre-cpp/include" \
  "$src/can_simple.cpp" "$here/test_fence.cpp" "$out/gate_fw.o" -o "$out/test_fence"
rc=0
"$out/test_fence" || rc=1

# Bounded exploration of the firmware loop (explore.c): exhaustive at small bounds, then seeded
# random walks at larger ones. EXPLORE=quick skips the exhaustive part (used by mutate.py).
ex="gcc -std=gnu11 -O2 -Wall -Wextra -Wno-type-limits -Wno-unused-function -I $gate $here/explore.c"
# Counterexample: an authority that mints for a challenge without checking the gate's tag. The
# search must find the stockpiled-token violation, or it could not see that class of attack.
# Skipped for mutants (EXPLORE_COUNTEREXAMPLE=0): a broken gate can make this search run to the end.
if [ "${EXPLORE_COUNTEREXAMPLE:-1}" = 1 ]; then
  $ex -DAUTHORITY_UNCHECKED -DHORIZON=5 -DGATE_W_MS=1u -DGATE_T_MS=3u -DNTOK=2 -DMAX_CHAL=2 -DMAX_BADS=0 -o "$out/explore_u"
  if "$out/explore_u" > "$out/u.log"; then echo "EXPLORE: unchecked authority was NOT caught"; rc=1
  else grep -q "VIOLATION I1" "$out/u.log" && echo "explore: unchecked authority -> $(grep -c '^  *[0-9]' "$out/u.log")-step I1 counterexample found, as expected" || rc=1; fi
fi
if [ "${EXPLORE:-full}" = full ]; then
  $ex -DHORIZON=5 -DGATE_W_MS=1u -DGATE_T_MS=3u -DNTOK=2 -DMAX_CHAL=2 -DMAX_BADS=0 -o "$out/explore" && "$out/explore" || rc=1
fi
$ex -DRANDOM_STEPS=${EXPLORE_STEPS:-5000000} -DHORIZON=60 -DGATE_W_MS=3u -DGATE_T_MS=6u -DNTOK=12 -DMAX_CHAL=8 -DMAX_BADS=4 -DNORIG=3 \
  -o "$out/explore_r" && "$out/explore_r" || rc=1
[ $rc = 0 ] && echo "SIL OK: tests and exploration passed" || echo "SIL FAILED"
exit $rc
