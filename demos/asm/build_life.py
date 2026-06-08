"""build_life.py -- assemble demos/asm/life.s, verify it in the 6502 simulator,
and emit the binary blob (origin $6000) for transfer to the Apple over MCP.

Run with the 6502-codegen skill's harness on the path, e.g.:
    SK=<skill dir>
    uv run --with py65 python3 demos/asm/build_life.py "$SK/scripts" /tmp/life.bin
"""
import sys
from pathlib import Path

SCRIPTS = sys.argv[1]
OUT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/life.bin"
sys.path.insert(0, SCRIPTS)
import harness  # noqa: E402

ORIGIN = 0x6000
BUFA, BUFB = 0x7000, 0x7800
STRIDE = 42


def source_lines():
    """life.s minus what the simulator's assembler can't take: full-line `*`
    comments, blanks, and the `ORG` directive (we pass the origin explicitly).
    merlin32 honors the ORG; the simulator gets it via the origin argument."""
    src = (Path(__file__).resolve().parent / "life.s").read_text().splitlines()
    out = []
    for ln in src:
        s = ln.strip()
        if not s or s.startswith("*") or s.split()[0].upper() == "ORG":
            continue
        out.append(ln)
    return out


def monitor_dump(data, origin, per=8):
    """Apple ][ monitor listing: 'ADDR:BB BB ...' lines (uppercase hex), `per`
    bytes each. Paste into the monitor (CALL -151) or wrap in an EXEC file to
    install the program, then run with 6000G (monitor) or CALL 24576 (BASIC)."""
    lines = []
    for i in range(0, len(data), per):
        chunk = data[i:i + per]
        lines.append(f"{origin + i:04X}:" + " ".join(f"{b:02X}" for b in chunk))
    return "\n".join(lines) + "\n"


code, syms, end = harness.assemble(source_lines(), ORIGIN, cpu="65c02")
blob = bytes(code.get(a, 0) for a in range(ORIGIN, end))


def fresh():
    mpu, _ = harness._make("65c02")
    harness.load(mpu, code)
    return mpu


def setptr(mpu, zp, addr):
    mpu.memory[zp] = addr & 0xFF
    mpu.memory[zp + 1] = (addr >> 8) & 0xFF


def cell(base, r, c):
    return base + r * STRIDE + c


def run(mpu, label, steps=3_000_000):
    return harness.run(mpu, syms[label], max_steps=steps)


fails = []

# --- GEN: vertical blinker (col5, rows4-6) in BUFA -> horizontal in BUFB ---
m = fresh()
for r in (4, 5, 6):
    m.memory[cell(BUFA, r, 5)] = 1
setptr(m, syms["GU"], BUFA)
setptr(m, syms["GM"], BUFA + STRIDE)
setptr(m, syms["GDN"], BUFA + 2 * STRIDE)
setptr(m, syms["GDST"], BUFB + STRIDE)
run(m, "GEN")
horiz = all(m.memory[cell(BUFB, 5, c)] == 1 for c in (4, 5, 6))
ends = m.memory[cell(BUFB, 4, 5)] == 0 and m.memory[cell(BUFB, 6, 5)] == 0
print("GEN blinker -> horizontal:", "PASS" if horiz and ends else "FAIL")
if not (horiz and ends):
    fails.append("GEN blinker")

# --- GEN: 2x2 block is a still life ---
m = fresh()
for (r, c) in ((4, 5), (4, 6), (5, 5), (5, 6)):
    m.memory[cell(BUFA, r, c)] = 1
setptr(m, syms["GU"], BUFA)
setptr(m, syms["GM"], BUFA + STRIDE)
setptr(m, syms["GDN"], BUFA + 2 * STRIDE)
setptr(m, syms["GDST"], BUFB + STRIDE)
run(m, "GEN")
block = all(m.memory[cell(BUFB, r, c)] == 1 for (r, c) in ((4, 5), (4, 6), (5, 5), (5, 6)))
print("GEN block still-life:", "PASS" if block else "FAIL")
if not block:
    fails.append("GEN block")

# --- RENDER: corner cells map to the right interleaved screen bytes ---
m = fresh()
m.memory[cell(BUFA, 1, 1)] = 1     # top-left interior -> screen row0 col0 = $0400
m.memory[cell(BUFA, 24, 40)] = 1   # bottom-right -> screen row23 col39 = $07F7
setptr(m, syms["RBUF"], BUFA)
m.memory[syms["RPG"]] = 0
run(m, "RENDER")
tl = m.memory[0x0400] == 0xA1 and m.memory[0x0401] == 0xA0
br = m.memory[0x07F7] == 0xA1
print("RENDER addressing (corners):", "PASS" if tl and br else "FAIL",
      f"($0400={m.memory[0x0400]:02X} $07F7={m.memory[0x07F7]:02X})")
if not (tl and br):
    fails.append("RENDER")

# --- SEED: density is roughly the ~30% target over 960 cells ---
m = fresh()
run(m, "SEED")
alive = sum(m.memory[cell(BUFA, r, c)] == 1
            for r in range(1, 25) for c in range(1, 41))
ok = 200 <= alive <= 380     # 288 expected; allow spread
print(f"SEED density: {alive}/960 alive ->", "PASS" if ok else "FAIL")
if not ok:
    fails.append("SEED")

Path(OUT).write_bytes(blob)
mon = Path(__file__).resolve().parent / "life.mon"
mon.write_text(monitor_dump(blob, ORIGIN))
print("-" * 40)
print(f"assembled {len(blob)} bytes  ${ORIGIN:04X}-${end - 1:04X} -> {OUT}")
print(f"monitor listing -> {mon}")
print(f"START=${syms['START']:04X}  LFSR=${syms['LFSR']:04X}  DLYCT=${syms['DLYCT']:04X}")
print("RESULT:", "ALL PASS" if not fails else f"FAILURES: {fails}")
sys.exit(1 if fails else 0)
