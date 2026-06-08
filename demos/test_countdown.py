"""Unit tests for the pure screen-decode helpers in countdown.py.

These cover the fiddly parts that are easy to get wrong without hardware: the
interleaved text-page row addresses and the high-bit display-byte decoding.
Run from this directory:

    uv run --with mcp pytest demos/test_countdown.py
"""
from countdown import text_row_base, decode_screen_byte, decode_row


def _encode(text: str) -> bytes:
    """Text -> normal-video screen bytes (ASCII with the high bit set)."""
    return bytes((ord(c) | 0x80) for c in text)


def test_row_bases_match_apple_interleave():
    # The three group starts and a couple of in-group steps, plus the last row.
    assert text_row_base(0) == 0x0400
    assert text_row_base(1) == 0x0480   # +$80 within the first group
    assert text_row_base(8) == 0x0428   # second group, +$28
    assert text_row_base(16) == 0x0450  # third group, +$50
    assert text_row_base(23) == 0x07D0  # last row


def test_all_rows_are_distinct_and_in_range():
    bases = [text_row_base(r) for r in range(24)]
    assert len(set(bases)) == 24
    assert all(0x0400 <= b <= 0x07FF for b in bases)


def test_decode_byte_strips_high_bit():
    assert decode_screen_byte(0xC1) == "A"
    assert decode_screen_byte(0xB0) == "0"
    assert decode_screen_byte(0xA1) == "!"
    assert decode_screen_byte(0xA0) == " "  # space


def test_decode_byte_non_printable_becomes_space():
    assert decode_screen_byte(0x00) == " "  # inverse '@' glyph -> blank
    assert decode_screen_byte(0x1F) == " "


def test_decode_row_trims_trailing_blanks():
    raw = _encode("LIFTOFF!") + bytes([0xA0]) * 32  # 40-col row, mostly blank
    assert decode_row(raw) == "LIFTOFF!"


def test_decode_row_keeps_interior_spaces():
    assert decode_row(_encode("10 FOR I = 10")) == "10 FOR I = 10"
