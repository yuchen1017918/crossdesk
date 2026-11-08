#!/usr/bin/env bash
# preflight-release.sh —— 发版前闸门（把"靠人记"的三条硬点变成 exit code）
#
# 三条硬点（来源：Lead 收口决策 + docs/licensing/decision.md）：
#   R1  NetBird 四个 AGPLv3 目录的任何字节不得进包          → 任何路径命中即 FAIL
#   R2  一个进程只允许一个 Go runtime                        → 宿主不得链接 motifd / 不得出现第二份 Go
#   R3  随包许可附件齐全（含 ring 的 Apache-2.0 AND ISC）    → 缺附件 = FAIL（不是"许可不对"）
#
# 用法：
#   ./preflight-release.sh --installer-dir dist/win --motif-src ../motif
#   ./preflight-release.sh --self-test          # 用合成目录验证闸门逻辑本身
#
# 退出码：0 全部通过；1 有 FAIL。
set -u

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
FAILS=0; WARNS=0
pass() { printf '  %sPASS%s  %s\n' "$GRN" "$RST" "$1"; }
fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RST" "$1"; FAILS=$((FAILS+1)); }
warn() { printf '  %sWARN%s  %s\n' "$YEL" "$RST" "$1"; WARNS=$((WARNS+1)); }
hdr()  { printf '\n%s== %s ==%s\n' "$DIM" "$1" "$RST"; }

INSTALLER=""; MOTIF_SRC=""; SELF_TEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --installer-dir) INSTALLER="${2:-}"; shift 2 ;;
    --motif-src)     MOTIF_SRC="${2:-}";  shift 2 ;;
    --self-test)     SELF_TEST=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) printf 'unknown arg: %s\n' "$1"; exit 2 ;;
  esac
done

# --------------------------------------------------------------------------
# R1 · AGPL 红线：NetBird 四目录任何字节不进包
# --------------------------------------------------------------------------
check_r1() {
  local root="$1" hits
  hdr "R1 · NetBird AGPLv3 四目录不得进包"
  [ -n "$root" ] || { warn "R1 跳过：未给 --installer-dir"; return; }
  hits=$(find "$root" -type d \( -path '*/netbird/management' -o -path '*/netbird/signal' \
           -o -path '*/netbird/relay' -o -path '*/netbird/combined' \) 2>/dev/null)
  if [ -n "$hits" ]; then
    fail "命中 NetBird AGPLv3 目录（构建脚本应阻断）："; printf '%s\n' "$hits" | sed 's/^/        /'
  else
    pass "未发现 netbird/{management,signal,relay,combined}"
  fi
  # 附带：这些目录里应有 34,523B 的 AGPLv3 全文；若被改名塞进别处，用大小+首行特征兜底
  local agpl
  agpl=$(find "$root" -type f -name 'LICENSE*' -size 34523c 2>/dev/null | head -5)
  [ -n "$agpl" ] && warn "发现 34523B 的 LICENSE（疑似 AGPLv3 全文），请人工确认来源" && printf '%s\n' "$agpl" | sed 's/^/        /'
}

# --------------------------------------------------------------------------
# R2 · 单 Go runtime：宿主不得链接 motifd；产物里只允许一份 Go
# --------------------------------------------------------------------------
check_r2() {
  local root="$1" bin self
  hdr "R2 · 单 Go runtime（宿主不得链接 motifd）"
  self="$(cd "$(dirname "$0")" && pwd)"

  # R2a 静态检查：Cargo 依赖面不得出现 motif-server / libtailscale / netbird-embed 之外的 Go 产物
  local ws
  ws="$(dirname "$self")/Cargo.toml"
  if [ -f "$ws" ]; then
    if grep -qE '^\s*motif-server\s*=|^\s*motif_net\s*=' "$ws"; then
      fail "workspace 依赖了 motif-server（会把 motifd 内嵌的 Go 链进宿主）"
    else
      pass "workspace 未依赖 motif-server"
    fi
  else
    warn "R2a 跳过：找不到 $ws"
  fi

  # R2b 产物检查：安装包里每个二进制各跑一次单 Go runtime 扫描
  [ -n "$root" ] || { warn "R2b 跳过：未给 --installer-dir"; return; }
  if [ ! -x "$self/check-single-go-runtime.sh" ]; then
    warn "R2b 跳过：缺少 check-single-go-runtime.sh"
    return
  fi
  local total=0 gobin=0
  for bin in "$root"/motifd "$root"/motifd.exe "$root"/crossdesk*.exe "$root"/crossdesk*; do
    [ -f "$bin" ] || continue
    total=$((total+1))
    if bash "$self/check-single-go-runtime.sh" "$bin" >/dev/null 2>&1; then
      case "$(basename "$bin")" in
        motifd*) gobin=$((gobin+1)) ;;
      esac
    else
      fail "$(basename "$bin") 含 ≥2 份 Go runtime 特征"
    fi
  done
  [ "$total" -eq 0 ] && warn "R2b 跳过：安装包里没找到二进制"
  if [ "$gobin" -gt 1 ]; then
    fail "安装包里有多份 motifd 形态的 Go 产物（$gobin 个），可能被链接进宿主"
  elif [ "$gobin" -eq 1 ]; then
    pass "motifd 是独立二进制（1 份 Go 产物），未与宿主合并"
  fi
}

# --------------------------------------------------------------------------
# R3 · 随包许可附件（含 ring 的 AND 双义务）
# --------------------------------------------------------------------------
check_r3() {
  local root="$1" miss=0 f
  hdr "R3 · 随包许可附件齐全"
  [ -n "$root" ] || { warn "R3 跳过：未给 --installer-dir"; return; }
  local tp="$root/third_party"
  if [ ! -d "$tp" ]; then
    fail "缺少 third_party/ 目录（形态 A 必带；形态 B 首启下载则本条不适用）"
    return
  fi
  # ring 是 Apache-2.0 AND ISC：两条都要有，缺 ISC 侧 = 缺附件
  for pair in "motif/LICENSE-MIT" "libghostty-vt/LICENSE" "libtailscale/LICENSE" \
              "ring/LICENSE-APACHE" "ring/LICENSE-ISC" "subtle/LICENSE"; do
    f="$tp/$pair"
    if [ -f "$f" ] && [ -s "$f" ]; then
      pass "third_party/$pair"
    else
      fail "缺附件 third_party/$pair"; miss=$((miss+1))
    fi
  done
  # ring 的 AND 义务：两份必须都在，且 ISC 侧要能被认出来
  if [ -f "$tp/ring/LICENSE-ISC" ] && ! grep -qi 'Permission to use, copy, modify' "$tp/ring/LICENSE-ISC"; then
    warn "ring/LICENSE-ISC 内容不像 ISC 文本，请人工确认（AND 义务不能漏）"
  fi
  # flutter_netbird 若已随包则必须有许可
  [ -d "$root/third_party/flutter-netbird" ] && [ ! -f "$root/third_party/flutter-netbird/LICENSE" ] \
    && fail "third_party/flutter-netbird 存在但缺 LICENSE（该组件许可尚未取得一手）"
  [ "$miss" -eq 0 ] && pass "形态 A 附件清单完整"
}

# --------------------------------------------------------------------------
# R4 · commit 锁定（防止版权行指向漂移的源码）
# --------------------------------------------------------------------------
check_r4() {
  hdr "R4 · motif 源码 commit 锁定"
  local pinned="5f25f81655765147b5156bff2aacb4260806a41d"
  if [ -n "$MOTIF_SRC" ] && [ -d "$MOTIF_SRC/.git" ]; then
    local head
    head=$(git -C "$MOTIF_SRC" rev-parse HEAD 2>/dev/null)
    if [ "$head" = "$pinned" ]; then
      pass "motif HEAD = ${pinned:0:7}（与版权行一致）"
    else
      fail "motif HEAD=${head:0:7} ≠ 许可声明锁定值 ${pinned:0:7}（commit 漂移会让版权行失效）"
    fi
  else
    warn "R4 跳过：未给 --motif-src（发版时必须给）"
  fi
}

# --------------------------------------------------------------------------
# 自检：用合成目录验证闸门真的会 FAIL
# --------------------------------------------------------------------------
self_test() {
  local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  local ok=0 bad=0
  # 干净安装包 → 应 0 FAIL
  mkdir -p "$tmp/good/third_party/"{motif,libghostty-vt,libtailscale,ring,subtle}
  printf 'MIT License\n' > "$tmp/good/third_party/motif/LICENSE-MIT"
  printf 'MIT\n' > "$tmp/good/third_party/libghostty-vt/LICENSE"
  printf 'MIT\n' > "$tmp/good/third_party/libtailscale/LICENSE"
  printf 'Apache\n' > "$tmp/good/third_party/ring/LICENSE-APACHE"
  printf 'Permission to use, copy, modify, and/or distribute\n' > "$tmp/good/third_party/ring/LICENSE-ISC"
  printf 'BSD\n' > "$tmp/good/third_party/subtle/LICENSE"
  if bash "$0" --installer-dir "$tmp/good" >/dev/null 2>&1; then ok=$((ok+1)); else bad=$((bad+1)); echo "  self-test FAIL: 干净包被判失败"; fi

  # 缺 ring ISC → 应失败
  rm -f "$tmp/good/third_party/ring/LICENSE-ISC"
  if bash "$0" --installer-dir "$tmp/good" >/dev/null 2>&1; then bad=$((bad+1)); echo "  self-test FAIL: 缺 ring/LICENSE-ISC 未被拦住"; else ok=$((ok+1)); fi

  # 塞进 AGPL 目录 → 应失败
  mkdir -p "$tmp/bad/netbird/relay" "$tmp/bad/third_party/ring"
  printf 'Apache\n' > "$tmp/bad/third_party/ring/LICENSE-APACHE"
  if bash "$0" --installer-dir "$tmp/bad" >/dev/null 2>&1; then bad=$((bad+1)); echo "  self-test FAIL: netbird/relay 未被拦住"; else ok=$((ok+1)); fi

  printf '\n自检：%d 通过 / %d 失败\n' "$ok" "$bad"
  [ "$bad" -eq 0 ]
}

if [ "$SELF_TEST" -eq 1 ]; then self_test; exit $?; fi

printf 'crossdesk preflight（installer=%s motif_src=%s）\n' "${INSTALLER:-<none>}" "${MOTIF_SRC:-<none>}"
check_r1 "$INSTALLER"
check_r2 "$INSTALLER"
check_r3 "$INSTALLER"
check_r4

printf '\n'
if [ "$FAILS" -gt 0 ]; then
  printf '%s发版阻断：%d 项 FAIL（%d WARN）%s\n' "$RED" "$FAILS" "$WARNS" "$RST"; exit 1
fi
printf '%spreflight 通过（%d WARN）%s\n' "$GRN" "$WARNS" "$RST"; exit 0
