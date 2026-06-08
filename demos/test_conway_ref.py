"""Tests for the reference Conway implementation (dead edges)."""
from conway_ref import step, from_coords


def test_blinker_oscillates_period_2():
    # Vertical 3-cell blinker centered in a 5x5 grid -> horizontal -> vertical.
    vert = from_coords(5, 5, [(2, 1), (2, 2), (2, 3)])
    horiz = from_coords(5, 5, [(1, 2), (2, 2), (3, 2)])
    assert step(vert) == horiz
    assert step(horiz) == vert


def test_block_is_a_still_life():
    block = from_coords(4, 4, [(1, 1), (2, 1), (1, 2), (2, 2)])
    assert step(block) == block


def test_glider_returns_to_shape_shifted_after_4_steps():
    g = from_coords(8, 8, [(1, 0), (2, 1), (0, 2), (1, 2), (2, 2)])
    after = g
    for _ in range(4):
        after = step(after)
    # A glider moves one cell down-right every 4 generations.
    expected = from_coords(8, 8, [(2, 1), (3, 2), (1, 3), (2, 3), (3, 3)])
    assert after == expected


def test_lone_cell_dies():
    assert step(from_coords(3, 3, [(1, 1)])) == from_coords(3, 3, [])


def test_dead_edges_no_wrap():
    # A blinker against the top edge loses its off-board neighbor; the middle
    # row survives but nothing wraps in from the bottom.
    b = from_coords(5, 5, [(0, 0), (1, 0), (2, 0)])
    nxt = step(b)
    assert nxt[0][1] == 1 and nxt[1][1] == 1   # vertical pair forms at column 1
    assert all(nxt[4][x] == 0 for x in range(5))  # nothing appears at the far edge
