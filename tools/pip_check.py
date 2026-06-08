"""pip_check.py -- drive PIP end-to-end with the OFFICIAL MCP SDK.

Launches tools/pippin_mcp.py as a stdio MCP server (which itself connects to the
//c+ over :1977 and speaks the binary protocol), then acts as an MCP client using
the official `mcp` SDK: initialize -> list_tools -> call_tool for status / read /
write. This exercises the whole stack: SDK -> FastMCP front-end -> binary wire ->
real Apple //c+.

    uv run --with mcp tools/pip_check.py [--port 1977]
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


async def run(port: int):
    params = StdioServerParameters(
        command="uv",
        args=["run", "--with", "mcp", "python", "tools/pippin_mcp.py",
              "--transport", "tcp", "--port", str(port)],
    )
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            init = await session.initialize()
            print("initialize ->", init.serverInfo.name, init.serverInfo.version)
            tools = await session.list_tools()
            print("list_tools ->", [t.name for t in tools.tools])

            r = await session.call_tool("status", {})
            print("status ->", _text(r))

            r = await session.call_tool("read_memory", {"address": 1024, "length": 16})
            print("read_memory($0400,16) ->", _text(r))

            r = await session.call_tool("write_memory", {"address": 768, "data_hex": "deadbeef"})
            print("write_memory($0300,deadbeef) ->", _text(r))

            r = await session.call_tool("read_memory", {"address": 768, "length": 4})
            print("read_memory($0300,4) ->", _text(r), "(expect deadbeef)")

            # error mapping: forbidden range should surface as a tool error
            r = await session.call_tool("read_memory", {"address": 49152, "length": 16})
            print("read_memory($C000,16) -> isError=", r.isError, _text(r))
    print("== MCP SDK round-trip complete ==")


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=1977)
    args = p.parse_args(argv)
    asyncio.run(run(args.port))
    return 0


if __name__ == "__main__":
    sys.exit(main())
