from __future__ import annotations

import io
import json
import os
import pathlib
import runpy
import subprocess
import tempfile
import unittest
from unittest import mock

from omarchy_protect.client import (
    Camera,
    ProtectClient,
    ProtectError,
    SameOriginRedirectHandler,
    SecretStore,
    _stream_manifest,
    _stream_relay_command,
    canonical_console_url,
    launch_mpv,
    runtime_frame_path,
    persist_settings,
    validate_camera_id,
    watch_snapshots,
    write_snapshot,
)


class FakeHeaders(dict):
    def get_content_type(self) -> str:
        return self.get("Content-Type", "application/octet-stream").split(";", 1)[0]


class FakeResponse(io.BytesIO):
    def __init__(self, body: bytes, content_type: str = "application/json") -> None:
        super().__init__(body)
        self.headers = FakeHeaders({"Content-Type": content_type, "Content-Length": str(len(body))})

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()


class ClientTests(unittest.TestCase):
    def test_malformed_api_keys_fail_without_exposing_or_using_the_key(self) -> None:
        for key in (
            "synthetic-secret\r\nX-Unwanted: value",
            "synthetic-secret\x00value",
            "synthetic-secret\tvalue",
            "synthetic-secret\x7fvalue",
            "synthetic-secret\u2603",
            "synthetic-secret" + "x" * 4096,
        ):
            with self.subTest(key=repr(key)):
                with mock.patch("urllib.request.build_opener") as opener:
                    with self.assertRaises(ProtectError) as failure:
                        ProtectClient("https://protect.local", key)
                    self.assertNotIn("synthetic-secret", str(failure.exception))
                    self.assertTrue(failure.exception.needs_auth)
                    opener.assert_not_called()
                with mock.patch("subprocess.run") as store:
                    with self.assertRaises(ProtectError) as failure:
                        SecretStore.store("https://protect.local", key)
                    self.assertNotIn("synthetic-secret", str(failure.exception))
                    store.assert_not_called()

    def test_api_key_validation_preserves_paste_whitespace_and_limit(self) -> None:
        key = "a" * 4096
        client = ProtectClient("https://protect.local", f" {key}\n")
        self.assertEqual(client.api_key, key)
        with mock.patch("subprocess.run") as store:
            SecretStore.store("https://protect.local", f" {key}\n")
            self.assertEqual(store.call_args.kwargs["input"], key)

    def test_cli_reports_invalid_key_as_authentication_error_without_io(self) -> None:
        cli = pathlib.Path(__file__).resolve().parents[1] / "bin" / "omarchy-protect"
        main = runpy.run_path(str(cli))["main"]
        with mock.patch("sys.argv", [str(cli), "--url", "https://protect.local", "connect", "--stdin"]), \
             mock.patch("sys.stdin", io.StringIO("synthetic-secret\u2603\n")), \
             mock.patch("sys.stdout", new_callable=io.StringIO) as output, \
             mock.patch("sys.stderr", new_callable=io.StringIO) as errors, \
             mock.patch("socket.create_connection") as network, \
             mock.patch("subprocess.run") as store:
            self.assertEqual(main(), 1)
        result = json.loads(output.getvalue())
        self.assertTrue(result["needsAuth"])
        self.assertEqual(result["error"], "Enter a valid UniFi API key")
        self.assertNotIn("synthetic-secret", output.getvalue() + errors.getvalue())
        self.assertEqual(errors.getvalue(), "")
        network.assert_not_called()
        store.assert_not_called()

    def test_canonical_console_url(self) -> None:
        self.assertEqual(canonical_console_url(" Protect.Local/ "), "https://protect.local")
        self.assertEqual(canonical_console_url("https://[fd00::1]:8443"), "https://[fd00::1]:8443")

    def test_console_url_rejects_unsafe_forms(self) -> None:
        for value in (
            "http://protect.local",
            "https://user:pass@protect.local",
            "https://protect.local/proxy/protect",
            "https://protect.local/?key=secret",
            "file:///tmp/protect",
            "https://protect.local:bad",
            "https://protect.local\\@other.test",
            "https://protect.local\n.other.test",
        ):
            with self.subTest(value=value), self.assertRaises(ProtectError):
                canonical_console_url(value)

    def test_camera_id_is_bounded(self) -> None:
        self.assertEqual(validate_camera_id("abc_123-Z"), "abc_123-Z")
        for value in ("", "../camera", "camera/id", "x" * 129):
            with self.subTest(value=value), self.assertRaises(ProtectError):
                validate_camera_id(value)

    def test_cross_origin_redirect_is_rejected(self) -> None:
        handler = SameOriginRedirectHandler(("https", "protect.local", None))
        request = mock.Mock(full_url="https://protect.local/api")
        with self.assertRaisesRegex(ProtectError, "another origin"):
            handler.redirect_request(request, None, 302, "Found", {}, "https://evil.test/capture")

    def test_camera_normalization_and_sorting(self) -> None:
        payload = [
            {"id": "b", "name": "Yard", "state": "connected", "hasPackageCamera": False, "isMicEnabled": True},
            {"id": "a", "name": "Door", "state": "unexpected", "hasPackageCamera": True},
        ]
        client = ProtectClient("https://protect.local", "key")
        client.opener = mock.Mock()
        client.opener.open.return_value = FakeResponse(json.dumps(payload).encode())
        self.assertEqual(
            client.cameras(),
            [Camera("a", "Door", "UNKNOWN"), Camera("b", "Yard", "CONNECTED")],
        )

    def test_camera_names_drop_control_characters(self) -> None:
        payload = [{"id": "a", "name": "Front\n\u202eDoor\x7f", "state": "CONNECTED"}]
        client = ProtectClient("https://protect.local", "key")
        client.opener = mock.Mock()
        client.opener.open.return_value = FakeResponse(json.dumps(payload).encode())
        self.assertEqual(client.cameras()[0].name, "FrontDoor")

    def test_snapshot_requires_complete_jpeg(self) -> None:
        client = ProtectClient("https://protect.local", "key")
        client.opener = mock.Mock()
        client.opener.open.return_value = FakeResponse(b"not-a-jpeg", "image/jpeg")
        with self.assertRaisesRegex(ProtectError, "invalid JPEG"):
            client.snapshot("camera")

    def test_stream_prefers_high_and_rejects_credentials(self) -> None:
        client = ProtectClient("https://protect.local", "key")
        client.json = mock.Mock(return_value={"high": "rtsps://nvr.local/live?token", "medium": None})
        self.assertEqual(client.stream_url("camera", "medium"), "rtsps://nvr.local/live?token")
        client.json = mock.Mock(return_value={"high": "rtsps://user:pass@nvr.local/live"})
        with self.assertRaisesRegex(ProtectError, "unsafe"):
            client.stream_url("camera")
        client.json = mock.Mock(return_value={"high": "rtsps://nvr.local/live?token='bad'"})
        with self.assertRaisesRegex(ProtectError, "unsafe"):
            client.stream_url("camera")

    def test_stream_manifest_carries_transport_and_tls_policy(self) -> None:
        manifest = _stream_manifest("rtsps://nvr.local/live?token", False)
        self.assertEqual(
            manifest,
            b"ffconcat version 1.0\n"
            b"file 'rtsps://nvr.local/live?token'\n"
            b"option rtsp_transport tcp\n"
            b"option tls_verify 0\n",
        )

    def test_stream_relay_avoids_startup_buffer_regression(self) -> None:
        command = _stream_relay_command()
        self.assertNotIn("nobuffer", command)
        self.assertEqual(command[-3:], ["-f", "matroska", "pipe:1"])
        self.assertEqual(command[command.index("-c") + 1], "copy")

    def test_secret_is_sent_on_stdin_not_argv(self) -> None:
        with mock.patch("subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, "")
            SecretStore.store("https://protect.local", "super-secret-key")
        args = run.call_args.args[0]
        self.assertNotIn("super-secret-key", args)
        self.assertEqual(run.call_args.kwargs["input"], "super-secret-key")

    def test_secret_service_failure_is_not_reported_as_missing(self) -> None:
        with mock.patch("subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess([], 1, "", "keyring unavailable")
            with self.assertRaisesRegex(ProtectError, "Secret Service"):
                SecretStore.lookup("https://protect.local")

    def test_runtime_frames_require_private_session_directory(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(ProtectError, "XDG_RUNTIME_DIR"):
                runtime_frame_path("camera")
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.dict(os.environ, {"XDG_RUNTIME_DIR": directory}, clear=True):
                path = runtime_frame_path("camera")
                write_snapshot(path, b"\xff\xd8data\xff\xd9")
                self.assertEqual(path.read_bytes(), b"\xff\xd8data\xff\xd9")
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)

    def test_one_shot_snapshot_preview_returns_after_first_frame(self) -> None:
        client = mock.Mock()
        client.snapshot.return_value = b"\xff\xd8data\xff\xd9"
        with tempfile.TemporaryDirectory() as directory, \
             mock.patch.dict(os.environ, {"XDG_RUNTIME_DIR": directory}, clear=True), \
             mock.patch("sys.stdout", new_callable=io.StringIO) as output:
            watch_snapshots(client, "camera", 10.0, once=True)
            result = json.loads(output.getvalue())
            self.assertEqual(
                pathlib.Path(result["path"].removeprefix("file://")).read_bytes(),
                b"\xff\xd8data\xff\xd9",
            )
        client.snapshot.assert_called_once_with("camera")

    def test_mpv_receives_stream_on_stdin(self) -> None:
        with mock.patch("os.pipe", return_value=(10, 11)), mock.patch("os.write") as write, \
             mock.patch("os.close"), mock.patch("subprocess.Popen") as popen:
            launch_mpv(
                "rtsps://nvr.local/live?token",
                hardware_decoding=False,
                muted=True,
                input_config=pathlib.Path("/plugin/mpv-camera.conf"),
            )
        argv = popen.call_args.args[0]
        self.assertNotIn("rtsps://nvr.local/live?token", argv)
        self.assertIn("--mute=yes", argv)
        self.assertIn("--ontop=no", argv)
        self.assertIn("--no-config", argv)
        self.assertIn("--hwdec=no", argv)
        self.assertIn("--wayland-app-id=io.github.luxore.unifi-protect-live", argv)
        self.assertIn("--input-conf=/plugin/mpv-camera.conf", argv)
        self.assertEqual(popen.call_args.kwargs["stdin"], 10)
        write.assert_called_once_with(11, b"rtsps://nvr.local/live?token\n")

    def test_persisted_settings_contain_no_secret(self) -> None:
        with mock.patch("subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, "", "")
            persist_settings("https://protect.local", False)
        commands = [call.args[0] for call in run.call_args_list]
        self.assertEqual(len(commands), 3)
        self.assertTrue(all(command[:4] == ["omarchy", "bar", "set", "io.github.luxore.unifi-protect"] for command in commands))
        self.assertNotIn("apiKey", json.dumps(commands))


if __name__ == "__main__":
    unittest.main()
