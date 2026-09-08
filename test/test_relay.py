"""Exercise relay cleanup using real sockets and an uncooperative child."""
import os
import pathlib
import signal
import socket
import subprocess
import sys
import unittest
import urllib.parse
from unittest import mock

from omarchy_protect.client import _accept_stream_request


class RelayTests(unittest.TestCase):
    def test_abandoned_and_oversized_requests_do_not_escape(self):
        for chunks in ([b"GET /private HTTP/1.1\r\n", b""], [b"x" * 8192]):
            connection = mock.Mock()
            connection.recv.side_effect = chunks
            self.assertFalse(_accept_stream_request(connection, "/private"))
            connection.sendall.assert_not_called()
        for error in (TimeoutError(), ConnectionResetError(), BrokenPipeError()):
            connection = mock.Mock()
            connection.recv.side_effect = error
            self.assertFalse(_accept_stream_request(connection, "/private"))

    def test_relay_survives_disconnect_and_reaps_child_that_ignores_term(self):
        child_code = (
            "import os,signal,time; "
            "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
            "print(os.getpid(), flush=True); time.sleep(60)"
        )
        relay_code = (
            "import sys; from omarchy_protect import client; "
            f"client._stream_relay_command = lambda: [sys.executable, '-c', {child_code!r}]; "
            "client.serve_stream('rtsps://example.invalid/live', "
            "lambda url: print(url, flush=True))"
        )
        relay = subprocess.Popen(
            [sys.executable, "-u", "-c", relay_code],
            cwd=pathlib.Path(__file__).resolve().parents[1],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        child_pid = None
        try:
            # A pipe read must also have a deadline when startup regresses.
            import select
            self.assertTrue(select.select([relay.stdout], [], [], 5)[0])
            url = urllib.parse.urlsplit(relay.stdout.readline().strip())
            with socket.create_connection((url.hostname, url.port), timeout=5) as abandoned:
                abandoned.sendall(b"GET /unfinished")
            with socket.create_connection((url.hostname, url.port), timeout=5) as viewer:
                viewer.sendall(f"GET {url.path} HTTP/1.1\r\nHost: localhost\r\n\r\n".encode())
                response = b""
                while b"\r\n\r\n" not in response:
                    response += viewer.recv(4096)
                headers, body = response.split(b"\r\n\r\n", 1)
                self.assertIn(b"200 OK", headers)
                while b"\n" not in body:
                    body += viewer.recv(4096)
                child_pid = int(body.splitlines()[0])
                relay.send_signal(signal.SIGTERM)
                _, errors = relay.communicate(timeout=6)
            self.assertEqual(relay.returncode, 0, errors)
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid, 0)
        finally:
            if relay.poll() is None:
                relay.kill()
            relay.communicate()
            if child_pid is not None:
                try:
                    os.kill(child_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
