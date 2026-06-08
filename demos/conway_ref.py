"""conway_ref.py -- a tiny pure-Python Conway's Game of Life (dead edges).

Reference implementation used to cross-check the boards we read back off the
Apple over MCP. Same rules and boundary behaviour as demos/life.bas: cells
outside the grid count as dead (no wrap). A board is a list of rows, each a list
of 0/1 ints.
"""


def step(board: list[list[int]]) -> list[list[int]]:
    """One Conway generation with dead edges."""
    h = len(board)
    w = len(board[0]) if h else 0
    out = [[0] * w for _ in range(h)]
    for y in range(h):
        for x in range(w):
            n = 0
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    if dx == 0 and dy == 0:
                        continue
                    ny, nx = y + dy, x + dx
                    if 0 <= ny < h and 0 <= nx < w:
                        n += board[ny][nx]
            out[y][x] = 1 if (n == 3 or (board[y][x] and n == 2)) else 0
    return out


def from_coords(w: int, h: int, live: list[tuple[int, int]]) -> list[list[int]]:
    """Build a w x h board with the given (x, y) cells alive."""
    board = [[0] * w for _ in range(h)]
    for x, y in live:
        board[y][x] = 1
    return board
