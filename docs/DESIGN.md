# PIPPIN Design

## 1. Overview

PIPPIN is a Model Context Protocol (MCP) server that runs as a ProDOS 8
terminate-stay-resident (TSR) program on an Apple II. It turns the Apple II
into a tool target for a language model: an MCP client on a modern machine
sends requests over a serial link (9600 8N1), and PIPPIN dispatches tool calls against the
running machine (`read_memory`, `write_memory`, `status`, and `send_keystroke`)
while the host BASIC `]` prompt stays interactive.

The point of the TSR design is concurrency. The user keeps typing at the
Applesoft prompt while PIPPIN listens in the background. PIPPIN gets that
background liveness from the Super Serial Card's (SSC) per-byte receive
interrupt: under ProDOS 8 on a stock Apple II, the SSC's RX IRQ is the only
event source that ticks reliably while the foreground sits at a blocking
keyboard read.

This is a proof of concept. It has been validated end to end against a genuine
Apple //c+ over a USB-serial null-modem link: the full MCP request/response
loop (`initialize`, `notifications/initialized`, `tools/list`, and `tools/call`
for all four tools) at back-to-back request rate, including driving the machine
with the official, unmodified Python MCP SDK as the client. The capstone test
had a client type and run an Applesoft program on the //c+ via `send_keystroke`
and read the result back out of memory via `read_memory`.

The target machines are the Apple //e (enhanced and unenhanced), the //c, the
//c+, and the IIgs in 8-bit ProDOS 8 mode.

Several capabilities described in this document are deliberately minimal or
absent. Clean tear-down (releasing the interrupt and restoring the keyboard
hook on exit) is not implemented. Booting another system program orphans the
handler. The SSC slot is hard-coded to slot 2 rather than discovered by
scanning. There is no transport other than the serial link. These are noted
where relevant; a future build could add them.

## 2. Two builds

PIPPIN ships as two independent builds that share most of their low-level code
but make opposite choices about where the MCP/JSON work happens.

### PIPPIN: the on-Apple (standalone) server

PIPPIN is a self-contained MCP server. It parses JSON-RPC frames on
the Apple II itself, dispatches the call, runs the tool, and serializes a
JSON-RPC response, all on the 1 MHz (or 4 MHz, on the //c+) 65C02. Nothing on
the host needs to understand the wire format beyond "newline-delimited
JSON-RPC." A generic MCP client, or the official MCP SDK, can talk to it
directly over the serial link.

This is the reference implementation; the rest of this document is primarily
about it. It is a complete, order-independent JSON-RPC server running in 5.5 KB
of resident code on an 8-bit machine.

### PIP: the host-assisted build

PIP is an optimization variant. It moves all MCP and JSON
overhead off the Apple II and onto the host. A host-side Python MCP front-end
speaks full MCP to clients (it answers `initialize`, `notifications/*`, and
`tools/list` entirely by itself), and only *tool executions* cross the wire, as
fixed-length binary frames. The Apple-side handler does no JSON parsing, no
decimal conversion, no text serialization; it reads a one-byte opcode and a
length, runs the tool on raw little-endian arguments, and emits a raw binary
response.

The trade-off is explicit: the on-device handler shrinks dramatically (the
resident handler is roughly 3.7x smaller, as the memory map in Section 8 shows,
and round trips are faster because the wire carries raw bytes instead of hex
and decimal text), but the Apple II is no longer a stand-alone MCP server. It
depends on the host front-end to be a conformant MCP endpoint. If you want a
genuine MCP server living on the Apple II with no host-side translation, use
PIPPIN; if you want the lowest-latency, smallest-footprint tool
executor and you're willing to run the host front-end, use PIP.

The two builds are byte-for-byte distinct sources with separate build targets.
PIPPIN is three flat binaries (a resident main-memory image, a
language-card image, and the install program that embeds both); PIP
is two (a single main-memory image plus its installer). PIP
reuses PIPPIN's install, SSC-init, keyboard-hook, and serial-transmit
code; the duplication is bounded and kept in sync by hand.

## 3. The inline-IRQ dispatch model

A natural design for a ProDOS TSR is a tiny interrupt handler that does almost
nothing (queue the received byte into a ring buffer, set a "work pending" flag,
return) and a foreground routine that does the real work (parse, dispatch,
respond) whenever the foreground next yields. ProDOS does not call your code on
a timer, so the conventional foreground-yield hook is the keyboard input vector
(`KSW`): every time the foreground asks for a keystroke, control passes through
your hook, and you can drain pending work before returning a key.

That model does not work here, for two compounding reasons:

- The keyboard hook fires only once per keystroke. It is not a periodic
  time slice. It is invoked when the foreground requests a key, returns one
  key, and is not invoked again until the foreground requests the next key.

- At the `]` prompt, the ROM keyboard read is a single blocking poll. When
  Applesoft or BASIC.SYSTEM is sitting idle waiting for input, it calls the
  keyboard read *once* and spins inside the ROM until a key is pressed. The
  hook fired on the way into that one read; it will not fire again until a key
  actually arrives. So at an idle prompt (exactly the state PIPPIN is designed
  to be useful in) there is no recurring foreground slice to drain work from.

Because there is no usable periodic foreground slice, PIPPIN parses and
dispatches inline in the interrupt handler. The IRQ handler queues each
received byte into the ring as before, but when the frame terminator (a
newline) arrives, the handler does not just set a flag and return. It runs the
parser, dispatches the tool call, transmits the entire response, and only then
returns from the interrupt. (In PIPPIN it bank-switches into the
language-card code to do this; see Section 8. In PIP the whole
handler is already in main memory, so it just calls the dispatcher directly.)

The consequence is the central operational quirk of PIPPIN: the host is deaf
during transmit. Dispatch and the full response transmission run with
interrupts disabled, inside the IRQ, so for the reply window (roughly 25 to 50
ms for a typical request on a 1 MHz machine) the foreground is frozen and
PIPPIN is not servicing new input through the normal interrupt path. The user
sees a brief pause at the prompt. This is acceptable for human-driven,
turn-taking LLM tool calls (the protocol assumes a roughly synchronous client
that waits for each response before sending the next request) and is the reason
for the receive-draining behavior described in Section 5.

The keyboard hook still exists, but in a reduced role: it no longer drains the
ring. Its only job is to inject synthetic keystrokes for the
`send_keystroke` tool. When the foreground next reads a key, the hook returns
the queued keystroke (high bit set, as the Apple II expects) instead of
chaining to the real keyboard read.

## 4. ProDOS interrupt contract

ProDOS 8 specifies a contract for interrupt handlers registered through its
`ALLOC_INTERRUPT` call (ProDOS 8 Technical Reference Manual, Chapter 6). PIPPIN
follows it, with one deliberate, hardware-driven deviation.

- Clear decimal mode first. The handler executes `CLD` as its first
  instruction. ProDOS does not guarantee the decimal flag is clear on entry,
  and arithmetic in the handler would misbehave in BCD mode.

- Registers and `$FA`-`$FF` are preserved by ProDOS. The dispatcher saves
  the registers and the top of zero page before calling the handler, so the
  handler is free to clobber A/X/Y.

- Never call the MLI from inside the handler. ProDOS is not reentrant: if
  `MLIACTV` (`$BF9B`) is non-zero, the MLI is already on the stack and calling
  it again corrupts ProDOS. PIPPIN makes no MLI calls from the interrupt
  handler at all, not even though dispatch runs inline in the IRQ. The
  tools read and write memory and queue keystrokes; none of them touch the file
  system or any other MLI service.

- Always claim the interrupt. This is the deviation. The textbook protocol
  is to return with carry clear if the interrupt was yours and carry set to
  chain to the next handler. The "is this mine?" test is normally "did my
  device's IRQ-status bit read as set?" PIPPIN instead returns carry clear
  *unconditionally*.

  The reason is a real-hardware failure observed on a genuine //c+. On the //c
  and //c+, the built-in firmware can read the 6551's status register during
  its own interrupt entry, and that read clears the chip's IRQ-status bit
  *before* ProDOS dispatches to PIPPIN's handler. By the time PIPPIN checks the
  bit, it reads clear, so the "is this mine?" test says no, PIPPIN returns
  carry set to chain, nothing downstream claims the interrupt, and ProDOS halts
  with an unclaimed-interrupt system failure (`RESTART SYSTEM-$01`). This was
  reproduced when serial bytes arrived during disk I/O and on serial
  connect/disconnect transitions.

  Claiming unconditionally is safe on the target machines: PIPPIN's slot-2 6551
  is the only device raising interrupts at a BASIC prompt, and reading the
  status register (and the data register when a byte is waiting) clears the
  chip, so there is no re-assert or interrupt livelock. On shutdown (in a build
  that implements clean tear-down) the device's IRQ source must be disabled
  *before* the interrupt is deallocated, or the same unclaimed-interrupt halt
  occurs on the next stray byte.

## 5. Real-hardware quirks

Three behaviors exist solely because PIPPIN runs on real silicon. Emulators
generally do not exhibit them, which makes them easy to "optimize away." Don't.

### The TDRE timing quirk

The genuine 6551 ACIA (and the WDC 65C51 in the //c+) reports its
transmit-data-register-empty (TDRE) status as "ready" prematurely. A naive
transmit loop that writes the next byte the instant TDRE reads ready will clobber
a byte still being clocked out, garbling the response. PIPPIN's
byte-transmit routine polls TDRE and then paces a fixed delay of at least one
character time before writing the next byte. The delay is load-bearing on real
hardware; some emulators model a correct TDRE and would run fine without it,
which is exactly the trap.

### Always-claim the interrupt

Covered in Section 4. The handler claims every interrupt rather than testing the
6551's IRQ-status bit, because the built-in firmware on the //c/c+ can clear
that bit before ProDOS dispatches to PIPPIN.

### Receive-draining during transmit

The 6551 has a one-byte receive register. There is no hardware receive
FIFO. Combined with the inline-IRQ dispatch model (Section 3), this is a real
hazard: while PIPPIN is transmitting a response, interrupts are disabled, so a
client that streams the *next* request frame before the reply finishes would
overrun that single receive register. The dropped byte misaligns the ring, and
every subsequent frame parses as garbage: an error cascade.

Two mitigations, both required:

- The transmit pacing loop drains receive. While it is waiting out the
  inter-byte delay (above), the transmit routine also polls the
  receive-data-register-full bit and, if a byte has arrived, stashes it into the
  ring. So bytes that arrive mid-reply are captured rather than dropped.

- The notification path drains receive to the next frame boundary. The
  `notifications/initialized` frame produces no response, so there is no
  transmit loop running behind it to soak up follow-on bytes. Its handler
  instead explicitly drains the receive register into the ring up to the next
  frame's newline.

If you add a new no-reply code path, or change the transmit routine, you must
preserve receive draining or you reintroduce the overrun. The protocol still
assumes a roughly synchronous client; the draining is what keeps a slightly
eager but well-behaved client from corrupting the stream.

## 6. JSON wire protocol and the order-independent parser

PIPPIN speaks newline-delimited JSON-RPC 2.0. Each request is a single
JSON object terminated by a newline (`\n`, byte `$0A`); the response is likewise
a single newline-terminated JSON object. The newline is the frame delimiter, and
JSON-RPC's structure guarantees no bare newline appears inside a frame.

Note that the wire bytes are 7-bit ASCII: the parser matches a newline as
`$0A`, not the high-ASCII `$8A` the Apple II text screen uses. Wire output and
screen output are different encodings and must not be conflated.

The five MCP methods are `initialize`, `notifications/initialized`,
`tools/list`, `tools/call`, and `ping`. The protocol version is pinned to
`2024-11-05`. Tool names are single characters (server-defined names are legal
MCP), and argument keys are single letters, to keep frames small and the parser
cheap: `s` is `status` (no arguments), `r` is `read_memory` (`a` = address, `l`
= length), `w` is `write_memory` (`a` = address, `v` = hex-encoded value), and
`k` is `send_keystroke` (`k` = key code).

### The parser

The parser is an order-independent, collision-safe, whitespace-tolerant
object scanner, not a fixed-offset template walker. A template walker that reads
discriminator bytes at hard-coded positions only works for one exact key order;
real MCP clients serialize keys in their own order (the SDK puts `method` first
and `id` last, and notifications carry no `id` at all). The scanner handles any
of these.

The flow is:

1. `find_newline` scans the ring from the read pointer for the frame
   terminator. If there is no complete frame buffered yet, it waits for more
   bytes. The newline's ring offset becomes the frame-end bound for everything
   downstream.

2. `parse_frame` classifies the frame and extracts argument positions, built
   entirely on a single primitive, `find_key`.

3. `find_key` takes an object's opening brace and a key string, scans that
   object's *own* members for the key, and returns the ring offset where the
   matching value begins. It skips whitespace between tokens, honors backslash
   escapes inside strings, and to step over a member it doesn't want, it calls:

4. `skip_value`, which advances past exactly one JSON value structurally:
   a string (escapes honored), a balanced object or array (tracking nesting
   depth, and tracking string state so braces inside strings don't count), or a
   primitive (number / `true` / `false` / `null`) up to its terminator.

Classification walks at most three object levels: the top-level object for
`method` and `id`, then `params` for the tool `name`, then `arguments` for the
per-tool argument keys. Each level is a fresh `find_key` call on the offset the
previous level returned: iterative, no recursion. The result is a small fixed
output: an op enum (0-7, or `$FF` for error), the ring offset of the `id`
digits, and the ring offsets (and, for `write_memory`, the length) of the tool
arguments. The dispatcher reads the op enum, rejects the error value, and
otherwise jumps through a jump table to the matching handler.

Three properties of this design matter:

- Order independence falls out of `find_key` searching by name rather than
  position. Any key order works.

- Collision safety. Because `skip_value` consumes string *values* opaquely,
  a key-looking substring inside a string value cannot be mistaken for a real
  key. A crafted `clientInfo.name` containing something like `","id":999` is
  consumed as string content and never matched. It cannot spoof a top-level
  `id` or redirect the dispatched method.

- Bounded termination. Every loop that advances through the ring is gated by
  the frame-end bound from `find_newline`: the moment the scan position reaches
  the newline before a structure closes, the routine returns "malformed," which
  `parse_frame` turns into the error op. This is not optional polish. The
  scanner's advances are data-driven and unbounded in principle; without the
  bound, an unterminated string or unbalanced brace from a truncated or hostile
  client would walk the index past the newline, through any later queued frames,
  and around the 256-byte ring indefinitely. And since dispatch runs inside the
  interrupt, that is a hard hang. The bound guarantees that a truncated or
  hostile frame yields an error response, never a hang.

## 7. PIP binary wire protocol

PIP replaces JSON with a compact, length-framed binary protocol.
Integers are little-endian; frames are self-describing in length, so the Apple
reads a known byte count and never scans for a terminator.

```
Request   host -> Apple:   A5  OP  ALEN  args[ALEN]  CK
                           CK = (OP + ALEN + sum(args)) & 0xFF

Response  Apple -> host:   A5  ST  RLEN  res[RLEN]   CK
                           CK = (ST + RLEN + sum(res)) & 0xFF
```

`A5` is the frame-start sync byte. `OP`, `ALEN`, `ST`, `RLEN`, and `CK` are each
one byte. The Apple resyncs to the next `A5`, reads `OP` and `ALEN`, waits until
a full `4 + ALEN`-byte frame is buffered, verifies the checksum, then dispatches
the one-byte opcode through a jump table.

Opcodes:

| OP   | Name    | Arguments                              | Response on `ST=00`        |
|------|---------|----------------------------------------|----------------------------|
| `00` | ping    | none                                   | none                       |
| `01` | status  | none                                   | a fixed status block       |
| `02` | read    | `addr_lo, addr_hi, count` (1..255)     | `count` raw bytes          |
| `03` | write   | `addr_lo, addr_hi, data[N]` (1..128)   | none                       |
| `04` | sendkey | `keycode` (0..127)                     | none                       |

Status (`ST`) codes:

| ST   | Meaning            |
|------|--------------------|
| `00` | OK                 |
| `01` | bad checksum       |
| `02` | bad opcode         |
| `03` | forbidden range    |
| `04` | bad length / param |

`01` is raised when the computed request checksum does not match the received
`CK`; `02` when the opcode is out of range; `03` for an address-range violation
(same rules as PIPPIN's I/O safety, Section 9); `04` for a wrong
`ALEN` for the opcode, a zero read count, or an out-of-range keystroke. Error
responses carry `RLEN=0`.

The same hang-safety discipline as PIPPIN's parser applies, re-expressed for
length framing: every loop over the ring is bounded either by the count of
buffered bytes or by a fixed per-opcode length, so a truncated or hostile frame
yields an `ST` error or waits for more bytes, never an unbounded ring
walk. The byte-transmit routine (shared with PIPPIN) is reused
verbatim, so the TDRE pacing and receive-draining behaviors of Section 5 carry
over unchanged.

## 8. Memory map

The BIN loads at `$2000`, where it runs transient install code:
banner, machine detection, SSC detection and 6551 initialization, copying the
resident image(s) into place, installing the keyboard hook, registering the
interrupt, and marking the resident pages busy in the ProDOS system bit map.
Once installed and chained to BASIC.SYSTEM, the `$2000` region is no longer
referenced and is free for HGR pages, `BLOAD`s, and Applesoft programs.

The resident runtime lives in two regions chosen so the user can use the
graphics pages freely without disturbing PIPPIN:

```
$2000-$2FFF   transient install code     (reclaimed after install)
$9000-$95FF   MAIN_RES (1536 bytes)      (marked busy in the system bit map)
$D000-$DFFF   language-card bank 2       (PIPPIN only; 4096 bytes)
```

MAIN_RES (`$9000`-`$95FF`, six pages) sits just below BASIC.SYSTEM's HIMEM.
It holds the interrupt handler, the keyboard hook, the serial-transmit routines,
the resident state, and the ring buffer: everything that must run while ProDOS
still has the language card mapped to its own bank. Notable fixed addresses
within it: the state block at `$9080`, the transmit-string helper at `$9100`,
the interrupt parameter block at `$93F0`, and the 256-byte receive ring at
`$9400`. The ring is page-aligned on purpose: the parser indexes it with an
8-bit register, so the index wrapping from `$FF` to `$00` *is* the ring wrap,
and every load is a deterministic four cycles with no page-crossing penalty.

The interrupt handler lives in MAIN_RES rather than the language card
deliberately. An interrupt can fire while ProDOS or BASIC.SYSTEM has the
language card mapped to bank 1 (their own code and data); a handler in the
language card would have to bank-switch under the interrupt, briefly unmapping
the system code area. Keeping the handler in main memory makes the language-card
bank state irrelevant to it: it only touches zero page, the ring, and the SSC
registers.

Language-card bank 2 (`$D000`-`$DFFF`, the full 4 KB) is used by
PIPPIN only. A plain ProDOS 8 reserves bank 1 of the language card
for itself and leaves bank 2 unused, so PIPPIN claims bank 2 exclusively for the
parser, the dispatch table, the nine handlers, and the response-template data
(the `tools/list` body alone is roughly 600 bytes). This region is read-only at
runtime (PIPPIN only reads from it after install), which is why any scratch the
handlers need to *write* lives back in MAIN_RES.

PIPPIN reaches its language-card code through a bank-switch
trampoline. When a complete frame arrives, the interrupt handler samples the
current language-card read state, switches to read bank 2, calls into the parser
at `$D000`, and on return restores whatever read state the interrupted code had
(bank-1 RAM under BASIC.SYSTEM, or ROM under bare Applesoft). The
language-card-resident code never chains the keyboard vector or touches the
saved hook; it does its parse/dispatch/handler work and may call back into
MAIN_RES to transmit response bytes (MAIN_RES is always readable regardless of
bank state).

PIP is MAIN_RES-only. The binary handler is small enough to
fit entirely in the six pages at `$9000`, so it has no language-card image and
no bank-switch trampoline. The interrupt handler calls the dispatcher directly.
This is the source of the size difference: PIPPIN's resident footprint
is the 1536-byte MAIN_RES image plus the 4096-byte language-card image (5632
bytes total), while PIP is the 1536-byte MAIN_RES image alone
(roughly 3.7x smaller), and it sheds the entire bank-switch-under-interrupt
apparatus along with it.

## 9. I/O safety

The Apple II's `$C000`-`$CFFF` page is memory-mapped I/O and slot firmware, and
*reading* parts of it has side effects: a read of `$C030` clicks the speaker, a
second read of certain language-card soft switches write-enables language-card
RAM, and the bank-select latches are especially hostile read targets. To keep
the memory tools from accidentally triggering hardware, both `read_memory` and
`write_memory` reject any requested range that overlaps `$C000`-`$CFFF`, and
both reject a range that would wrap past `$FFFF`. The range arithmetic checks the
computed end address against the boundary, so a read that starts below `$C000`
but whose length would run up into the I/O page is rejected as a whole.

`write_memory` additionally rejects any overlap with `$BF00`-`$BFFF`, the
ProDOS global page (which holds `MLIACTV`, the system bit map, and other state
that a stray write would corrupt). Because the forbidden write zone
`$BF00`-`$CFFF` is contiguous, guarding the lower boundary `$BF00` also covers
the I/O page for a write that starts below and runs up into it. Reading the
global page is side-effect-free, so `read_memory` guards only `$C000` and allows
reads of `$BF00`-`$BFFF`.

PIP applies the identical range rules, surfacing a violation as
status code `03` (forbidden range) rather than a JSON-RPC error.

These guards are security-critical. PIPPIN exposes the entire machine's memory
and keyboard to whatever is on the wire; the range checks are the one thing
standing between a malformed or hostile request and a hardware side effect or a
corrupted ProDOS.

## 10. References

- *ProDOS 8 Technical Reference Manual*, Chapter 6 ("Adding Routines to
  ProDOS"): the interrupt-handler contract, `ALLOC_INTERRUPT` /
  `DEALLOC_INTERRUPT`, and the system bit map.
- *Apple II Miscellaneous Technical Note #7: Apple II Family Identification*:
  the machine-detection routine distinguishing the enhanced //e, //c, //c+, and
  IIgs.
- *Apple II Miscellaneous Technical Note #8: Pascal 1.1 Firmware Protocol ID
  Bytes*: the signature used to detect the SSC (and the //c's built-in
  serial port) in a slot.
- *Super Serial Card Installation and Operating Manual*: the 6551 ACIA register
  layout, slot addressing, and interrupt configuration.
- Brutal Deluxe Merlin32 documentation: the cross-platform Merlin32 assembler
  used to build PIPPIN. <https://brutaldeluxe.fr/products/crossdevtools/merlin/>
