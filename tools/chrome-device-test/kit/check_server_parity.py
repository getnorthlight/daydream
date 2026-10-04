#!/usr/bin/env python3
"""Developer-only parity check for the kit's test-page server. Run it on a
developer Mac (it needs Python); it is never shipped in the kit.

It starts testpage/serve.py's own handler and the Swift server
(chrome-device-test-serve) on two spare loopback ports, sends both the same
raw requests over 127.0.0.1 and ::1, and requires the same status line,
header names, Content-Type, Cache-Control, Content-Length, Last-Modified and
body bytes. It then checks what only the Swift server promises: it listens on
loopback only, refuses a taken port or a missing page, never serves symlinks,
dotfiles or subfolders, an idle connection blocks nobody, a dropped client
does not kill it, and Ctrl+C / SIGTERM stop it cleanly.

Loopback only. It never starts or talks to Chrome.

Run:
  python3 tools/chrome-device-test/kit/check_server_parity.py \\
      --serve PATH/TO/chrome-device-test-serve --work SCRATCH_DIR
"""
import argparse
import functools
import http.server
import importlib.util
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
HARNESS = HERE.parent
PAGE = HARNESS / "testpage"

# Python 3.14's http.server error page; the Swift server sends exactly this.
TEMPLATE_314 = (
    '<!DOCTYPE HTML>\n<html lang="en">\n    <head>\n        <meta charset="utf-8">\n'
    '        <style type="text/css">\n            :root {\n                color-scheme: light dark;\n'
    '            }\n        </style>\n        <title>Error response</title>\n    </head>\n    <body>\n'
    '        <h1>Error response</h1>\n        <p>Error code: %(code)d</p>\n        <p>Message: %(message)s.</p>\n'
    '        <p>Error code explanation: %(code)s - %(explain)s.</p>\n    </body>\n</html>\n'
)
STRICT_ERRORS = http.server.DEFAULT_ERROR_MESSAGE == TEMPLATE_314

passed = 0
failed = 0


def check(ok, label, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print("ok    " + label)
    else:
        failed += 1
        print("FAIL  " + label + (("\n      " + detail) if detail else ""))


def free_port():
    """A port that is free on both 127.0.0.1 and ::1."""
    for _ in range(50):
        s6 = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        s6.bind(("::1", 0))
        port = s6.getsockname()[1]
        s4 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            s4.bind(("127.0.0.1", port))
            return port
        except OSError:
            continue
        finally:
            s4.close()
            s6.close()
    raise SystemExit("no free loopback port")


def raw(host, port, request, timeout=5.0):
    fam = socket.AF_INET6 if ":" in host else socket.AF_INET
    c = socket.socket(fam, socket.SOCK_STREAM)
    c.settimeout(timeout)
    c.connect((host, port))
    c.sendall(request)
    data = b""
    try:
        while True:
            b = c.recv(65536)
            if not b:
                break
            data += b
    finally:
        c.close()
    return data


def parse(data):
    """(status line or None, {lower name: value}, [names in order], body)."""
    if not data.startswith(b"HTTP/"):
        return None, {}, [], data
    head, _, body = data.partition(b"\r\n\r\n")
    lines = head.decode("latin-1").split("\r\n")
    headers, names = {}, []
    for line in lines[1:]:
        name, _, value = line.partition(":")
        headers[name.strip().lower()] = value.strip()
        names.append(name.strip().lower())
    return lines[0], headers, names, body


def error_lines(body):
    # Before Python 3.11 the explanation line reads "HTTPStatus.NOT_FOUND - ..."
    # where 3.11+ (and the Swift server) print "404 - ...". Same error either way.
    def number(m):
        return str(int(http.HTTPStatus[m.group(1).decode()])).encode()
    return [re.sub(rb"HTTPStatus\.([A-Z_]+)", number, line) for line in re.findall(rb"<p>.*?</p>", body)]


def status_code(status):
    try:
        return int(status.split()[1])
    except (AttributeError, IndexError, ValueError):
        return 0


def wait_for_banner(proc, log, seconds=10):
    end = time.time() + seconds
    while time.time() < end:
        if proc.poll() is not None:
            return False
        if log.exists() and "Serving " in log.read_text(errors="replace"):
            return True
        time.sleep(0.05)
    return False


def start_swift(serve, work, name, args):
    log = work / (name + ".log")
    env = dict(os.environ, TMPDIR=str(work / "tmp"), PATH="/usr/bin:/bin:/usr/sbin:/sbin")
    fh = open(log, "w")
    proc = subprocess.Popen([str(serve)] + args, stdout=fh, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env)
    return proc, log, fh


def stop(proc, sig=signal.SIGTERM):
    if proc.poll() is None:
        proc.send_signal(sig)
        try:
            return proc.wait(5)
        except subprocess.TimeoutExpired:
            proc.kill()
            return proc.wait(5)
    return proc.returncode


def requests_for(files):
    reqs = []
    for f in files:
        reqs.append(("GET /%s" % f, b"GET /%s HTTP/1.1\r\nHost: x\r\n\r\n" % f.encode()))
    for target in ["/", "/frame.html?x=1#y", "//frame.html", "/./index.html", "/%66rame.html", "/nope", "/favicon.ico",
                   "/index.html/", "/../README.md", "/../../README.md", "/%2e%2e/README.md", "/..%2fREADME.md",
                   "/%2e%2e%2f%2e%2e%2fPackage.swift", "/testpage/index.html", "/.DS_Store"]:
        reqs.append(("GET " + target, b"GET " + target.encode() + b" HTTP/1.1\r\nHost: x\r\n\r\n"))
    for target in ["/", "/frame.html", "/nope"]:
        reqs.append(("HEAD " + target, b"HEAD " + target.encode() + b" HTTP/1.1\r\nHost: x\r\n\r\n"))
    reqs += [
        ("POST /", b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n"),
        ("OPTIONS /", b"OPTIONS / HTTP/1.1\r\nHost: x\r\n\r\n"),
        ("PUT /x", b"PUT /x HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n"),
        ("GET / HTTP/1.0, no Host", b"GET / HTTP/1.0\r\n\r\n"),
        ("GET / If-Modified-Since future", b"GET / HTTP/1.1\r\nIf-Modified-Since: Fri, 01 Jan 2100 00:00:00 GMT\r\n\r\n"),
        ("GET / If-Modified-Since past", b"GET / HTTP/1.1\r\nIf-Modified-Since: Mon, 01 Jan 2001 00:00:00 GMT\r\n\r\n"),
        ("GET / If-None-Match + future IMS", b"GET / HTTP/1.1\r\nIf-None-Match: \"x\"\r\nIf-Modified-Since: Fri, 01 Jan 2100 00:00:00 GMT\r\n\r\n"),
        ("GET / HTTP/2.0", b"GET / HTTP/2.0\r\n\r\n"),
        ("GET / x HTTP/1.1", b"GET / x HTTP/1.1\r\n\r\n"),
        ("GET / HTTP/1.1 extra", b"GET / HTTP/1.1 extra\r\n\r\n"),
        ("GET / FTP/1.0", b"GET / FTP/1.0\r\n\r\n"),
        ("HTTP/0.9 GET /", b"GET /\r\n\r\n"),
        ("HTTP/0.9 HEAD /", b"HEAD /\r\n\r\n"),
        ("bare-LF request", b"GET /frame.html HTTP/1.1\nHost: x\n\n"),
    ]
    return reqs


def compare(host, label, py, sw, files):
    p_status, p_h, p_names, p_body = parse(py)
    s_status, s_h, s_names, s_body = parse(sw)
    problems = []
    if p_status != s_status:
        problems.append("status %r vs %r" % (p_status, s_status))
    if set(p_names) - {"server", "date"} != set(s_names) - {"server", "date"}:
        problems.append("headers %s vs %s" % (sorted(set(p_names)), sorted(set(s_names))))
    for h in ("content-type", "cache-control", "last-modified", "connection"):
        if p_h.get(h) != s_h.get(h):
            problems.append("%s %r vs %r" % (h, p_h.get(h), s_h.get(h)))
    is_error_page = (b"<title>Error response</title>" in p_body or b"<title>Error response</title>" in s_body
                     or status_code(p_status) >= 400)
    if is_error_page and not STRICT_ERRORS:
        # Older Python: same error, different page template. Compare what it says.
        if error_lines(p_body) != error_lines(s_body):
            problems.append("error text %r vs %r" % (error_lines(p_body), error_lines(s_body)))
        if not label.startswith("HEAD"):
            for name, h, body in (("python", p_h, p_body), ("swift", s_h, s_body)):
                if "content-length" in h and h["content-length"] != str(len(body)):
                    problems.append("%s Content-Length %s but body %d bytes" % (name, h["content-length"], len(body)))
    else:
        if p_h.get("content-length") != s_h.get("content-length"):
            problems.append("content-length %r vs %r" % (p_h.get("content-length"), s_h.get("content-length")))
        if p_body != s_body:
            problems.append("body differs (%d vs %d bytes)" % (len(p_body), len(s_body)))
    if s_status and s_status.startswith("HTTP/1.0 200") and not label.startswith("HEAD"):
        name = label.split(" ", 1)[1].split("?")[0].lstrip("/") or "index.html"
        if name in files and s_body != (PAGE / name).read_bytes():
            problems.append("body is not byte-identical to testpage/%s" % name)
    if s_status is not None and s_h.get("cache-control") != "no-store":
        problems.append("no Cache-Control: no-store")
    shown = s_status or "(body only, %d bytes)" % len(s_body)
    check(not problems, "[%s] %-34s -> %s" % (host, label, shown), "; ".join(problems))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--serve", required=True, help="path to the built chrome-device-test-serve")
    ap.add_argument("--work", required=True, help="scratch folder for logs and temporary copies")
    a = ap.parse_args()
    serve = Path(a.serve).resolve()
    work = Path(a.work).resolve() / "parity"
    if work.exists():
        shutil.rmtree(work)
    (work / "tmp").mkdir(parents=True)
    print("python %s (%s error pages)" % (sys.version.split()[0], "byte-for-byte" if STRICT_ERRORS else "older template: compared by text"))

    spec = importlib.util.spec_from_file_location("serve", PAGE / "serve.py")
    serve_py = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(serve_py)
    handler = functools.partial(serve_py.Quiet, directory=str(PAGE))
    p_port, s_port = free_port(), free_port()
    while s_port == p_port:
        s_port = free_port()
    py4 = http.server.ThreadingHTTPServer(("127.0.0.1", p_port), handler)
    py6 = serve_py.V6(("::1", p_port), handler)
    for s in (py4, py6):
        threading.Thread(target=s.serve_forever, daemon=True).start()

    proc, log, fh = start_swift(serve, work, "swift", ["--root", str(PAGE), "--port", str(s_port)])
    try:
        check(wait_for_banner(proc, log), "swift server starts and prints its banner", log.read_text(errors="replace"))
        banner = log.read_text(errors="replace")
        check("Serving %s at http://127.0.0.1:%d/ (loopback only). Ctrl+C to stop." % (PAGE.resolve(), s_port) in banner,
              "banner matches serve.py's", banner)

        files = sorted(p.name for p in PAGE.iterdir() if p.is_file() and not p.name.startswith("."))
        for host in ("127.0.0.1", "::1"):
            print("--- %s: serve.py on %d, swift on %d" % (host, p_port, s_port))
            for label, req in requests_for(files):
                compare(host, label, raw(host, p_port, req), raw(host, s_port, req), files)

        # Loopback only: exactly the two loopback listeners, nothing else.
        out = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(proc.pid), "-iTCP", "-sTCP:LISTEN", "-Fn"],
                             capture_output=True, text=True).stdout
        listening = sorted(l[1:] for l in out.splitlines() if l.startswith("n"))
        check(listening == sorted(["127.0.0.1:%d" % s_port, "[::1]:%d" % s_port]), "listens on 127.0.0.1 and ::1 only", repr(listening))

        # The same port again, and serve.py's port: refused with exit 3 and a plain message.
        for port, who in ((s_port, "itself"), (p_port, "serve.py")):
            p2, log2, fh2 = start_swift(serve, work, "taken-%d" % port, ["--root", str(PAGE), "--port", str(port)])
            try:
                rc = p2.wait(10)
            except subprocess.TimeoutExpired:
                rc = stop(p2)
            fh2.close()
            text = log2.read_text(errors="replace")
            check(rc == 3 and "already in use" in text, "refuses a port taken by %s (exit %s)" % (who, rc), text)

        # An idle connection (Chrome's spare sockets) blocks nobody.
        idle = socket.create_connection(("127.0.0.1", s_port))
        t0 = time.time()
        r = raw("127.0.0.1", s_port, b"GET / HTTP/1.1\r\n\r\n", timeout=3)
        check(r.startswith(b"HTTP/1.0 200") and time.time() - t0 < 2, "an idle connection does not block other requests")
        idle.close()

        # A client that vanishes mid-reply (SIGPIPE) does not kill the server.
        for _ in range(20):
            c = socket.create_connection(("::1", s_port))
            c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, b"\x01\x00\x00\x00\x00\x00\x00\x00")
            c.sendall(b"GET /index.html HTTP/1.1\r\n\r\n")
            c.close()
        time.sleep(0.3)
        check(proc.poll() is None and raw("::1", s_port, b"GET /frame.html HTTP/1.1\r\n\r\n").startswith(b"HTTP/1.0 200"),
              "dropped clients do not kill it")
    finally:
        rc = stop(proc, signal.SIGINT)
        fh.close()
        py4.shutdown(); py4.server_close(); py6.shutdown(); py6.server_close()
    check(rc == 0, "Ctrl+C (SIGINT) stops it with exit 0 (got %s)" % rc)

    # No page folder: refused with exit 2.
    empty = work / "empty"
    empty.mkdir()
    p3, log3, fh3 = start_swift(serve, work, "empty", ["--root", str(empty), "--port", str(free_port())])
    rc3 = p3.wait(10); fh3.close()
    check(rc3 == 2 and "index.html and frame.html" in log3.read_text(), "refuses a folder without the test page (exit %s)" % rc3)

    # Kit layout: bin/chrome-device-test-serve finds ../testpage by itself.
    kit = work / "kit"
    (kit / "bin").mkdir(parents=True)
    shutil.copy2(serve, kit / "bin" / "chrome-device-test-serve")
    (kit / "testpage").mkdir()
    for f in ("index.html", "frame.html"):
        shutil.copy2(PAGE / f, kit / "testpage" / f)
    port = free_port()
    p4, log4, fh4 = start_swift(kit / "bin" / "chrome-device-test-serve", work, "kit", ["--port", str(port)])
    try:
        ok = wait_for_banner(p4, log4)
        body = raw("127.0.0.1", port, b"GET / HTTP/1.1\r\n\r\n") if ok else b""
        check(ok and parse(body)[3] == (PAGE / "index.html").read_bytes() and str((kit / "testpage").resolve()) in log4.read_text(),
              "default page folder: testpage next to bin/", log4.read_text())
    finally:
        rc4 = stop(p4, signal.SIGTERM); fh4.close()
    check(rc4 == 0, "SIGTERM stops it with exit 0 (got %s)" % rc4)

    # Stricter than serve.py: symlinks, dotfiles and subfolders are 404.
    strict = work / "strict"
    strict.mkdir()
    for f in ("index.html", "frame.html"):
        shutil.copy2(PAGE / f, strict / f)
    (work / "outside.html").write_text("outside")
    os.symlink(work / "outside.html", strict / "link.html")
    (strict / ".hidden.html").write_text("hidden")
    (strict / "sub").mkdir()
    (strict / "sub" / "index.html").write_text("sub")
    port = free_port()
    p5, log5, fh5 = start_swift(serve, work, "strict", ["--root", str(strict), "--port", str(port)])
    try:
        check(wait_for_banner(p5, log5), "strict-root server starts")
        for target, want in (("/link.html", "404"), ("/.hidden.html", "404"), ("/sub/index.html", "404"), ("/sub/", "404"),
                             ("/sub", "404"), ("/index.html", "200")):
            st = parse(raw("127.0.0.1", port, b"GET " + target.encode() + b" HTTP/1.1\r\n\r\n"))[0] or ""
            check(st.startswith("HTTP/1.0 " + want), "strict: GET %s -> %s" % (target, want), st)
    finally:
        stop(p5); fh5.close()

    print("\nparity: %d passed, %d failed" % (passed, failed))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
