"""apple.py -- a small "Apple dev console" driven over MCP.

A reusable platform for driving a live Apple II (running PIP, the host-assisted
build) from the host: type programs and immediate commands at the `]` prompt,
read the text screen back to catch errors, and read the lo-res graphics screen
back to observe what the machine is drawing. Everything goes through the
official MCP SDK and PIP's four tools (status/read_memory/write_memory/
send_keystroke).

Pure helpers (address math, nibble decode, grid render) are at module scope and
unit-tested in test_apple.py. The `Apple` class wraps a live MCP ClientSession.

Typical use:

    async with Apple.connect(transport="serial") as ap:
        print(await ap.status())
        await ap.type_program(["NEW", '10 PRINT "HI"', "RUN"])
        grid = await ap.read_lores(0, 0, 20, 20)
        print(render_grid(grid))
"""
import asyncio
import contextlib
import sys
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

# Reuse the text-screen decoders proven in the countdown demo. char-row base
# addressing is identical for the text page and lo-res page 1.
from countdown import text_row_base as char_row_base, decode_row

TOOLS = Path(__file__).resolve().parent.parent / "tools"
CR = 13
LORES_BLACK = 0
LORES_WHITE = 15
ZP_PENDING_KEY = 0xEC   # PIP's single soft-inject slot; foreground zeroes it on read


# --- pure helpers ------------------------------------------------------------
def lores_addr(x: int, y: int) -> int:
    """Page-1 byte address holding lo-res pixel (x, y). Two stacked pixels share
    a byte, so row y lives in character row y // 2."""
    return char_row_base(y // 2) + x


def lores_nibble(byte_val: int, y: int) -> int:
    """The 0-15 color of pixel row `y` within its shared byte: high nibble for
    odd rows (bottom pixel), low nibble for even rows (top pixel)."""
    return (byte_val >> 4) & 0x0F if (y & 1) else byte_val & 0x0F


def decode_char_row(raw: bytes) -> tuple[list[int], list[int]]:
    """One character row's bytes -> (top pixel row, bottom pixel row) colors.
    Low nibble is the even (top) pixel, high nibble the odd (bottom) pixel."""
    top = [b & 0x0F for b in raw]
    bot = [(b >> 4) & 0x0F for b in raw]
    return top, bot


def render_grid(grid: list[list[int]], alive: str = "#", dead: str = ".") -> str:
    """Render a 2-D color grid as text: any non-black cell is `alive`."""
    return "\n".join("".join(alive if c else dead for c in row) for row in grid)


# --- live session ------------------------------------------------------------
class Apple:
    """A live MCP session to the Apple. Construct via `Apple.connect(...)`."""

    def __init__(self, session: ClientSession):
        self.s = session
        self.key_delay = 0.0
        self.drain_polls = 400

    @classmethod
    @contextlib.asynccontextmanager
    async def connect(cls, transport: str = "serial", host: str = "localhost",
                      port: int = 1977, device: str | None = None,
                      key_delay: float = 0.0):
        """Spawn tools/pippin_mcp.py as the MCP server and yield an Apple.

        transport="serial" talks straight to the USB-serial dongle (auto-detected
        if `device` is None); transport="tcp" connects to a bridge on host:port.
        """
        args = ["run", "--with", "mcp", "python", str(TOOLS / "pippin_mcp.py"),
                "--transport", transport]
        if transport == "tcp":
            args += ["--host", host, "--port", str(port)]
        elif device:
            args += ["--device", device]
        params = StdioServerParameters(command="uv", args=args)
        async with stdio_client(params) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                self = cls(session)
                self.key_delay = key_delay
                yield self

    # tool wrappers ----------------------------------------------------------
    async def _text(self, name: str, arguments: dict) -> str:
        r = await self.s.call_tool(name, arguments)
        for block in r.content:
            if getattr(block, "type", None) == "text":
                return block.text
        return repr(r.content)

    async def status(self) -> str:
        return await self._text("status", {})

    async def read_mem(self, address: int, length: int) -> bytes:
        return bytes.fromhex(await self._text(
            "read_memory", {"address": address, "length": length}))

    async def read_byte(self, address: int) -> int:
        return (await self.read_mem(address, 1))[0]

    async def write_mem(self, address: int, data: bytes) -> None:
        await self._text("write_memory",
                         {"address": address, "data_hex": data.hex()})

    async def key(self, code: int) -> None:
        """Inject one keystroke, then wait for the Apple's foreground to consume
        it before returning. PIP holds only one pending key ($EC), zeroed when
        the foreground reads it; without this wait, fast round-trips (e.g. over
        an emulator bridge) overwrite the slot and characters are dropped."""
        await self._text("send_keystroke", {"key": code})
        for _ in range(self.drain_polls):
            if await self.read_byte(ZP_PENDING_KEY) == 0:
                break
            await asyncio.sleep(0.005)
        if self.key_delay:
            await asyncio.sleep(self.key_delay)

    # higher-level console operations ---------------------------------------
    async def type_line(self, text: str) -> None:
        """Type `text` then RETURN, one round-tripped keystroke at a time."""
        for ch in text:
            await self.key(ord(ch))
        await self.key(CR)

    async def type_program(self, lines: list[str]) -> None:
        for line in lines:
            await self.type_line(line)

    async def send_immediate(self, command: str) -> list[str]:
        """Type an immediate-mode command, then return the text screen."""
        await self.type_line(command)
        return await self.read_text()

    async def read_text(self) -> list[str]:
        """The 24 text rows, top to bottom, trailing blanks trimmed."""
        rows = []
        for r in range(24):
            raw = await self.read_mem(char_row_base(r), 40)
            rows.append(decode_row(raw))
        return rows

    async def read_lores(self, x0: int, y0: int, w: int, h: int) -> list[list[int]]:
        """Read a w x h block of lo-res pixels starting at (x0, y0) as a grid of
        0-15 color values, top row first.

        Reads one character row (two pixel rows) at a time: each byte yields the
        two stacked pixels for columns x0..x0+w-1.
        """
        pixel_rows: dict[int, list[int]] = {}
        for cr in range((y0 // 2), ((y0 + h - 1) // 2) + 1):
            raw = await self.read_mem(char_row_base(cr) + x0, w)
            top, bot = decode_char_row(raw)
            pixel_rows[cr * 2], pixel_rows[cr * 2 + 1] = top, bot
        return [pixel_rows[y] for y in range(y0, y0 + h)]


# --- ad-hoc CLI: fire one immediate command and dump the screen --------------
async def _main(argv):
    import argparse
    p = argparse.ArgumentParser(description="Send one immediate command to the Apple.")
    p.add_argument("command", help="Applesoft immediate command, e.g. 'PRINT FRE(0)'")
    p.add_argument("--transport", choices=["serial", "tcp"], default="serial")
    p.add_argument("--device", default=None)
    p.add_argument("--host", default="localhost")
    p.add_argument("--port", type=int, default=1977)
    args = p.parse_args(argv)
    async with Apple.connect(transport=args.transport, host=args.host,
                             port=args.port, device=args.device) as ap:
        for line in await ap.send_immediate(args.command):
            if line:
                print(line)


if __name__ == "__main__":
    asyncio.run(_main(sys.argv[1:]))
