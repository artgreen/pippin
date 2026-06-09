"""Verify life.bas's flattened algorithm matches the 2-D reference Conway.

If step_flat (the port of the BASIC) agrees with conway_ref.step on random
boards over multiple generations, the 1-D index math and neighbor offsets in
life.bas are correct -- confidence gained without touching the Apple.
"""
import random

import conway_ref as cr
from life_model import W, board_to_flat, flat_to_board, step_flat


def _random_board(seed: int, density: float = 0.35) -> list[list[int]]:
    rng = random.Random(seed)
    return [[1 if rng.random() < density else 0 for _ in range(W)] for _ in range(W)]


def test_flat_roundtrip_is_identity():
    b = _random_board(1)
    assert flat_to_board(board_to_flat(b)) == b


def test_flat_matches_reference_over_random_boards():
    for seed in range(25):
        board = _random_board(seed)
        flat = board_to_flat(board)
        for _ in range(6):                       # several generations deep
            board = cr.step(board)
            flat = step_flat(flat)
            assert flat_to_board(flat) == board, f"divergence at seed {seed}"


def test_flat_blinker_oscillates():
    # The same interior blinker we verified live on the //c+.
    board = cr.from_coords(W, W, [(4, 4), (4, 5), (4, 6)])
    flat = board_to_flat(board)
    flat1 = step_flat(flat)
    assert flat_to_board(flat1) == cr.step(board)        # vertical -> horizontal
    assert flat_to_board(step_flat(flat1)) == board      # back to vertical


def test_flat_respects_dead_edges():
    # A glider seeded against the corner, stepped with dead edges (no wrap):
    # its first steps exercise the border cells, and the flat model must match
    # the reference's dead-edge behaviour cell-for-cell.
    board = cr.from_coords(W, W, [(1, 0), (2, 1), (0, 2), (1, 2), (2, 2)])
    flat = board_to_flat(board)
    for _ in range(8):
        board = cr.step(board)
        flat = step_flat(flat)
    assert flat_to_board(flat) == board
