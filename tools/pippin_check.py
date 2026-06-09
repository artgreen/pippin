"""pippin_check.py -- drive PIPPIN (the on-Apple server) end to end with the
official MCP SDK, over the real serial link (or any TCP bridge on :1977).

PIPPIN IS the MCP server: it speaks newline-framed JSON-RPC on the
Super Serial Card wire itself. This points the official `mcp` SDK at
tools/pippin_bridge.py (a raw stdin<->TCP relay), which carries the SDK's
JSON-RPC straight to the Apple. It runs the full lifecycle:
initialize -> list_tools -> call s/r/w/k, with a write+readback and a
forbidden-range error check.

(For PIP, use pip_check.py instead -- that one
goes through pippin_mcp.py and the binary protocol.)

Bring up the wire first. Real //c+ over a USB-serial dongle:
    tools/serial_bridge.sh               # socat: dongle <-> TCP :1977
Then:
    uv run --with mcp tools/pippin_check.py             # localhost:1977
    uv run --with mcp tools/pippin_check.py --port 1977
"""
import argparse
import asyncio
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


def _text(result):
    # CallToolResult.content is a list of content blocks; take the first text.
    for block in result.content:
        if getattr(block, "type", None) == "text":
            return block.text
    return repr(result.content)


async def run(host: str, port: int, sendkey):
    # PIPPIN speaks JSON-RPC on the wire; pippin_bridge.py relays
    # the SDK's stdio to that wire. It is pure stdlib, so spawn it with the
    # current interpreter -- no extra deps to resolve.
    params = StdioServerParameters(
        command=sys.executable,
        args=["tools/pippin_bridge.py", host, str(port)],
    )
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            init = await session.initialize()
            print("initialize ->", init.serverInfo.name, init.serverInfo.version)
            tools = await session.list_tools()
            print("list_tools ->", [t.name for t in tools.tools])

            r = await session.call_tool("s", {})
            print("status (s) ->", _text(r))

            r = await session.call_tool("r", {"a": 1024, "l": 16})
            print("read $0400,16 (r) ->", _text(r))

            r = await session.call_tool("w", {"a": 768, "v": "deadbeef"})
            print("write $0300=deadbeef (w) ->", _text(r))

            r = await session.call_tool("r", {"a": 768, "l": 4})
            print("read $0300,4 (r) ->", _text(r), "(expect deadbeef)")

            r = await session.call_tool("r", {"a": 49152, "l": 16})
            print("read $C000,16 (r) -> isError=", r.isError, _text(r),
                  "(expect rejected: forbidden I/O page)")

            r = await session.call_tool("r", {"a": 65534, "l": 2})
            print("read $FFFE,2 (r) ->", _text(r),
                  "(the IRQ vector; legal since v0.6 -- end-of-memory is not a wrap)")

            if sendkey is not None:
                r = await session.call_tool("k", {"k": sendkey})
                print(f"send_keystroke {sendkey} (k) ->", _text(r))
    print("== PIPPIN MCP round-trip complete ==")


def main(argv=None):
    p = argparse.ArgumentParser(
        description="End-to-end MCP check of PIPPIN (:1977)")
    p.add_argument("--host", default="localhost")
    p.add_argument("--port", type=int, default=1977)
    p.add_argument("--sendkey", type=int, default=None, metavar="KEYCODE",
                   help="also inject this keycode (0-127) via the k tool; off by "
                        "default since it types into the live machine")
    args = p.parse_args(argv)
    asyncio.run(run(args.host, args.port, args.sendkey))
    return 0


if __name__ == "__main__":
    sys.exit(main())
