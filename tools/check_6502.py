#!/usr/bin/env python3
"""check_6502.py -- fail if a build emitted any non-NMOS-6502 opcode.

Merlin32 v1.2 beta 2 accepts 65C02 opcodes regardless of the `xc` directive
(`xc` is documentation-only in this build), so it will NOT reject a stray 65C02
op in a 6502 target. This scans a build's `-V` listing and flags every emitted
opcode that is a 65C02 / Rockwell addition over the NMOS 6502 -- i.e. an opcode
that is undocumented/illegal on a real 6502. It is the build's true correctness
gate for the 6502 path.

It reads the opcode (first object byte of each emitted instruction) straight
from Merlin32's own decoded listing, so it never mistakes an operand or data
byte for an opcode. Pure stdlib -- no py65 needed.

Usage:
    check_6502.py LISTING.txt [LISTING2.txt ...]
Exit status: 0 if all clean, 1 if any listing emitted a non-6502 opcode.
"""
import re
import sys

# 65C02 / Rockwell opcodes that do NOT exist on the NMOS 6502 -> mnemonic.
C02_ONLY = {
    0x64: "stz zp", 0x74: "stz zp,x", 0x9C: "stz abs", 0x9E: "stz abs,x",
    0x80: "bra", 0x5A: "phy", 0x7A: "ply", 0xDA: "phx", 0xFA: "plx",
    0x04: "tsb zp", 0x0C: "tsb abs", 0x14: "trb zp", 0x1C: "trb abs",
    0x1A: "inc a", 0x3A: "dec a", 0x7C: "jmp (abs,x)",
    0x89: "bit #", 0x34: "bit zp,x", 0x3C: "bit abs,x",
    0x12: "ora (zp)", 0x32: "and (zp)", 0x52: "eor (zp)", 0x72: "adc (zp)",
    0x92: "sta (zp)", 0xB2: "lda (zp)", 0xD2: "cmp (zp)", 0xF2: "sbc (zp)",
    0xCB: "wai", 0xDB: "stp",
}
for _op in range(0x07, 0x100, 0x10):   # $x7 column: RMB0-7 / SMB0-7 (Rockwell)
    C02_ONLY.setdefault(_op, "rmb/smb")
for _op in range(0x0F, 0x100, 0x10):   # $xF column: BBR0-7 / BBS0-7 (Rockwell)
    C02_ONLY.setdefault(_op, "bbr/bbs")

# Merlin32 -V object field, e.g. "00/081D : 20 AF 08" -- grab addr + first byte.
_CODE = re.compile(r'/([0-9A-Fa-f]{4})\s*:\s*([0-9A-Fa-f]{2})')


def scan(listing_path):
    """Return [(addr, opcode, mnemonic)] for emitted non-NMOS-6502 opcodes."""
    bad = []
    with open(listing_path) as f:
        for line in f:
            cols = line.split('|')
            if len(cols) < 7 or cols[2].strip() != 'Code':
                continue
            m = _CODE.search(cols[6])
            if not m:
                continue
            addr, op = int(m.group(1), 16), int(m.group(2), 16)
            if op in C02_ONLY:
                bad.append((addr, op, C02_ONLY[op]))
    return bad


def main(argv):
    if len(argv) < 2:
        print("usage: check_6502.py LISTING.txt [LISTING2.txt ...]", file=sys.stderr)
        return 2
    rc = 0
    for path in argv[1:]:
        bad = scan(path)
        if bad:
            rc = 1
            print("FAIL %s: %d non-6502 opcode(s):" % (path, len(bad)))
            for addr, op, mn in bad:
                print("   $%04X: $%02X  %s" % (addr, op, mn))
        else:
            print("ok   %s: 0 non-6502 opcodes" % path)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
