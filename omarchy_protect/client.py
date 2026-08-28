"""Secure process boundary for the Omarchy Protect QML surface."""

from __future__ import annotations

import json
import os
import pathlib
import re
import secrets
import signal
import socket
import ssl
import subprocess
import tempfile
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import BinaryIO, Callable

APP_ID = "io.github.luxore.unifi-protect"
SECRET_SERVICE = "omarchy-unifi-protect"
MAX_JSON_BYTES = 4 * 1024 * 1024
MAX_SNAPSHOT_BYTES = 25 * 1024 * 1024
CAMERA_ID = re.compile(r"^[A-Za-z0-9_-]{1,128}$")


class ProtectError(RuntimeError):
    """Expected error safe to show in the plugin UI."""

    def __init__(self, message: str, *, needs_auth: bool = False) -> None:
        super().__init__(message)
        self.needs_auth = needs_auth


def canonical_console_url(value: str) -> str:
    raw = value.strip()
    if not raw:
        raise ProtectError("Enter the HTTPS address of the UniFi console")
    if "://" not in raw:
        raw = "https://" + raw
    if "\\" in raw or any(ord(character) < 32 or ord(character) == 127 for character in raw):
        raise ProtectError("Enter a valid UniFi console address")
    parsed = urllib.parse.urlsplit(raw)
    if parsed.scheme.lower() != "https":
        raise ProtectError("UniFi Protect connections require HTTPS")
    if parsed.username or parsed.password:
        raise ProtectError("Do not put credentials in the console URL")
    if not parsed.hostname:
        raise ProtectError("Enter a valid UniFi console address")
    if parsed.query or parsed.fragment:
        raise ProtectError("The console URL cannot contain a query or fragment")
    path = parsed.path.rstrip("/")
    if path and path != "/":
        raise ProtectError("Enter the UniFi console root URL, without an application path")
    hostname = parsed.hostname.lower()
    if ":" in hostname and not hostname.startswith("["):
        hostname = f"[{hostname}]"
    try:
        parsed_port = parsed.port
    except ValueError as error:
        raise ProtectError("Enter a valid UniFi console port") from error
    port = f":{parsed_port}" if parsed_port else ""
    return f"https://{hostname}{port}"


def validate_camera_id(value: str) -> str:
    if not CAMERA_ID.fullmatch(value):
        raise ProtectError("Protect returned an invalid camera identifier")
    return value


def safe_display_text(value: object, fallback: str) -> str:
    text = str(value) if value is not None else ""
    text = "".join(character for character in text if not unicodedata.category(character).startswith("C"))
    return text.strip()[:160] or fallback


class SecretStore:
    @staticmethod
    def lookup(console_url: str) -> str | None:
        try:
            result = subprocess.run(
                ["secret-tool", "lookup", "service", SECRET_SERVICE, "console", console_url],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=5,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired) as error:
            raise ProtectError("Secret Service is unavailable") from error
        key = result.stdout.strip()
        if result.returncode == 0:
            return key or None
        if result.stderr.strip():
            raise ProtectError("Could not read the API key from Secret Service")
        return None

    @staticmethod
    def store(console_url: str, api_key: str) -> None:
        key = api_key.strip()
        if not key or len(key) > 4096 or "\x00" in key:
            raise ProtectError("Enter a valid UniFi API key")
        try:
            subprocess.run(
                [
                    "secret-tool",
                    "store",
                    "--label=UniFi Protect Viewer API key",
                    "service",
                    SECRET_SERVICE,
                    "console",
                    console_url,
                ],
                input=key,
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
                timeout=10,
            )
        except FileNotFoundError as error:
            raise ProtectError("Secret Service is unavailable") from error
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            raise ProtectError("Could not save the API key in Secret Service") from error

    @staticmethod
    def clear(console_url: str) -> None:
        try:
            result = subprocess.run(
                ["secret-tool", "clear", "service", SECRET_SERVICE, "console", console_url],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
                timeout=5,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired) as error:
            raise ProtectError("Secret Service is unavailable") from error
        if result.returncode != 0 and result.stderr.strip():
            raise ProtectError("Could not remove the API key from Secret Service")


class SameOriginRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Reject redirects that could forward the API key to another origin."""

    def __init__(self, origin: tuple[str, str, int | None]) -> None:
        self.origin = origin

    @staticmethod
    def _origin(url: str) -> tuple[str, str, int | None]:
        parsed = urllib.parse.urlsplit(url)
        return parsed.scheme.lower(), (parsed.hostname or "").lower(), parsed.port

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        target = urllib.parse.urljoin(req.full_url, newurl)
        if self._origin(target) != self.origin:
            raise ProtectError("The UniFi console redirected the request to another origin")
        return super().redirect_request(req, fp, code, msg, headers, target)


def _bounded_read(response: BinaryIO, limit: int) -> bytes:
    content_length = getattr(response, "headers", {}).get("Content-Length")
    if content_length:
        try:
            if int(content_length) > limit:
                raise ProtectError("The UniFi console response was too large")
        except ValueError:
            pass
    data = response.read(limit + 1)
    if len(data) > limit:
        raise ProtectError("The UniFi console response was too large")
    return data


@dataclass(frozen=True)
class Camera:
    id: str
    name: str
    state: str

    def as_json(self) -> dict[str, object]:
        return {
            "id": self.id,
            "name": self.name,
            "state": self.state,
        }


class ProtectClient:
    def __init__(self, console_url: str, api_key: str, *, verify_tls: bool = True) -> None:
        self.console_url = canonical_console_url(console_url)
        self.api_key = api_key.strip()
        if not self.api_key:
            raise ProtectError("Connect a UniFi API key to continue", needs_auth=True)
        parsed = urllib.parse.urlsplit(self.console_url)
        self.origin = (parsed.scheme, parsed.hostname or "", parsed.port)
        context = ssl.create_default_context()
        if not verify_tls:
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=context),
            SameOriginRedirectHandler(self.origin),
        )

    def _url(self, path: str) -> str:
        return self.console_url + "/proxy/protect/integration" + path

    def request(self, path: str, *, accept: str, limit: int) -> tuple[bytes, str]:
        request = urllib.request.Request(
            self._url(path),
            headers={"Accept": accept, "X-API-Key": self.api_key},
            method="GET",
        )
        try:
            with self.opener.open(request, timeout=12) as response:
                content_type = response.headers.get_content_type()
                return _bounded_read(response, limit), content_type
        except ProtectError:
            raise
        except urllib.error.HTTPError as error:
            if error.code in {401, 403}:
                raise ProtectError("The UniFi API key was rejected", needs_auth=True) from error
            if error.code == 404:
                raise ProtectError("UniFi Protect did not recognize this request") from error
            if error.code == 503:
                raise ProtectError("The selected camera is offline") from error
            raise ProtectError(f"UniFi Protect returned HTTP {error.code}") from error
        except urllib.error.URLError as error:
            if isinstance(error.reason, ssl.SSLCertVerificationError):
                raise ProtectError(
                    "The console TLS certificate could not be verified. Trust its certificate or disable verification in Setup."
                ) from error
            raise ProtectError("Could not reach the UniFi Protect console") from error
        except TimeoutError as error:
            raise ProtectError("The UniFi Protect console timed out") from error

    def json(self, path: str) -> object:
        data, content_type = self.request(path, accept="application/json", limit=MAX_JSON_BYTES)
        if content_type != "application/json":
            raise ProtectError("The UniFi console returned an unexpected response")
        try:
            return json.loads(data)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ProtectError("The UniFi console returned malformed JSON") from error

    def cameras(self) -> list[Camera]:
        payload = self.json("/v1/cameras")
        if not isinstance(payload, list):
            raise ProtectError("The UniFi console returned an invalid camera list")
        cameras: list[Camera] = []
        for value in payload:
            if not isinstance(value, dict):
                raise ProtectError("The UniFi console returned an invalid camera")
            camera_id = validate_camera_id(str(value.get("id", "")))
            name = safe_display_text(value.get("name"), "Unnamed camera")
            state = str(value.get("state", "UNKNOWN")).upper()
            if state not in {"CONNECTED", "CONNECTING", "DISCONNECTED"}:
                state = "UNKNOWN"
            cameras.append(Camera(camera_id, name, state))
        cameras.sort(key=lambda camera: (camera.name.casefold(), camera.id))
        return cameras

    def snapshot(self, camera_id: str) -> bytes:
        camera_id = validate_camera_id(camera_id)
        data, content_type = self.request(
            f"/v1/cameras/{urllib.parse.quote(camera_id, safe='')}/snapshot",
            accept="image/jpeg",
            limit=MAX_SNAPSHOT_BYTES,
        )
        if content_type != "image/jpeg" or not data.startswith(b"\xff\xd8") or not data.endswith(b"\xff\xd9"):
            raise ProtectError("The camera returned an invalid JPEG snapshot")
        return data

    def stream_url(self, camera_id: str, preferred_quality: str = "auto") -> str:
        camera_id = validate_camera_id(camera_id)
        if preferred_quality not in {"auto", "high", "medium", "low"}:
            raise ProtectError("Choose a valid live stream quality")
        payload = self.json(
            f"/v1/cameras/{urllib.parse.quote(camera_id, safe='')}/rtsps-stream"
        )
        if not isinstance(payload, dict):
            raise ProtectError("Protect returned an invalid stream response")
        qualities = ["high", "medium", "low", "package"]
        if preferred_quality != "auto":
            qualities.remove(preferred_quality)
            qualities.insert(0, preferred_quality)
        for quality in qualities:
            value = payload.get(quality)
            if not isinstance(value, str) or not value:
                continue
            parsed = urllib.parse.urlsplit(value)
            if (parsed.scheme.lower() != "rtsps" or not parsed.hostname
                    or parsed.username or parsed.password
                    or any(character in value for character in "\r\n'")):
                raise ProtectError("Protect returned an unsafe stream URL")
            return value
        raise ProtectError("No RTSPS stream is enabled for this camera")


def runtime_frame_path(camera_id: str) -> pathlib.Path:
    camera_id = validate_camera_id(camera_id)
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    if not runtime or not os.path.isabs(runtime):
        raise ProtectError("XDG_RUNTIME_DIR is unavailable")
    root = pathlib.Path(runtime) / "omarchy-protect"
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    root.chmod(0o700)
    return root / f"{camera_id}.jpg"


def write_snapshot(path: pathlib.Path, data: bytes) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix="frame-", suffix=".jpg", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        path.chmod(0o600)
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            pass
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def persist_values(values: dict[str, str]) -> None:
    try:
        for key, value in values.items():
            subprocess.run(
                ["omarchy", "bar", "set", APP_ID, key, value],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
                timeout=10,
            )
    except FileNotFoundError as error:
        raise ProtectError("The Omarchy settings command is unavailable") from error
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise ProtectError("Could not save UniFi Protect Viewer settings") from error


def persist_settings(console_url: str, verify_tls: bool, *, setup_complete: bool = True) -> None:
    values = {
        "instanceUrl": canonical_console_url(console_url),
        "verifyTls": "true" if verify_tls else "false",
        "setupComplete": "true" if setup_complete else "false",
    }
    persist_values(values)


def launch_mpv(
    stream_url: str,
    *,
    hardware_decoding: bool = True,
    muted: bool = False,
    input_config: pathlib.Path | None = None,
) -> None:
    read_fd, write_fd = os.pipe()
    try:
        subprocess.Popen(
            [
                "mpv",
                "--no-config",
                "--playlist=-",
                "--force-window=immediate",
                "--profile=low-latency",
                "--rtsp-transport=tcp",
                f"--hwdec={'auto-safe' if hardware_decoding else 'no'}",
                "--osc=yes",
                "--keep-open=no",
                "--loop-file=inf",
                f"--mute={'yes' if muted else 'no'}",
                "--ontop=no",
                "--wayland-app-id=io.github.luxore.unifi-protect-live",
                "--title=UniFi Protect Live",
                *([f"--input-conf={input_config}"] if input_config else []),
            ],
            stdin=read_fd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
        )
        os.close(read_fd)
        read_fd = -1
        os.write(write_fd, (stream_url + "\n").encode("utf-8"))
    except FileNotFoundError as error:
        raise ProtectError("mpv is unavailable") from error
    finally:
        if read_fd >= 0:
            os.close(read_fd)
        os.close(write_fd)


def _stream_manifest(stream_url: str, verify_tls: bool) -> bytes:
    return (
        f"ffconcat version 1.0\nfile '{stream_url}'\n"
        "option rtsp_transport tcp\n"
        f"option tls_verify {1 if verify_tls else 0}\n"
    ).encode("utf-8")


def serve_stream(
    stream_url: str, ready: Callable[[str], None], *, verify_tls: bool = True
) -> None:
    """Relay one trusted RTSPS feed to a private loopback MPEG-TS endpoint."""
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 0))
    server.listen(2)
    server.settimeout(1.0)
    token = secrets.token_urlsafe(24)
    path = f"/{token}"
    child: subprocess.Popen[bytes] | None = None
    stopping = False

    def stop(_signum: int, _frame: object) -> None:
        nonlocal stopping
        stopping = True
        if child is not None and child.poll() is None:
            child.terminate()

    def reap_child() -> None:
        nonlocal child
        if child is None:
            return
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        child = None

    previous_term = signal.signal(signal.SIGTERM, stop)
    previous_int = signal.signal(signal.SIGINT, stop)
    try:
        port = server.getsockname()[1]
        ready(f"http://127.0.0.1:{port}{path}")
        while not stopping:
            try:
                connection, _address = server.accept()
            except socket.timeout:
                continue
            with connection:
                connection.settimeout(3.0)
                request = b""
                while b"\r\n\r\n" not in request and len(request) <= 8192:
                    chunk = connection.recv(2048)
                    if not chunk:
                        break
                    request += chunk
                first_line = request.split(b"\r\n", 1)[0]
                expected_get = f"GET {path} HTTP/1.1".encode("ascii")
                expected_head = f"HEAD {path} HTTP/1.1".encode("ascii")
                if first_line not in {expected_get, expected_head}:
                    connection.sendall(b"HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n")
                    continue
                connection.sendall(
                    b"HTTP/1.1 200 OK\r\n"
                    b"Content-Type: video/mp2t\r\n"
                    b"Cache-Control: no-store\r\n"
                    b"Connection: close\r\n\r\n"
                )
                if first_line == expected_head:
                    continue
                read_fd, write_fd = os.pipe()
                try:
                    child = subprocess.Popen(
                        [
                            "ffmpeg",
                            "-hide_banner",
                            "-loglevel", "error",
                            "-fflags", "nobuffer",
                            "-f", "concat",
                            "-safe", "0",
                            "-protocol_whitelist", "file,pipe,tcp,tls,rtp,udp,crypto,data",
                            "-i", "pipe:0",
                            "-map", "0:v:0",
                            "-map", "0:a:0?",
                            "-c", "copy",
                            "-muxdelay", "0",
                            "-muxpreload", "0",
                            "-f", "mpegts",
                            "pipe:1",
                        ],
                        stdin=read_fd,
                        stdout=connection.fileno(),
                        stderr=subprocess.DEVNULL,
                        close_fds=True,
                    )
                    os.close(read_fd)
                    read_fd = -1
                    os.write(write_fd, _stream_manifest(stream_url, verify_tls))
                    os.close(write_fd)
                    write_fd = -1
                    child.wait()
                finally:
                    if read_fd >= 0:
                        os.close(read_fd)
                    if write_fd >= 0:
                        os.close(write_fd)
                    reap_child()
    except FileNotFoundError as error:
        raise ProtectError("FFmpeg is unavailable") from error
    finally:
        stopping = True
        reap_child()
        server.close()
        signal.signal(signal.SIGTERM, previous_term)
        signal.signal(signal.SIGINT, previous_int)


def watch_snapshots(
    client: ProtectClient, camera_id: str, interval: float, *, once: bool = False
) -> None:
    path = runtime_frame_path(camera_id)
    delay = max(0.75, min(10.0, interval))
    while True:
        started = time.monotonic()
        try:
            write_snapshot(path, client.snapshot(camera_id))
            print(
                json.dumps(
                    {"path": path.as_uri(), "fetchedAt": int(time.time() * 1000)},
                    separators=(",", ":"),
                ),
                flush=True,
            )
        except ProtectError as error:
            print(json.dumps({"error": str(error)}, separators=(",", ":")), flush=True)
        if once:
            return
        time.sleep(max(0.05, delay - (time.monotonic() - started)))
