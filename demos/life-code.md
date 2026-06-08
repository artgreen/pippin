# Conway's Game of Life on an Apple II, code snapshot

Two Applesoft implementations of Conway's Game of Life, both written and debugged
on a real Apple (PIP, the host-assisted build) entirely over the MCP wire. This file is a
human-readable snapshot of the BASIC so it's easy to read and share; the
canonical source lives in `demos/life.bas` and `demos/life_flip.bas`, with Python
drivers/tooling alongside.

Both run on a `//e`/`//c`-class machine. Dead edges (no wrap), random-soup seed.

---

## 1. `life.bas`, lo-res color, double-buffered array

The straightforward version: the board lives in two BASIC arrays, computed
generation by generation, drawn to the lo-res screen with `PLOT`. The arrays are
1-D with an incrementally maintained index (`I`), which avoids Applesoft's
slow 2-D address multiply on the eight neighbor reads per cell; hot variables are
declared first so they sit at the front of the symbol table.

```basic
5 I=0:N=0:X=0:Y=0:S=22:W=20:C=0:G=0:T=S*S-1
10 DIM A(T),B(T)
20 GR : HOME
40 FOR Y=1 TO W:I=Y*S:FOR X=1 TO W:I=I+1:A(I)=(RND(1)<.3):NEXT X,Y
50 GOSUB 500
100 FOR G=1 TO 100
110 GOSUB 1000
120 POKE 768,G
130 NEXT G
140 END
500 FOR Y=1 TO W:I=Y*S:FOR X=1 TO W:I=I+1
510 C=0:IF A(I) THEN C=15
520 COLOR=C:PLOT X-1,Y-1
530 NEXT X,Y
540 POKE 768,0:RETURN
1000 FOR Y=1 TO W:I=Y*S:FOR X=1 TO W:I=I+1
1010 N=A(I-23)+A(I-22)+A(I-21)+A(I-1)+A(I+1)+A(I+21)+A(I+22)+A(I+23)
1020 B(I)=(N=3) OR (A(I) AND N=2)
1030 NEXT X,Y
1040 FOR Y=1 TO W:I=Y*S:FOR X=1 TO W:I=I+1
1050 IF B(I)=A(I) THEN 1080
1060 C=0:IF B(I) THEN C=15
1070 COLOR=C:PLOT X-1,Y-1:A(I)=B(I)
1080 NEXT X,Y
1090 RETURN
```

- 20×20 board (`W`), stride 22 (`S`) with a zeroed margin ring → dead edges with
  no per-cell bounds checks.
- `B(I)=(N=3) OR (A(I) AND N=2)` is Conway's rule in one line.
- `POKE 768,G` ($0300) is a frame sentinel the host polls to know when a
  generation is complete.
- ~4.8 s/generation (PLOT-heavy with a full random field).

---

## 2. `life_flip.bas`, text, screen-as-state, page-flipped (the fast one)

The clever version. No array at all, the board state lives directly in the
two text-screen pages. Each generation is built into the hidden page and revealed
with a single soft-switch flip (`$C054`/`$C055`), exactly like a hi-res
double-buffer: flicker-free, no copy, no `PLOT`. Cells are `$A0` (dead, blank) /
`$A1` (alive, `!`), one apart so a neighbor count is a plain byte sum.

To free text page 2 (`$0800-$0BFF`, normally Applesoft's program space), the
program is first relocated to `$0C01` (`POKE 103,1:POKE 104,12:POKE 3072,0:NEW`,
done by the host before typing this in).

Speed comes from a rolling vertical column-sum: instead of 9 `PEEK`s per cell,
keep three stacked cells per column and slide the 3×3 window across the row, so
each cell only reads the single new column entering its window, 3 `PEEK`s/cell.

```basic
5 CA=0:CB=0:CC=0:MB=0:MM=0:N=0:X=0:J=0:AL=0:UA=0:MA=0:DA=0:E=0:Y=0:SO=0:DO=0:G=0:T=0:A=0:DZ=160:K=1280
10 DIM RB(23)
20 FOR Y=0 TO 23:RB(Y)=1024+(Y-8*INT(Y/8))*128+INT(Y/8)*40:NEXT
30 POKE 49233,0
40 FOR A=1024 TO 3071:POKE A,160:NEXT
50 FOR Y=1 TO 22:MA=RB(Y):FOR X=1 TO 38:POKE MA+X,160+(RND(1)<.3):NEXT X,Y
60 POKE 49236,0
70 SO=0:DO=1024:POKE 768,0
100 FOR G=1 TO 100:GOSUB 1000
120 IF DO=0 THEN POKE 49236,0
130 IF DO>0 THEN POKE 49237,0
140 T=SO:SO=DO:DO=T:POKE 768,G:NEXT G
170 END
1000 FOR Y=1 TO 22:UA=RB(Y-1)+SO:MA=RB(Y)+SO:DA=RB(Y+1)+SO:E=RB(Y)+DO
1010 CA=PEEK(UA)+PEEK(MA)+PEEK(DA):MB=PEEK(MA+1):CB=PEEK(UA+1)+MB+PEEK(DA+1)
1020 FOR X=1 TO 38:J=X+1:MM=PEEK(MA+J):CC=PEEK(UA+J)+MM+PEEK(DA+J)
1030 N=CA+CB+CC-K-MB:AL=(N=3) OR ((MB>DZ) AND N=2):POKE E+X,DZ+AL:CA=CB:CB=CC:MB=MM:NEXT X
1040 NEXT Y
1090 RETURN
```

How it works, line by line:

- `RB(0..23)` (line 20): page-1 base address of each text row (the Apple's
  interleaved layout: `$400 + (r%8)*$80 + (r//8)*$28`). Page 2 is the same
  +1024, so the code just adds an offset `SO`/`DO` to switch pages.
- Line 30/40: text mode; blank both pages to `$A0`.
- Line 50: seed page 1's interior (cols 1..38, rows 1..22, a one-cell dead
  frame) with ~30% `!`.
- Lines 100-170: each generation builds into the destination page (`DO`),
  flips the display to it (`$C054`/`$C055`), bumps the frame sentinel, then swaps
  source/destination (`SO`/`DO`).
- Lines 1000-1090 (one generation):
  - `CA`,`CB`,`CC` are vertical 3-cell column sums for columns `x-1`, `x`, `x+1`.
  - `MB` is the center byte; `MM` the center of the entering column.
  - `N = CA+CB+CC - K - MB` is the live-neighbor count (`K = 8*$A0`). All cells
    are `$A0`/`$A1`, so the window sum minus `8*$A0` and the center is exactly
    the neighbor count.
  - `AL=(N=3) OR ((MB>DZ) AND N=2)` is Conway's rule; `POKE E+X,DZ+AL` writes
    `$A0`/`$A1`.
  - `CA=CB:CB=CC:MB=MM` slides the window right (so only `CC`/`MM` cost `PEEK`s).

Full-screen 38×22, every dot a life-form. ~1.9 s/generation, flicker-free.

---

## Python tooling (in `demos/`)

- `apple.py`, the "Apple dev console" over MCP: type programs/immediate
  commands, read the text screen for errors, read lo-res/text memory back as a
  grid. Keystrokes self-pace by polling PIP's pending-key byte (`$EC`).
- `life.py` / `life_flip.py`, drivers that type each program onto the Apple,
  run it, and render generations live by reading screen memory.
- `conway_ref.py`, `life_model.py`, `life_screen_model.py`, pure-Python
  references; `test_*.py` verify both rules *and* each BASIC's exact
  indexing/encoding against the reference offline (no hardware needed).
