#!/usr/bin/env bash
# probe/sim/run-all.sh —— 一条命令跑完 P0-B 协议级仿真
#
#   ./run-all.sh            # 快速档（6 profile，B2=45s，约 5 分钟）
#   ./run-all.sh --soak     # 追加 5 分钟长连接档（standard + direct，约 11 分钟）
#
# 报告落 reports/，stdout 落 logs/。退出码：所有 profile 的 overall=pass 才 0。
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p reports logs
TAG=fast
if [[ "${1:-}" == "--soak" ]]; then
  TAG=soak
  echo "[run-all] soak: B2=300s, 只跑 standard + direct"
  python3 bench.py --tag soak --profiles standard,direct \
    --b1-requests 50 --b2-seconds 300 --b3-bytes 1048576 --b3-frame 65536 \
    --b3-payloads random,tui --b4-cycles 2 | tee "logs/soak.log"
else
  python3 bench.py --tag fast \
    --profiles direct,standard,tinybuf,laggy,lossy,nohalf \
    --b1-requests 200 --b2-seconds 45 --b3-bytes 1048576 --b3-frame 65536 \
    --b3-payloads random,tui --b4-cycles 3 | tee "logs/fast.log"
fi

python3 - "$TAG" <<'PY'
import json, sys
tag = sys.argv[1]
d = json.load(open(f"reports/latest-{tag}.json"))
bad = [p["profile"] for p in d["profiles"]
       if p.get("verdict", {}).get("overall") != "pass"]
print("\n[run-all] profiles:", ", ".join(p["profile"] for p in d["profiles"]))
print("[run-all] not-pass :", bad or "none")
sys.exit(1 if bad else 0)
PY
