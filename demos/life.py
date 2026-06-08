"""life.py -- type Conway's Game of Life onto the Apple over MCP, run it, and
render each generation live by reading lo-res screen memory.

This is the showpiece driver. It loads demos/life.bas, types it onto the live
//c+ at the `]` prompt, RUNs it, then polls the frame sentinel at $0300; each
time the generation counter ticks it reads the 20x20 board out of lo-res page 1
($0400) and prints it as a grid. The Apple does all the computation.

    tools/serial_bridge.sh                       # only if using --transport tcp
    uv run --with mcp python demos/life.py                 # serial (auto-detect)
    uv run --with mcp python demos/life.py --transport tcp # via bridge on :1977

Loops are bounded in the BASIC (FOR G=1 TO 100); we cannot Ctrl-C a running
program over MCP, so to watch longer, raise N in life.bas or re-run.
"""
import argparse
import asyncio
import sys
from pathlib import Path

from apple import Apple, render_grid

LIFE_BAS = Path(__file__).resolve().parent / "life.bas"
SENTINEL = 768          # $0300: BASIC POKEs the generation number here
BOARD = (0, 0, 20, 20)  # x0, y0, w, h
MAX_GEN = 100           # must match FOR G=1 TO N in life.bas


def program_lines() -> list[str]:
    return [ln.rstrip("\n") for ln in LIFE_BAS.read_text().splitlines() if ln.strip()]


async def run(args) -> int:
    async with Apple.connect(transport=args.transport, host=args.host,
                             port=args.port, device=args.device,
                             key_delay=args.key_delay) as ap:
        print("status ->", await ap.status())

        print(f"typing {LIFE_BAS.name} onto the Apple...")
        await ap.type_line("NEW")
        await ap.type_program(program_lines())

        print("RUN -- watching generations (read_memory works mid-RUN)\n")
        await ap.type_line("RUN")

        last = -1
        idle = 0.0
        while True:
            gen = await ap.read_byte(SENTINEL)
            if gen != last:
                last, idle = gen, 0.0
                grid = await ap.read_lores(*BOARD)
                live = sum(c != 0 for row in grid for c in row)
                print(f"--- generation {gen}  ({live} alive) ---")
                print(render_grid(grid))
                print()
                if gen >= MAX_GEN:
                    print("reached final generation.")
                    return 0
            else:
                idle += args.poll
                if idle > args.timeout:
                    print(f"no new generation for {args.timeout:g}s -- stopping. "
                          "(Did the program error? Check the Apple's screen.)")
                    return 1
            await asyncio.sleep(args.poll)


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="Drive Conway's Life on the Apple over MCP.")
    p.add_argument("--transport", choices=["serial", "tcp"], default="serial")
    p.add_argument("--device", default=None, help="serial device (auto-detect if omitted)")
    p.add_argument("--host", default="localhost")
    p.add_argument("--port", type=int, default=1977)
    p.add_argument("--key-delay", type=float, default=0.0, metavar="SEC")
    p.add_argument("--poll", type=float, default=2.0, metavar="SEC",
                   help="how often to poll the frame sentinel (default 2.0). Keep "
                        "this gentle: every read fires RX interrupts that steal "
                        "cycles from the foreground BASIC and slow the simulation "
                        "you're watching (observer effect).")
    p.add_argument("--timeout", type=float, default=30.0, metavar="SEC",
                   help="give up if no new generation appears for this long")
    return asyncio.run(run(p.parse_args(argv)))


if __name__ == "__main__":
    sys.exit(main())
