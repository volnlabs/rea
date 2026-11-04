#!/usr/bin/env python3
"""Extract the RP1 Cortex-M3 firmware from a Raspberry Pi 5 pieeprom-*.bin.

Usage: python3 -I extract.py pieeprom.bin OUTDIR

Writes OUTDIR/rp1c0fw1.bin, rp1c0fw2.bin and rp1c0fw.bin (fw1+fw2, the
single image linked at 0x20000000). Needs the `lz4` CLI.
"""
import hashlib, os, struct, subprocess, sys

MAGIC_LZ4_FILE = 0x55aaf44f  # 16-byte name, LZ4 frame, 32-byte SHA-256 of plaintext


def sections(d):
    off = 0
    while off + 8 <= len(d):
        magic, ln = struct.unpack_from('>II', d, off)
        if magic & 0xffff0000 != 0x55aa0000:
            return
        yield magic, d[off + 8:off + 8 + ln]
        off = (off + 8 + ln + 7) & ~7


def main(src, out):
    os.makedirs(out, exist_ok=True)
    parts = {}
    for magic, body in sections(open(src, 'rb').read()):
        name = body[:16].rstrip(b'\0').decode(errors='replace')
        if magic != MAGIC_LZ4_FILE or not name.startswith('rp1c0fw'):
            continue
        frame, want = body[16:-32], body[-32:]
        data = subprocess.run(['lz4', '-d', '-c'], input=frame, capture_output=True, check=True).stdout
        assert hashlib.sha256(data).digest() == want, f'{name}: SHA-256 trailer mismatch'
        open(os.path.join(out, name), 'wb').write(data)
        parts[name] = data
        print(f'{name}: {len(data)} bytes sha256={hashlib.sha256(data).hexdigest()}')
    assert set(parts) == {'rp1c0fw1.bin', 'rp1c0fw2.bin'}, f'found {sorted(parts)}'
    # ponytail: assumes fw1 is exactly the first 16 KiB of one image (true for 2026-09-23);
    # recheck the base if fw1 size or the vector table changes.
    assert len(parts['rp1c0fw1.bin']) == 0x4000
    img = parts['rp1c0fw1.bin'] + parts['rp1c0fw2.bin']
    open(os.path.join(out, 'rp1c0fw.bin'), 'wb').write(img)
    print(f'rp1c0fw.bin: {len(img)} bytes sha256={hashlib.sha256(img).hexdigest()}')


if __name__ == '__main__':
    main(*sys.argv[1:3])
