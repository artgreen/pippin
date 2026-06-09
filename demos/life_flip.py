"""life_flip.py -- the page-flipped, screen-as-state Game of Life, over MCP.

Drives life_flip.bas on the Apple: the board lives directly in the two text
pages, and each generation is built into the hidden page and revealed with a
single soft-switch flip -- flicker-free, no array, no copy. To free text page 2
($0800-$0BFF, normally Applesoft's program space), this first relocates the
program to $0C01, and *verifies* the relocation over MCP before typing anything
(if it failed, clearing page 2 would clobber the program).

The host watches by reading whichever page is currently displayed -- generation
parity tells us which: odd -> page 2 ($0800), even -> page 1 ($0400).

    uv run --with mcp python demos/life_flip.py --transport tcp --port 2023
    uv run --with mcp python demos/life_flip.py            # serial (auto-detect)
"""
import argparse
import asyncio
import sys
from pathlib import Path

from apple import Apple, char_row_base, render_grid

LIFE_BAS = Path(__file__).resolve().parent / "life_flip.bas"
SENTINEL = 768          # $0300: BASIC POKEs the generation number here
TXTTAB_LO, TXTTAB_HI = 103, 104   # $67/$68: Applesoft program-start pointer
RELOCATE = "POKE 103,1:POKE 104,12:POKE 3072,0:NEW"   # move program to $0C01
COLS, ROWS = 38, 22     # live interior (one-cell dead frame)
MAX_GEN = 100
ALIVE_BYTE = 0xA1   # '!' in normal-video text ($21 | $80)


def program_lines() -> list[str]:
    return [ln.rstrip("\n") for ln in LIFE_BAS.read_text().splitlines() if ln.strip()]


async def read_board(ap: Apple, gen: int) -> list[list[int]]:
    """Read the currently displayed page's interior as a 0/1 grid. Odd gens show
    page 2 ($0800 = page-1 base + $400); even gens show page 1."""
    off = 0x400 if (gen % 2 == 1) else 0
    rows = []
    for r in range(1, ROWS + 1):
        raw = await ap.read_mem(char_row_base(r) + off + 1, COLS)
        rows.append([1 if b == ALIVE_BYTE else 0 for b in raw])
    return rows


async def wait_for(ap: Apple, target: int, poll: float, timeout: float,
                   exact: bool = False) -> int | None:
    """Poll the sentinel until it reaches `target`. Matches >= rather than ==
    so a generation that ticks past between polls (the BASIC runs ~1.9 s/gen
    while each rendered frame costs 22 read round-trips) can't strand the wait.
    Returns the observed generation, or None on timeout.

    `exact` is for the initial sync on 0: any stale byte satisfies >= 0, so
    the caller arms the sentinel with a value the BASIC never writes and then
    waits for the exact 0 that line 70 pokes once the pages are seeded."""
    waited = 0.0
    while waited < timeout:
        gen = await ap.read_byte(SENTINEL)
        if (gen == target) if exact else (gen >= target):
            return gen
        await asyncio.sleep(poll)
        waited += poll
    return None


async def run(args) -> int:
    async with Apple.connect(transport=args.transport, host=args.host,
                             port=args.port, device=args.device) as ap:
        print("status ->", await ap.status())

        print("relocating program to $0C01 to free text page 2...")
        await ap.type_line(RELOCATE)
        # The line executes asynchronously after its RETURN, so poll for the
        # effect rather than reading once (a single read can beat POKE 104,12).
        for _ in range(20):
            if (await ap.read_byte(TXTTAB_LO), await ap.read_byte(TXTTAB_HI)) == (1, 12):
                break
            await asyncio.sleep(0.2)
        else:
            hi = await ap.read_byte(TXTTAB_HI)
            print(f"relocation FAILED: TXTTAB hi=${hi:02X}, expected $0C. Aborting "
                  "before typing (page 2 would collide with the program).")
            return 1
        print("  relocation confirmed: TXTTAB = $0C01")

        print(f"typing {LIFE_BAS.name} ({COLS}x{ROWS} cells, page-flipped)...")
        await ap.type_program(program_lines())

        print("RUN -- clearing both pages and seeding (a few seconds)...\n")
        # Arm the sentinel with a value the BASIC never writes (gens are
        # 0..100) so a stale generation count from a previous run can't
        # satisfy the initial wait before the new run has seeded the pages.
        await ap.write_mem(SENTINEL, bytes([255]))
        await ap.type_line("RUN")

        if await wait_for(ap, 0, args.poll, timeout=40, exact=True) is None:
            print("never reached initial frame; check the Apple's screen.")
            return 1

        shown = 0
        target = 1
        while shown < args.gens:
            gen = await wait_for(ap, target, args.poll, timeout=60)
            if gen is None:
                print(f"generation {target}: timeout")
                return 1
            # Render the generation actually observed (it may have skipped past
            # `target`); its parity picks the page that is really displayed.
            board = await read_board(ap, gen)
            after = await ap.read_byte(SENTINEL)
            live = sum(sum(r) for r in board)
            page = 2 if gen % 2 else 1
            torn = "" if after == gen else f"  (advanced to {after} mid-read; may be torn)"
            print(f"=== generation {gen}  ({live} alive)  [showing page {page}]{torn} ===")
            print(render_grid(board, alive="#", dead="."))
            print()
            shown += 1
            target = gen + 1
        print(f"(continues to generation {MAX_GEN} on the Apple...)")
        return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="Page-flipped screen-state Life over MCP.")
    p.add_argument("--transport", choices=["serial", "tcp"], default="tcp")
    p.add_argument("--device", default=None)
    p.add_argument("--host", default="localhost")
    p.add_argument("--port", type=int, default=2023)
    p.add_argument("--poll", type=float, default=2.0, metavar="SEC",
                   help="frame-sentinel poll interval (keep gentle; reads steal "
                        "foreground cycles)")
    p.add_argument("--gens", type=int, default=8, metavar="N",
                   help="how many generations to render here before stopping")
    return asyncio.run(run(p.parse_args(argv)))


if __name__ == "__main__":
    sys.exit(main())
