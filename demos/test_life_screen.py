"""Verify life_flip.bas's screen-as-state, page-flipped scheme matches Conway.

If the screen model (exact memory addressing + the $A0/$A1 +1 encoding +
alternating page buffers) agrees with conway_ref across random boards and many
generations, the BASIC's addressing and encoding are correct -- confidence
gained without touching the Apple.
"""
import random

import conway_ref as cr
import life_screen_model as m


def _random_board(seed: int, density: float = 0.35) -> list[list[int]]:
    rng = random.Random(seed)
    return [[1 if rng.random() < density else 0 for _ in range(m.COLS)]
            for _ in range(m.ROWS)]


def test_seed_roundtrip():
    b = _random_board(7)
    mem = m.blank_mem()
    m.seed(mem, b, m.PAGE1)
    assert m.read_board(mem, m.PAGE1) == b


def test_pages_are_1024_apart():
    # The BASIC relies on page 2 being exactly page 1 + 1024 (a constant offset).
    assert m.PAGE2 - m.PAGE1 == 1024
    assert m.rb(0) == m.PAGE1 and m.rb(23) == 0x07D0


def test_flip_scheme_matches_reference():
    for seed in range(25):
        board = _random_board(seed)
        mem = m.blank_mem()
        m.seed(mem, board, m.PAGE1)
        src, dst = m.PAGE1, m.PAGE2
        for _ in range(8):                       # eight generations, alternating pages
            board = cr.step(board)
            m.step(mem, src, dst)
            assert m.read_board(mem, dst) == board, f"divergence at seed {seed}"
            src, dst = dst, src                  # page flip


def test_dead_frame_stays_blank():
    # The one-cell border is never written and must remain dead on both pages.
    board = _random_board(3)
    mem = m.blank_mem()
    m.seed(mem, board, m.PAGE1)
    m.step(mem, m.PAGE1, m.PAGE2)
    for off in (0, 1024):
        assert mem[m.rb(0) + off + 0] == m.DEAD       # top-left corner frame
        assert mem[m.rb(23) + off + 39] == m.DEAD     # bottom-right corner frame
