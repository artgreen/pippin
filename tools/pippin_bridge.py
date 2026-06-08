# tools/pippin_bridge.py
"""pippin_bridge.py -- raw stdin<->TCP passthrough.

Lets the official MCP SDK's stdio client drive the on-device JSON PIPPIN build:
the SDK spawns this as its "server" subprocess; we shuttle bytes between the SDK
(stdin/stdout) and the Apple's SSC wire (TCP host:port, normally :1977). PIPPIN's
newline-framed JSON-RPC is exactly the framing the stdio transport expects, so
this is a byte-transparent relay -- no translation. (This is a named, silent
reimplementation of the `socat - TCP:localhost:1977` passthrough that already
drove the //c+ with the unmodified SDK.)

    pippin_bridge.py HOST PORT [PACE_MS]

Exits 0 when either side closes. Silent on the happy path.

PACE_MS (optional): milliseconds to wait between each byte written toward the TCP
side. Needed for the microM8 emulator, whose SSC telnet feeds the emulated 6551
faster than 9600 baud and overruns its 1-byte RX register on long (~150-byte
JSON) frames. Real hardware is paced by the physical 9600-baud line, so omit it
(or pass 0) there.
"""
import os
import select
import socket
import sys
import time


def _write_all(fd: int, data: bytes) -> None:
    while data:
        n = os.write(fd, data)
        data = data[n:]


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) not in (2, 3):
        print("usage: pippin_bridge.py HOST PORT [PACE_MS]", file=sys.stderr)
        return 2
    host, port = argv[0], int(argv[1])
    pace_s = (float(argv[2]) / 1000.0) if len(argv) == 3 else 0.0
    sock = socket.create_connection((host, port))
    in_fd, out_fd, sock_fd = sys.stdin.fileno(), sys.stdout.fileno(), sock.fileno()
    try:
        while True:
            rlist, _, _ = select.select([in_fd, sock_fd], [], [])
            if sock_fd in rlist:
                data = sock.recv(65536)
                if not data:                 # peer (Apple/bridge) closed -> done
                    break
                _write_all(out_fd, data)
            if in_fd in rlist:
                data = os.read(in_fd, 65536)
                if not data:                 # SDK closed stdin -> done
                    break
                if pace_s:                   # byte-pace toward the emulator's 6551 RX
                    for i in range(len(data)):
                        sock.sendall(data[i:i + 1])
                        time.sleep(pace_s)
                else:
                    sock.sendall(data)
    finally:
        sock.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
