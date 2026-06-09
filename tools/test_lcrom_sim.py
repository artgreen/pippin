"""test_lcrom_sim.py -- execute the REAL assembled JSON-path images (MAINRES.BIN
at $9000 + LCROM.BIN at $D000) in a py65 65C02 simulator and verify the
newline-framed JSON-RPC protocol at the machine-code level.

Counterpart to test_handler_sim.py, which covers the PIP binary path; this
gives the PIPPIN (JSON) path the same treatment. We call the pinned LC entry
parse_dispatch ($D000) directly: the bank-switch trampoline in ssc_irq is not
modeled (py65 has no language card -- the LC image simply lives at $D000, and
parse_dispatch itself never touches the $C08x switches), and the SSC STATUS/
DATA registers are stubbed exactly like the PIP harness. Request frames go
into the RX ring at $9400; the transmitted response bytes are captured and
parsed back as JSON, so a passing test confirms the on-wire envelope is
well-formed end to end.

Like the PIP harness, this verifies the parser/handler LOGIC against the
actual object code -- classification, the order-independent scanner's frame
bound, the I/O range guards, response framing, and hang-safety (every run is
bounded by a step budget). It does NOT exercise the IRQ/ProDOS wiring, the
bank-switch trampoline, or the real-6551 timing quirks.

Run:  uv run --with py65 --with pytest pytest tools/test_lcrom_sim.py -v
"""
import json
import os

import pytest

py65_mpu = pytest.importorskip("py65.devices.mpu65c02")
from py65.devices.mpu65c02 import MPU          # noqa: E402
from py65.memory import ObservableMemory       # noqa: E402

# --- fixed addresses (deterministic from the mainres/lcrom layout) ---
MAINRES_ADDR   = 0x9000      # ORG of MAINRES.BIN
LC_ADDR        = 0xD000      # ORG of LCROM.BIN = parse_dispatch entry (pinned)
RX_BUF         = 0x9400      # page-aligned RX ring
ZP_PENDING_KEY = 0xEC
ZP_RX_WR       = 0xED
ZP_RX_RD       = 0xEE
ZP_MACHINE     = 0xEF
SSC_DATA       = 0xC0A8      # handler writes response bytes here (we capture)
SSC_STATUS     = 0xC0A9      # handler polls TDRE(bit4)/RDRF(bit3) here
RET_SENTINEL   = 0xFFF0      # parse_dispatch's terminal RTS returns here

HERE = os.path.dirname(__file__)
MAINRES_PATH = os.path.join(HERE, "..", "src", "MAINRES.BIN")
LCROM_PATH   = os.path.join(HERE, "..", "src", "LCROM.BIN")


def _load_image(path, name, want_size):
    # Gitignored build artifacts; skip (not error) in a fresh clone.
    try:
        with open(path, "rb") as f:
            img = f.read()
    except FileNotFoundError:
        pytest.skip(f"src/{name} not built -- run `make` first")
    assert len(img) == want_size, f"{name} should be {want_size} bytes, got {len(img)}"
    return img


def _make_machine():
    """MPU with both images loaded and the SSC stubbed: STATUS always reads
    TDRE-ready / RDRF-clear ($10) so ssc_tx_byte never spins and its RX-drain
    path never fires; DATA writes are captured into tx[]."""
    mainres = _load_image(MAINRES_PATH, "MAINRES.BIN", 1536)
    lcrom = _load_image(LCROM_PATH, "LCROM.BIN", 4096)
    mem = ObservableMemory()
    for i, b in enumerate(mainres):
        mem[MAINRES_ADDR + i] = b
    for i, b in enumerate(lcrom):
        mem[LC_ADDR + i] = b

    tx = []
    mem.subscribe_to_write([SSC_DATA], lambda addr, val: tx.append(val & 0xFF))
    mem.subscribe_to_read([SSC_STATUS], lambda addr: 0x10)   # TDRE set, RDRF clear

    mpu = MPU(memory=mem)
    return mpu, mem, tx


def _run(mpu, mem, max_steps=5_000_000):
    """JSR-style call into parse_dispatch: seed the stack so the terminal RTS
    lands on RET_SENTINEL, then single-step until it returns or the budget is
    exhausted (a hang would blow the budget and fail). Budget is larger than
    the PIP harness's: the tools/list reply alone is ~600 TX bytes, each paced
    by ssc_tx_byte's fixed delay loop."""
    mem[0x01FF] = (RET_SENTINEL - 1) >> 8
    mem[0x01FE] = (RET_SENTINEL - 1) & 0xFF
    mpu.sp = 0xFD
    mpu.pc = LC_ADDR
    steps = 0
    while mpu.pc != RET_SENTINEL and steps < max_steps:
        mpu.step()
        steps += 1
    assert steps < max_steps, f"handler did not return within {max_steps} steps (hang?)"
    return steps


def _drive(frame_bytes, *, machine=0x03, pending_key=0x00, premem=None,
           ring_fill=0x00):
    """Place raw frame bytes in the ring, run parse_dispatch, return the
    captured response bytes plus (mpu, mem). `ring_fill` pre-poisons every
    ring byte BEYOND the frame -- stale-traffic simulation for bound tests."""
    mpu, mem, tx = _make_machine()
    mem[ZP_MACHINE] = machine
    mem[ZP_PENDING_KEY] = pending_key
    if premem:
        for a, b in premem.items():
            mem[a] = b
    for i in range(256):
        mem[RX_BUF + i] = ring_fill
    for i, b in enumerate(frame_bytes):
        mem[RX_BUF + i] = b & 0xFF
    mem[ZP_RX_RD] = 0x00
    mem[ZP_RX_WR] = len(frame_bytes) & 0xFF
    _run(mpu, mem)
    return bytes(tx), mpu, mem


def _rpc(obj) -> bytes:
    return (json.dumps(obj, separators=(",", ":")) + "\n").encode("ascii")


def _call(name, arguments, rid=3) -> bytes:
    return _rpc({"jsonrpc": "2.0", "id": rid, "method": "tools/call",
                 "params": {"name": name, "arguments": arguments}})


def _response(tx: bytes):
    """The reply must be a single newline-terminated, parseable JSON object."""
    assert tx.endswith(b"\n"), f"unterminated response: {tx!r}"
    return json.loads(tx.decode("ascii"))


def _text(resp) -> str:
    return resp["result"]["content"][0]["text"]


# --------------------------------------------------------------------------- #
# MCP lifecycle methods.
# --------------------------------------------------------------------------- #
def test_initialize():
    tx, _, _ = _drive(_rpc({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                            "params": {"protocolVersion": "2024-11-05",
                                       "capabilities": {},
                                       "clientInfo": {"name": "sim", "version": "0"}}}))
    resp = _response(tx)
    assert resp["id"] == 1
    assert resp["result"]["protocolVersion"] == "2024-11-05"
    assert resp["result"]["serverInfo"] == {"name": "pippin", "version": "0.6"}


def test_notification_initialized_no_response():
    tx, _, _ = _drive(_rpc({"jsonrpc": "2.0",
                            "method": "notifications/initialized"}))
    assert tx == b"", "notifications must not produce a response"


def test_ping():
    tx, _, _ = _drive(_rpc({"jsonrpc": "2.0", "id": 7, "method": "ping"}))
    resp = _response(tx)
    assert resp == {"jsonrpc": "2.0", "id": 7, "result": {}}


def test_tools_list():
    tx, _, _ = _drive(_rpc({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}))
    resp = _response(tx)
    assert resp["id"] == 2
    assert [t["name"] for t in resp["result"]["tools"]] == ["s", "r", "w", "k"]


def test_method_keys_in_any_order():
    # The scanner is order-independent: id before method must classify too.
    tx, _, _ = _drive(_rpc({"id": 9, "jsonrpc": "2.0", "method": "ping"}))
    resp = _response(tx)
    assert resp["id"] == 9 and resp["result"] == {}


# --------------------------------------------------------------------------- #
# The four tools.
# --------------------------------------------------------------------------- #
def test_status():
    tx, _, _ = _drive(_rpc({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                            "params": {"name": "s", "arguments": {}}}))
    resp = _response(tx)
    assert resp["result"]["isError"] is False
    assert _text(resp).startswith("PIPPIN 0.6 m=3 ")


def test_read_memory():
    pre = {0x0300: 0xDE, 0x0301: 0xAD, 0x0302: 0xBE, 0x0303: 0xEF}
    tx, _, _ = _drive(_call("r", {"a": 768, "l": 4}), premem=pre)
    resp = _response(tx)
    assert resp["id"] == 3 and resp["result"]["isError"] is False
    assert _text(resp) == "deadbeef"


def test_write_memory():
    tx, _, mem = _drive(_call("w", {"a": 768, "v": "cafe42"}))
    resp = _response(tx)
    assert resp["result"]["isError"] is False and _text(resp) == "OK"
    assert mem[0x0300] == 0xCA and mem[0x0301] == 0xFE and mem[0x0302] == 0x42


def test_send_keystroke():
    tx, _, mem = _drive(_call("k", {"k": 65}))
    resp = _response(tx)
    assert resp["result"]["isError"] is False and _text(resp) == "OK"
    assert mem[ZP_PENDING_KEY] == 65


# --------------------------------------------------------------------------- #
# Range guards (mirrors the PIP harness coverage on the JSON build).
# --------------------------------------------------------------------------- #
def test_read_io_page_rejected():
    tx, _, _ = _drive(_call("r", {"a": 0xC000, "l": 16}))
    resp = _response(tx)
    assert resp["result"]["isError"] is True
    assert _text(resp) == "request rejected"


def test_write_prodos_globals_rejected():
    tx, _, mem = _drive(_call("w", {"a": 0xBF00, "v": "99"}))
    resp = _response(tx)
    assert resp["result"]["isError"] is True
    assert mem[0xBF00] != 0x99


def test_read_top_of_memory_allowed():
    # The exclusive-end fix on the JSON path: reading the IRQ vector at
    # $FFFE-$FFFF (end exactly $10000) is legal, not a wrap.
    pre = {0xFFFE: 0x34, 0xFFFF: 0x12}
    tx, _, _ = _drive(_call("r", {"a": 0xFFFE, "l": 2}), premem=pre)
    resp = _response(tx)
    assert resp["result"]["isError"] is False
    assert _text(resp) == "3412"


def test_read_wrap_past_top_rejected():
    tx, _, _ = _drive(_call("r", {"a": 0xFFFF, "l": 2}))
    resp = _response(tx)
    assert resp["result"]["isError"] is True


# --------------------------------------------------------------------------- #
# Frame-bound discipline (hostile/malformed frames).
# --------------------------------------------------------------------------- #
def test_short_method_does_not_probe_stale_ring_bytes():
    # Regression for the method[6] probe overshoot. The method value "t" puts
    # the frame's '\n' within 6 bytes of the discriminator, and every ring
    # byte beyond the frame is poisoned with 'l' -- stale traffic that the old
    # one-hop +6 probe would read, misclassifying this malformed frame as
    # tools/list and emitting a full bogus listing. The bounded probe must
    # yield the error envelope instead.
    frame = b'{"id":1,"method":"t"}\n'
    tx, _, _ = _drive(frame, ring_fill=ord("l"))
    resp = _response(tx)
    assert resp["result"]["isError"] is True
    assert _text(resp) == "request rejected"
    assert b'"tools"' not in tx, "stale ring byte was parsed as tools/list!"


def test_short_method_stale_c_not_tools_call():
    # Same overshoot, poisoned with 'c': must not classify as tools/call.
    frame = b'{"id":1,"method":"t"}\n'
    tx, _, _ = _drive(frame, ring_fill=ord("c"))
    resp = _response(tx)
    assert resp["result"]["isError"] is True


def test_unterminated_frame_no_response_no_hang():
    # No '\n' buffered: parse_dispatch must RTS with no output and leave the
    # partial frame unconsumed (RD unchanged), within the step budget.
    frame = b'{"jsonrpc":"2.0","id":1,"method":"ping"}'   # no terminator
    tx, _, mem = _drive(frame)
    assert tx == b""
    assert mem[ZP_RX_RD] == 0x00


def test_unknown_method_rejected():
    tx, _, _ = _drive(_rpc({"jsonrpc": "2.0", "id": 5, "method": "zap"}))
    resp = _response(tx)
    assert resp["result"]["isError"] is True


def test_two_frames_drained_in_one_call():
    # parse_dispatch loops until the ring is drained: two queued frames yield
    # two newline-terminated responses in order.
    pre = {0x0300: 0xAB}
    frames = (_call("r", {"a": 768, "l": 1}, rid=10)
              + _rpc({"jsonrpc": "2.0", "id": 11, "method": "ping"}))
    tx, _, _ = _drive(frames, premem=pre)
    parts = tx.split(b"\n")
    assert len(parts) == 3 and parts[2] == b""   # two replies + trailing split
    r1 = json.loads(parts[0])
    r2 = json.loads(parts[1])
    assert r1["id"] == 10 and _text(r1) == "ab"
    assert r2 == {"jsonrpc": "2.0", "id": 11, "result": {}}
