# RP1 firmware actuation inventory (Q1)

Labels: [obs] bytes/disassembly/source; [inf] inference; [unk] open.
Sources: `out/rp1c0fw.dis`, `out/rp1c0fw.bin`; host driver `~/Work/proc/.pi-kernel/linux/drivers/misc/{rp1-pio.c,rp1-fw-pio.h}`.

## Autonomous output (no host involvement after boot)
- [obs] `main 0x20000d08` arms GPIO29 (bank1) falling-edge IRQ (io_bank1 CTRL `+0xc` bit20,
  proc INTE `+0x104` bit1) and timer `0x400ac000` alarm `+0x1c = now+100000`.
- [obs] Edge IRQ `0x100007dc`: timestamps edges into 32-slot ring `0x10002160`; acks io_bank1 `+0xc`.
- [obs] Timer IRQ `0x1000080c`: from the ring computes `60000000/interval/k` (udiv) and writes
  **pwm1 `0x4009c000`** `+0x3c` CHAN2_PHASE / `+0x38` CHAN2_RANGE (datasheet §3.4 table);
  re-arms timer (500000 const). axiomos-sim `RP1_PWM.cs` rejects PHASE — would trip strict MMIO.
- [inf] Frequency-measure → PWM1 CHAN2 servo loop (e.g. fan tach → fan PWM). [unk] physical load.

## Host-commanded output (RPC over the RP1 mailbox, FOURCC "PIO ")
- [obs] Dispatcher `0x20000548` (`tbh`, 38 cases) = `enum rp1_pio_ops` in `rp1-fw-pio.h` (38 ops).
- [obs] GPIO ops `GPIO_INIT`…`GPIO_SET_DRIVE_STRENGTH` accept any pin 0–53; no whitelist in firmware.
- [obs] Host kernel `rp1-pio.c` exposes them as char-device ioctls (`HANDLER(GPIO_SET_OUTOVER…)`)
  and forwards args unchanged — no pin/ownership check, bypasses pinctrl/gpiolib claims.
- [obs] `WRITE_HW`/`READ_HW` bounded to PIO `[0x40178000,0x4017c000)` and proc-AHB
  `[0xf0000000,0xf0004000)`; cannot reach pwm/io_bank/pads/rio directly.
- [unk] `/dev/pio*` node permissions — set by distro udev rules, not the driver.

## Bounded negatives
- [obs] No boot or IRQ path writes io_bank0 (GPIO0–27, header) or pwm0 `0x40098000`.
  Header pins reachable from firmware only via host RPC.
- Coverage: PC-relative literals, movw/movt, decoded fixed bank bases. Fully computed bases could be missed.
