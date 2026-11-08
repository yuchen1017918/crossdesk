#!/usr/bin/env python3
"""
connect_proxy.py —— HTTP CONNECT 代理（模拟 iOS userspace netbird 的本地代理）

为什么自己写：iOS 上 netbird 是 userspace 实现，Dart 侧只能靠 `startProxy()` 给一个
本地 HTTP 代理端口，再由客户端 CONNECT 到 100.x:7777。这条链路上真正可能出问题的
不是 netbird 的加密（它对自己透明），而是**代理实现本身的几个经典坑**。本文件把这
些坑做成可切换的 profile，让仿真能给出"哪种实现会挂、怎么挂"的定量结论：

  standard      64 KiB 读缓冲，无延迟 —— 理想实现
  tinybuf       1 KiB 读缓冲 —— 模拟一次 read 只能拿几百字节的实现
                （考的是客户端/服务端不能假设"一次 read = 一个 WS 帧"）
  laggy        4 KiB/chunk + 每 chunk 2 ms —— 模拟 relayed 路径的吞吐上限（≈2 MB/s）
  lossy        **错误实现**：用一次 recv(4096) 读 CONNECT 头，把多读到的字节丢掉。
                客户端若"乐观流水线"（CONNECT 之后不等 200 就发 GET），首包必丢。
                这是真实项目里最常见的自研代理 bug，仿真里显式留一个对照位。
  nohalf       不传播半关闭（模拟没处理 shutdown 的代理；`Connection: close` 会挂住）

所有 profile 都是**字节透明**的：CONNECT 建立后只在两个 socket 之间搬字节，
不解析、不改写。这一点必须在报告里写清楚：如果 standard 都过不了，问题在客户端
或服务端，不在"隧道不可用"。
"""
from __future__ import annotations

import argparse
import socket
import threading
import time


class ConnectProxy:
    def __init__(
        self,
        host: str = "127.0.0.1",
        port: int = 0,
        name: str = "standard",
        buf_size: int = 65536,
        chunk_delay_ms: float = 0.0,
        lossy: bool = False,
        propagate_halfclose: bool = True,
        connect_timeout: float = 10.0,
    ):
        self.host, self.port = host, port
        self.name = name
        self.buf_size = buf_size
        self.chunk_delay_ms = chunk_delay_ms
        self.lossy = lossy
        self.propagate_halfclose = propagate_halfclose
        self.connect_timeout = connect_timeout
        self.sock: socket.socket | None = None
        self._stop = threading.Event()
        self.thread: threading.Thread | None = None
        self.lock = threading.Lock()
        self.stats = {
            "tunnels": 0,
            "up_bytes": 0,
            "down_bytes": 0,
            "connect_errors": 0,
            "discarded_bytes": 0,
            "relay_chunks": 0,
        }

    # -- 生命周期 ----------------------------------------------------------
    def start(self) -> int:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((self.host, self.port))
        s.listen(64)
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
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    # -- CONNECT 请求解析 --------------------------------------------------
    def _read_connect_head(self, conn: socket.socket) -> tuple[bytes, int]:
        """返回 (header_bytes, consumed_count)。

        正确实现逐字节读到 CRLFCRLF；lossy 实现一次 recv 4096 并把多余字节丢掉。
        """
        if self.lossy:
            data = conn.recv(4096)
            i = data.find(b"\r\n\r\n")
            if i < 0:
                return data, len(data)
            head, rest = data[: i + 4], data[i + 4:]
            with self.lock:
                self.stats["discarded_bytes"] += len(rest)
            return head, len(data)
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = conn.recv(1)
            if not chunk:
                raise ConnectionError("eof in connect head")
            buf += chunk
            if len(buf) > 16384:
                raise ValueError("connect head too large")
        return buf, len(buf)

    def _handle(self, conn: socket.socket) -> None:
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        upstream = None
        try:
            head, _ = self._read_connect_head(conn)
            text = head.decode("latin1")
            lines = text.split("\r\n")
            if not lines or not lines[0].upper().startswith("CONNECT "):
                conn.sendall(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n")
                return
            parts = lines[0].split()
            target = parts[1]
            host, _, port_s = target.rpartition(":")
            port = int(port_s)
            upstream = socket.create_connection((host, port), timeout=self.connect_timeout)
            upstream.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            upstream.settimeout(None)
            conn.settimeout(None)
            conn.sendall(b"HTTP/1.1 200 Connection Established\r\nProxy-Agent: crossdesk-probe\r\n\r\n")
            with self.lock:
                self.stats["tunnels"] += 1
            t1 = threading.Thread(target=self._relay, args=(conn, upstream, "up"), daemon=True)
            t2 = threading.Thread(target=self._relay, args=(upstream, conn, "down"), daemon=True)
            t1.start()
            t2.start()
            t1.join()
            t2.join()
        except (OSError, ValueError, ConnectionError):
            with self.lock:
                self.stats["connect_errors"] += 1
            try:
                conn.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
            except OSError:
                pass
        finally:
            for s in (conn, upstream):
                if s is not None:
                    try:
                        s.close()
                    except OSError:
                        pass

    def _relay(self, src: socket.socket, dst: socket.socket, direction: str) -> None:
        try:
            while True:
                data = src.recv(self.buf_size)
                if not data:
                    break
                dst.sendall(data)
                with self.lock:
                    self.stats["up_bytes" if direction == "up" else "down_bytes"] += len(data)
                    self.stats["relay_chunks"] += 1
                if self.chunk_delay_ms:
                    time.sleep(self.chunk_delay_ms / 1000.0)
        except OSError:
            pass
        finally:
            if self.propagate_halfclose:
                try:
                    dst.shutdown(socket.SHUT_WR)
                except OSError:
                    pass

    def snapshot(self) -> dict:
        with self.lock:
            return dict(self.stats)


PROFILES = {
    "standard": dict(name="standard", buf_size=65536),
    "tinybuf": dict(name="tinybuf", buf_size=1024),
    "laggy": dict(name="laggy", buf_size=4096, chunk_delay_ms=2.0),
    "lossy": dict(name="lossy", buf_size=65536, lossy=True),
    "nohalf": dict(name="nohalf", buf_size=65536, propagate_halfclose=False),
}


def make_proxy(profile: str, host: str = "127.0.0.1") -> ConnectProxy:
    cfg = dict(PROFILES.get(profile, PROFILES["standard"]))
    return ConnectProxy(host=host, **cfg)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=18080)
    ap.add_argument("--profile", default="standard", choices=sorted(PROFILES))
    args = ap.parse_args()
    p = make_proxy(args.profile, args.host)
    port = p.start()
    print(f"connect proxy '{args.profile}' on {args.host}:{port}", flush=True)
    try:
        while True:
            time.sleep(1.0)
    except KeyboardInterrupt:
        p.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
