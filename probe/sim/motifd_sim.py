#!/usr/bin/env python3
"""
motifd_sim.py —— 最小 motifd 假服务（协议级仿真用，纯标准库）

依据：Motif 上游 docs/rpc.md（自称 wire-level 唯一权威，2026-11-02 版）。
实现其中与 P0-B 判定相关的三条通道 + 鉴权/会话语义：

  GET  /ping                200 JSON，不需要鉴权（探活）
  POST /rpc/{method}        401 无 token / 404 未知方法 / 409 NotAttached
                            version, session.attach(detach/list), pty.create/list/resize/kill
  GET  /events?...          WS 升级；服务端推送 JSON-RPC Notification；20s Ping；45s 空闲 Close
  GET  /pty/{id}?...        WS 双向；首帧 Text meta；之后 Binary；
                            上行 raw stdin，下行 raw 或 opt-in framed zlib（1 字节 flags）

不是 motifd 的完整实现：没有真实 PTY、没有 VT 回放、没有 4096 事件环回放语义的完整版。
它存在的唯一目的是回答一个问题：**HTTP/1.1 + WS 升级 + 双向 raw 二进制，能不能
原样穿过一条 CONNECT 隧道**。所以这里刻意把协议里对隧道最不友好的部分都保留了：
keep-alive、chunked 请求体、64 KiB 级 WS 帧、16 位/64 位长度、ping/pong、close code。

额外提供 `GET /__sim/stats`（**非 motifd 路由**，仅仿真用）供测试器读取服务端计数，
用于把"客户端没收到"和"服务端没发出"区分开。

用法：
    python3 motifd_sim.py --port 17777 --token secret
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import socket
import struct
import sys
import threading
import time
import uuid
import zlib

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
PROTOCOL_VERSION = "sim-0.9.0"


# --------------------------------------------------------------------------
# 字节缓冲：所有读都从这里走，保证握手后残留字节不丢（真实代理/客户端同理）
# --------------------------------------------------------------------------
class Buf:
    def __init__(self, sock: socket.socket):
        self.sock = sock
        self.buf = b""
        self.eof = False

    def _fill(self, n: int = 65536) -> None:
        data = self.sock.recv(n)
        if not data:
            self.eof = True
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

    def take_pending(self) -> bytes:
        out, self.buf = self.buf, b""
        return out


def xor_mask(data: bytes, mask: bytes) -> bytes:
    """遮罩/解遮罩。用大整数 XOR 走 C 循环，1MB 也是毫秒级。"""
    n = len(data)
    if n == 0:
        return b""
    key = (mask * (n // 4 + 1))[:n]
    return (int.from_bytes(data, "big") ^ int.from_bytes(key, "big")).to_bytes(n, "big")


# --------------------------------------------------------------------------
# WebSocket 最小实现（RFC 6455 子集：text/binary/ping/pong/close + 分片读）
# --------------------------------------------------------------------------
OP_CONT, OP_TEXT, OP_BIN, OP_CLOSE, OP_PING, OP_PONG = 0x0, 0x1, 0x2, 0x8, 0x9, 0xA


class WS:
    def __init__(self, sock: socket.socket, buf: Buf | None = None, is_client: bool = False):
        self.sock = sock
        self.buf = buf or Buf(sock)
        self.is_client = is_client
        self.close_code: int | None = None
        self.close_reason: str = ""

    # -- 读 ----------------------------------------------------------------
    def recv_frame(self) -> tuple[bool, int, bytes]:
        h = self.buf.read_exact(2)
        b1, b2 = h[0], h[1]
        fin = bool(b1 & 0x80)
        rsv = b1 & 0x70
        opcode = b1 & 0x0F
        masked = bool(b2 & 0x80)
        ln = b2 & 0x7F
        if rsv:
            raise ValueError(f"unexpected RSV bits {rsv:#x}")
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
        return fin, opcode, payload

    def recv_message(self) -> tuple[int, bytes]:
        """读一条完整消息（拼分片），顺带处理 ping/pong/close 并返回其 opcode。"""
        op, data = None, b""
        while True:
            fin, opcode, payload = self.recv_frame()
            if opcode in (OP_PING, OP_PONG):
                return opcode, payload
            if opcode == OP_CLOSE:
                return OP_CLOSE, payload
            if opcode == OP_CONT:
                data += payload
            else:
                op, data = opcode, payload
            if fin:
                return op, data

    # -- 写 ----------------------------------------------------------------
    def send_frame(self, opcode: int, payload: bytes = b"", fin: bool = True) -> None:
        b1 = (0x80 if fin else 0x00) | opcode
        n = len(payload)
        header = bytearray([b1])
        mask_bit = 0x80 if self.is_client else 0x00
        if n < 126:
            header.append(mask_bit | n)
        elif n < (1 << 16):
            header.append(mask_bit | 126)
            header += struct.pack("!H", n)
        else:
            header.append(mask_bit | 127)
            header += struct.pack("!Q", n)
        if self.is_client:
            key = os.urandom(4)
            header += key
            payload = xor_mask(payload, key)
        self.sock.sendall(bytes(header) + payload)

    def send_text(self, text: str) -> None:
        self.send_frame(OP_TEXT, text.encode())

    def send_binary(self, data: bytes) -> None:
        self.send_frame(OP_BIN, data)

    def ping(self, payload: bytes = b"") -> None:
        self.send_frame(OP_PING, payload)

    def pong(self, payload: bytes = b"") -> None:
        self.send_frame(OP_PONG, payload)

    def close(self, code: int = 1000, reason: str = "") -> None:
        body = struct.pack("!H", code) + reason.encode()
        try:
            self.send_frame(OP_CLOSE, body)
        except OSError:
            pass


def ws_accept(key: str) -> str:
    return base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()


# --------------------------------------------------------------------------
# 服务端
# --------------------------------------------------------------------------
class Stats:
    def __init__(self):
        self.lock = threading.Lock()
        self.data = {
            "http_requests": 0,
            "rpc_calls": {},
            "auth_401": 0,
            "not_attached_409": 0,
            "method_not_found_404": 0,
            "ws_upgrades": 0,
            "ws_client_frames": 0,
            "events_sent": 0,
            "pings_sent": 0,
            "pongs_recv": 0,
            "pty_conns": 0,
            "pty_bytes_up": 0,
            "pty_bytes_down": 0,
            "pty_wire_bytes_down": 0,
            "pty_frames_down": 0,
            "pty_close_4011": 0,
            "pty_not_found_404": 0,
            "connections": 0,
        }

    def inc(self, key: str, n: int = 1):
        with self.lock:
            if key in self.data:
                self.data[key] += n

    def bump(self, method: str):
        with self.lock:
            d = self.data["rpc_calls"]
            d[method] = d.get(method, 0) + 1

    def snapshot(self) -> dict:
        with self.lock:
            return json.loads(json.dumps(self.data))


class Registry:
    """ConnRegistry 的最小等价物：sid -> 绑定信息。"""

    def __init__(self):
        self.lock = threading.Lock()
        self.entries: dict[str, dict] = {}

    def attach(self, hint: str | None) -> tuple[str, dict]:
        with self.lock:
            if hint and hint in self.entries:
                return hint, self.entries[hint]
            sid = "sid-" + uuid.uuid4().hex[:12]
            entry = {
                "client_id": "cli-" + uuid.uuid4().hex[:8],
                "session": "sess-main",
                "attached_at": time.time(),
                "last_seq": 42,
            }
            self.entries[sid] = entry
            return sid, entry

    def get(self, sid: str | None) -> dict | None:
        if not sid:
            return None
        with self.lock:
            return self.entries.get(sid)

    def detach(self, sid: str | None) -> None:
        with self.lock:
            self.entries.pop(sid or "", None)


class MotifdSim:
    def __init__(
        self,
        host: str = "127.0.0.1",
        port: int = 0,
        token: str = "",
        ping_interval: float = 20.0,
        idle_timeout: float = 45.0,
        event_interval: float = 0.25,
        compress_min: int = 64,
    ):
        self.host, self.port = host, port
        self.token = token
        self.ping_interval = ping_interval
        self.idle_timeout = idle_timeout
        self.event_interval = event_interval
        self.compress_min = compress_min
        self.stats = Stats()
        self.registry = Registry()
        self.ptys: dict[str, dict] = {
            "pty-1": {"id": "pty-1", "cmd": "/bin/zsh", "cwd": "/home/dev/proj",
                      "cols": 120, "rows": 32, "alive": True,
                      "created_at": int(time.time() * 1000) - 600_000,
                      "running_command": None},
        }
        self.ptys_lock = threading.Lock()
        self.sock: socket.socket | None = None
        self._stop = threading.Event()
        self.thread: threading.Thread | None = None

    # -- 生命周期 ----------------------------------------------------------
    def start(self) -> int:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((self.host, self.port))
        s.listen(128)
        self.sock = s
        self.port = s.getsockname()[1]
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()
        return self.port

    def stop(self) -> None:
        self._stop.set()
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass

    def _serve(self) -> None:
        while not self._stop.is_set():
            try:
                conn, addr = self.sock.accept()
            except OSError:
                return
            self.stats.inc("connections")
            t = threading.Thread(target=self._handle, args=(conn, addr), daemon=True)
            t.start()

    # -- 鉴权 --------------------------------------------------------------
    def _authorized(self, headers: dict, query: dict, allow_query: bool) -> bool:
        if not self.token:
            return True
        h = headers.get("authorization", "")
        if h.lower().startswith("bearer ") and hmac.compare_digest(h[7:].strip(), self.token):
            return True
        if allow_query and hmac.compare_digest(query.get("token", ""), self.token):
            return True
        return False

    # -- HTTP 基础 ---------------------------------------------------------
    def _read_request(self, buf: Buf) -> dict | None:
        try:
            line = buf.readline()
        except (EOFError, OSError):
            return None
        line = line.decode("latin1").strip()
        if not line:
            return None
        parts = line.split()
        if len(parts) < 3:
            return None
        method, target, version = parts[0], parts[1], parts[2]
        headers: dict[str, str] = {}
        while True:
            h = buf.readline()
            if h == b"\r\n":
                break
            k, _, v = h.decode("latin1").partition(":")
            headers[k.strip().lower()] = v.strip()
        body = b""
        te = headers.get("transfer-encoding", "").lower()
        if "chunked" in te:
            chunks = []
            while True:
                size_line = buf.readline().strip()
                size = int(size_line.split(b";")[0], 16)
                if size == 0:
                    buf.readline()
                    break
                chunks.append(buf.read_exact(size))
                buf.read_exact(2)
            body = b"".join(chunks)
        elif "content-length" in headers:
            n = int(headers["content-length"])
            body = buf.read_exact(n) if n else b""
        path, _, qs = target.partition("?")
        query = {}
        for kv in qs.split("&"):
            if not kv:
                continue
            k, _, v = kv.partition("=")
            query[k] = v
        return {
            "method": method,
            "path": path,
            "query": query,
            "version": version,
            "headers": headers,
            "body": body,
        }

    def _send_response(self, sock, status: int, reason: str, headers: dict, body: bytes, keep=True):
        hdrs = {
            "Content-Length": str(len(body)),
            "Connection": "keep-alive" if keep else "close",
            "Server": "motifd-sim",
        }
        hdrs.update({k: v for k, v in headers.items() if v is not None})
        head = f"HTTP/1.1 {status} {reason}\r\n"
        for k, v in hdrs.items():
            head += f"{k}: {v}\r\n"
        sock.sendall(head.encode() + b"\r\n" + body)

    def _json(self, sock, status, obj, headers=None, reason=None):
        reason = reason or {200: "OK", 400: "Bad Request", 401: "Unauthorized",
                            404: "Not Found", 409: "Conflict", 500: "Internal Server Error"}.get(status, "OK")
        body = json.dumps(obj).encode()
        h = {"Content-Type": "application/json"}
        if headers:
            h.update(headers)
        self._send_response(sock, status, reason, h, body)

    def _rpc_error(self, sock, status, code, message, data=None):
        err = {"code": code, "message": message}
        if data is not None:
            err["data"] = data
        self._json(sock, status, {"jsonrpc": "2.0", "id": 0, "error": err})

    # -- 主处理 ------------------------------------------------------------
    def _handle(self, conn: socket.socket, addr) -> None:
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        buf = Buf(conn)
        try:
            while not self._stop.is_set():
                req = self._read_request(buf)
                if req is None:
                    return
                self.stats.inc("http_requests")
                close_after = (req["headers"].get("connection", "").lower() == "close")
                path = req["path"]
                if path.startswith("/__sim/"):
                    self._control(conn, req)
                    if close_after:
                        return
                    continue
                if path == "/ping":
                    if req["method"] != "GET":
                        self._json(conn, 405, {"error": "method not allowed"})
                        continue
                    self._json(conn, 200, {
                        "ok": True, "name": "motifd", "version": PROTOCOL_VERSION,
                        "capabilities": [],
                    })
                    if close_after:
                        return
                    continue
                if path.startswith("/rpc/"):
                    if not self._authorized(req["headers"], req["query"], allow_query=False):
                        self.stats.inc("auth_401")
                        self._json(conn, 401, {"jsonrpc": "2.0", "id": 0,
                                               "error": {"code": 401, "message": "missing or invalid Bearer token"}},
                                   headers=None)
                        continue
                    self._rpc(conn, req)
                    continue
                if path == "/events":
                    if not self._authorized(req["headers"], req["query"], allow_query=True):
                        self.stats.inc("auth_401")
                        self._send_response(conn, 401, "Unauthorized",
                                            {"Content-Type": "text/plain"}, b"missing or invalid Bearer token",
                                            keep=False)
                        return
                    if not self.registry.get(req["query"].get("session")):
                        self.stats.inc("not_attached_409")
                        self._send_response(conn, 409, "Conflict",
                                            {"Content-Type": "application/json"},
                                            json.dumps({"jsonrpc": "2.0", "id": 0,
                                                        "error": {"code": 409, "message": "NotAttached"}}).encode(),
                                            keep=False)
                        return
                    self._ws_events(conn, buf, req)
                    return
                if path.startswith("/pty/"):
                    if not self._authorized(req["headers"], req["query"], allow_query=True):
                        self.stats.inc("auth_401")
                        self._send_response(conn, 401, "Unauthorized",
                                            {"Content-Type": "text/plain"}, b"missing or invalid Bearer token",
                                            keep=False)
                        return
                    if not self.registry.get(req["query"].get("session")):
                        self.stats.inc("not_attached_409")
                        self._send_response(conn, 409, "Conflict",
                                            {"Content-Type": "application/json"},
                                            json.dumps({"jsonrpc": "2.0", "id": 0,
                                                        "error": {"code": 409, "message": "NotAttached"}}).encode(),
                                            keep=False)
                        return
                    pty_id = path[len("/pty/"):]
                    if pty_id not in self.ptys:
                        self.stats.inc("pty_not_found_404")
                        self._send_response(conn, 404, "Not Found",
                                            {"Content-Type": "application/json"},
                                            json.dumps({"jsonrpc": "2.0", "id": 0,
                                                        "error": {"code": 404, "message": "PtyNotFound"}}).encode(),
                                            keep=False)
                        return
                    self._ws_pty(conn, buf, req)
                    return
                self.stats.inc("method_not_found_404")
                self._json(conn, 404, {"error": "not found", "path": path})
        except (EOFError, ConnectionResetError, BrokenPipeError, OSError, ValueError):
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def _control(self, conn, req) -> None:
        if req["path"] == "/__sim/stats":
            self._json(conn, 200, self.stats.snapshot())
        elif req["path"] == "/__sim/reset":
            self.stats.__init__()
            self._json(conn, 200, {"ok": True})
        else:
            self._json(conn, 404, {"error": "unknown control path"})

    # -- RPC ---------------------------------------------------------------
    def _rpc(self, conn, req) -> None:
        method = req["path"][len("/rpc/"):]
        self.stats.bump(method)
        sid_hdr = req["headers"].get("x-motif-session")
        try:
            params = json.loads(req["body"]) if req["body"] else None
        except json.JSONDecodeError:
            self._rpc_error(conn, 400, -32700, "Parse error")
            return

        # ⚠️ 上游 motifd **没有** /rpc/version（2026-11-08 lead 纠偏）。
        # 这里保留是为了和早期草稿对拍，验收一律用 GET /ping。
        if method == "version":
            self._json(conn, 200, {
                "version": PROTOCOL_VERSION, "build": "probe-sim",
                "protocol": 1, "name": "motifd",
            })
            return
        if method == "session.attach":
            sid, entry = self.registry.attach(sid_hdr)
            body = {
                "session": {"id": "sess-main", "name": (params or {}).get("name") or "main",
                            "custom_name": None, "workdir": "/home/dev/proj",
                            "created_at": int(time.time() * 1000) - 3600_000, "client_count": 1},
                "client_id": entry["client_id"],
                "clients": [],
                "ptys": list(self.ptys.values()),
                "views": [{"id": "view-1", "pty_id": "pty-1", "title": "shell"}],
                "active_view": "view-1",
                "last_seq": entry["last_seq"],
                "theme": "dark",
            }
            self._json(conn, 200, body, headers={"X-Motif-Session": sid})
            return
        if method == "session.list":
            self._json(conn, 200, {"sessions": [{"id": "sess-main", "name": "main",
                                                 "custom_name": None, "workdir": "/home/dev/proj",
                                                 "created_at": int(time.time() * 1000) - 3600_000,
                                                 "client_count": 1}]})
            return
        if method == "session.detach":
            self.registry.detach(sid_hdr)
            self._json(conn, 200, {})
            return

        entry = self.registry.get(sid_hdr)
        if entry is None:
            self.stats.inc("not_attached_409")
            self._rpc_error(conn, 409, 409, "NotAttached",
                            {"hint": "POST /rpc/session.attach and reuse X-Motif-Session"})
            return

        if method == "pty.create":
            with self.ptys_lock:
                n = len(self.ptys) + 1
                pid = f"pty-{n}"
                info = {
                    "id": pid,
                    "cmd": (params or {}).get("cmd") or "/bin/zsh",
                    "cwd": (params or {}).get("cwd") or "/home/dev/proj",
                    "cols": (params or {}).get("cols") or 120,
                    "rows": (params or {}).get("rows") or 32,
                    "alive": True,
                    "created_at": int(time.time() * 1000),
                    "running_command": None,
                }
                self.ptys[pid] = info
            self._json(conn, 200, {"info": info})
            return
        if method == "pty.list":
            self._json(conn, 200, {"ptys": list(self.ptys.values())})
            return
        if method == "pty.resize":
            self._json(conn, 200, {})
            return
        if method == "pty.kill":
            self._json(conn, 200, {})
            return
        self.stats.inc("method_not_found_404")
        self._rpc_error(conn, 404, -32601, "Method not found", {"method": method})

    # -- WS 升级 -----------------------------------------------------------
    def _do_handshake(self, conn, buf, req) -> WS | None:
        key = req["headers"].get("sec-websocket-key")
        upgrade = req["headers"].get("upgrade", "").lower()
        if not key or upgrade != "websocket":
            self._send_response(conn, 400, "Bad Request", {"Content-Type": "text/plain"},
                                b"expected websocket upgrade", keep=False)
            return None
        proto = req["headers"].get("sec-websocket-protocol")
        lines = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            f"Sec-WebSocket-Accept: {ws_accept(key)}",
        ]
        if proto:
            lines.append(f"Sec-WebSocket-Protocol: {proto.split(',')[0].strip()}")
        conn.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
        self.stats.inc("ws_upgrades")
        return WS(conn, buf, is_client=False)

    # -- /events -----------------------------------------------------------
    def _ws_events(self, conn, buf: Buf, req) -> None:
        ws = self._do_handshake(conn, buf, req)
        if ws is None:
            return
        seq = int(req["query"].get("since") or 42)
        stop = threading.Event()
        state = {"last_rx": time.time()}

        def reader():
            try:
                while not stop.is_set():
                    fin, op, payload = ws.recv_frame()
                    state["last_rx"] = time.time()
                    if op == OP_CLOSE:
                        stop.set()
                        return
                    if op == OP_PING:
                        ws.pong(payload)
                    elif op == OP_PONG:
                        self.stats.inc("pongs_recv")
                    elif op in (OP_TEXT, OP_BIN):
                        self.stats.inc("ws_client_frames")
            except (EOFError, OSError, ValueError):
                stop.set()

        rt = threading.Thread(target=reader, daemon=True)
        rt.start()
        last_ping = time.time()
        last_event = 0.0
        try:
            while not stop.is_set():
                now = time.time()
                if now - last_event >= self.event_interval:
                    seq += 1
                    ws.send_text(json.dumps({
                        "jsonrpc": "2.0",
                        "method": "pty.output",
                        "params": {"seq": seq, "pty_id": "pty-1", "bytes": 42,
                                   "t": int(now * 1000)},
                    }))
                    self.stats.inc("events_sent")
                    last_event = now
                if now - last_ping >= self.ping_interval:
                    ws.ping(str(int(now * 1000)).encode())
                    self.stats.inc("pings_sent")
                    last_ping = now
                if now - state["last_rx"] > self.idle_timeout:
                    ws.close(1001, "idle timeout")
                    return
                stop.wait(0.02)
            ws.close(1000, "server stop")
        except (OSError, ValueError):
            pass
        finally:
            stop.set()

    # -- /pty --------------------------------------------------------------
    def _ws_pty(self, conn, buf: Buf, req) -> None:
        ws = self._do_handshake(conn, buf, req)
        if ws is None:
            return
        self.stats.inc("pty_conns")
        q = req["query"]
        framed = q.get("pty_frame") == "v1"
        compress = q.get("pty_compress") == "zlib" and framed
        since = int(q.get("since") or 0)
        meta = {"since": since}
        if framed:
            meta["pty_frame"] = "v1"
            if compress:
                meta["pty_compress"] = "zlib"
        try:
            ws.send_text(json.dumps(meta))
        except OSError:
            return
        try:
            while True:
                fin, op, payload = ws.recv_frame()
                if op == OP_CLOSE:
                    return
                if op == OP_PING:
                    ws.pong(payload)
                    continue
                if op == OP_PONG:
                    self.stats.inc("pongs_recv")
                    continue
                if op == OP_TEXT:
                    continue
                if op == OP_BIN:
                    self.stats.inc("pty_bytes_up", len(payload))
                    # PTY 语义：stdin 被 shell 回显 → 原样吐回 master 端
                    out = payload
                    if framed:
                        flags = 0
                        if compress and len(out) >= self.compress_min:
                            comp = zlib.compress(out, 6)
                            if len(comp) < len(out):
                                flags = 1
                                out = comp
                        wire = bytes([flags]) + out
                    else:
                        wire = out
                    ws.send_binary(wire)
                    self.stats.inc("pty_bytes_down", len(payload))
                    self.stats.inc("pty_wire_bytes_down", len(wire))
                    self.stats.inc("pty_frames_down")
        except (EOFError, OSError, ValueError):
            return


def main() -> int:
    ap = argparse.ArgumentParser(description="minimal motifd simulator")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=17777)
    ap.add_argument("--token", default="")
    ap.add_argument("--ping-interval", type=float, default=20.0)
    ap.add_argument("--idle-timeout", type=float, default=45.0)
    ap.add_argument("--event-interval", type=float, default=0.25)
    args = ap.parse_args()
    sim = MotifdSim(host=args.host, port=args.port, token=args.token,
                    ping_interval=args.ping_interval, idle_timeout=args.idle_timeout,
                    event_interval=args.event_interval)
    port = sim.start()
    print(f"motifd-sim listening on {args.host}:{port} (token={'set' if args.token else 'disabled'})",
          flush=True)
    try:
        while True:
            time.sleep(1.0)
    except KeyboardInterrupt:
        sim.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
