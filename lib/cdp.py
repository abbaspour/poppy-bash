#!/usr/bin/env python3
##########################################################################################
# Author: Amin Abbaspour
# Date: 2026-11-26
# License: LGPL 2.1
#
# cdp.py: one Chrome DevTools Protocol call, for browser-join.sh. Opens a WebSocket to a page's
# webSocketDebuggerUrl on this machine, sends one command, prints its "result" as JSON on stdout
# and exits 0. A protocol error or a failure to connect prints a message on stderr and exits 1.
# Standard library only: bash can't speak WebSocket, and this keeps websocat out of the setup.
#
#   python3 -I cdp.py ws://127.0.0.1:9222/devtools/page/ID Page.navigate '{"url":"https://..."}'
#
# Run it with -I so the current directory isn't searched for modules. CDP_TIMEOUT (seconds,
# default 30) bounds the connection and the wait for the answer.
##########################################################################################

import base64
import hashlib
import json
import os
import socket
import struct
import sys
from urllib.parse import urlparse

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"  # RFC 6455 section 1.3
MAX_MESSAGE = 16 * 1024 * 1024


def fail(message):
    print(f"cdp.py: {message}", file=sys.stderr)
    sys.exit(1)


def read_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            fail("connection closed by the browser")
        buf += chunk
    return buf


def connect(url, timeout):
    u = urlparse(url)
    # the debugger is on this machine only: never take a URL that points anywhere else
    if u.scheme != "ws" or u.hostname not in ("127.0.0.1", "localhost", "::1"):
        fail(f"refusing {url}: the DevTools WebSocket must be ws:// on this machine")
    sock = socket.create_connection((u.hostname, u.port or 80), timeout=timeout)
    key = base64.b64encode(os.urandom(16)).decode()
    request = (
        f"GET {u.path or '/'}{'?' + u.query if u.query else ''} HTTP/1.1\r\n"
        f"Host: {u.hostname}:{u.port or 80}\r\n"
        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
    )
    sock.sendall(request.encode())
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = sock.recv(1024)
        if not chunk:
            fail("the browser closed the connection during the handshake")
        head += chunk
        if len(head) > 16384:
            fail("handshake response too large")
    status = head.split(b"\r\n", 1)[0].decode(errors="replace")
    if " 101 " not in status:
        fail(f"WebSocket handshake refused: {status}")
    expected = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    if f"sec-websocket-accept: {expected}".lower() not in head.decode(errors="replace").lower():
        fail("WebSocket handshake: bad Sec-WebSocket-Accept")
    return sock


def send_frame(sock, opcode, payload):
    header = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        header += bytes([0x80 | n])
    elif n < 65536:
        header += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        header += bytes([0x80 | 127]) + struct.pack(">Q", n)
    mask = os.urandom(4)  # client frames are masked (RFC 6455 section 5.3)
    sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))


def receive_message(sock):
    message, kind = b"", None
    while True:
        b0, b1 = read_exact(sock, 2)
        fin, opcode = b0 & 0x80, b0 & 0x0F
        n = b1 & 0x7F
        if n == 126:
            n = struct.unpack(">H", read_exact(sock, 2))[0]
        elif n == 127:
            n = struct.unpack(">Q", read_exact(sock, 8))[0]
        if n > MAX_MESSAGE or len(message) + n > MAX_MESSAGE:
            fail("message from the browser is too large")
        data = read_exact(sock, n)  # server frames aren't masked
        if opcode == 8:
            fail("the browser closed the connection")
        if opcode == 9:
            send_frame(sock, 10, data)
            continue
        if opcode == 10:
            continue
        if opcode in (1, 2):
            kind = opcode
        message += data
        if fin:
            return kind, message


def main():
    if len(sys.argv) < 3:
        fail("usage: cdp.py <ws-url> <method> [params-json]")
    url, method = sys.argv[1], sys.argv[2]
    try:
        params = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
    except json.JSONDecodeError as e:
        fail(f"params aren't JSON: {e}")
    timeout = float(os.environ.get("CDP_TIMEOUT", "30"))

    try:
        sock = connect(url, timeout)
        send_frame(sock, 1, json.dumps({"id": 1, "method": method, "params": params}).encode())
        while True:
            _, raw = receive_message(sock)
            message = json.loads(raw)
            if message.get("id") != 1:
                continue  # an event, or another command's answer
            if "error" in message:
                fail(f"{method}: {message['error'].get('message', message['error'])}")
            print(json.dumps(message.get("result", {})))
            return
    except (OSError, socket.timeout) as e:
        fail(f"{method}: {e}")


if __name__ == "__main__":
    main()
