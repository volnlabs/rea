#!/usr/bin/env bash
# Build and run the fence SIL test against an unmodified ODrive checkout.
# Also builds the gate core and firmware loop from ../gate (GATE_DIR overrides).
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
"$out/test_fence"
