#!/usr/bin/env python3
"""No-motor bench test of the ODrive v3 (fw 0.5.x) node-ID epoch fence.

Hardware: ODrive v3 with NO motor connected, CAN adapter (python-can, e.g. socketcan can0),
UART or USB-serial to the ODrive ASCII protocol. The axis must be IDLE. This script never
requests an axis state, and restores the original node id and input_torque = 0 on exit.

Tests (results written as JSON):
  T0 readback latency: UART `r axis0.controller.input_torque`
  T1 rotation: node id change via UART `w` and via CAN SET_AXIS_NODE_ID, time to readback
  T2 filter window: after rotation, first time a frame to the NEW id takes effect
  T3 stale frames: frames to the OLD id after rotation must never take effect  (PASS/FAIL)
  T4 optional (--reset): node id after CAN RESET_ODRIVE (what the drive reverts to)

Usage:
  python3 fence_bench.py --selftest
  python3 fence_bench.py --serial /dev/ttyACM0 --can-channel can0 --out results.json [--reset]
Requires: pip install python-can pyserial
"""
import argparse, json, statistics, struct, sys, time

# Verified in ODrive source 3a2e4dd1: can_simple.hpp enum order, can_simple.cpp handlers.
CMD_SET_AXIS_NODE_ID = 0x006
CMD_SET_INPUT_TORQUE = 0x00E
CMD_RESET_ODRIVE = 0x016
NUM_CMD_ID_BITS = 5          # standard frames: 6-bit node id | 5-bit cmd
IDLE = 1                     # ODrive.Axis.AxisState: UNDEFINED=0, IDLE=1


def arb_id(node, cmd):
    return (node << NUM_CMD_ID_BITS) | cmd


def torque_payload(nm):
    return struct.pack('<f', nm) + bytes(4)      # float32 at bit 0, little-endian


def node_id_payload(n):
    return struct.pack('<I', n) + bytes(4)       # uint32 at bit 0, little-endian


class Ascii:
    def __init__(self, port, baud):
        import serial
        self.port, self.baud = port, baud
        self.ser = serial.Serial(port, baud, timeout=0.5)

    def read(self, prop):
        self.ser.reset_input_buffer()
        self.ser.write(f'r {prop}\n'.encode())
        line = self.ser.readline().decode(errors='replace').strip()
        if not line:
            raise RuntimeError(f'no reply reading {prop}')
        return line

    def write(self, prop, value):
        self.ser.write(f'w {prop} {value}\n'.encode())

    def reopen(self, wait_s=10.0):
        self.ser.close()
        deadline = time.monotonic() + wait_s
        while time.monotonic() < deadline:
            try:
                self.__init__(self.port, self.baud)
                self.read('axis0.current_state')
                return
            except Exception:
                time.sleep(0.25)
        raise RuntimeError('ODrive did not come back after reset')


def torque_now(a):
    return float(a.read('axis0.controller.input_torque'))


def node_now(a):
    return int(a.read('axis0.config.can.node_id'))


def send(bus, node, cmd, data):
    import can
    bus.send(can.Message(arbitration_id=arb_id(node, cmd), data=data, is_extended_id=False))


def wait_until(pred, timeout_s, poll_s=0.0):
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout_s:
        if pred():
            return time.monotonic() - t0
        if poll_s:
            time.sleep(poll_s)
    return None


def run(args):
    import can
    a = Ascii(args.serial, args.baud)
    bus = can.interface.Bus(channel=args.can_channel, interface=args.can_interface)
    state = int(a.read('axis0.current_state'))
    if state != IDLE:
        sys.exit(f'refusing: axis0.current_state = {state}, need IDLE ({IDLE}). Disconnect the motor.')
    if a.read('axis0.config.can.is_extended').strip() not in ('0', 'False', 'false'):
        sys.exit('refusing: this script assumes standard (11-bit) CAN frames')
    orig = node_now(a)
    res = {'original_node_id': orig, 'started': time.time()}
    try:
        # T0 readback latency
        lat = []
        for _ in range(args.reads):
            t = time.monotonic(); torque_now(a); lat.append(time.monotonic() - t)
        res['T0_readback_s'] = {'n': len(lat), 'min': min(lat), 'median': statistics.median(lat), 'max': max(lat)}

        old, new_uart, new_can = orig, (orig + 1) % 64, (orig + 2) % 64

        # T1a rotation via UART
        a.write('axis0.config.can.node_id', new_uart)
        res['T1_uart_rotation_s'] = wait_until(lambda: node_now(a) == new_uart, 2.0)

        # T2 filter-renewal window: first frame to the new id that takes effect
        marker = 0.011
        t0 = time.monotonic()
        hit = None
        while time.monotonic() - t0 < 2.0 and hit is None:
            send(bus, new_uart, CMD_SET_INPUT_TORQUE, torque_payload(marker))
            if abs(torque_now(a) - marker) < 1e-6:
                hit = time.monotonic() - t0
        res['T2_new_id_effective_s'] = hit

        # T3 stale frames to the old id must be ignored
        stale_hits = []
        for k in range(args.stale):
            v = 0.02 + 0.001 * k
            send(bus, old, CMD_SET_INPUT_TORQUE, torque_payload(v))
            time.sleep(args.stale_gap)
            got = torque_now(a)
            if abs(got - v) < 1e-6:
                stale_hits.append({'value': v, 'readback': got})
        res['T3_stale_frames_sent'] = args.stale
        res['T3_stale_frames_effective'] = stale_hits
        res['T3_pass'] = not stale_hits

        # T1b rotation via CAN SET_AXIS_NODE_ID, addressed to the current id
        send(bus, new_uart, CMD_SET_AXIS_NODE_ID, node_id_payload(new_can))
        res['T1_can_rotation_s'] = wait_until(lambda: node_now(a) == new_can, 2.0)

        # T4 node id after reset (optional)
        if args.reset:
            send(bus, node_now(a), CMD_RESET_ODRIVE, bytes(8))
            time.sleep(1.0)
            a.reopen()
            res['T4_node_id_after_reset'] = node_now(a)
    finally:
        try:
            a.write('axis0.controller.input_torque', 0)
            a.write('axis0.config.can.node_id', orig)
            res['restored_node_id'] = node_now(a)
        finally:
            bus.shutdown()
    res['finished'] = time.time()
    return res


def selftest():
    assert arb_id(3, CMD_SET_INPUT_TORQUE) == 0x06E
    assert torque_payload(1.0)[:4] == bytes.fromhex('0000803f')
    assert node_id_payload(5)[:4] == bytes.fromhex('05000000')
    print('selftest ok')


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--selftest', action='store_true')
    ap.add_argument('--serial')
    ap.add_argument('--baud', type=int, default=115200)
    ap.add_argument('--can-channel', default='can0')
    ap.add_argument('--can-interface', default='socketcan')
    ap.add_argument('--reads', type=int, default=200)
    ap.add_argument('--stale', type=int, default=50)
    ap.add_argument('--stale-gap', type=float, default=0.01)
    ap.add_argument('--reset', action='store_true')
    ap.add_argument('--out', default='fence_results.json')
    args = ap.parse_args()
    if args.selftest:
        selftest(); sys.exit(0)
    if not args.serial:
        ap.error('--serial is required (or use --selftest)')
    out = run(args)
    json.dump(out, open(args.out, 'w'), indent=2)
    print(json.dumps(out, indent=2))
