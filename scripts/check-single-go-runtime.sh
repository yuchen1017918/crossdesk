#!/usr/bin/env bash
# 单 Go runtime 检查（plan-v3 §3.3 第 4 条 / §7 验收最后一项）。
#
# 背景：netbird-embed 的 Go 侧是 c-shared 动态库。同一个进程里只要加载了**两份**
# Go runtime（两份 .dll/.so，或 exe 静态链一份 + 再加载一份），GC 就会互相踩内存，
# 表现是随机 crash 而不是漂亮的错误。这类事故在测试机上往往看不出来，所以做成
# 构建期/打包期的硬检查。
#
# 判定（三层证据，任一命中即算"这个文件里有 Go runtime"）：
#   1) Go 1.12+ 必带的 buildinfo 字符串 `go1.`
#   2) Go 运行时符号/名字 `runtime.`（strip 后函数名仍留在 pclntab 里）
#   3) nm 符号表 / objdump 的 .gopclntab 段（前两条都拿不到时才用）
#
# 规则：
#   - 候选产物理有 0 份 Go runtime → 通过（--strict 时视为失败，防止"扫错目录"假通过）
#   - 恰好 1 份               → 通过（可用 --expect-name 断言是预期那一个）
#   - ≥2 份                   → 失败，exit 1
#
# 用法：
#   bash scripts/check-single-go-runtime.sh                    # 扫 artifacts/ 与 target/
#   bash scripts/check-single-go-runtime.sh artifacts/*.dll    # 只扫指定产物
#   bash scripts/check-single-go-runtime.sh --expect-name netbird_embed artifacts/
#   bash scripts/check-single-go-runtime.sh --strict           # 没扫到 Go runtime 也算失败
#   bash scripts/check-single-go-runtime.sh --self-test        # 自检检测逻辑（不需要 Go/cargo）
#
# 退出码：0 通过 / 1 发现多个 Go runtime（或 --strict 未命中）/ 2 参数错误

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

QUIET=0
STRICT=0
EXPECT_NAME=""
SELF_TEST=0
PATHS=()

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=1; shift ;;
    --strict) STRICT=1; shift ;;
    --expect-name) EXPECT_NAME="${2:-}"; shift 2 ;;
    --self-test) SELF_TEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "未知参数：$1" >&2; exit 2 ;;
    *) PATHS+=("$1"); shift ;;
  esac
done

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
bad() { printf '%s\n' "$*" >&2; }

# ---------------------------------------------------------------- 检测核心
# 判断单个文件里是否有 Go runtime。
has_go_runtime() {
  local file="$1"

  # 第一道：Go buildinfo 字符串。没有它基本可以直接判否。
  grep -aqF 'go1.' "$file" 2>/dev/null || return 1

  # 第二道：runtime 名字（strip 也去不掉的 pclntab 字符串）
  if grep -aqF 'runtime.' "$file" 2>/dev/null; then
    EVIDENCE="go1.* + runtime.*"
    return 0
  fi

  # 第三道：符号表（需要 nm；交叉产物可能要 --extern-only）
  if command -v nm >/dev/null 2>&1; then
    if nm -a --defined-only "$file" 2>/dev/null | grep -q 'runtime\.' ||
       nm -D --defined-only "$file" 2>/dev/null | grep -q 'runtime\.'; then
      EVIDENCE="go1.* + nm runtime.*"
      return 0
    fi
  fi

  # 第四道：Go 的段名
  if command -v objdump >/dev/null 2>&1; then
    if objdump -h "$file" 2>/dev/null | grep -qi 'gopclntab\|go\.buildinfo'; then
      EVIDENCE="go1.* + .gopclntab/.go.buildinfo"
      return 0
    fi
  fi

  return 1
}

collect_candidates() {
  local path
  for path in "${PATHS[@]}"; do
    if [ -f "$path" ]; then
      printf '%s\n' "$path"
    elif [ -d "$path" ]; then
      find "$path" -type f \
        \( -name '*.dll' -o -name '*.so' -o -name '*.dylib' \
           -o -name '*.exe' -o -name '*.node' \) 2>/dev/null
    else
      bad "  !! 路径不存在：$path"
    fi
  done
}

human_size() {
  awk -v bytes="$1" 'BEGIN {
    if (bytes >= 1048576) printf "%.2f MB", bytes / 1048576;
    else if (bytes >= 1024) printf "%.1f KB", bytes / 1024;
    else printf "%d B", bytes;
  }'
}

run_check() {
  local total=0
  local hits=()
  local candidate

  say ""
  say "=== 单 Go runtime 检查 ======================================="
  say "  扫描范围：${PATHS[*]}"

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    EVIDENCE=""
    if has_go_runtime "$candidate"; then
      hits+=("$candidate")
      total=$((total + 1))
      say "  [GO]  $(printf '%-58s' "$candidate") $(printf '%10s' "$(human_size "$(wc -c < "$candidate" | tr -d ' ')")")  $EVIDENCE"
    fi
  done < <(collect_candidates | sort -u)

  say ""
  if [ "$total" -eq 0 ]; then
    bad "  !! 没扫到任何 Go runtime 特征。"
    bad "     若产物里应该有（netbird_embed），说明扫错目录了；确认无误就用 --strict 之外的方式跳过。"
    if [ "$STRICT" -eq 1 ]; then
      return 1
    fi
    return 0
  fi

  if [ "$total" -gt 1 ]; then
    bad "  !! 发现 $total 份 Go runtime —— 同一进程加载两份会导致 GC 损坏："
    local hit
    for hit in "${hits[@]}"; do
      bad "       - $hit"
    done
    bad "     处理：只保留一份（通常只该有 netbird_embed 的 .dll/.so）；把 mesh 拆到独立进程，"
    bad "           或改回静态链一份（plan-v3 §3.3 第 3 条）。"
    return 1
  fi

  if [ -n "$EXPECT_NAME" ]; then
    case "$(basename "${hits[0]}")" in
      *"$EXPECT_NAME"*)
        say "  OK：唯一的 Go runtime 是 ${hits[0]}（匹配 --expect-name $EXPECT_NAME）"
        ;;
      *)
        bad "  !! 唯一的 Go runtime 是 ${hits[0]}，但 --expect-name 要求包含 $EXPECT_NAME"
        return 1
        ;;
    esac
  else
    say "  OK：只有 1 份 Go runtime —— ${hits[0]}"
  fi
  return 0
}

# ---------------------------------------------------------------- 自检
fake_go_bin() {
  # 仿 Go 产物：buildinfo 字符串 + 运行时符号名
  printf 'Go buildinf:\x00 go1.25.3 \x00runtime.schedinit\x00runtime.rt0_go\x00runtime.main\x00' > "$1"
}

fake_rust_bin() {
  printf 'rustc 1.88.0\x00.rustc\x00std::rt::lang_start\x00' > "$1"
}

self_test() {
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/single-go-runtime.XXXXXX")"
  local failures=0

  printf '\n=== 自检：检测逻辑 =========================================\n'

  fake_go_bin "$tmp/netbird_embed.dll"
  bash "${BASH_SOURCE[0]}" --quiet "$tmp" >/dev/null 2>&1
  if [ $? -eq 0 ]; then printf '  PASS 单个 Go 产物 → 通过\n'; else printf '  FAIL 单个 Go 产物被判失败\n'; failures=$((failures + 1)); fi

  fake_rust_bin "$tmp/motif-probe.exe"
  bash "${BASH_SOURCE[0]}" --quiet "$tmp" >/dev/null 2>&1
  if [ $? -eq 0 ]; then printf '  PASS Go 产物 + Rust exe → 通过（Rust 里没有 Go runtime）\n'; else printf '  FAIL Go + Rust 被判成了两个 runtime\n'; failures=$((failures + 1)); fi

  fake_go_bin "$tmp/second_go.dll"
  bash "${BASH_SOURCE[0]}" --quiet "$tmp" >/dev/null 2>&1
  if [ $? -eq 1 ]; then printf '  PASS 两个 Go 产物 → exit 1\n'; else printf '  FAIL 两个 Go 产物没有被拦下\n'; failures=$((failures + 1)); fi

  rm -f "$tmp/second_go.dll"
  bash "${BASH_SOURCE[0]}" --quiet --expect-name netbird_embed "$tmp" >/dev/null 2>&1
  if [ $? -eq 0 ]; then printf '  PASS --expect-name 命中\n'; else printf '  FAIL --expect-name 未命中预期名称\n'; failures=$((failures + 1)); fi

  bash "${BASH_SOURCE[0]}" --quiet --expect-name totally-other "$tmp" >/dev/null 2>&1
  if [ $? -eq 1 ]; then printf '  PASS --expect-name 不匹配 → exit 1\n'; else printf '  FAIL --expect-name 不匹配却没报错\n'; failures=$((failures + 1)); fi

  mkdir -p "$tmp/empty"
  bash "${BASH_SOURCE[0]}" --quiet --strict "$tmp/empty" >/dev/null 2>&1
  if [ $? -eq 1 ]; then printf '  PASS --strict 空目录 → exit 1\n'; else printf '  FAIL --strict 空目录没报错\n'; failures=$((failures + 1)); fi

  # 真实二进制：用 gcc 造一个带 runtime.schedinit 符号 + go1. 字符串的 .so，
  # 专门验证"没有 pclntab 字符串、只能靠符号表/段名识别"的那条兜底路径。
  if command -v gcc >/dev/null 2>&1; then
    cat > "$tmp/fake_go.c" <<'EOF'
const char buildinfo[] = "go1.25.3-elf";
__asm__(".globl runtime.schedinit\nruntime.schedinit:\n\tret\n");
int fake_entry(void) { return 0; }
EOF
    if gcc -shared -fPIC -o "$tmp/libfakego.so" "$tmp/fake_go.c" 2>/dev/null; then
      rm -rf "$tmp/empty"
      bash "${BASH_SOURCE[0]}" --quiet --strict "$tmp/libfakego.so" >/dev/null 2>&1
      if [ $? -eq 0 ]; then printf '  PASS gcc 造的真二进制（符号表路径）被识别\n'; else printf '  FAIL gcc 二进制没被识别（符号表/段名兜底失效）\n'; failures=$((failures + 1)); fi
    else
      printf '  SKIP 用 gcc 造真二进制失败（跳过符号表路径自检）\n'
    fi
  else
    printf '  SKIP 没有 gcc（跳过真二进制自检）\n'
  fi

  rm -rf "$tmp"
  printf '\n'
  if [ "$failures" -eq 0 ]; then
    printf '自检全部通过。\n'
    return 0
  fi
  bad "自检失败 $failures 项。"
  return 1
}

if [ "$SELF_TEST" -eq 1 ]; then
  self_test
  exit $?
fi

if [ ${#PATHS[@]} -eq 0 ]; then
  [ -d "$ROOT/artifacts" ] && PATHS+=("$ROOT/artifacts")
  [ -d "$ROOT/target" ] && PATHS+=("$ROOT/target")
  if [ ${#PATHS[@]} -eq 0 ]; then
    bad "没有 artifacts/ 也没有 target/：先构建，或显式传路径。"
    exit 2
  fi
fi

if run_check; then
  exit 0
fi
exit 1
