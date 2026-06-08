"""life_model.py -- a faithful Python port of life.bas's flattened algorithm.

life.bas stores the board in 1-D arrays indexed I = Y*S + X (stride S=22, with
X,Y in 1..W and a zeroed border ring), and counts neighbors with the constant
offsets +-1, +-(S-1), +-S, +-(S+1) = +-1, +-21, +-22, +-23. This module mirrors
that exact scheme so its correctness can be checked against conway_ref (the
plain 2-D dead-edge reference) offline, with no hardware in the loop.

Why 1-D *real* arrays in the BASIC, not integer (%)? Applesoft holds every
number as a float internally, so integer arrays pay a convert-on-every-access
tax; real arrays are as-fast-or-faster for arithmetic. The speed win is the
flattening (no per-access 2-D address multiply) plus declaring hot variables
first, not the element type.
"""
W = 20          # live board is W x W
S = 22          # row stride (W + 2 border columns)
SIZE = S * S    # 484 cells including the border ring

# Neighbor offsets in the flattened array (must match life.bas line 1010).
OFFSETS = (-S - 1, -S, -S + 1, -1, 1, S - 1, S, S + 1)


def board_to_flat(board: list[list[int]]) -> list[int]:
    """A W x W 0/1 board -> flattened array with a zeroed border ring."""
    flat = [0] * SIZE
    for y in range(W):
        for x in range(W):
            flat[(y + 1) * S + (x + 1)] = board[y][x]
    return flat


def flat_to_board(flat: list[int]) -> list[list[int]]:
    """Inverse of board_to_flat: extract the W x W interior."""
    return [[flat[(y + 1) * S + (x + 1)] for x in range(W)] for y in range(W)]


def step_flat(flat: list[int]) -> list[int]:
    """One generation on the flattened board. Mirrors life.bas exactly: borders
    stay 0 (never written), so off-board neighbors count as dead."""
    new = flat[:]
    for y in range(1, W + 1):
        i = y * S
        for _ in range(1, W + 1):
            i += 1
            n = sum(flat[i + d] for d in OFFSETS)
            new[i] = 1 if (n == 3 or (flat[i] and n == 2)) else 0
    return new
