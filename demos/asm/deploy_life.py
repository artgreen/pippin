"""deploy_life.py -- transfer the assembled Life blob to the Apple over MCP, run
it, measure the frame rate, then freeze and render a clean frame.

    uv run --with mcp python3 demos/asm/deploy_life.py --port 2023
"""
import argparse
import asyncio
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # demos/
from apple import Apple, char_row_base, render_grid  # noqa: E402

START = 0x6000
FRAME = 0x7B    # Applesoft DATLIN -- free zero page while we run in the foreground
STOPF = 0x7C
RELOCATE = "POKE 103,1:POKE 104,12:POKE 3072,0:NEW"


async def reloc_ok(ap):
    await ap.type_line(RELOCATE)
    for _ in range(20):
        if await ap.read_byte(104) == 12:
            return True
        await asyncio.sleep(0.2)
    return False


async def read_screen(ap, page_off=0):
    rows = []
    for r in range(24):
        raw = await ap.read_mem(char_row_base(r) + page_off, 40)
        rows.append([1 if b == 0xA1 else 0 for b in raw])
    return rows


async def run(args):
    blob = Path(args.bin).read_bytes()
    async with Apple.connect(transport=args.transport, host=args.host, port=args.port) as ap:
        print("status ->", await ap.status())
        print("relocating to free text page 2...")
        if not await reloc_ok(ap):
            print("relocation failed; aborting")
            return 1

        print(f"writing {len(blob)} bytes to ${START:04X} ...")
        for off in range(0, len(blob), 128):
            chunk = blob[off:off + 128]
            await ap.write_mem(START + off, chunk)
        back = await ap.read_mem(START, 16)
        if bytes(back) != blob[:16]:
            print(f"readback mismatch: {back.hex()} != {blob[:16].hex()}")
            return 1
        print("  readback verified")

        print("CALL 24576 -> running; measuring frame rate...")
        await ap.type_line("CALL 24576")
        t0 = time.monotonic()
        prev = await ap.read_byte(FRAME)
        total = 0
        for _ in range(12):
            await asyncio.sleep(0.25)
            cur = await ap.read_byte(FRAME)
            total += (cur - prev) & 0xFF
            prev = cur
        dt = time.monotonic() - t0
        print(f"  ~{total/dt:.0f} generations/sec  ({total} gens in {dt:.1f}s)")

        print("freezing (STOP flag) and reading a clean frame...")
        await ap.write_mem(STOPF, bytes([1]))
        await asyncio.sleep(0.3)
        board = await read_screen(ap, 0)   # page 1
        live = sum(sum(r) for r in board)
        print(f"--- frozen frame, page 1 ({live} alive) ---")
        print(render_grid(board, alive="#", dead="."))
        return 0


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--transport", choices=["serial", "tcp"], default="tcp")
    p.add_argument("--host", default="localhost")
    p.add_argument("--port", type=int, default=2023)
    p.add_argument("--bin", default="/tmp/life.bin")
    return asyncio.run(run(p.parse_args(argv)))


if __name__ == "__main__":
    sys.exit(main())
