"""Tests for the pure lo-res decode/render helpers in apple.py."""
from apple import lores_addr, lores_nibble, decode_char_row, render_grid


def test_lores_addr_shares_byte_between_stacked_rows():
    # Rows 0 and 1 of column 5 live in the same byte (char row 0).
    assert lores_addr(5, 0) == lores_addr(5, 1) == 0x0400 + 5
    # Rows 2 and 3 are char row 1 -> +$80 in the interleave.
    assert lores_addr(0, 2) == 0x0480
    assert lores_addr(0, 3) == 0x0480
    # Row 16 -> char row 8 -> second interleave group (+$28).
    assert lores_addr(0, 16) == 0x0428


def test_lores_nibble_low_for_even_high_for_odd():
    assert lores_nibble(0xF0, 0) == 0x0   # even row -> low nibble
    assert lores_nibble(0xF0, 1) == 0xF   # odd row -> high nibble
    assert lores_nibble(0x3C, 2) == 0xC
    assert lores_nibble(0x3C, 3) == 0x3


def test_decode_char_row_splits_nibbles():
    top, bot = decode_char_row(bytes([0x0F, 0xF0, 0x12]))
    assert top == [0x0F & 0x0F, 0x00, 0x02]   # low nibbles -> even/top pixel row
    assert bot == [0x00, 0x0F, 0x01]          # high nibbles -> odd/bottom pixel row


def test_decode_char_row_matches_lores_nibble():
    raw = bytes([0x00, 0x1F, 0xA5, 0xF0])
    top, bot = decode_char_row(raw)
    for x, b in enumerate(raw):
        assert top[x] == lores_nibble(b, 0)   # even row
        assert bot[x] == lores_nibble(b, 1)   # odd row


def test_render_grid_marks_nonblack_alive():
    grid = [[0, 15, 0], [15, 0, 15]]
    assert render_grid(grid) == ".#.\n#.#"
    assert render_grid(grid, alive="O", dead=" ") == " O \nO O"
