#!/usr/bin/env bash
# P0-A：构建 netbird-embed 的 Go c-shared 库 + Rust 侧，并产出体积报告。
#
# 为什么需要这个脚本（而不是只靠 build.rs）：
#   netbird-embed 0.3.1 的 build.rs 执行的是
#       go build -buildmode=c-shared -o <OUT_DIR>/netbird_embed.dll .
#   **没有** -ldflags="-s -w"，所以 cargo 链进去的那份是"肥"的。
#   plan-v3 §5 要求给出 -s -w 前后的实测体积，并写进 artifacts/size-report.json。
#
# 本脚本做两次 Go 构建（同一份源码）：
#   A) 原样              -> artifacts/netbird_embed.unstripped.{dll,so,dylib}
#   B) -trimpath -s -w   -> artifacts/netbird_embed.{dll,so,dylib}     ← 该分发的那份
# 然后再跑 cargo（可选），把所有产物体积记下来。
#
# 用法：
#   bash scripts/build-win-mesh.sh                 # 按宿主机 GOOS 构建
#   bash scripts/build-win-mesh.sh --windows       # 交叉编译 Windows（需 mingw-w64 gcc）
#   bash scripts/build-win-mesh.sh --go-lib PATH --skip-rust
#   bash scripts/build-win-mesh.sh --budget-mb 120
#
# 退出码：0 通过 / 1 超预算 / 2 环境或构建失败

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT/artifacts"
GO_LIB=""
SKIP_RUST=0
BUDGET_MB=120
GOOS_ARG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --windows) GOOS_ARG="windows"; shift ;;
    --linux) GOOS_ARG="linux"; shift ;;
    --darwin) GOOS_ARG="darwin"; shift ;;
    --go-lib) GO_LIB="${2:-}"; shift 2 ;;
    --out) OUT_DIR="${2:-}"; shift 2 ;;
    --skip-rust) SKIP_RUST=1; shift ;;
    --budget-mb) BUDGET_MB="${2:-120}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "未知参数：$1（--help 看用法）" >&2; exit 2 ;;
  esac
done

section() {
  local pad=$((56 - ${#1}))
  [ "$pad" -lt 1 ] && pad=1
  local line=""
  local i=0
  while [ "$i" -lt "$pad" ]; do line="$line="; i=$((i + 1)); done
  printf '\n=== %s %s\n' "$1" "$line"
}
step() { printf '  -> %s\n' "$1"; }
fail() { printf '  !! %s\n' "$1" >&2; }

section "P0-A build-win-mesh (sh)"
step "repo root  $ROOT"

# ---------------------------------------------------------------- 环境检查
section "environment"

if ! command -v go >/dev/null 2>&1; then
  fail "找不到 go。netbird-embed 需要 Go >= 1.25（https://go.dev/dl/）"
  exit 2
fi
GO_VERSION="$(go version)"
step "go         $GO_VERSION"

GO_MINOR="$(printf '%s\n' "$GO_VERSION" | sed -n 's/.*go1\.\([0-9]\+\).*/\1/p')"
if [ -n "$GO_MINOR" ] && [ "$GO_MINOR" -lt 25 ]; then
  fail "go 1.$GO_MINOR 太旧，netbird-embed 0.3.1 要求 >= 1.25"
  exit 2
fi

if [ -z "$GOOS_ARG" ]; then
  case "$(uname -s)" in
    Linux) GOOS_ARG="linux" ;;
    Darwin) GOOS_ARG="darwin" ;;
    MINGW*|MSYS*|CYGWIN*) GOOS_ARG="windows" ;;
    *) GOOS_ARG="linux" ;;
  esac
fi
GOARCH_ARG="${GOARCH:-$(go env GOARCH 2>/dev/null || echo amd64)}"

if [ "$GOOS_ARG" = "windows" ] && [ "$(uname -s)" != "MINGW"* ] && [ "$(uname -s)" != "MSYS"* ]; then
  if ! command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
    fail "交叉编译 Windows 需要 x86_64-w64-mingw32-gcc（apt install mingw-w64 / brew install mingw-w64）"
    exit 2
  fi
  export CC="${CC:-x86_64-w64-mingw32-gcc}"
  step "CC         $CC（交叉编译）"
fi

step "GOOS/GOARCH $GOOS_ARG/$GOARCH_ARG"

# ---------------------------------------------------------- 定位 go-lib
section "locate go-lib"

resolve_go_lib() {
  if [ -n "$GO_LIB" ]; then
    if [ ! -f "$GO_LIB/go.mod" ]; then
      echo "-go-lib $GO_LIB 里没有 go.mod" >&2
      return 1
    fi
    printf '%s\n' "$GO_LIB"
    return 0
  fi

  local vendored="$ROOT/vendor/netbird-embed/go-lib"
  if [ -f "$vendored/go.mod" ]; then
    printf '%s\n' "$vendored"
    return 0
  fi

  # cargo registry（先 cargo fetch / cargo build 一次让它落地）
  local cargo_home="${CARGO_HOME:-$HOME/.cargo}"
  local found
  found="$(find "$cargo_home/registry/src" -maxdepth 2 -type d -name 'netbird-embed-0.3.1' 2>/dev/null | head -n 1)"
  if [ -n "$found" ] && [ -f "$found/go-lib/go.mod" ]; then
    printf '%s\n' "$found/go-lib"
    return 0
  fi

  echo "找不到 netbird-embed 的 go-lib。先跑一次 'cargo fetch'，或用 --go-lib <path>" >&2
  return 1
}

if ! GO_LIB_PATH="$(resolve_go_lib)"; then
  exit 2
fi
step "go-lib     $GO_LIB_PATH"

# ---------------------------------------------------------- 拷贝源码
section "stage go sources"
WORK_DIR="$OUT_DIR/go-build"
rm -rf "$WORK_DIR"
mkdir -p "$OUT_DIR"
cp -R "$GO_LIB_PATH" "$WORK_DIR"
step "staged     $WORK_DIR"

export CGO_ENABLED=1
export GOOS="$GOOS_ARG"
export GOARCH="$GOARCH_ARG"

case "$GOOS_ARG" in
  windows) LIB_EXT="dll" ;;
  darwin) LIB_EXT="dylib" ;;
  *) LIB_EXT="so" ;;
esac

go_build() {
  local output="$1"; shift
  step "go build -buildmode=c-shared -trimpath $* -o $output ."
  ( cd "$WORK_DIR" && go build -buildmode=c-shared -trimpath "$@" -o "$output" . )
}

file_bytes() {
  if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else echo 0; fi
}
format_mb() { awk -v bytes="$1" 'BEGIN { printf "%.2f MB", bytes / 1048576 }'; }

# ---------------------------------------------------------- A：不 strip
section "build A: plain（这就是 build.rs 现在产出的东西）"
DLL_PLAIN="$OUT_DIR/netbird_embed.unstripped.$LIB_EXT"
if ! go_build "$DLL_PLAIN"; then
  fail "go build 失败。首次运行需要网络（go mod download 拉 netbirdio/netbird）"
  exit 2
fi
PLAIN_BYTES="$(file_bytes "$DLL_PLAIN")"
step "size       $(format_mb "$PLAIN_BYTES")"

# ---------------------------------------------------------- B：strip
section "build B: -ldflags=\"-s -w\"（该分发的那份）"
DLL_STRIPPED="$OUT_DIR/netbird_embed.$LIB_EXT"
if ! go_build "$DLL_STRIPPED" "-ldflags=-s -w"; then
  fail "go build（strip）失败"
  exit 2
fi
STRIPPED_BYTES="$(file_bytes "$DLL_STRIPPED")"
SAVED_BYTES=$((PLAIN_BYTES - STRIPPED_BYTES))
if [ "$PLAIN_BYTES" -gt 0 ]; then
  SAVED_PERCENT="$(awk -v saved="$SAVED_BYTES" -v plain="$PLAIN_BYTES" 'BEGIN { printf "%.1f", 100 * saved / plain }')"
else
  SAVED_PERCENT="0.0"
fi
step "size       $(format_mb "$STRIPPED_BYTES")   （省 $(format_mb "$SAVED_BYTES")，$SAVED_PERCENT%）"

# ---------------------------------------------------------- Rust 侧
CARGO_DLL_BYTES=0
PROBE_EXE_BYTES=0
CARGO_DLL_PATH=""
PROBE_EXE_PATH=""
if [ "$SKIP_RUST" -eq 0 ]; then
  section "cargo build (release)"
  if ! command -v cargo >/dev/null 2>&1; then
    fail "找不到 cargo（rust-toolchain.toml 要求 1.88）；用 --skip-rust 只测 Go 侧"
    exit 2
  fi
  ( cd "$ROOT" && cargo build --release -p crossdesk-mesh ) || { fail "cargo build -p crossdesk-mesh 失败"; exit 2; }
  ( cd "$ROOT" && cargo build --release -p motif-probe --features mesh ) || { fail "cargo build -p motif-probe 失败"; exit 2; }

  CARGO_DLL_PATH="$(find "$ROOT/target" -name "netbird_embed.$LIB_EXT" -type f 2>/dev/null | head -n 1)"
  PROBE_EXE_PATH="$(find "$ROOT/target" -type f \( -name "motif-probe" -o -name "motif-probe.exe" \) 2>/dev/null | head -n 1)"
  [ -n "$CARGO_DLL_PATH" ] && CARGO_DLL_BYTES="$(file_bytes "$CARGO_DLL_PATH")"
  [ -n "$PROBE_EXE_PATH" ] && PROBE_EXE_BYTES="$(file_bytes "$PROBE_EXE_PATH")"
fi

# ---------------------------------------------------------- 报告
section "size report"
RUNTIME_DLL_BYTES="$STRIPPED_BYTES"
[ "$CARGO_DLL_BYTES" -gt 0 ] && RUNTIME_DLL_BYTES="$CARGO_DLL_BYTES"
TOTAL_BYTES=$((RUNTIME_DLL_BYTES + PROBE_EXE_BYTES))
TOTAL_MB="$(awk -v bytes="$TOTAL_BYTES" 'BEGIN { printf "%.2f", bytes / 1048576 }')"
VERDICT="OK"
awk -v total="$TOTAL_MB" -v budget="$BUDGET_MB" 'BEGIN { exit !(total > budget) }' && VERDICT="OVER_BUDGET"

REPORT="$OUT_DIR/size-report.json"
cat > "$REPORT" <<JSON
{
  "schema": "crossdesk.size-report/1",
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "host": {
    "os": "$GOOS_ARG",
    "arch": "$GOARCH_ARG",
    "go": $(printf '%s' "$GO_VERSION" | sed 's/"/\\"/g; s/^/"/; s/$/"/')
  },
  "items": {
    "netbird_embed_dll_unstripped": {
      "path": "$DLL_PLAIN",
      "bytes": $PLAIN_BYTES,
      "note": "netbird-embed 0.3.1 build.rs 的产物（没有 -ldflags）"
    },
    "netbird_embed_dll_stripped": {
      "path": "$DLL_STRIPPED",
      "bytes": $STRIPPED_BYTES,
      "note": "go build -ldflags=\"-s -w\" -trimpath；分发用这一份"
    },
    "strip_saving": {
      "bytes": $SAVED_BYTES,
      "percent": $SAVED_PERCENT
    },
    "cargo_linked_dll": {
      "path": "$CARGO_DLL_PATH",
      "bytes": $CARGO_DLL_BYTES,
      "note": "cargo 无法给 build.rs 传 -ldflags，所以这份是未 strip 的"
    },
    "motif_probe_exe": {
      "path": "$PROBE_EXE_PATH",
      "bytes": $PROBE_EXE_BYTES,
      "note": "[profile.release] strip=symbols + lto=thin 已生效"
    }
  },
  "budget": {
    "budget_mb": $BUDGET_MB,
    "measured_total_mb": $TOTAL_MB,
    "verdict": "$VERDICT"
  },
  "next_steps": [
    "bash scripts/check-single-go-runtime.sh",
    "用 artifacts/netbird_embed.$LIB_EXT 覆盖 cargo 链进去的那份（体积对齐，见 runbook §4）",
    "target/release/motif-probe --with-mesh --motif-target <overlay_ip:7777>"
  ]
}
JSON
step "report     $REPORT"

rm -rf "$WORK_DIR"

# ---------------------------------------------------------- 汇总
section "summary"
printf '  %-34s %s\n' "netbird_embed plain" "$(format_mb "$PLAIN_BYTES")"
printf '  %-34s %s (saved %s%%)\n' "netbird_embed stripped" "$(format_mb "$STRIPPED_BYTES")" "$SAVED_PERCENT"
[ "$CARGO_DLL_BYTES" -gt 0 ] && printf '  %-34s %s  <- replace with stripped\n' "cargo-linked dll" "$(format_mb "$CARGO_DLL_BYTES")"
[ "$PROBE_EXE_BYTES" -gt 0 ] && printf '  %-34s %s\n' "motif-probe" "$(format_mb "$PROBE_EXE_BYTES")"
printf '  %-34s %s MB / budget %s MB  -> %s\n' "package total" "$TOTAL_MB" "$BUDGET_MB" "$VERDICT"

if [ "$VERDICT" != "OK" ]; then
  exit 1
fi
exit 0
