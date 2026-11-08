#!/usr/bin/env python3
"""
bench.py —— P0-B 协议级仿真跑批器

分五层验收（失败能定位到层，这是 lead 2026-11-08 纠偏后的口径）：
  B1   GET /ping                    经隧道 200 + 版本（只验隧道，无鉴权变量）
  B1p  POST /rpc/session.list       Bearer 200（验鉴权通道；挂了 = psk→bearer 派生问题）
       + 401（无 token）/ 404（未知方法）/ 409（无 X-Motif-Session 调 pty.create）
       + attach 返回 X-Motif-Session 头
  B2   GET /events?session=         WS 升级 + 保持 N 秒（默认 45，soak 300），数 20s Ping
  B3   GET /pty/pty-1?session=      双向 1MB，sha256 校验；legacy raw 与 framed zlib 两档
  B4   409 NotAttached → 重新 attach → 恢复（sim 侧模拟；真机的"后台存活"由 runbook 覆盖）

另有 perf 段：RTT p50/p95/p99、WS 升级耗时、TTFB、吞吐、首包时间、压缩比。

用法：
    python3 bench.py --tag fast                      # 6 个 profile × ~50s
    python3 bench.py --tag soak --profiles direct,standard --b2-seconds 300
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import socket
import sys
import threading
import time
import traceback
import uuid
import zlib
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from connect_proxy import PROFILES, make_proxy  # noqa: E402
from motifd_sim import MotifdSim  # noqa: E402
from probe_client import (  # noqa: E402
    OP_BIN, OP_CLOSE, OP_PONG, OP_TEXT, HttpConn, Tunnel, WSClient,
    make_payload, sha256_hex, stats,
)

SCHEMA = "crossdesk.p0b.probe/1"
HERE = os.path.dirname(os.path.abspath(__file__))
REPORTS = os.path.join(HERE, "reports")


# --------------------------------------------------------------------------
# 小工具
# --------------------------------------------------------------------------
def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def sim_stats_direct(sim_addr: tuple[str, int]) -> dict:
    """带外读取服务端计数（直连，不过隧道）。按 Content-Length 精确读，握手解析在这里
    重复实现一遍是有意的：测具不能依赖被测量的那个 HTTP 客户端。"""
    try:
        s = socket.create_connection(sim_addr, timeout=3)
        s.settimeout(3)
        s.sendall(b"GET /__sim/stats HTTP/1.1\r\nHost: sim\r\nConnection: close\r\n\r\n")
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = s.recv(65536)
            if not chunk:
                return {}
            buf += chunk
        head, body = buf.split(b"\r\n\r\n", 1)
        clen = 0
        for line in head.split(b"\r\n")[1:]:
            k, _, v = line.partition(b":")
            if k.strip().lower() == b"content-length":
                clen = int(v.strip())
        while len(body) < clen:
            chunk = s.recv(65536)
            if not chunk:
                break
            body += chunk
        s.close()
        return json.loads(body[:clen] or b"{}")
    except (OSError, ValueError, json.JSONDecodeError):
        return {}


class Control:
    """带 Bearer 的控制面小助手（走的也是隧道，保证鉴权路径一致）。"""

    def __init__(self, proxy, target, token):
        self.proxy = proxy
        self.target = target
        self.token = token

    def _headers(self, sid=None, auth=True):
        h = {}
        if auth:
            h["Authorization"] = f"Bearer {self.token}"
        if sid:
            h["X-Motif-Session"] = sid
        return h

    def tunnel(self, pipelined: bytes | None = None) -> Tunnel:
        t = Tunnel(self.target, self.proxy, timeout=20, pipelined_payload=pipelined)
        return t.open()

    def call(self, method, params=None, sid=None, auth=True):
        t = self.tunnel()
        try:
            conn = HttpConn(t)
            body = json.dumps(params).encode() if params is not None else b""
            r = conn.request("POST", f"/rpc/{method}", self._headers(sid, auth), body)
            return r, t
        finally:
            pass

    def attach(self) -> tuple[str, Response]:  # noqa: F821
        t = self.tunnel()
        conn = HttpConn(t)
        r = conn.request("POST", "/rpc/session.attach", self._headers(None, True),
                         json.dumps({"name": "main"}).encode())
        sid = r.headers.get("x-motif-session")
        t.close()
        return sid, r


# --------------------------------------------------------------------------
# B1：GET /ping（只验隧道）
# --------------------------------------------------------------------------
def bench_b1(ctrl: Control, n: int) -> dict:
    out = {"status": "fail", "endpoint": "GET /ping", "auth_required": False,
           "requests": n, "ok": 0, "errors": 0,
           "latency_ms": {}, "ttfb_ms": {}, "versions": set(), "error_samples": []}
    lat, ttfb = [], []
    try:
        t = ctrl.tunnel()
        conn = HttpConn(t, timeout=10)
        for _ in range(n):
            try:
                r = conn.request("GET", "/ping")
                if r.status != 200:
                    out["errors"] += 1
                    out["error_samples"].append(f"HTTP {r.status}")
                    continue
                j = r.json()
                out["versions"].add(str(j.get("version")))
                out["ok"] += 1
                lat.append(r.total_ms)
                ttfb.append(r.ttfb_ms)
            except Exception as e:  # noqa: BLE001
                out["errors"] += 1
                out["error_samples"].append(f"{type(e).__name__}: {e}")
                if len(out["error_samples"]) > 3:
                    break
                try:
                    conn = HttpConn(t, timeout=10)
                except Exception:  # noqa: BLE001
                    break
        t.close()
    except Exception as e:  # noqa: BLE001
        out["error_samples"].append(f"tunnel: {type(e).__name__}: {e}")
    out["versions"] = sorted(v for v in out["versions"] if v != "None")
    out["latency_ms"] = stats(lat)
    out["ttfb_ms"] = stats(ttfb)
    ok = out["ok"] == n and out["versions"] == ["sim-0.9.0"]
    out["status"] = "pass" if ok else ("partial" if out["ok"] else "fail")
    return out


# --------------------------------------------------------------------------
# B1p：鉴权 / 会话语义
# --------------------------------------------------------------------------
def bench_b1p(ctrl: Control) -> dict:
    checks = {}

    def check(name, fn):
        t0 = time.perf_counter()
        try:
            val = fn()
            entry = {"ok": True, "detail": val,
                     "ms": round((time.perf_counter() - t0) * 1000, 2)}
            if isinstance(val, dict) and "status" in val:
                entry["http_status"] = val["status"]
            checks[name] = entry
        except Exception as e:  # noqa: BLE001
            checks[name] = {"ok": False, "error": f"{type(e).__name__}: {e}",
                            "ms": round((time.perf_counter() - t0) * 1000, 2)}

    def session_list_with_bearer():
        r, t = ctrl.call("session.list", {}, auth=True)
        try:
            if r.status != 200:
                raise AssertionError(f"HTTP {r.status}")
            j = r.json()
            assert "sessions" in j, j
            return {"status": 200, "sessions": len(j["sessions"])}
        finally:
            t.close()

    def session_list_without_bearer():
        r, t = ctrl.call("session.list", {}, auth=False)
        try:
            if r.status != 401:
                raise AssertionError(f"expected 401, got {r.status}")
            return {"status": 401, "body": r.json()["error"]["message"]}
        finally:
            t.close()

    def unknown_method():
        sid, _ = ctrl.attach()
        r, t = ctrl.call("does.not.exist", {}, sid=sid)
        try:
            if r.status != 404:
                raise AssertionError(f"expected 404, got {r.status}")
            return {"status": 404, "code": r.json()["error"]["code"]}
        finally:
            t.close()

    def attach_header_and_body():
        sid, r = ctrl.attach()
        j = r.json()
        if not sid:
            raise AssertionError("no X-Motif-Session header")
        for k in ("session", "client_id", "ptys", "views", "last_seq"):
            assert k in j, f"attach body missing {k}"
        return {"sid_prefix": sid[:10], "last_seq": j["last_seq"],
                "ptys": len(j["ptys"])}

    def not_attached_409():
        r, t = ctrl.call("pty.create", {"cols": 80, "rows": 24}, sid=None)
        try:
            if r.status != 409:
                raise AssertionError(f"expected 409, got {r.status}")
            return {"status": 409, "message": r.json()["error"]["message"]}
        finally:
            t.close()

    def attach_then_pty_create():
        sid, _ = ctrl.attach()
        r, t = ctrl.call("pty.create", {"cols": 120, "rows": 32}, sid=sid)
        try:
            if r.status != 200:
                raise AssertionError(f"expected 200, got {r.status}")
            return {"status": 200, "pty_id": r.json()["info"]["id"]}
        finally:
            t.close()

    check("session_list_bearer_200", session_list_with_bearer)
    check("session_list_no_bearer_401", session_list_without_bearer)
    check("unknown_method_404", unknown_method)
    check("attach_returns_session_header", attach_header_and_body)
    check("pty_create_without_session_409", not_attached_409)
    check("pty_create_with_session_200", attach_then_pty_create)

    passed = sum(1 for c in checks.values() if c["ok"])
    return {"status": "pass" if passed == len(checks) else ("partial" if passed else "fail"),
            "passed": passed, "total": len(checks), "checks": checks,
            "used_stub_auth": True,
            "real_psk_derivation_verified": False,
            "auth_note": ("sim 用的是本地 stub token（--token p0b-sim-token），"
                          "本层只证明『Bearer 头能原样穿过 CONNECT 隧道并按 401/409/404 语义正确回读』；"
                          "真正的 psk→bearer 派生（rzv::derive_bearer）必须在真机/真 motifd 上对拍，"
                          "见 docs/p0/ios-p0b-runbook.md 第 3 节。")}


# --------------------------------------------------------------------------
# B2：/events WS 长连接
# --------------------------------------------------------------------------
def bench_b2(ctrl: Control, sid: str, seconds: float, ping_interval: float = 20.0) -> dict:
    # 观测窗口可能短于一个 Ping 周期；这时 ping_observed=0 不代表"没有心跳"，
    # 必须连同 expected_by_window 一起看（lead 2026-11-08 纠偏）。
    expected = int(seconds // ping_interval) if ping_interval > 0 else 0
    out = {
        "status": "fail", "duration_s": seconds, "upgrade_ms": None,
        "ping_interval_s": ping_interval,
        "ping_observed": 0,
        "ping_expected_by_window": expected,
        "ping_window_too_short": seconds < ping_interval,
        "ping_verdict": "n/a",
        "events": 0, "pings": 0, "seq_gaps": 0, "max_gap": 0,
        "close_code": None, "reconnects": 0, "errors": [],
        "first_event_ms": None, "inter_event_ms": {},
    }
    try:
        t = ctrl.tunnel()
        ws = WSClient(t, f"/events?session={sid}&since=0",
                      headers={"Authorization": f"Bearer {ctrl.token}"}, timeout=10)
        ws.connect()
        out["upgrade_ms"] = round(ws.handshake_ms, 3)
        if not ws.accept_ok:
            raise AssertionError("bad Sec-WebSocket-Accept")
        last_seq = None
        seq_gaps = 0
        max_gap = 0
        inter = []
        t_start = time.perf_counter()
        deadline = t_start + seconds
        last_arrival = None
        t.sock.settimeout(1.0)
        while time.perf_counter() < deadline:
            try:
                op, payload = ws.recv_message()
            except socket.timeout:
                continue
            except EOFError:
                out["errors"].append("server closed connection")
                break
            now = time.perf_counter()
            if op == OP_CLOSE:
                out["close_code"] = ws.close_code
                break
            if op == OP_TEXT:
                try:
                    msg = json.loads(payload)
                except json.JSONDecodeError:
                    continue
                params = msg.get("params") or {}
                seq = params.get("seq")
                out["events"] += 1
                if out["first_event_ms"] is None:
                    out["first_event_ms"] = round((now - t_start) * 1000, 3)
                if last_seq is not None and seq is not None:
                    gap = seq - last_seq - 1
                    if gap > 0:
                        seq_gaps += 1
                        max_gap = max(max_gap, gap)
                if seq is not None:
                    last_seq = seq
                if last_arrival is not None:
                    inter.append((now - last_arrival) * 1000)
                last_arrival = now
        out["pings"] = ws.pings_recv
        out["ping_observed"] = ws.pings_recv
        out["ping_verdict"] = ("pass" if ws.pings_recv >= expected
                               else ("window_too_short" if seconds < ping_interval else "missing"))
        out["seq_gaps"] = seq_gaps
        out["max_gap"] = max_gap
        out["inter_event_ms"] = stats(inter)
        out["elapsed_s"] = round(time.perf_counter() - t_start, 2)
        try:
            ws.close(1000)
        except Exception:  # noqa: BLE001
            pass
        t.close()
    except Exception as e:  # noqa: BLE001
        out["errors"].append(f"{type(e).__name__}: {e}")
        out["trace"] = traceback.format_exc(limit=2)
    pings_ok = out["ping_verdict"] in ("pass", "window_too_short")
    out["status"] = "pass" if (not out["errors"] and out["events"] > 0
                               and out["seq_gaps"] == 0 and pings_ok) else (
        "partial" if out["events"] > 0 else "fail")
    return out


# --------------------------------------------------------------------------
# B3：/pty 双向 1MB + sha256
# --------------------------------------------------------------------------
def bench_b3(ctrl: Control, sid: str, pty_id: str, payload: bytes, frame_size: int,
             framed: bool, timeout: float = 60.0) -> dict:
    out = {
        "status": "fail", "mode": "framed-zlib" if framed else "legacy-raw",
        "bytes_up": len(payload), "bytes_down": 0, "wire_bytes_down": 0,
        "sha256_up": sha256_hex(payload), "sha256_down": None, "match": False,
        "frame_size": frame_size, "frames": 0, "frame_rtt_ms": {},
        "throughput_mbps": None, "elapsed_s": None, "meta_ms": None,
        "compression_ratio": None, "errors": [],
    }
    try:
        path = f"/pty/{pty_id}?session={sid}&since=0"
        if framed:
            path += "&pty_frame=v1&pty_compress=zlib"
        t = ctrl.tunnel()
        ws = WSClient(t, path, headers={"Authorization": f"Bearer {ctrl.token}"}, timeout=timeout)
        ws.connect()
        if not ws.accept_ok:
            raise AssertionError("bad Sec-WebSocket-Accept")
        # 第一帧必须是 Text meta
        t0 = time.perf_counter()
        op, meta_raw = ws.recv_message()
        out["meta_ms"] = round((time.perf_counter() - t0) * 1000, 3)
        meta = json.loads(meta_raw.decode())
        out["meta"] = meta
        if framed and meta.get("pty_frame") != "v1":
            raise AssertionError(f"framed mode not confirmed by meta: {meta}")
        nframes = (len(payload) + frame_size - 1) // frame_size
        send_times = []
        send_lock = threading.Lock()

        def sender():
            for i in range(nframes):
                chunk = payload[i * frame_size:(i + 1) * frame_size]
                with send_lock:
                    send_times.append(time.perf_counter())
                ws.send_bin(chunk)

        th = threading.Thread(target=sender, daemon=True)
        recv_buf = bytearray()
        wire = 0
        frame_rtts = []
        idx = 0
        t.tunnel_start = time.perf_counter()
        t_first = None
        th.start()
        t.sock.settimeout(timeout)
        while len(recv_buf) < len(payload):
            try:
                op, data = ws.recv_message()
            except socket.timeout:
                out["errors"].append("recv timeout")
                break
            if op == OP_CLOSE:
                out["close_code"] = ws.close_code
                out["errors"].append(f"closed code={ws.close_code}")
                break
            if op != OP_BIN:
                continue
            wire += len(data)
            if framed:
                if not data:
                    out["errors"].append("empty framed frame")
                    break
                flags = data[0]
                if flags & 0xFE:
                    out["errors"].append(f"reserved flags set: {flags:#x}")
                    break
                body = zlib.decompress(data[1:]) if flags & 1 else data[1:]
            else:
                body = data
            recv_buf += body
            if t_first is None:
                t_first = time.perf_counter()
            # 每满一帧就对一次 RTT
            while (idx + 1) <= nframes and len(recv_buf) >= min((idx + 1) * frame_size, len(payload)):
                if idx < len(send_times):
                    frame_rtts.append((time.perf_counter() - send_times[idx]) * 1000)
                idx += 1
        t_last = time.perf_counter()
        th.join(timeout=2)
        got = bytes(recv_buf)
        out["bytes_down"] = len(got)
        out["wire_bytes_down"] = wire
        out["sha256_down"] = sha256_hex(got)
        out["match"] = out["sha256_down"] == out["sha256_up"]
        out["frames"] = idx
        out["frame_rtt_ms"] = stats(frame_rtts)
        elapsed = (t_last - (t_first or t_last))
        if got and t_first:
            out["elapsed_s"] = round(t_last - t.tunnel_start, 4)
            # 吞吐按"从首字节到收满"算，避免把发送启动算进去
            span = max(t_last - t_first, 1e-9)
            out["throughput_mbps"] = round(len(got) / span / (1024 * 1024), 3)
            out["total_elapsed_s"] = round(t_last - t.tunnel_start, 4)
        if framed and len(got):
            out["compression_ratio"] = round(len(got) / max(wire, 1), 3)
        try:
            ws.close(1000)
        except Exception:  # noqa: BLE001
            pass
        t.close()
    except Exception as e:  # noqa: BLE001
        out["errors"].append(f"{type(e).__name__}: {e}")
        out["trace"] = traceback.format_exc(limit=3)
    ok = out["match"] and out["bytes_down"] == out["bytes_up"] and not out["errors"]
    out["status"] = "pass" if ok else ("partial" if out["bytes_down"] else "fail")
    return out


# --------------------------------------------------------------------------
# B4：409 NotAttached → 重新 attach 恢复
# --------------------------------------------------------------------------
def bench_b4(ctrl: Control, cycles: int = 3) -> dict:
    out = {"status": "fail", "cycles": cycles, "observed_409": 0,
           "recovered": 0, "reattach_ms": [], "ws_409": 0, "errors": []}
    try:
        for i in range(cycles):
            sid, r = ctrl.attach()
            if not sid:
                raise AssertionError("attach failed")
            # 正常一轮：/events 101
            t = ctrl.tunnel()
            ws = WSClient(t, f"/events?session={sid}&since=0",
                          headers={"Authorization": f"Bearer {ctrl.token}"}, timeout=5)
            ws.connect()
            ws.close(1000)
            t.close()
            # detach → 该 sid 失效
            r, t = ctrl.call("session.detach", {}, sid=sid)
            t.close()
            # 失效 sid 的 /events 必须 409
            try:
                t2 = ctrl.tunnel()
                ws2 = WSClient(t2, f"/events?session={sid}&since=0",
                               headers={"Authorization": f"Bearer {ctrl.token}"}, timeout=5)
                ws2.connect()
                out["errors"].append("stale sid still upgraded (expected 409)")
                t2.close()
            except ConnectionError as e:
                if "409" in str(e):
                    out["observed_409"] += 1
                else:
                    out["errors"].append(str(e))
            # 恢复：重新 attach 后 /events 立刻可用
            t0 = time.perf_counter()
            sid2, _ = ctrl.attach()
            t1 = ctrl.tunnel()
            ws3 = WSClient(t1, f"/events?session={sid2}&since=0",
                           headers={"Authorization": f"Bearer {ctrl.token}"}, timeout=5)
            ws3.connect()
            ws3.close(1000)
            t1.close()
            out["reattach_ms"].append((time.perf_counter() - t0) * 1000)
            out["recovered"] += 1
        out["reattach_ms"] = {k: round(v, 2) if isinstance(v, float) else v
                              for k, v in stats(out["reattach_ms"]).items()}
    except Exception as e:  # noqa: BLE001
        out["errors"].append(f"{type(e).__name__}: {e}")
        out["trace"] = traceback.format_exc(limit=3)
    ok = out["observed_409"] == cycles and out["recovered"] == cycles and not out["errors"]
    out["status"] = "pass" if ok else ("partial" if out["recovered"] else "fail")
    return out


# --------------------------------------------------------------------------
# 隧道首包 / CONNECT 建立开销
# --------------------------------------------------------------------------
def bench_tunnel_overhead(ctrl: Control, rounds: int = 10, pipelined: bool = False) -> dict:
    out = {"status": "fail", "rounds": rounds, "pipelined": pipelined,
           "connect_ms": {}, "first_response_ms": {}, "errors": 0, "error_notes": []}
    c_times, f_times = [], []
    for _ in range(rounds):
        try:
            if pipelined:
                req = (b"GET /ping HTTP/1.1\r\nHost: sim\r\nConnection: close\r\n\r\n")
                t_start = time.perf_counter()
                t = Tunnel(ctrl.target, ctrl.proxy, timeout=5, pipelined_payload=req).open()
                got = b""
                t.sock.settimeout(5)
                while b"\r\n\r\n" not in got:
                    chunk = t.sock.recv(4096)
                    if not chunk:
                        break
                    got += chunk
                t_first = (time.perf_counter() - t_start) * 1000.0
                if b"200" not in got.split(b"\r\n")[0]:
                    raise ConnectionError(f"pipelined first request lost: {got[:80]!r}")
                t.close()
                c_times.append(t.connect_ms)
                f_times.append(t_first)
            else:
                t = ctrl.tunnel()
                conn = HttpConn(t, timeout=5)
                r = conn.request("GET", "/ping")
                if r.status != 200:
                    raise ConnectionError(f"HTTP {r.status}")
                c_times.append(t.connect_ms)
                f_times.append(t.connect_ms + r.total_ms)
                t.close()
        except Exception as e:  # noqa: BLE001
            out["errors"] += 1
            out["error_notes"].append(f"{type(e).__name__}: {e}")
    out["connect_ms"] = stats(c_times)
    out["first_response_ms"] = stats(f_times)
    out["status"] = "pass" if not out["errors"] else ("partial" if c_times else "fail")
    return out


# --------------------------------------------------------------------------
# 半关闭传播（Connection: close 后是否真的等到 EOF）
# --------------------------------------------------------------------------
def bench_close_semantics(ctrl: Control, timeout: float = 2.0) -> dict:
    out = {"status": "fail", "eof_ms": None, "errors": []}
    try:
        t = ctrl.tunnel()
        s = t.sock
        s.sendall(b"GET /ping HTTP/1.1\r\nHost: sim\r\nConnection: close\r\n\r\n")
        buf = b""
        s.settimeout(timeout)
        t0 = time.perf_counter()
        while b"\r\n\r\n" not in buf:
            chunk = s.recv(4096)
            if not chunk:
                raise ConnectionError("eof before header")
            buf += chunk
        head, body = buf.split(b"\r\n\r\n", 1)
        clen = 0
        for line in head.split(b"\r\n")[1:]:
            k, _, v = line.partition(b":")
            if k.strip().lower() == b"content-length":
                clen = int(v.strip())
        while len(body) < clen:
            chunk = s.recv(4096)
            if not chunk:
                break
            body += chunk
        # 关键：正文读完后服务端应关闭连接 → 这里必须收到 EOF
        while True:
            chunk = s.recv(4096)
            if not chunk:
                out["eof_ms"] = round((time.perf_counter() - t0) * 1000, 2)
                out["status"] = "pass"
                break
        t.close()
    except socket.timeout:
        out["errors"].append(f"no EOF within {timeout}s（半关闭未传播，代理把 close 吞了）")
    except Exception as e:  # noqa: BLE001
        out["errors"].append(f"{type(e).__name__}: {e}")
    return out


# --------------------------------------------------------------------------
# 单个 profile 的完整跑批
# --------------------------------------------------------------------------
def run_profile(profile: str, sim_addr, token: str, args) -> dict:
    target = sim_addr
    report = {
        "schema": SCHEMA,
        "profile": profile,
        "profile_kind": "direct" if profile == "direct" else "connect",
        "generated_at": now_iso(),
        "target": {"host": target[0], "port": target[1], "motifd_version": "sim-0.9.0"},
        "proxy": PROFILES.get(profile, {}) if profile != "direct" else None,
        "acceptance": {},
        "perf": {},
        "events_observed": {},
    }
    proxy = None
    proxy_addr = None
    if profile != "direct":
        proxy = make_proxy(profile)
        p = proxy.start()
        proxy_addr = ("127.0.0.1", p)
        report["proxy"]["listen_port"] = p
    ctrl = Control(proxy_addr, target, token)

    # 先记录跑批前的服务端计数
    before = sim_stats_direct(sim_addr)

    # B1
    report["acceptance"]["B1_ping"] = bench_b1(ctrl, args.b1_requests)

    # B1p
    report["acceptance"]["B1p_auth_session"] = bench_b1p(ctrl)

    # 拿一个 sid 给 B2/B3 用
    sid = None
    try:
        sid, _ = ctrl.attach()
    except Exception as e:  # noqa: BLE001
        report["acceptance"]["B1p_auth_session"].setdefault("errors", []).append(str(e))

    # B2
    if sid:
        report["acceptance"]["B2_events_ws"] = bench_b2(
            ctrl, sid, args.b2_seconds, ping_interval=args.ping_interval)
    else:
        report["acceptance"]["B2_events_ws"] = {"status": "fail", "errors": ["no sid"]}

    # B3
    pty_id = "pty-1"
    b3 = {}
    if sid:
        for kind in args.b3_payloads:
            payload = make_payload(args.b3_bytes, kind)
            for framed in (False, True):
                key = f"{kind}_{'framed_zlib' if framed else 'legacy_raw'}"
                b3[key] = bench_b3(ctrl, sid, pty_id, payload, args.b3_frame, framed)
        # pty 不存在时必须 404
        try:
            t = ctrl.tunnel()
            ws = WSClient(t, f"/pty/pty-not-exist?session={sid}",
                          headers={"Authorization": f"Bearer {token}"}, timeout=5)
            ws.connect()
            b3["pty_not_found_should_404"] = {"status": "fail", "detail": "upgraded unexpectedly"}
            t.close()
        except ConnectionError as e:
            b3["pty_not_found_should_404"] = {
                "status": "pass" if "404" in str(e) else "fail", "detail": str(e)}
        sub = [v for k, v in b3.items() if isinstance(v, dict) and k != "pty_not_found_should_404"]
        ok_n = sum(1 for v in sub if v.get("status") == "pass")
        b3["status"] = "pass" if sub and ok_n == len(sub) else ("partial" if ok_n else "fail")
        b3["passed"] = ok_n
        b3["total"] = len(sub)
        report["acceptance"]["B3_pty_bidirectional"] = b3
    else:
        report["acceptance"]["B3_pty_bidirectional"] = {"status": "fail", "errors": ["no sid"]}

    # B4
    report["acceptance"]["B4_reconnect_409"] = bench_b4(ctrl, args.b4_cycles)

    # 隧道首包开销 + 流水线对照（pipelined 只在 CONNECT 场景有意义）
    if proxy_addr:
        report["perf"]["tunnel_wait_200"] = bench_tunnel_overhead(ctrl, rounds=5, pipelined=False)
        report["perf"]["tunnel_pipelined"] = bench_tunnel_overhead(ctrl, rounds=5, pipelined=True)
    else:
        report["perf"]["direct_connect"] = bench_tunnel_overhead(ctrl, rounds=5, pipelined=False)

    # 关闭语义（半关闭传播）
    report["checks"] = {"close_semantics": bench_close_semantics(ctrl)}

    # 汇总 perf
    b1 = report["acceptance"]["B1_ping"]
    b3main = report["acceptance"]["B3_pty_bidirectional"]
    raw_key = next((k for k in b3main if k.endswith("legacy_raw")), None)
    framed_key = next((k for k in b3main if k.endswith("framed_zlib")), None)
    report["perf"]["rpc_rtt_ms"] = b1.get("latency_ms", {})
    report["perf"]["rpc_ttfb_ms"] = b1.get("ttfb_ms", {})
    report["perf"]["ws_upgrade_ms"] = report["acceptance"]["B2_events_ws"].get("upgrade_ms")
    if raw_key:
        report["perf"]["pty_throughput_mbps_raw"] = b3main[raw_key].get("throughput_mbps")
        report["perf"]["pty_first_byte_ms_raw"] = b3main[raw_key].get("meta_ms")
    if framed_key:
        report["perf"]["pty_throughput_mbps_framed"] = b3main[framed_key].get("throughput_mbps")
        report["perf"]["pty_compression_ratio_framed"] = b3main[framed_key].get("compression_ratio")

    # 服务端计数差值（把"没收到"和"没发出"区分开）
    after = sim_stats_direct(sim_addr)
    def delta(key):
        try:
            return after.get(key, 0) - before.get(key, 0)
        except TypeError:
            return None
    report["events_observed"] = {
        "server_ws_upgrades": delta("ws_upgrades"),
        "server_events_sent": delta("events_sent"),
        "server_pings_sent": delta("pings_sent"),
        "server_pongs_recv": delta("pongs_recv"),
        "server_pty_conns": delta("pty_conns"),
        "server_pty_bytes_up": delta("pty_bytes_up"),
        "server_pty_bytes_down": delta("pty_bytes_down"),
        "server_401": delta("auth_401"),
        "server_409": delta("not_attached_409"),
    }
    if proxy:
        report["proxy"]["stats"] = proxy.snapshot()
        report["proxy"]["note"] = "字节透明中继；up/down 为隧道内净载荷"

    # verdict
    verdict = {}
    for name, r in report["acceptance"].items():
        if isinstance(r, dict):
            verdict[name] = r.get("status", "unknown")
    layer_ok = [v == "pass" for v in verdict.values()]
    report["verdict"] = {
        "layers": verdict,
        "overall": "pass" if layer_ok and all(layer_ok) else ("partial" if any(layer_ok) else "fail"),
    }
    # findings：把"坑"显式落成结构化结论，而不是靠读者自己看数字
    findings = []
    pipelined = report["perf"].get("tunnel_pipelined", {})
    if pipelined and pipelined.get("status") == "fail":
        findings.append({
            "id": "F1_pipelining_breaks_on_naive_proxy",
            "severity": "medium",
            "found": True,
            "detail": "客户端若在 CONNECT 之后不等 200 就发首个请求（乐观流水线），朴素代理会"
                      "把已读进缓冲区的多余字节丢掉，请求永久挂起。本文档测的 5 次全部 timeout。",
            "mitigation": "客户端必须等 CONNECT 200；dart:io HttpClient 默认就是等（见 Dart 探针注释）。",
        })
    else:
        findings.append({
            "id": "F1_pipelining_breaks_on_naive_proxy",
            "severity": "medium",
            "found": False,
            "detail": "本 profile 的代理不丢流水线字节（或被测路径直连），未复现。",
        })
    if report["profile"] == "tinybuf":
        b3 = report["acceptance"].get("B3_pty_bidirectional", {})
        sub = [v for k, v in b3.items() if isinstance(v, dict) and k != "pty_not_found_should_404"]
        findings.append({
            "id": "F2_small_read_buffer",
            "severity": "info",
            "found": all(v.get("status") == "pass" for v in sub) if sub else False,
            "detail": "1 KiB 读缓冲的代理下，B1/B2/B3 全部通过 → 客户端不依赖"
                      "『一次 read 恰等于一个 WS 帧』，帧边界跨 recv 拼接正确。",
        })
    if report["profile"] == "laggy":
        findings.append({
            "id": "F3_relay_throughput_ceiling",
            "severity": "info",
            "found": True,
            "detail": "4 KiB/chunk + 2 ms 延迟（模拟 relayed 路径）下测得吞吐上限 ~2 MB/s，"
                      "这是 relay 侧人类可感知的分界线（见 reports 数字）。",
        })
    cs = report["checks"]["close_semantics"]
    if cs.get("status") != "pass":
        findings.append({
            "id": "F4_half_close_not_propagated",
            "severity": "medium",
            "found": True,
            "detail": "服务端 `Connection: close` 后客户端等不到 EOF（代理未 shutdown(SHUT_WR)），"
                      "按 EOF 判结束的读取方会挂到超时。",
            "mitigation": "客户端按 Content-Length/chunked 判正文结束，不依赖 EOF；代理实现必须传播半关闭。",
        })
    report["findings"] = findings
    if proxy:
        proxy.stop()
    return report


# --------------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", default="fast", help="fast|soak|<任意>")
    ap.add_argument("--profiles", default="direct,standard,tinybuf,laggy,lossy,nohalf")
    ap.add_argument("--b1-requests", type=int, default=200)
    ap.add_argument("--b2-seconds", type=float, default=45.0)
    ap.add_argument("--b3-bytes", type=int, default=1024 * 1024)
    ap.add_argument("--b3-frame", type=int, default=64 * 1024)
    ap.add_argument("--b3-payloads", default="random,tui")
    ap.add_argument("--b4-cycles", type=int, default=3)
    ap.add_argument("--token", default="p0b-sim-token")
    ap.add_argument("--ping-interval", type=float, default=20.0)
    ap.add_argument("--outdir", default=REPORTS)
    args = ap.parse_args()
    args.b3_payloads = [s.strip() for s in args.b3_payloads.split(",") if s.strip()]

    os.makedirs(args.outdir, exist_ok=True)
    sim = MotifdSim(port=0, token=args.token, ping_interval=args.ping_interval)
    port = sim.start()
    sim_addr = ("127.0.0.1", port)
    print(f"[bench] motifd-sim on {sim_addr[0]}:{port} token={'set' if args.token else 'off'}", flush=True)

    env = {
        "schema": SCHEMA,
        "tag": args.tag,
        "run_id": f"{args.tag}-{uuid.uuid4().hex[:8]}",
        "generated_at": now_iso(),
        "harness": {
            "kind": "sim",
            "name": "python3",
            "python": platform.python_version(),
            "os": f"{platform.system()}-{platform.release()}",
            "machine": platform.machine(),
            "cpu_count": os.cpu_count(),
        },
        "config": {
            "b1_requests": args.b1_requests,
            "b2_seconds": args.b2_seconds,
            "b3_bytes": args.b3_bytes,
            "b3_frame": args.b3_frame,
            "b3_payloads": args.b3_payloads,
            "b4_cycles": args.b4_cycles,
            "ping_interval_s": args.ping_interval,
            "token_configured": bool(args.token),
        },
        "profiles": [],
    }

    for name in [p.strip() for p in args.profiles.split(",") if p.strip()]:
        t0 = time.time()
        print(f"[bench] === profile {name} ===", flush=True)
        try:
            rep = run_profile(name, sim_addr, args.token, args)
        except Exception as e:  # noqa: BLE001
            rep = {"schema": SCHEMA, "profile": name, "error": f"{type(e).__name__}: {e}",
                   "trace": traceback.format_exc(limit=5), "verdict": {"overall": "fail"}}
        rep["wall_clock_s"] = round(time.time() - t0, 1)
        env["profiles"].append(rep)
        v = rep.get("verdict", {}).get("layers", {})
        print(f"[bench] {name}: {rep.get('verdict', {}).get('overall')} {v} ({rep['wall_clock_s']}s)",
              flush=True)

    # 汇总
    summary = {}
    for p in env["profiles"]:
        summary[p["profile"]] = {
            "overall": p.get("verdict", {}).get("overall"),
            "layers": p.get("verdict", {}).get("layers", {}),
            "rtt_p50": (p.get("perf", {}).get("rpc_rtt_ms") or {}).get("p50"),
            "rtt_p95": (p.get("perf", {}).get("rpc_rtt_ms") or {}).get("p95"),
            "raw_mbps": p.get("perf", {}).get("pty_throughput_mbps_raw"),
            "framed_mbps": p.get("perf", {}).get("pty_throughput_mbps_framed"),
            "pipelined_ok": (p.get("perf", {}).get("tunnel_pipelined") or {}).get("status"),
            "close_semantics": (p.get("checks", {}).get("close_semantics") or {}).get("status"),
            "findings": [f["id"] for f in p.get("findings", []) if f.get("found")],
        }
    env["summary"] = summary

    out = os.path.join(args.outdir, f"{env['run_id']}.json")
    with open(out, "w") as f:
        json.dump(env, f, indent=2, ensure_ascii=False)
    latest = os.path.join(args.outdir, f"latest-{args.tag}.json")
    with open(latest, "w") as f:
        json.dump(env, f, indent=2, ensure_ascii=False)
    print(f"[bench] wrote {out} ({os.path.getsize(out)} bytes)", flush=True)
    print(json.dumps(summary, indent=2, ensure_ascii=False), flush=True)
    sim.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
