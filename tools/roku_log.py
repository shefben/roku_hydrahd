#!/usr/bin/env python3
"""Tail the Roku BrightScript debug console (port 8085) to a file.

Roku's dev console is a plain TCP stream — not true telnet — so we
just connect to <roku-ip>:8085, mirror every line to stdout, and
append it to a rotating log on disk. If the channel reloads or the
TV reboots the socket drops, so we reconnect with backoff.

Default target is 192.168.3.2 (the TV in the user's setup).

Usage:
  python roku_log.py                     # defaults
  python roku_log.py --host 192.168.3.5  # different TV
  python roku_log.py --log roku.log      # custom log file
  python roku_log.py --no-stdout         # only write to file
"""

from __future__ import annotations

import argparse
import datetime as dt
import errno
import os
import signal
import socket
import sys
import time

DEFAULT_HOST = "192.168.3.2"
DEFAULT_PORT = 8085
DEFAULT_LOG = "roku_debug.log"
RECONNECT_MIN = 1.0
RECONNECT_MAX = 15.0
BUFSIZE = 4096


def now() -> str:
    return dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]


def open_log(path: str) -> object:
    parent = os.path.dirname(os.path.abspath(path))
    if parent:
        os.makedirs(parent, exist_ok=True)
    return open(path, "a", buffering=1, encoding="utf-8", errors="replace")


def write(stream, log_fp, line: str, to_stdout: bool) -> None:
    stamped = f"[{now()}] {line}"
    if to_stdout:
        try:
            stream.write(stamped + "\n")
            stream.flush()
        except Exception:
            pass
    log_fp.write(stamped + "\n")


def banner(text: str) -> str:
    return f"================= {text} ================="


def stream_once(host: str, port: int, log_fp, to_stdout: bool) -> bool:
    """Connect once. Return True if we want the caller to retry."""
    write(sys.stdout, log_fp, banner(f"connecting to {host}:{port}"), to_stdout)
    try:
        sock = socket.create_connection((host, port), timeout=10)
    except OSError as exc:
        write(sys.stdout, log_fp, banner(f"connect failed: {exc}"), to_stdout)
        return True

    sock.settimeout(None)
    write(sys.stdout, log_fp, banner("connected — streaming"), to_stdout)

    buf = b""
    try:
        while True:
            try:
                chunk = sock.recv(BUFSIZE)
            except socket.timeout:
                continue
            except OSError as exc:
                if exc.errno in (errno.ECONNRESET, errno.EPIPE):
                    write(sys.stdout, log_fp, banner(f"socket reset: {exc}"), to_stdout)
                    return True
                raise
            if not chunk:
                write(sys.stdout, log_fp, banner("remote closed connection"), to_stdout)
                return True
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                text = line.decode("utf-8", errors="replace").rstrip("\r")
                write(sys.stdout, log_fp, text, to_stdout)
    finally:
        try:
            sock.close()
        except Exception:
            pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                      formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default=DEFAULT_HOST,
                        help=f"Roku IP (default {DEFAULT_HOST})")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT,
                        help=f"BrightScript debug port (default {DEFAULT_PORT})")
    parser.add_argument("--log", default=DEFAULT_LOG,
                        help=f"Output log file (default {DEFAULT_LOG})")
    parser.add_argument("--no-stdout", action="store_true",
                        help="Don't echo to stdout, only write to log file")
    args = parser.parse_args()

    log_fp = open_log(args.log)
    write(sys.stdout, log_fp,
          banner(f"roku_log started, writing to {os.path.abspath(args.log)}"),
          not args.no_stdout)

    def handle_sigint(signum, frame):
        write(sys.stdout, log_fp, banner("stopped by user"),
              not args.no_stdout)
        log_fp.close()
        sys.exit(0)

    signal.signal(signal.SIGINT, handle_sigint)
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, handle_sigint)

    backoff = RECONNECT_MIN
    while True:
        retry = stream_once(args.host, args.port, log_fp, not args.no_stdout)
        if not retry:
            break
        write(sys.stdout, log_fp,
              banner(f"reconnecting in {backoff:.1f}s"), not args.no_stdout)
        time.sleep(backoff)
        backoff = min(backoff * 2, RECONNECT_MAX)
    return 0


if __name__ == "__main__":
    sys.exit(main())
