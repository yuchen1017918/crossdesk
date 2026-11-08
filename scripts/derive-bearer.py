#!/usr/bin/env python3
"""derive-bearer.py —— 从 motif 的 psk 推导 motifd 要求的 Bearer token。

为什么需要这个：motifd 的网络监听**没有"无 token 逃生口"**（上游
`crates/motif-server/src/config.rs` 注释原话：any network `listen` is set up
with both TLS and a bearer）。而 token 不是 psk 本身，是 psk 经过一次 HKDF 派生
的值——所以拿 psk 必须自己派生。

算法（逐字对齐上游 `crates/motif-server/src/rzv.rs`）：

    HKDF-SHA256(ikm=psk, salt=32 字节 0x00, info=<label>, L=32)
      prk       = HMAC-SHA256(salt, psk)
      T(1)      = HMAC-SHA256(prk, info || 0x01)     # L == HashLen，单块
    bearer      = base64url_nopad(T(1))

    label: AUTH_BEARER_INFO = b"motif-auth-bearer-v1"   ← motifd 鉴权用
           TOKEN_INFO       = b"motif-rzv-token-v1"      ← relay 会合用（与本工具无关）

已验证：与上游 `rzv.rs` 的跨语言固定向量逐字节一致（`--self-test` 会复核）。

用法：
    python3 derive-bearer.py --self-test
    python3 derive-bearer.py --pair-uri 'motif://pair?v=1&host=...&port=7777&psk=...'
    python3 derive-bearer.py --psk-b64url <psk>
    python3 derive-bearer.py --psk-hex <64 位 hex>
    python3 derive-bearer.py --pair-uri '...' --json      # 给脚本吃

安全：psk 是密钥。本工具不落盘、不打日志；`--json` 输出里的 psk 字段默认脱敏。
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import sys
from urllib.parse import parse_qs, urlparse

AUTH_BEARER_INFO = b"motif-auth-bearer-v1"
TOKEN_INFO = b"motif-rzv-token-v1"

# 上游 rzv.rs tests::bearer_derivation_is_stable_and_distinct 的固定向量
VEC_PSK = bytes(range(32))
VEC_TOKEN_HEX = "bb48b13937710e30c1fffa843593313a7d403c44236eb01d6c86842e43bfa7da"
VEC_BEARER_HEX = "b15f7d9c90b425671f2fd6b31584ad68b3f177a73bbc7e49fbc882505e329ddf"


def b64url_nopad_decode(s: str) -> bytes:
    """base64url（无 padding）解码；容忍客户端把它当普通 base64 传进来。"""
    s = s.strip().replace("-", "+").replace("_", "/")
    s += "=" * (-len(s) % 4)
    return base64.b64decode(s)


def b64url_nopad_encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def hkdf_expand_label(psk: bytes, info: bytes) -> bytes:
    """HKDF-SHA256，salt=32 个 0，L=32（单块 expand）。"""
    prk = hmac.new(b"\x00" * 32, psk, hashlib.sha256).digest()
    return hmac.new(prk, info + b"\x01", hashlib.sha256).digest()


def derive_bearer(psk: bytes) -> bytes:
    return hkdf_expand_label(psk, AUTH_BEARER_INFO)


def bearer_token(psk: bytes) -> str:
    return b64url_nopad_encode(derive_bearer(psk))


def psk_from_pair_uri(uri: str) -> bytes:
    """从 `motif://pair?...&psk=<b64url>` 里取出 32 字节 psk。"""
    parsed = urlparse(uri)
    if not parsed.scheme.startswith("motif"):
        raise ValueError(f"不是 motif:// 链接（scheme={parsed.scheme!r}）")
    q = parse_qs(parsed.query)
    raw = q.get("psk")
    if not raw:
        raise ValueError("链接里没有 psk 参数（是不是二维码只给了 host/port 的直连形态？）")
    psk = b64url_nopad_decode(raw[0])
    if len(psk) != 32:
        raise ValueError(f"psk 解出来 {len(psk)} 字节，期望 32（base64url-nopad 编码的 32 字节）")
    return psk


def self_test() -> int:
    ok = 0
    fail = 0

    t = hkdf_expand_label(VEC_PSK, TOKEN_INFO).hex()
    if t == VEC_TOKEN_HEX:
        ok += 1
        print(f"  PASS  token 向量匹配（{t[:16]}…）")
    else:
        fail += 1
        print(f"  FAIL  token 向量不匹配\n        得到 {t}\n        期望 {VEC_TOKEN_HEX}")

    b = derive_bearer(VEC_PSK).hex()
    if b == VEC_BEARER_HEX:
        ok += 1
        print(f"  PASS  bearer 向量匹配（{b[:16]}…）")
    else:
        fail += 1
        print(f"  FAIL  bearer 向量不匹配\n        得到 {b}\n        期望 {VEC_BEARER_HEX}")

    # bearer 必须与 relay token 不同（不同 HKDF label）
    if derive_bearer(VEC_PSK) != hkdf_expand_label(VEC_PSK, TOKEN_INFO):
        ok += 1
        print("  PASS  bearer 与 relay token 不同（label 隔离生效）")
    else:
        fail += 1
        print("  FAIL  bearer 与 relay token 相同——label 用错了")

    # pair URI 解析
    sample = "motif://pair?v=1&host=192.168.1.9&port=7777&psk=" + b64url_nopad_encode(VEC_PSK)
    if psk_from_pair_uri(sample) == VEC_PSK:
        ok += 1
        print("  PASS  pair URI 解析出正确 psk")
    else:
        fail += 1
        print("  FAIL  pair URI 解析结果不对")

    print(f"\n自检：{ok} 通过 / {fail} 失败")
    return 0 if fail == 0 else 1


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True, description="从 motif psk 推导 motifd Bearer token")
    src = ap.add_mutually_exclusive_group()
    src.add_argument("--pair-uri", help="motif://pair?v=1&...&psk=<b64url>")
    src.add_argument("--psk-b64url", help="psk 的 base64url（无 padding）")
    src.add_argument("--psk-hex", help="psk 的 64 位 hex")
    ap.add_argument("--json", action="store_true", help="输出 JSON（psk 脱敏）")
    ap.add_argument("--self-test", action="store_true", help="用上游固定向量自检")
    ap.add_argument("--show-paired", action="store_true", help="在 pair URI 模式下也打印解析到的 psk（默认不打印）")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    if args.pair_uri:
        psk = psk_from_pair_uri(args.pair_uri)
        source = "pair-uri"
    elif args.psk_b64url:
        psk = b64url_nopad_decode(args.psk_b64url)
        source = "psk-b64url"
    elif args.psk_hex:
        psk = bytes.fromhex(args.psk_hex.strip())
        source = "psk-hex"
    else:
        ap.print_help()
        return 2

    if len(psk) != 32:
        print(f"psk 必须是 32 字节，拿到 {len(psk)}", file=sys.stderr)
        return 2

    bearer = bearer_token(psk)

    if args.json:
        print(json.dumps({
            "source": source,
            "bearer": bearer,
            "bearer_hex": derive_bearer(psk).hex(),
            "psk": b64url_nopad_encode(psk) if args.show_paired else "<redacted>",
            "algorithm": "HKDF-SHA256(psk, salt=0^32, info='motif-auth-bearer-v1', L=32) → base64url-nopad",
        }, ensure_ascii=False, indent=2))
    else:
        print(f"source : {source}")
        print(f"bearer : {bearer}")
        print(f"用法   : motif-probe ... --token {bearer}")
        print("注意   : 这是 psk 的派生值，不是 psk 原文；不要与 relay token 混用")
    return 0


if __name__ == "__main__":
    sys.exit(main())
