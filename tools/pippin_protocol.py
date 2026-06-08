"""pippin_protocol.py -- PIP binary wire codec (pure, no I/O).

Request  host -> Apple:  A5 OP ALEN args[ALEN] CK   CK = (OP + ALEN + Σargs) & FF
Response Apple -> host:  A5 ST RLEN res[RLEN]  CK   CK = (ST + RLEN + Σres)  & FF
See docs/DESIGN.md (PIP binary protocol).
"""
SYNC = 0xA5

OP_PING, OP_STATUS, OP_READ, OP_WRITE, OP_SENDKEY = 0, 1, 2, 3, 4
ST_OK, ST_BAD_CK, ST_BAD_OP, ST_FORBIDDEN, ST_BAD_LEN = 0, 1, 2, 3, 4

ST_MESSAGES = {
    ST_BAD_CK: "Apple reported bad request checksum",
    ST_BAD_OP: "Apple reported bad opcode",
    ST_FORBIDDEN: "address range forbidden (I/O space $C000-$CFFF; "
                  "write also $BF00-$BFFF)",
    ST_BAD_LEN: "bad length or parameter",
}


class BadChecksum(Exception):
    """Response trailing checksum did not match the payload."""


class ShortFrame(Exception):
    """Frame too short, or missing the A5 sync byte."""


def checksum(payload: bytes) -> int:
    return sum(payload) & 0xFF


def encode_request(op: int, args: bytes) -> bytes:
    if not (0 <= op <= 0xFF):
        raise ValueError(f"op {op} out of byte range")
    if len(args) > 0xFF:
        raise ValueError(f"args length {len(args)} exceeds 255")
    alen = len(args)
    ck = checksum(bytes([op, alen]) + args)
    return bytes([SYNC, op, alen]) + args + bytes([ck])


def decode_response(frame: bytes) -> tuple[int, bytes]:
    if len(frame) < 4 or frame[0] != SYNC:
        raise ShortFrame(f"need >=4 bytes starting with A5, got {frame.hex()}")
    st, rlen = frame[1], frame[2]
    if len(frame) < 4 + rlen:
        raise ShortFrame(f"frame {frame.hex()} shorter than RLEN={rlen} implies")
    res = frame[3:3 + rlen]
    ck = frame[3 + rlen]
    if checksum(bytes([st, rlen]) + res) != ck:
        raise BadChecksum(f"computed {checksum(bytes([st, rlen]) + res):#04x} "
                          f"!= received {ck:#04x}")
    return st, bytes(res)
