# Running PIPPIN and PIP

> 🚧 **Work in progress.** This doc is thin right now — it covers the
> real-hardware path; emulator and bridge setups are still to come.

The ways to run PIPPIN and PIP — on real Apple II hardware over a serial link,
or through an emulator's TCP-bridged Super Serial Card. Either way, the same
host code drives the dongle or the emulator.

## Run it on real hardware

You need an enhanced //e, a //c, a //c+, or a IIgs in 8-bit mode, and a
USB-serial null-modem dongle. All of these carry a 65C02, so use the default
build.

For an unenhanced //e (an NMOS 6502) use the `.6502` builds instead:
`make all6502` / `make pip6502`, and `make recv6502` for `RECV.6502`.

```sh
make recv                                     # build RECV.BIN (the receiver)
# transfer RECV.BIN to the Apple once; after that serial_send.py does the transfers
make                                          # build PIPPIN
# on the Apple:  BRUN RECV.BIN  (it waits, receiving into $2000)
uv run tools/serial_send.py PIPPIN            # blast it across the wire
# on the Apple:  CALL 8192                     (run the installer; PIPPIN goes resident)
#                (or BSAVE it, then run)
tools/serial_bridge.sh                        # socat bridge: TCP :1977 <-> the dongle
uv run --with mcp tools/pippin_check.py       # drive PIPPIN end to end
```

(`pippin_check.py` drives PIPPIN directly over the wire. For
the PIP build, run its front-end instead: `uv run --with mcp python
tools/pippin_mcp.py`.)

On an unenhanced //e, swap `RECV.6502` and `PIPPIN.6502` (or `PIP.6502`) into the
same steps: `BRUN RECV.6502`, then send `PIPPIN.6502`. The `.6502` builds are the
only ones that will run there; the 65C02 builds use opcodes a real NMOS 6502 does
not have and would crash. PIPPIN's `status` reports `m=5` ("unenhanced //e") on
that machine.

`RECV.BIN` is a standalone serial receiver (also its own project,
[gullet](https://github.com/artgreen/gullet)) that bootstraps a `$2000` binary onto
the machine over the same wire. `serial_bridge.sh` exposes the dongle on `:1977`
with a socat one-liner, mirroring microM8's port; [tincan](https://github.com/artgreen/tincan) does the same job
as a self-contained Python script (`uv run tincan.py -d /dev/cu.usbserial-XXXX`,
listening on `:1977`). Either way, the same host code drives the dongle or the
emulator.
