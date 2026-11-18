# Runs inside Renode (IronPython 2.7), started by renode_test.sh. Drives the STM32F4 build of the
# gate firmware through one whole sequence on emulated peripherals and writes PASS/FAIL lines to OUT.
# This checks the board layer's logic against Renode's peripheral models, not against silicon,
# and it says nothing about timing.
import hashlib, hmac, struct, traceback
from Antmicro.Renode.Core.CAN import CANMessageFrame
from Antmicro.Renode.Time import TimeInterval
from Antmicro.Renode.Peripherals.CPU import RegisterValue
from System import Array, Byte

out = open(OUT, "w")
fails = [0]
def check(ok, what):
    out.write(("PASS  " if ok else "FAIL  ") + what + "\n"); out.flush()
    if not ok: fails[0] += 1

KEY = "".join(chr(i) for i in range(1, 33))
def mac(key, msg): return hmac.new(key, msg, hashlib.sha256).digest()

try:
    emu = emulationManager.CurrentEmulation
    m = list(emu.Machines)[0]
    bus = m.SystemBus
    for i, ch in enumerate(KEY):   # provisioning: the key goes into its flash slot before boot
        bus.WriteByte(0x08004000 + i, ord(ch))
    can1, can2, uart, cpu = m["sysbus.can1"], m["sysbus.can2"], m["sysbus.usart1"], m["sysbus.cpu"]
    up_tx, down_tx, uart_tx = [], [], []
    grab = lambda f: (int(f.Id), "".join(chr(b) for b in f.Data))
    can1.FrameSent += lambda f: up_tx.append(grab(f))
    can2.FrameSent += lambda f: down_tx.append(grab(f))
    uart.CharReceived += lambda c: uart_tx.append(chr(c))
    def run(ms): emu.RunFor(TimeInterval.FromMilliseconds(ms))
    def up(ident, data): can1.OnFrameReceived(CANMessageFrame(ident, Array[Byte]([Byte(ord(c)) for c in data]), False, False, False, False))
    def word(a): return int(bus.ReadDoubleWord(a))
    def en_running(): return word(0x40000000) & 1
    def challenge():
        del up_tx[:]
        up(0x010, "")
        run(5)
        return [d for i, d in up_tx if i == 0x011]

    run(50)
    check("r axis0.controller.input_vel\n" in "".join(uart_tx), "S1 boots and polls the drive over UART (%d chars seen)" % len(uart_tx))
    check(not en_running(), "S2 EN_GATE one-shot is stopped after boot")
    check(word(0x08040000) == 0x47415445, "S3 stored state exists in flash (demo self-provisioning)")

    c = challenge()
    ok = len(c) == 1 and len(c[0]) == 8 and c[0][4:] == mac(KEY, "G" + c[0][:4])[:4]
    check(ok, "S4 challenge request answered on the upstream bus with the gate's tag")
    chal = c[0][:4] if ok else "\0\0\0\0"

    up(0x020, "\x00\x00" + chal)
    up(0x021, mac("x" * 32, "T\x00\x00" + chal)[:8])
    run(5)
    check(not down_tx, "S5 token under a wrong key: nothing sent downstream")

    up(0x020, "\x00\x00" + chal)
    up(0x021, mac(KEY, "T\x00\x00" + chal)[:8])
    run(5)
    check(down_tx == [(0x006, struct.pack("<I", 1))], "S6 valid token: rotation frame to the drive (node 0 -> 1) on the downstream bus")
    recs = [a for a in range(0x08040000, 0x08040400, 32) if word(a) == 0x47415445]
    check(len(recs) >= 2 and word(recs[-1] + 24) == 1, "S7 new node id is in flash (record %d)" % len(recs))

    ks = mac(KEY, "S\x00" + chal)
    torque = struct.pack("<f", 0.25)
    del down_tx[:]
    up(0x030, torque + mac(ks, "C" + struct.pack("<I", 0) + torque)[:4])
    run(5)
    check(down_tx == [((1 << 5) | 0x0D, struct.pack("<ff", 2.0, 0.25))], "S8 authenticated command forwarded to node 1 with session tag 2")
    check(not en_running(), "S9 EN_GATE still off before the drive's readback")

    for ch in "2.000000\n": uart.WriteChar(ord(ch))
    run(10)
    left = word(0x4000002C) - word(0x40000024)
    check(en_running() and 0 < left <= 200, "S10 readback matches: one-shot running, %d ms left (lease is 200 ms)" % left)

    cpu.IsHalted = True            # the firmware hangs; only the timer can act now
    run(300)
    check(not en_running(), "S11 firmware halted: the one-shot timer stops by itself within the lease (CNT %d ARR %d)" % (word(0x40000024), word(0x4000002C)))
    cpu.IsHalted = False
    run(10)
    check(not en_running(), "S12 after the lease the firmware keeps EN_GATE off")

    m.Reset()                      # flash contents stay; Renode needs the boot vector set again
    cpu.VectorTableOffset = 0x08000000
    cpu.SP = RegisterValue.Create(word(0x08000000), 32)
    cpu.PC = RegisterValue.Create(word(0x08000004), 32)
    run(50)
    c2 = challenge()
    ok = len(c2) == 1 and struct.unpack("<I", c2[0][:4])[0] > struct.unpack("<I", chal)[0]
    check(ok, "S13 after a reset the next challenge is above the one issued before it")
    up(0x020, "\x00\x00" + chal)
    up(0x021, mac(KEY, "T\x00\x00" + chal)[:8])
    del down_tx[:]
    run(5)
    check(not down_tx, "S14 the token from before the reset is dead")
except Exception:
    check(False, "exception: " + traceback.format_exc())
out.write("RENODE %s: %d failure(s)\n" % ("FAILED" if fails[0] else "OK", fails[0]))
out.close()
