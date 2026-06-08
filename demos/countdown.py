"""countdown.py -- the "hello world" of driving an Apple II over MCP.

Types a short Applesoft program onto the live machine, RUNs it, and reads the
result back off the text screen. The program counts down from 10 and prints
LIFTOFF!:

    10 FOR I = 10 TO 1 STEP -1
    20 PRINT I
    30 NEXT I
    40 PRINT "LIFTOFF!"

Every keystroke and every screen read crosses the wire as a real MCP tool call,
issued with the official `mcp` SDK -- the same stack the acceptance checks use.
It works against either build:

  --build pippin  (default)  The Apple IS the MCP server (JSON-RPC on the wire).
                             Driven via tools/pippin_bridge.py; tools s/r/w/k.
  --build pip                A host sidecar (tools/pippin_mcp.py) is the MCP
                             server; binary frames cross the wire. Tools
                             status/read_memory/write_memory/send_keystroke.

Bring the wire up first (a TCP endpoint on :1977 -- emulator, or
tools/serial_bridge.sh to a real USB-serial dongle), with the matching build
installed and sitting at the Applesoft `]` prompt. Then:

    uv run --with mcp python demos/countdown.py                  # PIPPIN, :1977
    uv run --with mcp python demos/countdown.py --build pip
    uv run --with mcp python demos/countdown.py --pace-ms 2      # microM8 emulator

Exit 0 if LIFTOFF! is found on the screen afterward, 1 if not.

Keystroke pacing: the Apple holds exactly one pending injected key
(ZP_PENDING_KEY) and only consumes it at the foreground `]` prompt -- never
mid-RUN. So we type one fully-round-tripped key at a time, let the prompt drain
each before the next, and don't try to inject into a running program.
"""
import argparse
import asyncio
import sys
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

TOOLS = Path(__file__).resolve().parent.parent / "tools"

# --- Apple II 40-column text screen ($0400-$07FF) ----------------------------
SCREEN_BASE = 0x0400
TEXT_COLS = 40
TEXT_ROWS = 24
CR = 13

# The countdown program, typed line by line. NEW first for a clean slate; RUN
# last to execute it. Uppercase throughout -- that's what the Applesoft
# tokenizer expects.
PROGRAM = [
    "NEW",
    "10 FOR I = 10 TO 1 STEP -1",
    "20 PRINT I",
    "30 NEXT I",
    '40 PRINT "LIFTOFF!"',
    "RUN",
]


def text_row_base(row: int) -> int:
    """Start address of text-screen `row` (0..23).

    The Apple II text page is not laid out in row order: 24 rows are stored as
    three interleaved groups of eight, $28 bytes apart, with the eight rows of
    each group $80 bytes apart. Row 0 -> $0400, row 1 -> $0480, row 8 -> $0428,
    row 23 -> $07D0.
    """
    return SCREEN_BASE + (row % 8) * 0x80 + (row // 8) * 0x28


def decode_screen_byte(b: int) -> str:
    """One screen byte -> its ASCII character. Display bytes carry the high bit
    set in normal video ('A' is $C1); masking it off yields ASCII. Anything
    outside the printable range (inverse/control glyphs) becomes a space."""
    c = b & 0x7F
    return chr(c) if 0x20 <= c <= 0x7E else " "


def decode_row(raw: bytes) -> str:
    """A row's worth of screen bytes -> text, trailing blanks trimmed."""
    return "".join(decode_screen_byte(b) for b in raw).rstrip()


# --- per-build adapter -------------------------------------------------------
# The two builds differ only in how the MCP server is spawned and in the tool
# names / argument keys. Everything below the adapter is build-agnostic.

def _pippin_params(host: str, port: int, pace_ms: float) -> StdioServerParameters:
    args = [str(TOOLS / "pippin_bridge.py"), host, str(port)]
    if pace_ms:
        args.append(str(pace_ms))
    # pippin_bridge.py is pure stdlib -- spawn it with this interpreter.
    return StdioServerParameters(command=sys.executable, args=args)


def _pip_params(host: str, port: int, pace_ms: float) -> StdioServerParameters:
    # pippin_mcp.py is the MCP server here; it dials the wire itself over TCP.
    return StdioServerParameters(
        command="uv",
        args=["run", "--with", "mcp", "python", str(TOOLS / "pippin_mcp.py"),
              "--transport", "tcp", "--host", host, "--port", str(port)],
    )


BUILDS = {
    "pippin": {
        "params": _pippin_params,
        "key_tool": "k", "key_args": lambda code: {"k": code},
        "read_tool": "r", "read_args": lambda addr, n: {"a": addr, "l": n},
    },
    "pip": {
        "params": _pip_params,
        "key_tool": "send_keystroke", "key_args": lambda code: {"key": code},
        "read_tool": "read_memory",
        "read_args": lambda addr, n: {"address": addr, "length": n},
    },
}


def _text(result) -> str:
    """First text content block of a CallToolResult (tool replies are text)."""
    for block in result.content:
        if getattr(block, "type", None) == "text":
            return block.text
    return repr(result.content)


# --- the demo ----------------------------------------------------------------
async def _send_key(session, build, code: int, delay: float) -> None:
    await session.call_tool(build["key_tool"], build["key_args"](code))
    if delay:
        await asyncio.sleep(delay)


async def type_line(session, build, text: str, delay: float) -> None:
    """Type `text` then a carriage return, one round-tripped keystroke each."""
    for ch in text:
        await _send_key(session, build, ord(ch), delay)
    await _send_key(session, build, CR, delay)


async def read_screen(session, build) -> list[str]:
    """Read all 24 text rows over MCP and decode them, top to bottom."""
    lines = []
    for row in range(TEXT_ROWS):
        r = await session.call_tool(
            build["read_tool"], build["read_args"](text_row_base(row), TEXT_COLS))
        lines.append(decode_row(bytes.fromhex(_text(r))))
    return lines


async def run(args) -> int:
    build = BUILDS[args.build]
    params = build["params"](args.host, args.port, args.pace_ms)
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            init = await session.initialize()
            print(f"initialize -> {init.serverInfo.name} {init.serverInfo.version}")
            tools = await session.list_tools()
            print(f"list_tools -> {[t.name for t in tools.tools]}")

            print(f"\ntyping the countdown program ({args.build} build)...")
            await _send_key(session, build, CR, args.key_delay)  # fresh prompt line
            for line in PROGRAM:
                await type_line(session, build, line, args.key_delay)
                print(f"  ] {line}")

            print(f"\nrunning... (waiting {args.run_wait:g}s for it to finish)")
            await asyncio.sleep(args.run_wait)

            lines = await read_screen(session, build)
            print("\n--- Apple text screen ---")
            for ln in lines:
                if ln:
                    print(f"  {ln}")
            print("--- end screen ---\n")

            if any("LIFTOFF!" in ln for ln in lines):
                print("LIFTOFF! confirmed on the Apple screen -- liftoff.")
                return 0
            print("LIFTOFF! not found on the screen. Is the machine at the `]` "
                  "prompt, and is the right build installed?")
            return 1


def main(argv=None) -> int:
    p = argparse.ArgumentParser(
        description="Type a countdown program onto the Apple II over MCP, RUN "
                    "it, and read LIFTOFF! back off the screen.")
    p.add_argument("--build", choices=["pippin", "pip"], default="pippin",
                   help="which build to drive: PIPPIN or PIP (default: pippin)")
    p.add_argument("--host", default="localhost")
    p.add_argument("--port", type=int, default=1977)
    p.add_argument("--key-delay", type=float, default=0.05, metavar="SEC",
                   help="extra pause after each keystroke (default: 0.05)")
    p.add_argument("--run-wait", type=float, default=1.0, metavar="SEC",
                   help="pause after RUN before reading the screen (default: 1.0)")
    p.add_argument("--pace-ms", type=float, default=0.0, metavar="MS",
                   help="PIPPIN only: byte-pace the wire for the microM8 "
                        "emulator (e.g. 2). Omit on real hardware.")
    args = p.parse_args(argv)
    return asyncio.run(run(args))


if __name__ == "__main__":
    sys.exit(main())
