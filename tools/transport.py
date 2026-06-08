"""transport.py -- serial/TCP transports shared by the file-transfer tool and
PIP's MCP front-end. TcpTransport talks to a bridge (microM8
SSC telnet :1977 or tools/serial_bridge.sh socat); SerialTransport talks to a
pyserial device directly (--baud). Both expose write / read_exact / read_chunk
/ close."""
import socket
import time


class TcpTransport:
    """Talk to the SSC over a TCP bridge: microM8's SSC telnet (:1977) or
    the socat bridge to a real serial port (tools/serial_bridge.sh)."""

    def __init__(self, host: str, port: int):
        self.sock = socket.create_connection((host, port))

    def write(self, data: bytes) -> None:
        self.sock.sendall(data)

    def read_exact(self, n: int, timeout: float) -> bytes:
        self.sock.settimeout(timeout)
        buf = b""
        try:
            while len(buf) < n:
                chunk = self.sock.recv(n - len(buf))
                if not chunk:
                    raise EOFError(f"connection closed after {len(buf)} of {n} bytes")
                buf += chunk
        except socket.timeout:
            pass
        return buf

    def read_chunk(self, maxn: int, timeout: float) -> bytes:
        """Return up to maxn bytes available within `timeout`; b'' if none."""
        self.sock.settimeout(timeout)
        try:
            return self.sock.recv(maxn)
        except socket.timeout:
            return b""

    def close(self) -> None:
        self.sock.close()


class SerialTransport:
    """Talk to a serial device directly. Requires pyserial (lazy import) and
    is the path where --baud actually sets the line speed, for troubleshooting."""

    def __init__(self, device: str, baud: int):
        import serial  # lazy: only needed for direct-device mode
        self.ser = serial.Serial(device, baud, timeout=0.2)

    def write(self, data: bytes) -> None:
        self.ser.write(data)
        self.ser.flush()

    def read_exact(self, n: int, timeout: float) -> bytes:
        self.ser.timeout = timeout
        buf = b""
        deadline = time.monotonic() + timeout
        while len(buf) < n and time.monotonic() < deadline:
            chunk = self.ser.read(n - len(buf))
            if chunk:
                buf += chunk
        return buf

    def read_chunk(self, maxn: int, timeout: float) -> bytes:
        """Return up to maxn bytes available within `timeout`; b'' if none."""
        self.ser.timeout = timeout
        return self.ser.read(maxn)

    def close(self) -> None:
        self.ser.close()
