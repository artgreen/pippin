# Building PIPPIN and PIP

How PIPPIN and PIP are built from source, and how one set of sources targets two
CPUs. The binaries ship prebuilt in the tree, so this is only needed to rebuild
them. It needs [Merlin32](https://brutaldeluxe.fr/products/crossdevtools/merlin/)
and `uv` (see [Requirements](../README.md#requirements)).

## Make targets

```sh
make            # PIPPIN         (on-Apple MCP server, 65C02, ~6.2 KB)
make pip        # PIP            (host-assisted variant, 65C02)
make all6502    # PIPPIN.6502    (on-Apple, NMOS 6502)
make pip6502    # PIP.6502       (host-assisted, NMOS 6502)
make both       # all four binaries (both CPUs, both builds)
make recv       # RECV.BIN       (the serial file receiver, 65C02)
make recv6502   # RECV.6502      (the receiver, NMOS 6502)
make scan       # opcode gate: fail if any 6502 build emitted a 65C02 opcode
make shk        # PIPPIN.SHK     (ShrinkIt container; preserves BIN / $2000 metadata)
make verbose    # + per-segment listings and symbol tables
make clean
```

PIPPIN builds in three passes: a `mainres` driver assembles to a main-memory
image (`$9000-$95FF`), an `lcrom` driver to a language-card image
(`$D000-$DFFF`), and an `install` driver embeds both and runs as transient
install code at `$2000`. Each unit is a shared body plus two thin per-CPU
drivers (`*-65c02.s` / `*-6502.s`); see [6502 and 65C02](#6502-and-65c02) below.
The built binaries land at the repo root (`PIPPIN`, `PIPPIN.6502`, `PIP`,
`PIP.6502`, `RECV.BIN`, `RECV.6502`); the four PIPPIN/PIP binaries ship in the
tree, the `RECV` blobs are gitignored build artifacts.

## 6502 and 65C02

PIPPIN builds for both the 65C02 (//e enhanced, //c, //c+, IIgs) and the NMOS
6502 (the unenhanced //e) from one set of source bodies. The whole CPU
difference is one symbol, `CPUC02` (1 = 65C02, 0 = 6502), set by each thin
driver alongside the output filename. Six binaries come from the shared bodies:

| | `CPUC02=1` (65C02) | `CPUC02=0` (6502) |
|---|---|---|
| PIPPIN (JSON/MCP) | `PIPPIN` | `PIPPIN.6502` |
| PIP (binary) | `PIP` | `PIP.6502` |
| receiver | `RECV.BIN` | `RECV.6502` |

Nobody names a 65C02 opcode directly. They go through macros in
[`src/cpu.macs`](../src/cpu.macs), which emit the native opcode for `CPUC02=1` and a
legal-6502 equivalent for `CPUC02=0`:

| macro | 65C02 | 6502 | why the 6502 form is safe |
|---|---|---|---|
| `_STZ a` | `stz a` | `lda #0` / `sta a` | A is dead at every `_STZ` site |
| `_STZA a,t` | `stz a` | `stx t` / `ldx #0` / `stx a` / `ldx t` | zeroes `a` while preserving A and Y, restoring X (the one `stz` site whose A is live) |
| `_BRA t` | `bra t` | `jmp t` | PIPPIN's images load at fixed orgs and are never relocated, so an absolute `jmp` is fine; it preserves all flags and registers and has unbounded range |
| `_PHX t` / `_PLX t` | `phx` / `plx` | `stx t` / `ldx t` | saves X preserving A and carry (unlike `txa/pha`) |
| `_PHY t` / `_PLY t` | `phy` / `ply` | `sty t` / `ldy t` | saves Y preserving A and carry |
| `_STAIND p,t` | `sta (p)` | `sty t` / `ldy #0` / `sta (p),y` / `ldy t` | zero-index indirect store, emulated; preserves A and the live Y |
| `_JMPINDX tbl,p` | `jmp (tbl,x)` | copy `tbl[X]` into ZP word `p`, `jmp (p)` | indexed-indirect dispatch at a tail jump (nothing returns), so clobbering A and `p` is fine |

The 6502 substitutions for `_PHX/_PHY/_PLX/_PLY/_STZA/_STAIND` run inside the
interrupt (the TX pacing and the LC parser/dispatch dispatch inline in the IRQ),
so they must not borrow a foreground-live zero-page byte. They use `$FA-$FF`,
which ProDOS preserves across IRQ entry (TRM Ch 6) and which nothing else in
PIPPIN touches: the designated interrupt-handler scratch. The scratch byte is
passed in explicitly at each call site so the discipline is auditable, and the
one nested case uses a distinct byte so the outer save is not clobbered. `recv`
is a polled receiver (SEI on entry, no IRQ), so its scratch bytes are never
preempted.

The macros must carry the conditional _inside_ the body (`_STZ mac` / `do
CPUC02` / ... / `<<<`). Wrapping the macro *definitions* in `do/else/fin` does
not work in Merlin32 v1.2 beta 2: it registers both and emits the 65C02 form for
both CPUs (verified by test assemble).

### The opcode-scanner gate

`xc` is documentation-only in Merlin32 v1.2 beta 2. It accepts 65C02 opcodes
regardless, so the assembler will *not* catch a stray `stz`/`bra` in a 6502
build. [`tools/check_6502.py`](../tools/check_6502.py) is the real gate: it reads
each 6502 build's listing and fails if any emitted opcode is outside the legal
NMOS-6502 set. `make scan` runs it over every 6502 listing, including
`RECV.6502`.

### Machine detection and byte-identity

`src/machine_detect.s` follows Technote #7. The one divergence between the two
builds is the unenhanced //e (`$FBC0=$EA`), an NMOS 6502: the 6502 build accepts
it as `MACH_IIE` and reports `m=5` ("unenhanced //e"); the 65C02 build rejects it
(its opcodes would crash there). That accept path, and the `MACH_IIE` name-table
entry and string, are `CPUC02`-gated to the 6502 build only, so the 65C02 image
gains zero bytes from them. The result: the 65C02 builds assemble byte-for-byte
identical to the pre-split monolithic sources, every time, which the build
verifies.

## Source file map

Every unit is a shared body (`*_body.s`, or an `_a`/`_b` fragment pair) plus two
thin per-CPU drivers, `*-65c02.s` and `*-6502.s`, that set `CPUC02` and the
output filename and `PUT` the body. The body is the single source for both CPUs;
`src/cpu.macs` is the only place they diverge (see
[6502 and 65C02](#6502-and-65c02) above).

| Path | What it does |
|---|---|
| `src/cpu.macs` | The CPU-portability layer: macros that emit native 65C02 opcodes for `CPUC02=1` and legal-6502 equivalents for `CPUC02=0`. The one place the two CPU targets diverge. |
| `src/install_a.s`, `src/install_b.s` | PIPPIN install body. ORG `$2000`: install routine, SSC init, copy loops, `PUTBIN`s the two resident images. `PUT`s `machine_detect.s`. |
| `src/install-65c02.s`, `src/install-6502.s` | Per-CPU drivers for the PIPPIN installer (build `PIPPIN` / `PIPPIN.6502`). |
| `src/machine_detect.s` | Technote #7 family identification. The `$EA` (unenhanced //e) branch is `CPUC02`-gated: the 6502 build accepts it as `MACH_IIE` (`m=5`), the 65C02 build rejects it. |
| `src/mainres_a.s`, `src/mainres_b.s` | PIPPIN resident body `$9000-$95FF`: the interrupt handler (inline dispatch and RX-draining TX), the state block, the emit helpers, the ring at `$9400`. |
| `src/mainres-65c02.s`, `src/mainres-6502.s` | Per-CPU drivers for the PIPPIN resident image (`MAINRES.BIN` / `MAINRES6502.BIN`). |
| `src/lcrom_body.s` | PIPPIN resident language-card bank 2 `$D000`: the JSON-RPC parser, dispatch table, the handlers, and response data. |
| `src/lcrom-65c02.s`, `src/lcrom-6502.s` | Per-CPU drivers for the LC image (`LCROM.BIN` / `LCROM6502.BIN`). |
| `src/equates.s`, `src/equates-common.s` | Zero-page map, hardware addresses, machine codes, and shared constants. |
| `src/ksw_hook.s` | The keyboard hook (synthetic-key injection), shared body. |
| `src/ssc_common.s` | The TDRE-paced, RX-draining byte-transmit routine, shared body. |
| `src/recv_body.s` | Standalone serial file receiver body (`$0801` to `$2000`). |
| `src/recv-65c02.s`, `src/recv-6502.s` | Per-CPU drivers for the receiver (`RECV.BIN` / `RECV.6502`). |
| `src/installpip_a.s`, `src/installpip_b.s`, `src/install-pip-65c02.s`, `src/install-pip-6502.s` | The PIP installer: body plus per-CPU drivers (`PIP` / `PIP.6502`). |
| `src/mainrespip_a.s`, `src/mainrespip_b.s`, `src/mainres-pip-65c02.s`, `src/mainres-pip-6502.s`, `src/equates-pip.s` | The PIP main-memory-only binary handler: body, per-CPU drivers, and its constants. |
| `Makefile` | The per-CPU builds (`make` / `pip` / `all6502` / `pip6502` / `both`), plus `recv`, `recv6502`, `scan`, `shk`, `verbose`, `clean`. |
| `docs/DESIGN.md` | The full design. |
