#!/usr/bin/env python3
"""Authority-service and controller side of the gate's upstream protocol (see gate_fw.c).

Reference for bench scripts: builds the frames a real authority service and controller would
send. Message authentication is the same draft as in gate.h (one shared key, truncated tags):
not reviewed cryptography.

Self-test: python3 -I authority.py   (vectors are also checked by the C side, sil/test_fence.cpp M3)
"""
import hashlib, hmac, struct

CHAL_REQ, CHAL, TOKEN1, TOKEN2, CMD = 0x010, 0x011, 0x020, 0x021, 0x030
OVERLAP = 1


def _mac(key: bytes, msg: bytes) -> bytes:
    return hmac.new(key, msg, hashlib.sha256).digest()


def verify_challenge(key: bytes, data: bytes):
    """Authority service: the challenge in a CHAL frame, or None if the gate did not issue it.

    Never mint for a challenge that fails this: the challenge is a counter, and a token for a
    future value would outlive the revocation of whoever asked for it.
    """
    if len(data) != 8 or not hmac.compare_digest(_mac(key, b"G" + data[:4])[:4], data[4:]):
        return None
    return struct.unpack("<I", data[:4])[0]


def token_frames(key: bytes, origin: int, flags: int, chal: int):
    """Authority service: grant `origin` a lease for the gate's challenge `chal` (verified first)."""
    tag = _mac(key, b"T" + bytes([origin, flags]) + struct.pack("<I", chal))[:8]
    return (TOKEN1, bytes([origin, flags]) + struct.pack("<I", chal)), (TOKEN2, tag)


def session_key(key: bytes, origin: int, chal: int) -> bytes:
    """Authority service: the key it hands to the controller it granted, with the token."""
    return _mac(key, b"S" + bytes([origin]) + struct.pack("<I", chal))


class Controller:
    """A controller holding a session key. Commands carry a sequence-numbered tag."""

    def __init__(self, ks: bytes):
        self.ks, self.seq = ks, 0

    def command(self, torque: float):
        t = struct.pack("<f", torque)
        tag = _mac(self.ks, b"C" + struct.pack("<I", self.seq) + t)[:4]
        self.seq += 1
        return CMD, t + tag


VECTOR_KEY = bytes(range(1, 33))
VECTORS = {  # shared with sil/test_fence.cpp (M3): origin 1, flags OVERLAP, chal 0x01020304, seq 5, torque 0.25
    "token": "010104030201df76ba38f2d3efbb",
    "session": "449f553da026f01fab96eb03a9b4ffef243dfb6fd51a328e0f6b528d1708e50d",
    "cmd": "0000803eeffe5bc6",
    "chal": "04030201e5981d30",
}

if __name__ == "__main__":
    (_, t1), (_, t2) = token_frames(VECTOR_KEY, 1, OVERLAP, 0x01020304)
    ks = session_key(VECTOR_KEY, 1, 0x01020304)
    c = Controller(ks)
    c.seq = 5
    _, cmd = c.command(0.25)
    chal = struct.pack("<I", 0x01020304) + _mac(VECTOR_KEY, b"G" + struct.pack("<I", 0x01020304))[:4]
    assert verify_challenge(VECTOR_KEY, chal) == 0x01020304
    assert verify_challenge(VECTOR_KEY, struct.pack("<I", 0x01020305) + chal[4:]) is None
    got = {"token": (t1 + t2).hex(), "session": ks.hex(), "cmd": cmd.hex(), "chal": chal.hex()}
    assert got == VECTORS, got
    print("authority.py: vectors match")
