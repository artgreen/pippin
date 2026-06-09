# Changing the baud rate

PIPPIN runs at 9600 baud by default, but the 6551 supports any standard rate.
The line speed is one byte loaded into the 6551 control register. To change it,
patch that byte (default `$1E`) to a value from the table below in both places,
so the receiver and the live session agree:

- `RECV.BIN` (loads at `$0801`): `$0819` (the `.6502` build: `$0823`).
- the installer (loads at `$2000`); the address depends on the build:

  | Build | Patch address |
  |---|---|
  | `PIPPIN` | `$21DF` |
  | `PIPPIN.6502` | `$21F8` |
  | `PIP` | `$21AB` |
  | `PIP.6502` | `$21C8` |

19200 (`$1F`) runs reliably on a //c+ over a real USB-serial link; drop to 300
(`$16`) for an original-ROM //c with the known 9600-baud timing bug.

Match the host with `--baud N`. Over a TCP bridge (an emulator, or tincan/socat)
the wire is a raw byte pipe, so the emulated baud is irrelevant and only the
bridge's serial speed has to match the Apple.

| Value | Baud | Value | Baud | Value | Baud |
|---|---|---|---|---|---|
| `$11` | 50 | `$16` | 300 | `$1B` | 3600 |
| `$12` | 75 | `$17` | 600 | `$1C` | 4800 |
| `$13` | 110 | `$18` | 1200 | `$1D` | 7200 |
| `$14` | 134.5 | `$19` | 1800 | `$1E` | 9600 |
| `$15` | 150 | `$1A` | 2400 | `$1F` | 19200 |
