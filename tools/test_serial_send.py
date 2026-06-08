import sys, os
import pytest
sys.path.insert(0, os.path.dirname(__file__))
import serial_send as ss


class FakeTransport:
    """Minimal transport double: records writes, replays queued read bytes."""
    def __init__(self, to_read=b""):
        self.written = b""
        self._to_read = bytes(to_read)
    def write(self, b):
        self.written += bytes(b)
    def read_chunk(self, n, timeout=0.5):
        chunk, self._to_read = self._to_read[:n], self._to_read[n:]
        return chunk
    def close(self):
        pass


def test_checksum16_empty():
    assert ss.checksum16(b"") == 0


def test_checksum16_simple():
    # 1 + 2 + 3 = 6
    assert ss.checksum16(bytes([1, 2, 3])) == 6


def test_checksum16_wraps_mod_65536():
    # checksum16 sums INDIVIDUAL bytes. 258 * 0xFF = 65790 = 0x100FE,
    # which exceeds 16 bits -> & 0xFFFF = 0x00FE.
    assert ss.checksum16(bytes([0xFF]) * 258) == 0x00FE


def test_sync_constant():
    assert ss.SYNC == b"\xA5\x5A"


def test_build_header_layout():
    # length 0x1234, checksum 0xABCD -> sync + LL LH + CL CH (little-endian)
    h = ss.build_header(0x1234, 0xABCD)
    assert h == b"\xA5\x5A" + bytes([0x34, 0x12, 0xCD, 0xAB])


def test_build_header_zero():
    assert ss.build_header(0, 0) == b"\xA5\x5A\x00\x00\x00\x00"


def test_build_header_rejects_oversize_length():
    with pytest.raises(ValueError):
        ss.build_header(0x10000, 0)


def test_build_header_rejects_oversize_checksum():
    with pytest.raises(ValueError):
        ss.build_header(0, 0x10000)


def test_read_ack_ok():
    status, raw = ss.read_ack(FakeTransport(b"\x00"))
    assert status == 0 and raw == b"\x00"


def test_read_ack_nonzero_reason():
    status, _ = ss.read_ack(FakeTransport(b"\x02"))
    assert status == 2


def test_read_ack_timeout_returns_none():
    status, raw = ss.read_ack(FakeTransport(b""), total_timeout=0.05)
    assert status is None and raw == b""


def test_send_file_ok():
    data = bytes([0x11, 0x22, 0x33])              # cksum 0x66
    t = FakeTransport(b"\x00")                     # receiver acks OK
    v = ss.send_file(t, data)
    assert v["ok"] is True and v["status"] == 0 and v["error"] is None
    # request header went out first: SYNC + len(3) LE + cksum(0x66) LE
    assert t.written[:6] == b"\xA5\x5A\x03\x00\x66\x00"
    assert t.written[6:] == data


def test_send_file_failure_status():
    t = FakeTransport(b"\x01")                     # receiver acks checksum mismatch
    v = ss.send_file(t, bytes([1, 2, 3]))
    assert v["ok"] is False and v["status"] == 1


def test_send_file_no_ack():
    v = ss.send_file(FakeTransport(b""), bytes([1, 2, 3]), result_timeout=0.05)
    assert v["ok"] is False and v["status"] is None and v["error"]


def test_status_names_cover_enum():
    assert ss.STATUS_NAMES[0] == "OK"
    assert set(ss.STATUS_NAMES) == {0, 1, 2, 3}
