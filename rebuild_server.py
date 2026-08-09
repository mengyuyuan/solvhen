#!/usr/bin/env python3
"""Authenticated LAN-only rebuild helper for Solvhen developer mode.

The server is intentionally not a production update channel. It accepts one
rebuild at a time, only from loopback/private clients (and optionally an exact
IP allowlist), and requires both a 256-bit bearer token and a one-time nonce.

Example:
  set SOLVHEN_REBUILD_TOKEN=<token copied from Solvhen>
  python rebuild_server.py --bind 0.0.0.0 --allow-client 192.168.1.23
"""

from __future__ import annotations

import argparse
import hmac
import http.server
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import threading
import time
from typing import Any


DEFAULT_PROJECT = os.environ.get("SOLVHEN_PROJECT", str(Path.cwd()))
DEFAULT_DEVICE = os.environ.get("SOLVHEN_DEVICE", "")
FLUTTER_CMD = os.environ.get("SOLVHEN_FLUTTER", "flutter")
ADB_CMD = os.environ.get("SOLVHEN_ADB", "adb")

PROJECT_DIR = Path(DEFAULT_PROJECT).resolve()
DEVICE_ID = DEFAULT_DEVICE
SERVER_TOKEN = ""
ALLOWED_CLIENTS: set[ipaddress.IPv4Address | ipaddress.IPv6Address] = set()

_NONCE_PATTERN = re.compile(r"^[A-Za-z0-9_-]{22,128}$")
_NONCE_TTL_SECONDS = 10 * 60
_seen_nonces: dict[str, float] = {}
_nonce_lock = threading.Lock()
_build_lock = threading.Lock()


def _private_client(raw: str) -> bool:
    try:
        address = ipaddress.ip_address(raw)
    except ValueError:
        return False
    if not (address.is_private or address.is_loopback or address.is_link_local):
        return False
    return not ALLOWED_CLIENTS or address in ALLOWED_CLIENTS


def _consume_nonce(nonce: str) -> bool:
    if not _NONCE_PATTERN.fullmatch(nonce):
        return False
    now = time.monotonic()
    with _nonce_lock:
        expired = [
            value
            for value, timestamp in _seen_nonces.items()
            if now - timestamp > _NONCE_TTL_SECONDS
        ]
        for value in expired:
            _seen_nonces.pop(value, None)
        if nonce in _seen_nonces:
            return False
        _seen_nonces[nonce] = now
    return True


def _run(command: list[str], *, timeout: int) -> subprocess.CompletedProcess[str]:
    # flutter.bat/adb.exe may require the Windows command processor. Arguments
    # are still a fixed list; no request-controlled command text is accepted.
    return subprocess.run(
        command,
        cwd=PROJECT_DIR,
        capture_output=True,
        text=True,
        timeout=timeout,
        shell=os.name == "nt",
        check=False,
    )


class RebuildHandler(http.server.BaseHTTPRequestHandler):
    server_version = "SolvhenRebuild/2"

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"[{self.log_date_time_string()}] {self.client_address[0]} {fmt % args}")

    def _authorized(self, *, require_nonce: bool) -> bool:
        if not _private_client(self.client_address[0]):
            return False
        authorization = self.headers.get("Authorization", "")
        prefix = "Bearer "
        supplied = authorization[len(prefix) :] if authorization.startswith(prefix) else ""
        if not supplied or not hmac.compare_digest(supplied, SERVER_TOKEN):
            return False
        if require_nonce:
            return _consume_nonce(self.headers.get("X-Solvhen-Nonce", ""))
        return True

    def _respond(self, code: int, data: dict[str, Any]) -> None:
        payload = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path != "/status":
            self._respond(404, {"error": "not_found"})
            return
        if not self._authorized(require_nonce=False):
            self._respond(401, {"error": "unauthorized"})
            return
        self._respond(200, {"status": "ready", "busy": _build_lock.locked()})

    def do_OPTIONS(self) -> None:  # noqa: N802
        # Browser/CORS use is deliberately unsupported.
        self._respond(405, {"error": "method_not_allowed"})

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/rebuild":
            self._respond(404, {"error": "not_found"})
            return
        if not self._authorized(require_nonce=True):
            self._respond(401, {"error": "unauthorized"})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._respond(400, {"error": "invalid_length"})
            return
        if length < 2 or length > 4096:
            self._respond(413, {"error": "invalid_body_size"})
            return
        try:
            body = json.loads(self.rfile.read(length))
        except (json.JSONDecodeError, UnicodeDecodeError):
            self._respond(400, {"error": "invalid_json"})
            return
        if not isinstance(body, dict) or body.get("action") != "rebuild":
            self._respond(400, {"error": "invalid_action"})
            return
        if not _build_lock.acquire(blocking=False):
            self._respond(409, {"error": "rebuild_in_progress"})
            return
        try:
            result = self._rebuild()
            self._respond(200 if result.get("rebuilt") else 500, result)
        except subprocess.TimeoutExpired:
            self._respond(504, {"rebuilt": False, "error": "build_timeout"})
        except Exception as error:  # keep internal details out of the response
            print(f"rebuild error: {error!r}")
            self._respond(500, {"rebuilt": False, "error": "internal_error"})
        finally:
            _build_lock.release()

    def _rebuild(self) -> dict[str, Any]:
        print("[1/2] Building signed-in developer APK...")
        build = _run([FLUTTER_CMD, "build", "apk", "--debug"], timeout=300)
        if build.returncode != 0:
            print(build.stderr[-1000:])
            return {"rebuilt": False, "error": "build_failed"}

        apk_path = (
            PROJECT_DIR / "build" / "app" / "outputs" / "flutter-apk" / "app-debug.apk"
        ).resolve()
        if PROJECT_DIR not in apk_path.parents or not apk_path.is_file():
            return {"rebuilt": False, "error": "apk_not_found"}

        print("[2/2] Installing APK to the configured ADB device...")
        command = [ADB_CMD]
        if DEVICE_ID:
            command.extend(["-s", DEVICE_ID])
        command.extend(["install", "-r", str(apk_path)])
        install = _run(command, timeout=90)
        if install.returncode != 0:
            print(install.stderr[-1000:])
            return {"rebuilt": False, "error": "install_failed"}
        return {"rebuilt": True, "message": "APK 已通过配对开发机编译并安装"}


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Authenticated Solvhen rebuild server")
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9120)
    parser.add_argument("--project", default=DEFAULT_PROJECT)
    parser.add_argument("--device", default=DEFAULT_DEVICE)
    parser.add_argument(
        "--token",
        default=os.environ.get("SOLVHEN_REBUILD_TOKEN", ""),
        help="Prefer SOLVHEN_REBUILD_TOKEN; minimum 32 characters",
    )
    parser.add_argument(
        "--allow-client",
        action="append",
        default=[],
        help="Exact loopback/private client IP; repeat for multiple devices",
    )
    return parser.parse_args()


def main() -> None:
    global PROJECT_DIR, DEVICE_ID, SERVER_TOKEN, ALLOWED_CLIENTS
    args = _parse_args()
    if not 1024 <= args.port <= 65535:
        raise SystemExit("port must be between 1024 and 65535")
    if len(args.token) < 32:
        raise SystemExit("SOLVHEN_REBUILD_TOKEN (or --token) must be at least 32 characters")

    project = Path(args.project).expanduser().resolve()
    if not project.is_dir() or not (project / "pubspec.yaml").is_file():
        raise SystemExit("--project must be a Flutter project containing pubspec.yaml")
    try:
        allowlist = {ipaddress.ip_address(value) for value in args.allow_client}
    except ValueError as error:
        raise SystemExit(f"invalid --allow-client: {error}") from error
    if any(not (ip.is_private or ip.is_loopback or ip.is_link_local) for ip in allowlist):
        raise SystemExit("--allow-client accepts only loopback/private/link-local IPs")

    PROJECT_DIR = project
    DEVICE_ID = args.device
    SERVER_TOKEN = args.token
    ALLOWED_CLIENTS = allowlist

    print("Solvhen authenticated rebuild server")
    print(f"Project: {PROJECT_DIR}")
    print(f"Bind:    {args.bind}:{args.port}")
    print(f"Clients: {', '.join(map(str, ALLOWED_CLIENTS)) or 'private/loopback only'}")
    print("Auth:    bearer token + one-time nonce")

    server = http.server.ThreadingHTTPServer((args.bind, args.port), RebuildHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("Shutting down...")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
