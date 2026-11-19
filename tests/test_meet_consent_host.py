from __future__ import annotations

import hashlib
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


HOST = Path(__file__).parents[1] / "scripts" / "meet-consent-host"


def read_frame(stream) -> dict[str, object]:
    (length,) = struct.unpack("=I", stream.read(4))
    return json.loads(stream.read(length))


def write_frame(stream, message: dict[str, object]) -> None:
    body = json.dumps(message).encode()
    stream.write(struct.pack("=I", len(body)) + body)
    stream.flush()


class MeetConsentHostTests(unittest.TestCase):
    def listen(self, home: str) -> socket.socket:
        digest = hashlib.sha256(home.encode()).hexdigest()[:12]
        socket_path = f"/tmp/granola-meet-consent-{digest}.sock"
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(socket_path)
        self.addCleanup(os.unlink, socket_path)
        self.addCleanup(server.close)
        server.listen(1)
        server.settimeout(10)
        return server

    def start_host(self, home: str, *python_arguments: str) -> subprocess.Popen[bytes]:
        host = subprocess.Popen(
            [sys.executable, *python_arguments, str(HOST)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            env={**os.environ, "HOME": home},
        )
        self.addCleanup(host.stdout.close)
        self.addCleanup(host.wait, 10)
        self.addCleanup(host.stdin.close)
        return host

    def test_relays_both_ways_and_reports_app_disconnect(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            server = self.listen(home)
            host = self.start_host(home)

            app, _ = server.accept()
            app.sendall(b'{"type":"granola:status","connected":true}\n')
            self.assertEqual(
                read_frame(host.stdout), {"type": "granola:status", "connected": True}
            )

            write_frame(host.stdin, {"type": "meet_meeting_detected", "value": 1})
            app.settimeout(10)
            self.assertEqual(
                app.recv(4096), b'{"type":"meet_meeting_detected","value":1}\n'
            )

            app.close()
            self.assertEqual(
                read_frame(host.stdout), {"type": "granola:status", "connected": False}
            )

    def test_drops_socket_owned_by_another_user(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            server = self.listen(home)
            # The host runs as a user that doesn't own the socket.
            host = self.start_host(
                home,
                "-c",
                "import os, runpy, sys; os.getuid = lambda: -1; "
                "runpy.run_path(sys.argv[1], run_name='__main__')",
            )

            app, _ = server.accept()
            app.settimeout(10)
            self.assertEqual(app.recv(1), b"")

            host.stdin.close()
            self.assertEqual(host.stdout.read(), b"")


if __name__ == "__main__":
    unittest.main()
