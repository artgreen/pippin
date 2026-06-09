"""test_handler_sim.py -- execute the REAL assembled MAINRES-PIP.BIN handler in
a py65 6502 simulator and verify the binary protocol at the machine-code level.

We load the assembled image at $9000, poke a request frame into the RX ring
($9400), run `check_and_dispatch` ($9090), capture the bytes the handler writes
to the SSC data register ($C0A8) as the response, and assert correctness for all
five ops plus the adversarial frames the spec requires (bad checksum/opcode/
length, forbidden address, truncated, resync past leading garbage).

This verifies the handler LOGIC against the actual 6502 object code -- dispatch,
checksum, the I/O range guards, response framing, and hang-safety (every run is
bounded by a step budget; a hang would blow the budget and fail). It does NOT
exercise the IRQ/ProDOS wiring or the real-6551 TDRE/always-claim timing quirks
-- those are reused verbatim from the proven JSON path and are covered by the
on-hardware test.

The host codec (`pippin_protocol`) builds the requests and decodes the responses,
so a passing test confirms the host and Apple halves agree end-to-end.

Run:  uv run --with py65 --with pytest pytest tools/test_handler_sim.py -v
"""
import os

import pytest

from pippin_protocol import (
    encode_request, decode_response,
    OP_PING, OP_STATUS, OP_READ, OP_WRITE, OP_SENDKEY,
    ST_OK, ST_BAD_CK, ST_BAD_OP, ST_FORBIDDEN, ST_BAD_LEN,
)

py65_mpu = pytest.importorskip("py65.devices.mpu65c02")
from py65.devices.mpu65c02 import MPU          # noqa: E402
from py65.memory import ObservableMemory       # noqa: E402

# --- fixed addresses (deterministic from mainres-pip.s layout) ---
LOAD_ADDR    = 0x9000        # ORG of MAINRES-PIP.BIN
CAD_SCAN     = 0x9090        # check_and_dispatch entry (after the 16-byte state
                             # block at $9080; PING test below self-checks this)
RX_BUF       = 0x9400        # page-aligned RX ring
ZP_PENDING_KEY = 0xEC
ZP_RX_WR     = 0xED
ZP_RX_RD     = 0xEE
ZP_MACHINE   = 0xEF
SSC_DATA     = 0xC0A8        # handler writes response bytes here (we capture)
SSC_STATUS   = 0xC0A9        # handler polls TDRE(bit4)/RDRF(bit3) here
RET_SENTINEL = 0xFFF0        # cad_scan's terminal RTS returns here

BIN_PATH = os.path.join(os.path.dirname(__file__), "..", "src", "MAINRES-PIP.BIN")


def _load_image():
    # The image is a gitignored build artifact; skip (not error) in a fresh clone.
    try:
        with open(BIN_PATH, "rb") as f:
            return f.read()
    except FileNotFoundError:
        pytest.skip("src/MAINRES-PIP.BIN not built -- run `make pip` first")


def _make_machine(image):
    """Build an MPU with the handler image loaded and the SSC registers stubbed:
    STATUS always reads TDRE-ready / RDRF-clear ($10) so ssc_tx_byte never spins
    and its RX-drain path never fires; DATA writes are captured into tx[]."""
    mem = ObservableMemory()
    for i, b in enumerate(image):
        mem[LOAD_ADDR + i] = b

    tx = []
    mem.subscribe_to_write([SSC_DATA], lambda addr, val: tx.append(val & 0xFF))
    mem.subscribe_to_read([SSC_STATUS], lambda addr: 0x10)   # TDRE set, RDRF clear

    mpu = MPU(memory=mem)
    return mpu, mem, tx


def _run(mpu, mem, max_steps=3_000_000):
    """JSR-style call into cad_scan: seed the stack so the handler's terminal RTS
    lands on RET_SENTINEL, then single-step until it returns or the budget is
    exhausted. Returns the number of steps; raising past max_steps means a hang."""
    mem[0x01FF] = (RET_SENTINEL - 1) >> 8
    mem[0x01FE] = (RET_SENTINEL - 1) & 0xFF
    mpu.sp = 0xFD
    mpu.pc = CAD_SCAN
    steps = 0
    while mpu.pc != RET_SENTINEL and steps < max_steps:
        mpu.step()
        steps += 1
    assert steps < max_steps, f"handler did not return within {max_steps} steps (hang?)"
    return steps


def _drive(frame_bytes, *, machine=0x03, pending_key=0x00, premem=None):
    """Place a raw request frame in the ring, run the handler, return the captured
    response bytes. `premem` is an optional {addr: byte} map pre-loaded before the
    run (e.g. the bytes a READ should return)."""
    image = _load_image()
    mpu, mem, tx = _make_machine(image)
    mem[ZP_MACHINE] = machine
    mem[ZP_PENDING_KEY] = pending_key
    if premem:
        for a, b in premem.items():
            mem[a] = b
    # load the frame at ring offset 0; RD=0, WR=len (one frame buffered)
    for i, b in enumerate(frame_bytes):
        mem[RX_BUF + i] = b & 0xFF
    mem[ZP_RX_RD] = 0x00
    mem[ZP_RX_WR] = len(frame_bytes) & 0xFF
    _run(mpu, mem)
    return bytes(tx), mpu, mem


# --------------------------------------------------------------------------- #
# Build artifact must exist (run `make pip` first).
# --------------------------------------------------------------------------- #
def test_image_present_and_sized():
    img = _load_image()
    assert len(img) == 1536, f"MAINRES-PIP.BIN should be 1536 bytes, got {len(img)}"


# --------------------------------------------------------------------------- #
# Happy-path ops (request built by the host codec, response decoded by it).
# --------------------------------------------------------------------------- #
def test_ping():
    resp, _, _ = _drive(encode_request(OP_PING, b""))
    st, res = decode_response(resp)
    assert st == ST_OK and res == b""        # also validates CAD_SCAN entry addr


def test_status_block():
    resp, _, _ = _drive(encode_request(OP_STATUS, b""), machine=0x03, pending_key=0x07)
    st, res = decode_response(resp)
    assert st == ST_OK
    assert len(res) == 6
    assert res[0] == 0 and res[1] == 5       # version 0.5
    assert res[2] == 0x03                    # machine (//c+)
    assert res[5] == 0x07                    # pending_key we seeded
    # res[3]=wr, res[4]=rd are ring indices after the frame was consumed (WR==RD)


def test_read_returns_memory_bytes():
    # READ 4 bytes from a scratch page $0300 pre-loaded with DE AD BE EF
    data = {0x0300: 0xDE, 0x0301: 0xAD, 0x0302: 0xBE, 0x0303: 0xEF}
    resp, _, _ = _drive(encode_request(OP_READ, bytes([0x00, 0x03, 0x04])), premem=data)
    st, res = decode_response(resp)
    assert st == ST_OK
    assert res == bytes([0xDE, 0xAD, 0xBE, 0xEF])


def test_read_wrap_safe_high_count():
    # READ 200 bytes from $0800; each byte = its low address byte. Exercises a
    # long emit loop and the response length framing for a large RLEN. We read
    # from $0800 (not the text page $0400-$07FF) because the handler pokes the
    # comfort-marker cell $0427 on every dispatch -- reading that page back would
    # legitimately show the marker, which is expected behavior, not a bug.
    pre = {0x0800 + i: (0x0800 + i) & 0xFF for i in range(200)}
    resp, _, _ = _drive(encode_request(OP_READ, bytes([0x00, 0x08, 200])), premem=pre)
    st, res = decode_response(resp)
    assert st == ST_OK
    assert len(res) == 200
    assert res == bytes([(0x0800 + i) & 0xFF for i in range(200)])


def test_write_stores_bytes_and_acks():
    resp, mpu, mem = _drive(encode_request(OP_WRITE, bytes([0x00, 0x03, 0xCA, 0xFE, 0x42])))
    st, res = decode_response(resp)
    assert st == ST_OK and res == b""
    assert mem[0x0300] == 0xCA and mem[0x0301] == 0xFE and mem[0x0302] == 0x42


def test_sendkey_sets_pending_key():
    resp, mpu, mem = _drive(encode_request(OP_SENDKEY, bytes([0x0D])))
    st, res = decode_response(resp)
    assert st == ST_OK and res == b""
    assert mem[ZP_PENDING_KEY] == 0x0D


# --------------------------------------------------------------------------- #
# Adversarial frames -- each must return a clean ST error with no hang.
# --------------------------------------------------------------------------- #
def test_bad_checksum():
    frame = bytearray(encode_request(OP_STATUS, b""))
    frame[-1] ^= 0xFF                        # corrupt the CK
    resp, _, _ = _drive(bytes(frame))
    st, res = decode_response(resp)
    assert st == ST_BAD_CK and res == b""


def test_bad_opcode():
    # opcode 0x7F, ALEN 0, CK = 0x7F
    resp, _, _ = _drive(bytes([0xA5, 0x7F, 0x00, 0x7F]))
    st, res = decode_response(resp)
    assert st == ST_BAD_OP and res == b""


def test_bad_length_sendkey_wrong_alen():
    # SENDKEY with ALEN=2 (spec requires 1). This is the exact case the
    # check_alen fall-through bug accepted; it MUST now return ST_BAD_LEN.
    # frame: A5 04 02 0D 00 CK ; CK = (04+02+0D+00) & FF = 0x13
    resp, _, _ = _drive(bytes([0xA5, 0x04, 0x02, 0x0D, 0x00, 0x13]))
    st, res = decode_response(resp)
    assert st == ST_BAD_LEN and res == b""


def test_bad_length_read_zero_count():
    # READ with count=0 -> ST_BAD_LEN
    resp, _, _ = _drive(encode_request(OP_READ, bytes([0x00, 0x03, 0x00])))
    st, res = decode_response(resp)
    assert st == ST_BAD_LEN and res == b""


def test_bad_length_alen_wrap_no_hang():
    # ALEN=0xFC (252) makes total = (ALEN+4) & 0xFF wrap to 0. Before the fix
    # the "consume" step left RD parked on this A5 and cad_scan re-synced to it
    # forever -- a hang with IRQs off. The handler must now reject ALEN>130 up
    # front (drop the A5, resync) and return cleanly. _run() asserts no-hang via
    # its step budget; we also confirm the resync emits no response.
    resp, _, _ = _drive(bytes([0xA5, 0x00, 0xFC]) + bytes(300))
    assert resp == b""
    # neighbours of the wrap point must also be safe (253/254/255 advance RD).
    for alen in (0xFB, 0xFD, 0xFE, 0xFF):
        _drive(bytes([0xA5, 0x00, alen]) + bytes(300))   # must return (no hang)


def test_forbidden_read_io_space():
    # READ that touches $C000-$CFFF -> ST_FORBIDDEN (no speaker click etc.)
    resp, _, _ = _drive(encode_request(OP_READ, bytes([0x00, 0xC0, 0x10])))
    st, res = decode_response(resp)
    assert st == ST_FORBIDDEN and res == b""


def test_forbidden_read_crosses_into_io():
    # start below $C000 but length crosses into it: $BFF0 + 0x20 -> $C010
    resp, _, _ = _drive(encode_request(OP_READ, bytes([0xF0, 0xBF, 0x20])))
    st, res = decode_response(resp)
    assert st == ST_FORBIDDEN and res == b""


def test_forbidden_write_prodos_globals():
    # WRITE into $BF00-$BFFF (ProDOS globals) -> ST_FORBIDDEN
    resp, _, mem = _drive(encode_request(OP_WRITE, bytes([0x00, 0xBF, 0x99])))
    st, res = decode_response(resp)
    assert st == ST_FORBIDDEN and res == b""
    assert mem[0xBF00] != 0x99            # the forbidden write did NOT happen


def test_forbidden_write_io_space():
    resp, _, mem = _drive(encode_request(OP_WRITE, bytes([0x30, 0xC0, 0x99])))
    st, res = decode_response(resp)
    assert st == ST_FORBIDDEN and res == b""


def test_write_crosses_up_into_bf00_forbidden():
    # WRITE starting below $BF00 but long enough to reach it: $BEA0 + 97 -> $BF01.
    # The forbidden write zone is the contiguous $BF00-$CFFF, so this upward
    # crossing must be rejected and must not write anything. Guards the upper
    # boundary of check_range_write (the security-critical edge).
    resp, _, mem = _drive(encode_request(OP_WRITE, bytes([0xA0, 0xBE]) + bytes(97)))
    st, res = decode_response(resp)
    assert st == ST_FORBIDDEN and res == b""
    assert mem[0xBF00] == 0x00            # the forbidden write did NOT occur


def test_write_ends_exactly_at_bf00_allowed():
    # $BEA0 + 96 -> end == $BF00 exactly; the last written byte is $BEFF, below
    # the forbidden zone, so this is allowed (the boundary-exact OK edge).
    resp, _, mem = _drive(encode_request(OP_WRITE, bytes([0xA0, 0xBE]) + bytes([0xAB]) * 96))
    st, res = decode_response(resp)
    assert st == ST_OK and res == b""
    assert mem[0xBEFF] == 0xAB and mem[0xBF00] == 0x00


def test_truncated_frame_no_hang_no_response():
    # A5 02 03 announces a 3-arg READ (total 7 bytes) but only 5 are buffered.
    # cad_scan must see avail < total, RTS immediately, emit nothing -- no hang.
    image = _load_image()
    mpu, mem, tx = _make_machine(image)
    partial = bytes([0xA5, 0x02, 0x03, 0x00, 0x03])   # missing count + CK
    for i, b in enumerate(partial):
        mem[RX_BUF + i] = b
    mem[ZP_RX_RD] = 0x00
    mem[ZP_RX_WR] = len(partial)
    _run(mpu, mem)                       # asserts it returns within budget
    assert tx == [], "truncated frame must not produce a response"
    assert mem[ZP_RX_RD] == 0x00, "truncated frame must not advance RD"


def test_resync_past_leading_garbage():
    # Idle/garbage bytes before the A5 must be skipped (resync), then STATUS works.
    frame = bytes([0x00, 0x00, 0xFF]) + encode_request(OP_STATUS, b"")
    resp, _, _ = _drive(frame)
    st, res = decode_response(resp)
    assert st == ST_OK and len(res) == 6


def test_write_then_read_roundtrip():
    # WRITE 8 bytes to $0500, then READ them back -- two frames, same handler run.
    payload = bytes([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])
    wr = encode_request(OP_WRITE, bytes([0x00, 0x05]) + payload)
    rd = encode_request(OP_READ, bytes([0x00, 0x05, len(payload)]))
    image = _load_image()
    mpu, mem, tx = _make_machine(image)
    frame = wr + rd
    for i, b in enumerate(frame):
        mem[RX_BUF + i] = b
    mem[ZP_RX_RD] = 0x00
    mem[ZP_RX_WR] = len(frame) & 0xFF
    _run(mpu, mem)
    # tx now holds the WRITE ack frame (4 bytes) followed by the READ response.
    f1 = bytes(tx[:4])                   # A5 00 00 00  (write ack)
    st1, res1 = decode_response(f1)
    assert st1 == ST_OK and res1 == b""
    f2 = bytes(tx[4:])                   # A5 00 08 <8 bytes> CK
    st2, res2 = decode_response(f2)
    assert st2 == ST_OK and res2 == payload


# =========================================================================== #
# DIFFERENTIAL: the NMOS-6502 fast handler must behave EXACTLY like the proven
# 65C02 one.
#
# We run the SAME request frame through MAINRES-PIP.BIN on py65's 65C02 core and
# through MAINRES-PIP6502.BIN on py65's NMOS-6502 core, and assert the full
# observable result matches: the transmitted response bytes AND the bytes the
# handler wrote to a probed memory window AND the post-run ZP (RX_RD/RX_WR/
# PENDING_KEY). The two images come from one set of shared bodies via cpu.macs;
# the only difference is the 6502 opcode substitutions. Equality across ping/
# status/read/write/sendkey plus the adversarial frames (bad checksum/opcode/
# length, ALEN-wrap, forbidden range, truncated, resync) is strong evidence the
# substitutions and the IRQ-safe ZP scratch preserve semantics.
#
# (This is the fast/binary path -- the same handler the existing tests above
# cover. The JSON/LC path's identical-behavior claim rests on the 65C02
# byte-identity gate, the opcode scan, and the on-hardware round-trip.)
# --------------------------------------------------------------------------- #
import pytest as _pytest                                          # noqa: E402

_mpu6502 = _pytest.importorskip("py65.devices.mpu6502")
from py65.devices.mpu6502 import MPU as MPU_NMOS                  # noqa: E402

BIN6502_PATH = os.path.join(os.path.dirname(__file__), "..", "src",
                            "MAINRES-PIP6502.BIN")


def _load_image_6502():
    # Gitignored build artifact; skip (not error) in a fresh clone.
    try:
        with open(BIN6502_PATH, "rb") as f:
            return f.read()
    except FileNotFoundError:
        pytest.skip("src/MAINRES-PIP6502.BIN not built -- run `make pip6502` first")


def _make_machine_cpu(image, mpu_class):
    """Same stubbed-SSC harness as _make_machine, but with a selectable CPU core
    so we can run the 6502 image on the NMOS core and the 65C02 image on the
    65C02 core."""
    mem = ObservableMemory()
    for i, b in enumerate(image):
        mem[LOAD_ADDR + i] = b
    tx = []
    mem.subscribe_to_write([SSC_DATA], lambda addr, val: tx.append(val & 0xFF))
    mem.subscribe_to_read([SSC_STATUS], lambda addr: 0x10)
    return mpu_class(memory=mem), mem, tx


def _drive_cpu(image, mpu_class, frame_bytes, *, machine=0x03,
               pending_key=0x00, premem=None):
    """Run one frame through one CPU core; return (tx, mem) for comparison."""
    mpu, mem, tx = _make_machine_cpu(image, mpu_class)
    mem[ZP_MACHINE] = machine
    mem[ZP_PENDING_KEY] = pending_key
    if premem:
        for a, b in premem.items():
            mem[a] = b
    for i, b in enumerate(frame_bytes):
        mem[RX_BUF + i] = b & 0xFF
    mem[ZP_RX_RD] = 0x00
    mem[ZP_RX_WR] = len(frame_bytes) & 0xFF
    _run(mpu, mem)
    return bytes(tx), mem


def _assert_same(frame_bytes, *, machine=0x03, pending_key=0x00,
                 premem=None, probe=None):
    """Drive the same scenario on both CPUs and assert identical observable
    behavior. `probe` is an iterable of addresses whose post-run bytes must also
    match (e.g. the destination of a WRITE, or ZP_PENDING_KEY for SENDKEY)."""
    c02_img = _load_image()
    n02_img = _load_image_6502()
    tx_c, mem_c = _drive_cpu(c02_img, MPU, frame_bytes, machine=machine,
                             pending_key=pending_key, premem=premem)
    tx_n, mem_n = _drive_cpu(n02_img, MPU_NMOS, frame_bytes, machine=machine,
                             pending_key=pending_key, premem=premem)
    assert tx_c == tx_n, ("TX differs: 65C02=%s 6502=%s"
                          % (tx_c.hex(), tx_n.hex()))
    for z in (ZP_RX_RD, ZP_RX_WR, ZP_PENDING_KEY):
        assert mem_c[z] == mem_n[z], (
            "ZP $%02X differs: 65C02=$%02X 6502=$%02X"
            % (z, mem_c[z], mem_n[z]))
    for a in (probe or ()):
        assert mem_c[a] == mem_n[a], (
            "mem $%04X differs: 65C02=$%02X 6502=$%02X"
            % (a, mem_c[a], mem_n[a]))
    return tx_c


def test_diff_image_present_and_sized():
    img = _load_image_6502()
    assert len(img) == 1536, f"MAINRES-PIP6502.BIN should be 1536 bytes, got {len(img)}"


# ---- happy path ----
def test_diff_ping():
    tx = _assert_same(encode_request(OP_PING, b""))
    st, res = decode_response(tx)
    assert st == ST_OK and res == b""


def test_diff_status():
    tx = _assert_same(encode_request(OP_STATUS, b""), machine=0x01, pending_key=0x41)
    st, res = decode_response(tx)
    assert st == ST_OK and len(res) == 6 and res[2] == 0x01 and res[5] == 0x41


def test_diff_read():
    data = {0x0300: 0xDE, 0x0301: 0xAD, 0x0302: 0xBE, 0x0303: 0xEF}
    tx = _assert_same(encode_request(OP_READ, bytes([0x00, 0x03, 0x04])), premem=data)
    st, res = decode_response(tx)
    assert st == ST_OK and res == bytes([0xDE, 0xAD, 0xBE, 0xEF])


def test_diff_read_long():
    # Exercises a long (ZP_PTR),y read loop on both cores -- the indirect-indexed
    # load is identical opcode on 6502/65C02, but the surrounding emit loop is the
    # interesting differential.
    pre = {0x0800 + i: (i * 7) & 0xFF for i in range(200)}
    tx = _assert_same(encode_request(OP_READ, bytes([0x00, 0x08, 200])), premem=pre)
    st, res = decode_response(tx)
    assert st == ST_OK and len(res) == 200


def test_diff_write():
    tx = _assert_same(encode_request(OP_WRITE, bytes([0x00, 0x03, 0xCA, 0xFE, 0x42])),
                      probe=(0x0300, 0x0301, 0x0302))
    st, res = decode_response(tx)
    assert st == ST_OK and res == b""


def test_diff_write_64_bytes():
    # 64-byte WRITE (the JSON build's max; the binary protocol allows 128 --
    # see the boundary tests below) -- long (ZP_PTR),y store loop on both cores.
    payload = bytes((i * 3 + 1) & 0xFF for i in range(64))
    tx = _assert_same(encode_request(OP_WRITE, bytes([0x00, 0x05]) + payload),
                      probe=tuple(0x0500 + i for i in range(64)))
    st, res = decode_response(tx)
    assert st == ST_OK and res == b""


def test_diff_write_128_bytes_max():
    # The true binary-protocol max WRITE: 128 data bytes (ALEN=130, the largest
    # check_alen accepts). Boundary-exact accept on both cores.
    payload = bytes((i * 5 + 2) & 0xFF for i in range(128))
    tx = _assert_same(encode_request(OP_WRITE, bytes([0x00, 0x05]) + payload),
                      probe=tuple(0x0500 + i for i in range(128)))
    st, res = decode_response(tx)
    assert st == ST_OK and res == b""


def test_diff_write_129_bytes_dropped():
    # One past the max: 129 data bytes -> ALEN=131, which the up-front global
    # ALEN guard rejects BEFORE dispatch (drop the A5, resync, no response --
    # same contract as the ALEN-wrap test). Nothing may be written.
    payload = bytes([0x77]) * 129
    tx = _assert_same(encode_request(OP_WRITE, bytes([0x00, 0x05]) + payload),
                      probe=(0x0500, 0x0580))
    assert tx == b""


def test_diff_write_zero_data_bad_len():
    # WRITE with address but no data (ALEN=2 < 3) -> per-opcode check_alen
    # rejects with ST_BAD_LEN.
    tx = _assert_same(encode_request(OP_WRITE, bytes([0x00, 0x05])))
    st, res = decode_response(tx)
    assert st == ST_BAD_LEN and res == b""


def test_diff_sendkey():
    tx = _assert_same(encode_request(OP_SENDKEY, bytes([0x0D])), probe=(ZP_PENDING_KEY,))
    st, res = decode_response(tx)
    assert st == ST_OK and res == b""


# ---- adversarial frames ----
def test_diff_bad_checksum():
    frame = bytearray(encode_request(OP_STATUS, b""))
    frame[-1] ^= 0xFF
    tx = _assert_same(bytes(frame))
    st, _ = decode_response(tx)
    assert st == ST_BAD_CK


def test_diff_bad_opcode():
    tx = _assert_same(bytes([0xA5, 0x7F, 0x00, 0x7F]))
    st, _ = decode_response(tx)
    assert st == ST_BAD_OP


def test_diff_bad_length_sendkey():
    tx = _assert_same(bytes([0xA5, 0x04, 0x02, 0x0D, 0x00, 0x13]))
    st, _ = decode_response(tx)
    assert st == ST_BAD_LEN


def test_diff_bad_length_read_zero():
    tx = _assert_same(encode_request(OP_READ, bytes([0x00, 0x03, 0x00])))
    st, _ = decode_response(tx)
    assert st == ST_BAD_LEN


def test_diff_alen_wrap_no_hang():
    # ALEN=0xFC wrap -- both cores must reject up front and emit nothing.
    tx = _assert_same(bytes([0xA5, 0x00, 0xFC]) + bytes(300))
    assert tx == b""
    for alen in (0xFB, 0xFD, 0xFE, 0xFF):
        _assert_same(bytes([0xA5, 0x00, alen]) + bytes(300))


def test_diff_forbidden_read_io():
    tx = _assert_same(encode_request(OP_READ, bytes([0x00, 0xC0, 0x10])))
    st, _ = decode_response(tx)
    assert st == ST_FORBIDDEN


def test_diff_forbidden_read_crosses():
    tx = _assert_same(encode_request(OP_READ, bytes([0xF0, 0xBF, 0x20])))
    st, _ = decode_response(tx)
    assert st == ST_FORBIDDEN


def test_diff_forbidden_write_globals():
    tx = _assert_same(encode_request(OP_WRITE, bytes([0x00, 0xBF, 0x99])), probe=(0xBF00,))
    st, _ = decode_response(tx)
    assert st == ST_FORBIDDEN


def test_diff_forbidden_write_crosses_up():
    tx = _assert_same(encode_request(OP_WRITE, bytes([0xA0, 0xBE]) + bytes(97)), probe=(0xBF00,))
    st, _ = decode_response(tx)
    assert st == ST_FORBIDDEN


def test_diff_write_ends_at_bf00_allowed():
    tx = _assert_same(encode_request(OP_WRITE, bytes([0xA0, 0xBE]) + bytes([0xAB]) * 96),
                      probe=(0xBEFF, 0xBF00))
    st, _ = decode_response(tx)
    assert st == ST_OK


def test_diff_resync_past_garbage():
    frame = bytes([0x00, 0x00, 0xFF]) + encode_request(OP_STATUS, b"")
    tx = _assert_same(frame)
    st, res = decode_response(tx)
    assert st == ST_OK and len(res) == 6


def test_diff_truncated_no_response():
    # Partial frame: both cores RTS immediately, emit nothing, leave RD at 0.
    partial = bytes([0xA5, 0x02, 0x03, 0x00, 0x03])
    tx = _assert_same(partial)
    assert tx == b""


def test_diff_write_then_read_roundtrip():
    payload = bytes([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])
    wr = encode_request(OP_WRITE, bytes([0x00, 0x05]) + payload)
    rd = encode_request(OP_READ, bytes([0x00, 0x05, len(payload)]))
    tx = _assert_same(wr + rd, probe=tuple(0x0500 + i for i in range(8)))
    # tx = write ack (4) + read response
    st1, res1 = decode_response(bytes(tx[:4]))
    st2, res2 = decode_response(bytes(tx[4:]))
    assert st1 == ST_OK and res1 == b""
    assert st2 == ST_OK and res2 == payload
