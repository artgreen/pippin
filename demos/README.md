# demos

> Hello, I'm Claude, and everything in this directory is my fault. Over one
> long conversation I reached through an MCP server, down a 9600-baud serial
> line, and into a genuine 1988 Apple //c+, where I typed, ran, and debugged
> Conway's Game of Life three different ways: first in Applesoft with lo-res
> color; then again with no array at all, the board living in the text pages,
> hardware page-flipped like a hi-res demo; and finally in hand-written 65C02
> assembly that out-ran the BASIC by roughly five hundred to one. Every
> keystroke, every screen read, every poked byte crossed that wire as a real
> tool call, and every risky line was verified in a simulator before it touched
> the metal. The humans supplied the hardware, the wit, and the occasional
> "why not use zero page?"; I supplied the bugs and, eventually, the fixes.
> What follows is the evidence.

## Table of contents

- [countdown.py](#countdownpy): the "hello world", type a program, run it, read it back
- [life.py](#lifepy): Conway's Game of Life in Applesoft, lo-res color
- [life_flip.py](#life_flippy): the page-flipped version, with no array at all
- [asm/](#asm): Conway in 65C02 assembly, ~500x faster
- [Tests](#tests): everything host-side is verified offline

All of it drives `PIP` (the host-assisted build) over MCP. The pieces are
self-contained Python; the Apple-side artifacts are the `.bas` and `.s` files.

## countdown.py

The "hello world": types an Applesoft program onto the live Apple, RUNs it, and
reads the result back off the text screen: a countdown from 10 to `LIFTOFF!`.
Every keystroke and screen read is a real MCP tool call made with the official
`mcp` SDK, so it exercises the whole stack end to end.

Prerequisites: a TCP endpoint on `:1977` carrying the wire (the microM8
emulator, or `tools/serial_bridge.sh` to a USB-serial dongle), with the matching
PIPPIN build installed and the machine sitting at the Applesoft `]` prompt.

```sh
uv run --with mcp python demos/countdown.py                 # PIPPIN, :1977
uv run --with mcp python demos/countdown.py --build pip     # PIP (host-assisted)
uv run --with mcp python demos/countdown.py --pace-ms 2     # microM8 emulator
```

Exits 0 once `LIFTOFF!` shows up on the screen, 1 if it doesn't. See the module
docstring for all flags.

## life.py

A bigger flex: Claude drives the Apple over MCP to type, debug, and run Conway's
Game of Life in Applesoft with lo-res color graphics. The Apple does all the
computation (20x20, dead edges, random soup); the host types the program on, then
watches by reading lo-res screen memory (`$0400`) back and rendering each
generation as a grid.

Supporting pieces:

- `apple.py`: a reusable "Apple dev console" over MCP. Type programs and immediate
  commands, read the text screen for errors, read the lo-res screen as a color
  grid. Keystrokes self-pace by polling PIP's pending-key byte (`$EC`), so typing
  is reliable even over a fast emulator bridge.
- `life.bas`: the Applesoft artifact (flattened 1-D arrays for speed).
- `conway_ref.py` / `life_model.py`: pure-Python references used to verify both
  the rules and `life.bas`'s flattened indexing offline, no hardware.

```sh
uv run --with mcp python demos/life.py                 # serial (auto-detect)
uv run --with mcp python demos/life.py --transport tcp --port 2023   # via a bridge
```

Notes from live bringup: accelerate the emulator's CPU to make generations
watchable (the wire stays at 9600); keep `--poll` gentle, since every read steals
cycles from the running BASIC.

## life_flip.py

A cleverer take with no array at all: the board state lives directly in the two
text pages, and each generation is built into the hidden page and revealed with a
single soft-switch flip, flicker-free double buffering, exactly like hi-res. To
free text page 2 (`$0800`, normally the Applesoft program area), it relocates the
program to `$0C01` first. Cells are `$A0` (dead) or `$A1` (alive `!`), one apart
so a neighbor count is a plain `PEEK` sum. Full-screen 38x22, every dot a
life-form.

```sh
uv run --with mcp python demos/life_flip.py --transport tcp --port 2023
```

`life_screen_model.py` / `test_life_screen.py` verify the exact memory addressing,
the `+1` encoding, and page alternation against `conway_ref` offline.

## asm/

The same Game of Life, but native code instead of Applesoft. On a real //c+ it
runs at about 66 generations/sec (faster still when the host isn't polling it),
versus about 8 s/gen for the BASIC on the same machine, roughly a 500x speedup.
The board lives in two linear bordered buffers (`$7000`/`$7800`), one generation
is 8 `ADC (zp),Y` per cell, and each frame is rendered to the interleaved text
screen and hardware page-flipped. Dead edges live in the off-screen buffer border,
so the whole 40x24 screen is playable.

- `asm/life.s`: the 65C02 source (Merlin32-style, with an `ORG`).
- `asm/build_life.py`: assembles `life.s` and verifies the generation, render
  addressing, and seed in the 6502 simulator (from the `6502-codegen` skill), then
  emits the blob. Run it with the skill's `scripts/` dir on argv:
  `uv run --with py65 python3 demos/asm/build_life.py <skill>/scripts /tmp/life.bin`
- `asm/deploy_life.py`: transfers the blob into the Apple over MCP (`write_memory`),
  `CALL`s it, measures the frame rate, and renders a frozen frame. Stop it any time
  by setting the `$7C` flag (`write_memory`) or pressing a key on the Apple. (The
  counter and flag live in `$7B`/`$7C`, Applesoft's DATA pointers, which are
  dormant while we run in the foreground via `CALL`.)
- `asm/life.mon`: the assembled program as an Apple monitor listing
  (`ADDR:BB BB ...`), for EXEC-style install (`CALL -151`, paste, then `6000G` or
  `CALL 24576`).

```sh
uv run --with mcp python3 demos/asm/deploy_life.py --port 2023
```

## Tests

Every Apple-side algorithm has a pure-Python mirror checked against a reference
implementation, so the logic is proven before a single byte reaches the wire:

```sh
uv run --with mcp --with pytest pytest demos/
```
