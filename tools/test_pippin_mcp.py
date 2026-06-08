import pytest
from pippin_mcp import PippinClient, McpToolError
from pippin_protocol import OP_READ, ST_OK

class FakeTransport:
    def __init__(self, scripted):  # scripted: list of bytes blobs to return
        self.scripted = list(scripted); self.writes = []
    def write(self, data): self.writes.append(data)
    def read_chunk(self, maxn, timeout):
        return self.scripted.pop(0) if self.scripted else b""
    def close(self): pass

def test_exchange_ok():
    # READ 1 byte @ $0300 -> resp A5 00 01 7F 80
    t = FakeTransport([bytes([0xA5, 0x00, 0x01, 0x7F, 0x80])])
    c = PippinClient(t)
    st, res = c.exchange(OP_READ, bytes([0x00, 0x03, 0x01]))
    assert st == ST_OK and res == bytes([0x7F])

def test_exchange_retransmits_on_bad_ck_then_succeeds():
    good = bytes([0xA5, 0x00, 0x01, 0x7F, 0x80])
    bad  = bytes([0xA5, 0x00, 0x01, 0x7F, 0xFF])  # wrong CK
    t = FakeTransport([bad, good])
    c = PippinClient(t)
    st, res = c.exchange(OP_READ, bytes([0x00, 0x03, 0x01]))
    assert st == ST_OK and res == bytes([0x7F])
    assert len(t.writes) == 2  # retransmitted once

def test_read_memory_rejects_bad_length():
    c = PippinClient(FakeTransport([]))
    with pytest.raises(McpToolError):
        c.read_memory(0x0300, 0)      # length 0
    with pytest.raises(McpToolError):
        c.read_memory(0x0300, 256)    # length > 255

def test_write_memory_rejects_odd_hex():
    c = PippinClient(FakeTransport([]))
    with pytest.raises(McpToolError):
        c.write_memory(0x0300, "abc")

def test_exchange_retries_on_st_bad_ck():
    from pippin_protocol import ST_OK
    bad = bytes([0xA5, 0x01, 0x00, 0x01])           # ST=01 bad-checksum, valid response CK
    good = bytes([0xA5, 0x00, 0x01, 0x7F, 0x80])    # READ 1 byte -> 0x7F
    t = FakeTransport([bad, good])
    c = PippinClient(t)
    st, res = c.exchange(OP_READ, bytes([0x00, 0x03, 0x01]))
    assert st == ST_OK and res == bytes([0x7F])
    assert len(t.writes) == 2                        # retransmitted on ST=01

def test_st_not_ok_raises_with_message():
    t = FakeTransport([bytes([0xA5, 0x03, 0x00, 0x03])])   # ST=03 forbidden, RLEN=0
    c = PippinClient(t)
    with pytest.raises(McpToolError, match="forbidden"):
        c.read_memory(0x0300, 4)
