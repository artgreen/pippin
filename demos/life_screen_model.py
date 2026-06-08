"""life_screen_model.py -- Python port of life_flip.bas's screen-as-state scheme.

life_flip.bas keeps the board *in text-screen memory* and double-buffers across
the two text pages, flipping the display each generation. There is no array:
a cell's value is the byte on screen ($A0 dead / $A1 alive '!', chosen one apart
so neighbor sums are trivial). This mirrors the exact memory addressing and the
rolling column-sum used by the BASIC, so the scheme can be checked against
conway_ref offline -- no Apple in the loop.

Speed note: rather than 9 PEEKs per cell, the BASIC keeps a rolling vertical
column-sum (three stacked cells). Sliding one column right reuses two of the
three columns, so each cell only reads the single *new* column -- 3 PEEKs/cell.
This model reproduces that exactly.

Geometry: a 40x24 text page with a one-cell dead frame, so the live interior is
cols 1..38 x rows 1..22 (38x22). Page 1 starts at $0400 (1024), page 2 at $0800
(2048) -- exactly +1024, which is why the BASIC just adds an offset SO/DO.
"""
DEAD = 0xA0          # 160, a blank space
ALIVE = 0xA1         # 161, '!' -- one above DEAD so a column sum counts cheaply
PAGE1 = 1024         # $0400
PAGE2 = 2048         # $0800
COLS, ROWS = 38, 22  # live interior


def rb(y: int) -> int:
    """Page-1 base address of text row y (same interleave as the display)."""
    return 1024 + (y % 8) * 128 + (y // 8) * 40


def blank_mem() -> bytearray:
    """Memory through both text pages, every screen byte blank ($A0)."""
    mem = bytearray(0x0C00)
    for a in range(PAGE1, PAGE2 + 1024):
        mem[a] = DEAD
    return mem


def seed(mem: bytearray, board: list[list[int]], page: int = PAGE1) -> None:
    """Write a ROWS x COLS 0/1 board into `page`'s interior (rows/cols 1-based)."""
    off = page - PAGE1
    for ry in range(ROWS):
        for rx in range(COLS):
            mem[rb(ry + 1) + off + (rx + 1)] = ALIVE if board[ry][rx] else DEAD


def step(mem: bytearray, src_page: int, dst_page: int) -> None:
    """One generation, mirroring life_flip.bas 1000-1090: a rolling column-sum
    slides across each row so only the entering column is read per cell.

    With every cell DEAD ($A0) or ALIVE ($A1), a 3-cell column sum is
    3*DEAD + (alive in that column). For the 3x3 window CA+CB+CC, subtracting
    8*DEAD and the centre byte MB leaves exactly the live-neighbor count.
    """
    so, do = src_page - PAGE1, dst_page - PAGE1
    k = 8 * DEAD
    for y in range(1, ROWS + 1):
        ua, ma, da, e = rb(y - 1) + so, rb(y) + so, rb(y + 1) + so, rb(y) + do
        ca = mem[ua] + mem[ma] + mem[da]            # column x-1 sum
        mb = mem[ma + 1]                            # centre byte at x=1
        cb = mem[ua + 1] + mb + mem[da + 1]         # column x sum
        for x in range(1, COLS + 1):
            j = x + 1
            mm = mem[ma + j]                        # centre of the entering column
            cc = mem[ua + j] + mm + mem[da + j]     # column x+1 sum (3 PEEKs)
            n = ca + cb + cc - k - mb               # live neighbors of (x, y)
            al = 1 if (n == 3 or (mb > DEAD and n == 2)) else 0
            mem[e + x] = DEAD + al
            ca, cb, mb = cb, cc, mm                 # slide the window right


def read_board(mem: bytearray, page: int) -> list[list[int]]:
    """Extract the ROWS x COLS interior of `page` as a 0/1 board."""
    off = page - PAGE1
    return [[1 if mem[rb(y) + off + x] == ALIVE else 0
             for x in range(1, COLS + 1)] for y in range(1, ROWS + 1)]
