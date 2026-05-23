#!/usr/bin/env python3
"""
kc_locationspoof Mac host daemon.

Run with sudo (RSD tunnel needs root):
    sudo python3 host/start.py

HTTP API on 127.0.0.1:8765:
    GET  /api/loc?lat=24.15&lon=120.64    set spoofed location
    GET  /api/status                      daemon + tunnel state
    POST /api/clear                       stop spoof, resume real GPS

Pure stdlib. Toolchain binaries live in host/bin/ (PyInstaller-packed
pymobiledevice3 + dvt-location-stream). Override paths via env vars
PYMOBILEDEVICE3_BIN / DVT_STREAM_BIN if needed.
"""

import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
PMD_BIN = os.environ.get("PYMOBILEDEVICE3_BIN", os.path.join(HERE, "bin", "pymobiledevice3"))
DVT_BIN = os.environ.get("DVT_STREAM_BIN", os.path.join(HERE, "bin", "dvt-location-stream"))
PORT = int(os.environ.get("PORT", "8765"))
BIND_HOST = os.environ.get("BIND_HOST", "127.0.0.1")
RECOVERABLE_DVT_ERROR_MARKERS = (
    "Broken pipe",
    "Connection reset",
    "Connection aborted",
)


class State:
    tunnel_proc: "subprocess.Popen[str] | None" = None
    dvt_proc: "subprocess.Popen[str] | None" = None
    rsd_host: "str | None" = None
    rsd_port: "str | None" = None
    last_seq = 0
    last_loc: "tuple[float, float] | None" = None
    lock = threading.Lock()


state = State()


def start_tunnel() -> None:
    proc = subprocess.Popen(
        [PMD_BIN, "remote", "start-tunnel", "--script-mode"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    line = proc.stdout.readline().strip()
    parts = line.split()
    if len(parts) != 2:
        err = proc.stderr.read() if proc.stderr else ""
        raise RuntimeError(f"tunnel did not return HOST PORT (got {line!r}); stderr: {err}")
    state.tunnel_proc = proc
    state.rsd_host, state.rsd_port = parts
    print(f"[tunnel] up at {state.rsd_host}:{state.rsd_port}", flush=True)


def start_dvt_stream() -> None:
    proc = subprocess.Popen(
        [DVT_BIN, state.rsd_host, state.rsd_port],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    line = proc.stdout.readline().strip()
    if line != "READY":
        err = proc.stderr.read() if proc.stderr else ""
        raise RuntimeError(f"dvt stream did not signal READY (got {line!r}); stderr: {err}")
    state.dvt_proc = proc
    print("[dvt] stream ready", flush=True)


def stop_dvt_stream(send_quit: bool = False) -> None:
    proc = state.dvt_proc
    state.dvt_proc = None
    if not proc:
        return

    if send_quit and proc.poll() is None and proc.stdin:
        try:
            proc.stdin.write("QUIT\n")
            proc.stdin.flush()
            proc.wait(timeout=3)
        except Exception:
            pass

    for stream in (proc.stdin, proc.stdout):
        try:
            if stream:
                stream.close()
        except Exception:
            pass

    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()


def restart_dvt_stream(reason: str) -> None:
    print(f"[dvt] restarting stream after {reason}", flush=True)
    stop_dvt_stream(send_quit=False)
    start_dvt_stream()


def is_recoverable_dvt_response(resp: str) -> bool:
    if not resp:
        return True
    return resp.startswith("ERR") and any(
        marker in resp for marker in RECOVERABLE_DVT_ERROR_MARKERS
    )


def exchange_dvt_command(cmd: str, *, retry: bool = True) -> str:
    proc = state.dvt_proc
    if proc is None or proc.poll() is not None:
        restart_dvt_stream("process not running")
        proc = state.dvt_proc

    try:
        proc.stdin.write(cmd)
        proc.stdin.flush()
    except (BrokenPipeError, OSError) as error:
        if not retry:
            raise
        restart_dvt_stream(f"write failed: {error}")
        return exchange_dvt_command(cmd, retry=False)

    resp = proc.stdout.readline().strip()
    if retry and is_recoverable_dvt_response(resp):
        restart_dvt_stream(f"recoverable response: {resp or '<eof>'}")
        return exchange_dvt_command(cmd, retry=False)
    return resp


def inject(lat: float, lon: float) -> int:
    with state.lock:
        state.last_seq += 1
        seq = state.last_seq
        resp = exchange_dvt_command(f"{seq},{lat},{lon}\n")
        if not resp.startswith(f"OK {seq}"):
            raise RuntimeError(f"dvt stream rejected: {resp}")
        state.last_loc = (lat, lon)
        return seq


def clear() -> None:
    with state.lock:
        resp = exchange_dvt_command("CLEAR\n")
        if resp != "CLEARED":
            raise RuntimeError(f"clear failed: {resp}")
        state.last_loc = None


class Handler(BaseHTTPRequestHandler):
    def _json(self, code: int, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        url = urlparse(self.path)
        if url.path == "/" or url.path == "/index.html":
            try:
                with open(os.path.join(HERE, "web", "index.html"), "rb") as f:
                    data = f.read()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except FileNotFoundError:
                self._json(404, {"error": "web/index.html missing"})
            return
        if url.path == "/api/loc":
            qs = parse_qs(url.query)
            try:
                lat = float(qs["lat"][0])
                lon = float(qs["lon"][0])
            except (KeyError, ValueError, IndexError):
                self._json(400, {"error": "missing or invalid lat/lon"})
                return
            try:
                seq = inject(lat, lon)
                self._json(200, {"ok": True, "seq": seq, "lat": lat, "lon": lon})
            except Exception as e:
                self._json(500, {"error": str(e)})
        elif url.path == "/api/status":
            self._json(
                200,
                {
                    "tunnel": f"{state.rsd_host}:{state.rsd_port}" if state.rsd_host else None,
                    "dvt_alive": state.dvt_proc is not None and state.dvt_proc.poll() is None,
                    "last_seq": state.last_seq,
                    "last_loc": state.last_loc,
                },
            )
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self) -> None:
        url = urlparse(self.path)
        if url.path == "/api/clear":
            try:
                clear()
                self._json(200, {"ok": True})
            except Exception as e:
                self._json(500, {"error": str(e)})
        else:
            self._json(404, {"error": "not found"})

    def log_message(self, fmt: str, *args) -> None:
        print(f"[http] {fmt % args}", flush=True)


def cleanup() -> None:
    print("[shutdown] cleaning up", flush=True)
    stop_dvt_stream(send_quit=True)
    if state.tunnel_proc and state.tunnel_proc.poll() is None:
        state.tunnel_proc.terminate()
        try:
            state.tunnel_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            state.tunnel_proc.kill()


def main() -> int:
    if os.geteuid() != 0:
        print("ERROR: must run as root (sudo) — RSD tunnel needs raw socket", file=sys.stderr)
        return 1
    for path, label in [(PMD_BIN, "PYMOBILEDEVICE3_BIN"), (DVT_BIN, "DVT_STREAM_BIN")]:
        if not os.path.isfile(path):
            print(f"ERROR: {label} not found at {path}", file=sys.stderr)
            return 1

    try:
        start_tunnel()
        start_dvt_stream()
    except Exception as e:
        print(f"[startup] failed: {e}", file=sys.stderr)
        cleanup()
        return 2

    server = ThreadingHTTPServer((BIND_HOST, PORT), Handler)
    print(f"[http] listening on http://{BIND_HOST}:{PORT}", flush=True)
    print("  GET  /api/loc?lat=...&lon=...", flush=True)
    print("  GET  /api/status", flush=True)
    print("  POST /api/clear", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[shutdown] SIGINT", flush=True)
    finally:
        server.shutdown()
        cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
