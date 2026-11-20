#!/bin/sh
# Inductive proof of the gate firmware loop with CBMC (prove_fw.c). GATE_DIR: gate sources.
here=$(dirname "$0")
cbmc "$here/prove_fw.c" -I "${GATE_DIR:-$here/../gate}" -I "$here/stubs" --object-bits 12 \
    --unwind 65 --unwinding-assertions --bounds-check --pointer-check --div-by-zero-check "$@"
