# tools/test_pippin_bridge.py
"""CI-green test for pippin_bridge.py: spawn it pointed at a local TCP
server and verify it relays bytes both directions, then exits on stdin EOF.
No Apple/emulator involved -- just a loopback socket."""
import os
import socket
import subprocess
import sys
import time

BRIDGE = os.path.join(os.path.dirname(__file__), "pippin_bridge.py")


def _free_port():
    s = socket.socket()
    s.bind(("localhost", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _accept_or_fail(listener, proc):
    """Accept with a deadline so a bridge that never connects fails fast
    instead of hanging CI (no pytest-timeout in this repo)."""
    listener.settimeout(5)
    try:
        conn, _ = listener.accept()
    except socket.timeout:
        proc.kill()
        raise AssertionError("bridge never connected within 5s")
    return conn


def test_bridge_relays_both_directions_and_exits_on_eof():
    port = _free_port()
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("localhost", port))
    listener.listen(1)

    proc = subprocess.Popen(
        [sys.executable, BRIDGE, "localhost", str(port)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    )
    conn = None
    try:
        conn = _accept_or_fail(listener, proc)
        conn.settimeout(5)

        # stdin -> socket
        proc.stdin.write(b'{"hello":1}\n')
        proc.stdin.flush()
        got = b""
        while not got.endswith(b"\n"):
            got += conn.recv(64)
        assert got == b'{"hello":1}\n'

        # socket -> stdout
        conn.sendall(b'{"world":2}\n')
        out = b""
        while not out.endswith(b"\n"):
            out += proc.stdout.read(1)
        assert out == b'{"world":2}\n'

        # stdin EOF -> bridge exits cleanly
        proc.stdin.close()
        assert proc.wait(timeout=5) == 0
    finally:
        if proc.poll() is None:
            proc.kill()
        if conn:
            conn.close()
        listener.close()


def test_socket_frame_not_dropped_when_stdin_closes_same_wakeup():
    """Regression: a final Apple->SDK frame arriving in the same select()
    wakeup as stdin EOF must not be dropped. The bridge has to drain the
    socket before honoring stdin EOF. Fails on the old (stdin-first) branch
    order; passes once the socket branch runs first."""
    port = _free_port()
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("localhost", port))
    listener.listen(1)

    proc = subprocess.Popen(
        [sys.executable, BRIDGE, "localhost", str(port)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    )
    conn = None
    try:
        conn = _accept_or_fail(listener, proc)
        conn.settimeout(5)

        # Let the bridge settle into its select() so the frame + stdin EOF
        # below land in one wakeup, making the race fire.
        time.sleep(0.1)

        # Final socket frame and stdin EOF back-to-back.
        conn.sendall(b'{"final":1}\n')
        proc.stdin.close()

        # Read stdout until newline or EOF; the frame must survive.
        out = b""
        while not out.endswith(b"\n"):
            chunk = proc.stdout.read(1)
            if not chunk:                    # bridge exited without the frame
                break
            out += chunk
        assert out == b'{"final":1}\n'

        assert proc.wait(timeout=5) == 0
    finally:
        if proc.poll() is None:
            proc.kill()
        if conn:
            conn.close()
        listener.close()
