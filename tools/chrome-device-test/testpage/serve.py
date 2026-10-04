#!/usr/bin/env python3
"""Serve the device-test page on this Mac only (loopback), port 8765.

Listens on 127.0.0.1 and ::1 so both http://127.0.0.1:8765/ and
http://localhost:8765/ work (the page uses one as a cross-site iframe for the
other). Nothing is reachable from the network. Ctrl+C to stop.
"""
import functools
import http.server
import socket
import sys
import threading
from pathlib import Path

PORT = 8765
ROOT = Path(__file__).resolve().parent


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


class V6(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6


def main():
    handler = functools.partial(Quiet, directory=str(ROOT))
    servers = [http.server.ThreadingHTTPServer(("127.0.0.1", PORT), handler)]
    try:
        servers.append(V6(("::1", PORT), handler))
    except OSError:
        print("note: IPv6 loopback unavailable; http://localhost may still work via 127.0.0.1")
    for s in servers[1:]:
        threading.Thread(target=s.serve_forever, daemon=True).start()
    print(f"Serving {ROOT} at http://127.0.0.1:{PORT}/ (loopback only). Ctrl+C to stop.")
    try:
        servers[0].serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        for s in servers:
            s.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
