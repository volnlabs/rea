# rea: actuation-finality evidence for AxiomOS

Reverse engineering, formal models and software tests behind the AxiomOS actuation-authority
work. Question: after a controller's authority is revoked, when can it no longer cause physical
output?

| Directory | Contents |
|---|---|
| `rp1-fw/` | Raspberry Pi 5 RP1 Cortex-M3 firmware: extraction scripts and static analysis of output ownership, persistence, PCIe failure handling, and the guardian/finality limits |
| `odrive/` | ODrive v3 (fw 0.5.x) command lifecycle, STM32/DRV8301 gate analysis, bench script (`bench/`, needs hardware) and software-in-the-loop fence test (`sil/`) |
| `finality/` | Lean 4 proofs and Python models: composed timed finality, gate refinement, impossibility without a downstream bound or fence, finite node-id fence. Start with `finality/PROOF.md` |

Run everything: `./check.sh` (Lean 4.35.0 via elan, python3, g++).

`ARCHITECTURE_REVIEW.md` reviews the AxiomOS brief against this evidence.

`PAPER_OUTLINE.md` maps every claim to its evidence: proved, executed, static, assumed or open.

`rp1-fw/out/` is not committed. Regenerate it with:

```sh
curl -LO https://raw.githubusercontent.com/raspberrypi/rpi-eeprom/master/firmware-2712/latest/pieeprom-2026-09-23.bin
python3 -I rp1-fw/extract.py pieeprom-2026-09-23.bin rp1-fw/out
bash rp1-fw/build-elf.sh rp1-fw/out
```

Nothing here has been run on motor hardware. See `finality/PROOF.md` for what is proved,
what is assumed and what is still open.
