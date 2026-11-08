#!/usr/bin/env python3
"""
probe_client.py —— 客户端测具（纯标准库）

包含三件东西：
  Tunnel    一条 TCP 连接，可选经 HTTP CONNECT 代理建立（就是 iOS netbird 的形态）
  HttpConn  Tunnel 上的 HTTP/1.1 客户端（keep-alive、Content-Length、chunked）
  WSClient  Tunnel 上的 WebSocket 客户端（握手校验、掩码帧、ping/pong 自动应答）

刻意不依赖 http.client / websockets：要测的正是"裸字节能不能过隧道"，
中间层越少，结论越干净。行为上对齐 dart:io 的等价实现，便于和 iOS 侧对拍。
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import socket
import struct
import time

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
OP_CONT, OP_TEXT, OP_BIN, OP_CLOSE, OP_PING, OP_PONG = 0x0, 0x1, 0x2, 0x8, 0x9, 0xA


# --------------------------------------------------------------------------
def pct(values: list[float], p: float) -> float:
    if not values:
        return float("nan")
    s = sorted(values)
    if len(s) == 1:
        return s[0]
    k = (len(s) - 1) * (p / 100.0)
    lo = int(k)
    hi = min(lo + 1, len(s) - 1)
    frac = k - lo
    return s[lo] * (1 - frac) + s[hi] * frac


def stats(values: list[float]) -> dict:
    if not values:
        return {"n": 0}
    return {
        "n": len(values),
        "min": round(min(values), 3),
        "p50": round(pct(values, 50), 3),
        "p95": round(pct(values, 95), 3),
        "p99": round(pct(values, 99), 3),
        "max": round(max(values), 3),
        "mean": round(sum(values) / len(values), 3),
    }


def xor_mask(data: bytes, mask: bytes) -> bytes:
    n = len(data)
    if n == 0:
        return b""
    key = (mask * (n // 4 + 1))[:n]
    return (int.from_bytes(data, "big") ^ int.from_bytes(key, "big")).to_bytes(n, "big")


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class Buf:
    def __init__(self, sock: socket.socket):
        self.sock = sock
        self.buf = b""

    def _fill(self) -> None:
        data = self.sock.recv(65536)
        if not data:
            raise EOFError("peer closed")
        self.buf += data

    def read_exact(self, n: int) -> bytes:
        while len(self.buf) < n:
            self._fill()
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def read_until(self, delim: bytes, limit: int = 1 << 20) -> bytes:
        while delim not in self.buf:
            if len(self.buf) > limit:
                raise ValueError("header too large")
            self._fill()
        i = self.buf.index(delim) + len(delim)
        out, self.buf = self.buf[:i], self.buf[i:]
        return out

    def readline(self) -> bytes:
        return self.read_until(b"\r\n")


# --------------------------------------------------------------------------
class Tunnel:
    """一条到 motifd 的 TCP 连接；proxy 给定时先做 HTTP CONNECT。"""

    def __init__(
        self,
        target: tuple[str, int],
        proxy: tuple[str, int] | None = None,
        timeout: float = 15.0,
        pipelined_payload: bytes | None = None,
    ):
        self.target = target
        self.proxy = proxy
        self.timeout = timeout
        self.pipelined_payload = pipelined_payload
        self.sock: socket.socket | None = None
        self.buf: Buf | None = None
        self.connect_ms = 0.0        # TCP（+CONNECT 往返）建立耗时
        self.connect_status = 0
        self.forwarded_bytes = 0     # 客户端主动流水线时发出去的字节数

    def open(self) -> "Tunnel":
        t0 = time.perf_counter()
        sock = socket.create_connection(self.proxy or self.target, timeout=self.timeout)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.settimeout(self.timeout)
        if self.proxy:
            host, port = self.target
            head = (f"CONNECT {host}:{port} HTTP/1.1\r\n"
                    f"Host: {host}:{port}\r\n"
                    f"Proxy-Connection: keep-alive\r\n\r\n").encode()
            if self.pipelined_payload:
                sock.sendall(head + self.pipelined_payload)
                self.forwarded_bytes = len(self.pipelined_payload)
            else:
                sock.sendall(head)
            buf = Buf(sock)
            status_line = buf.readline().decode("latin1").strip()
            parts = status_line.split()
            self.connect_status = int(parts[1]) if len(parts) > 1 else 0
            while True:
                line = buf.readline()
                if line == b"\r\n":
                    break
            self.buf = buf
            if self.connect_status != 200:
                raise ConnectionError(f"CONNECT failed: {status_line}")
        self.sock = sock
        if self.buf is None:
            self.buf = Buf(sock)
        self.connect_ms = (time.perf_counter() - t0) * 1000.0
        return self

    def close(self) -> None:
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None


# --------------------------------------------------------------------------
class Response:
    __slots__ = ("status", "reason", "headers", "body", "t_sent", "t_first", "t_done")

    def __init__(self, status, reason, headers, body, t_sent, t_first, t_done):
        self.status = status
        self.reason = reason
        self.headers = headers
        self.body = body
        self.t_sent = t_sent
        self.t_first = t_first
        self.t_done = t_done

    @property
    def ttfb_ms(self) -> float:
        return (self.t_first - self.t_sent) * 1000.0

    @property
    def total_ms(self) -> float:
        return (self.t_done - self.t_sent) * 1000.0

    def json(self):
        return json.loads(self.body.decode())


class HttpConn:
    def __init__(self, tunnel: Tunnel, timeout: float = 15.0):
        self.tunnel = tunnel
        self.timeout = timeout
        tunnel.sock.settimeout(timeout)

    def request(
        self,
        method: str,
        path: str,
        headers: dict | None = None,
        body: bytes = b"",
        chunked: bool = False,
    ) -> Response:
        h = {
            "Host": f"{self.tunnel.target[0]}:{self.tunnel.target[1]}",
            "User-Agent": "crossdesk-p0b-probe/1",
            "Connection": "keep-alive",
        }
        if headers:
            h.update(headers)
        if body or method in ("POST", "PUT"):
            if chunked:
                h["Transfer-Encoding"] = "chunked"
            else:
                h["Content-Length"] = str(len(body))
        head = f"{method} {path} HTTP/1.1\r\n" + "".join(f"{k}: {v}\r\n" for k, v in h.items()) + "\r\n"
        raw = head.encode()
        if chunked and body:
            raw += b"%x\r\n%s\r\n0\r\n\r\n" % (len(body), body)
        elif body:
            raw += body
        sock = self.tunnel.sock
        t_sent = time.perf_counter()
        sock.sendall(raw)
        buf = self.tunnel.buf
        status_line = buf.readline().decode("latin1").strip()
        t_first = time.perf_counter()
        parts = status_line.split()
        if len(parts) < 2:
            raise ConnectionError(f"bad status line: {status_line!r}")
        status = int(parts[1])
        reason = parts[2] if len(parts) > 2 else ""
        resp_headers: dict[str, str] = {}
        while True:
            line = buf.readline()
            if line == b"\r\n":
                break
            k, _, v = line.decode("latin1").partition(":")
            resp_headers[k.strip().lower()] = v.strip()

        payload = b""
        if "transfer-encoding" in resp_headers and "chunked" in resp_headers["transfer-encoding"].lower():
            chunks = []
            while True:
                size_line = buf.readline().strip()
                size = int(size_line.split(b";")[0], 16)
                if size == 0:
                    buf.readline()
                    break
                chunks.append(buf.read_exact(size))
                buf.read_exact(2)
            payload = b"".join(chunks)
        elif "content-length" in resp_headers:
            n = int(resp_headers["content-length"])
            payload = buf.read_exact(n) if n else b""
        else:
            # close-delimited
            try:
                while True:
                    payload += buf.read_exact(4096)
            except (EOFError, OSError):
                pass
        t_done = time.perf_counter()
        return Response(status, reason, resp_headers, payload, t_sent, t_first, t_done)


# --------------------------------------------------------------------------
class WSClient:
    """隧道上的 WS 客户端。ping 自动回 pong（与 dart:io / 浏览器一致）。"""

    def __init__(self, tunnel: Tunnel, path: str, headers: dict | None = None, timeout: float = 15.0):
        self.tunnel = tunnel
        self.path = path
        self.headers = headers or {}
        self.timeout = timeout
        self.ws: "WSFrames | None" = None
        self.handshake_ms = 0.0
        self.accept_ok = False
        self.status = 0
        self.close_code: int | None = None
        self.pings_recv = 0
        self.events_recv = 0

    def connect(self) -> "WSClient":
        key = base64.b64encode(os.urandom(16)).decode()
        h = {
            "Host": f"{self.tunnel.target[0]}:{self.tunnel.target[1]}",
            "Upgrade": "websocket",
            "Connection": "Upgrade",
            "Sec-WebSocket-Key": key,
            "Sec-WebSocket-Version": "13",
            "User-Agent": "crossdesk-p0b-probe/1",
        }
        h.update(self.headers)
        raw = (f"GET {self.path} HTTP/1.1\r\n" +
               "".join(f"{k}: {v}\r\n" for k, v in h.items()) + "\r\n").encode()
        s = self.tunnel.sock
        s.settimeout(self.timeout)
        t0 = time.perf_counter()
        s.sendall(raw)
        buf = self.tunnel.buf
        status_line = buf.readline().decode("latin1").strip()
        parts = status_line.split()
        self.status = int(parts[1]) if len(parts) > 1 else 0
        resp_headers: dict[str, str] = {}
        while True:
            line = buf.readline()
            if line == b"\r\n":
                break
            k, _, v = line.decode("latin1").partition(":")
            resp_headers[k.strip().lower()] = v.strip()
        self.handshake_ms = (time.perf_counter() - t0) * 1000.0
        if self.status != 101:
            raise ConnectionError(f"upgrade failed: {status_line}")
        expect = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        self.accept_ok = resp_headers.get("sec-websocket-accept") == expect
        self.ws = WSFrames(s, buf, is_client=True)
        return self

    # -- 帧 ---------------------------------------------------------------
    def send(self, opcode: int, payload: bytes = b"") -> None:
        assert self.ws
        self.ws.send(opcode, payload)

    def send_text(self, text: str) -> None:
        self.send(OP_TEXT, text.encode())

    def send_bin(self, data: bytes) -> None:
        self.send(OP_BIN, data)

    def recv_frame(self) -> tuple[int, bytes]:
        assert self.ws
        op, payload = self.ws.recv_frame()
        if op == OP_PING:
            self.ws.send(OP_PONG, payload)
            self.pings_recv += 1
        elif op == OP_CLOSE:
            self.close_code = self.ws.close_code
        return op, payload

    def recv_message(self, auto_pong: bool = True) -> tuple[int, bytes]:
        assert self.ws
        opcode, data = None, b""
        while True:
            op, payload = self.ws.recv_frame()
            if op == OP_PING:
                if auto_pong:
                    self.ws.send(OP_PONG, payload)
                self.pings_recv += 1
                continue
            if op == OP_PONG:
                continue
            if op == OP_CLOSE:
                self.close_code = self.ws.close_code
                return OP_CLOSE, payload
            if op == OP_CONT:
                data += payload
            else:
                opcode, data = op, payload
            if self.ws.last_fin:
                return opcode, data

    def close(self, code: int = 1000) -> None:
        if self.ws:
            try:
                self.ws.send(OP_CLOSE, struct.pack("!H", code))
            except OSError:
                pass


class WSFrames:
    """客户端侧帧编解码（发必须掩码，收不掩码）。"""

    def __init__(self, sock: socket.socket, buf: Buf, is_client: bool = True):
        self.sock = sock
        self.buf = buf
        self.is_client = is_client
        self.last_fin = True
        self.close_code: int | None = None
        self.close_reason = ""

    def send(self, opcode: int, payload: bytes = b"", fin: bool = True) -> None:
        b1 = (0x80 if fin else 0) | opcode
        n = len(payload)
        header = bytearray([b1])
        if n < 126:
            header.append(0x80 | n)
        elif n < (1 << 16):
            header.append(0x80 | 126)
            header += struct.pack("!H", n)
        else:
            header.append(0x80 | 127)
            header += struct.pack("!Q", n)
        key = os.urandom(4)
        header += key
        self.sock.sendall(bytes(header) + xor_mask(payload, key))

    def recv_frame(self) -> tuple[int, bytes]:
        h = self.buf.read_exact(2)
        b1, b2 = h[0], h[1]
        self.last_fin = bool(b1 & 0x80)
        opcode = b1 & 0x0F
        masked = bool(b2 & 0x80)
        ln = b2 & 0x7F
        if ln == 126:
            ln = struct.unpack("!H", self.buf.read_exact(2))[0]
        elif ln == 127:
            ln = struct.unpack("!Q", self.buf.read_exact(8))[0]
        mask = self.buf.read_exact(4) if masked else None
        payload = self.buf.read_exact(ln) if ln else b""
        if mask:
            payload = xor_mask(payload, mask)
        if opcode == OP_CLOSE:
            if len(payload) >= 2:
                self.close_code = struct.unpack("!H", payload[:2])[0]
                self.close_reason = payload[2:].decode("utf-8", "replace")
            else:
                self.close_code = 1005
        return opcode, payload


def make_payload(size: int, kind: str = "random", seed: int = 1234) -> bytes:
    """生成测试载荷。

    random: 不可压缩（测纯吞吐）
    tui:    模拟终端 UI 输出（ANSI 彩色、短行、大量重复 → 可被 framed zlib 压缩）
    """
    if kind == "random":
        # 固定种子，便于跨语言（Dart 侧）复现同一份 sha256
        import random
        rnd = random.Random(seed)
        return bytes(rnd.getrandbits(8) for _ in range(size))
    if kind == "tui":
        lines = []
        total = 0
        i = 0
        while total < size:
            i += 1
            line = (
                f"\x1b[38;5;{i % 256}m~/proj/src/main.rs:{i % 500}\x1b[0m  "
                f"\x1b[1;32m+{i % 97}\x1b[0m \x1b[2mfn handler_{i % 40}(&self) -> Result<()>\x1b[0m\r\n"
                f"\x1b[34m  cargo build --release --target x86_64-pc-windows-msvc\x1b[0m\r\n"
                f"   Compiling crossdesk v0.1.{i % 9} ({i % 500}/512)\r\n"
            )
            lines.append(line.encode())
            total += len(line)
        blob = b"".join(lines)
        return blob[:size]
    raise ValueError(f"unknown payload kind {kind}")
