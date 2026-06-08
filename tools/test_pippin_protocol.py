import pytest
from pippin_protocol import (
    checksum, encode_request, decode_response,
    OP_PING, OP_STATUS, OP_READ, OP_WRITE, OP_SENDKEY,
    ST_OK, ST_BAD_CK, ST_BAD_OP, ST_FORBIDDEN, ST_BAD_LEN,
    BadChecksum, ShortFrame,
)

def test_checksum_wraps_mod_256():
    assert checksum(b"\xDE\xAD") == (0xDE + 0xAD) & 0xFF

def test_encode_ping():
    # A5 00 00 00
    assert encode_request(OP_PING, b"") == bytes([0xA5, 0x00, 0x00, 0x00])

def test_encode_status():
    # A5 01 00 01
    assert encode_request(OP_STATUS, b"") == bytes([0xA5, 0x01, 0x00, 0x01])

def test_encode_read():
    # READ 4 bytes @ $0300: A5 02 03 00 03 04 0C
    assert encode_request(OP_READ, bytes([0x00, 0x03, 0x04])) == \
        bytes([0xA5, 0x02, 0x03, 0x00, 0x03, 0x04, 0x0C])

def test_encode_write():
    # WRITE DE AD @ $0300: A5 03 04 00 03 DE AD 95
    assert encode_request(OP_WRITE, bytes([0x00, 0x03, 0xDE, 0xAD])) == \
        bytes([0xA5, 0x03, 0x04, 0x00, 0x03, 0xDE, 0xAD, 0x95])

def test_encode_sendkey():
    # SENDKEY 13: A5 04 01 0D 12
    assert encode_request(OP_SENDKEY, bytes([0x0D])) == \
        bytes([0xA5, 0x04, 0x01, 0x0D, 0x12])

def test_decode_status_response():
    # A5 00 06 00 05 03 1A 1A 00 42
    frame = bytes([0xA5, 0x00, 0x06, 0x00, 0x05, 0x03, 0x1A, 0x1A, 0x00, 0x42])
    st, res = decode_response(frame)
    assert st == ST_OK
    assert res == bytes([0x00, 0x05, 0x03, 0x1A, 0x1A, 0x00])

def test_decode_error_response():
    # bad opcode: A5 02 00 02
    st, res = decode_response(bytes([0xA5, 0x02, 0x00, 0x02]))
    assert st == ST_BAD_OP
    assert res == b""

def test_decode_bad_ck_status():
    # ST_BAD_CK error frame (RLEN=0, CK = ST = 0x01): A5 01 00 01
    st, res = decode_response(bytes([0xA5, 0x01, 0x00, 0x01]))
    assert st == ST_BAD_CK
    assert res == b""

def test_decode_forbidden_status():
    # ST_FORBIDDEN error frame (RLEN=0, CK = ST = 0x03): A5 03 00 03
    st, res = decode_response(bytes([0xA5, 0x03, 0x00, 0x03]))
    assert st == ST_FORBIDDEN
    assert res == b""

def test_decode_bad_len_status():
    # ST_BAD_LEN error frame (RLEN=0, CK = ST = 0x04): A5 04 00 04
    st, res = decode_response(bytes([0xA5, 0x04, 0x00, 0x04]))
    assert st == ST_BAD_LEN
    assert res == b""

def test_decode_bad_checksum_raises():
    # STATUS resp with wrong trailing CK
    bad = bytes([0xA5, 0x00, 0x06, 0x00, 0x03, 0x03, 0x1A, 0x1A, 0x00, 0xFF])
    with pytest.raises(BadChecksum):
        decode_response(bad)

def test_decode_short_frame_raises():
    with pytest.raises(ShortFrame):
        decode_response(bytes([0xA5, 0x00]))

def test_decode_bad_sync_raises():
    with pytest.raises(ShortFrame):
        decode_response(bytes([0x00, 0x00, 0x00, 0x00]))

def test_roundtrip_encode_then_manual_decode():
    req = encode_request(OP_READ, bytes([0x00, 0x04, 0x10]))
    assert req[0] == 0xA5 and req[1] == OP_READ and req[2] == 3
    assert req[-1] == checksum(bytes([OP_READ, 3]) + bytes([0x00, 0x04, 0x10]))
