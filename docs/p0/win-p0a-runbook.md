# P0-A Windows 实机执行清单（gate-A）

> 目标机：**Windows 10/11 x64**，装有 Rust 1.88 + Go 1.25 + MinGW-w64 gcc。
> 产出物状态：**未编译、未跑通**。本机（Linux 容器）无 cargo/rustc/go，只有 gcc/nm/strip，
> 所以下面每条命令都是"待你在实机执行并记录输出"的步骤，不是"已验证通过"的记录。
> 本清单里唯一在本机真跑过的是 `scripts/check-single-go-runtime.sh --self-test`（见 §3.3）。

gate-A 三条验收（plan-v3 §1）：

1. `/ping` 经 mesh proxy 返回 200 + motifd 版本号；
2. `peers()` 里目标机 `direct=true`（P2P 直连，不是 relay）；
3. 连续两次启动，`proxy` 端口不同（禁止写死端口的反证）。

---

## 0.0 setup key 纪律（2026-11-08 实测踩过）

- **一次性 key 只能用一次**：我们本机第一次注册成功后，第二次立即报
  `PermissionDenied: couldn't add peer: setup key is invalid`。
  实机要反复验收 → 在 NetBird 控制台建 **reusable** key，或每轮换新 key。
- **状态文件不一定落盘**：显式传 `state_path` 后仍可能没有文件生成（疑为 embed 模式内存态）。
  跑完第一件事是 `ls -la $NB_STATE_PATH` 确认：
  - 有文件 → 下次可传空 `setup_key` 复用身份（`MeshConfig.setup_key=""`）；
  - 没文件 → 每次都是新设备，请预留 key 消耗预算。
- 申请到的 peer 会留在租户里，验收完记得在控制台清理，别攒垃圾设备。

## 0. 工具链（一次性）

```powershell
# Rust 1.88（rust-toolchain.toml 已钉版本，rustup 会自动装）
rustup show

# 关键：Windows 上请用 GNU toolchain，不要 MSVC
#   原因：netbird-embed 的 build.rs 只给 cargo 发 `cargo:rustc-link-lib=dylib=netbird_embed`，
#   而 `go build -buildmode=c-shared` 在 Windows 上只产 netbird_embed.dll + .h，
#   **不产 MSVC 需要的 .lib 导入库** → MSVC 链接阶段会报 LNK1181。
#   GNU ld 能直接对 .dll 链接（auto-import），所以选 windows-gnu。
rustup toolchain install stable-x86_64-pc-windows-gnu
rustup default stable-x86_64-pc-windows-gnu

# Go >= 1.25（netbird-embed 下限）
go version            # 期望：go version go1.25.x windows/amd64

# 关键：国内网络必须换 Go module 代理，否则 build.rs 拉 proxy.golang.org 会全部 i/o timeout
#（实测：netbirdio/netbird、wireguard/wgctrl、google/uuid 全部超时，报错长得像代码问题）
go env -w GOPROXY=https://goproxy.cn,direct
go env -w GOSUMDB=sum.golang.google.cn

# cgo 需要真 gcc（MSYS2 mingw64），并把 C:\msys64\mingw64\bin 放进 PATH
gcc --version
```

**预期**：`gcc --version` 有输出、`go version` ≥ 1.25、`rustc --version` = 1.88.x。
**失败分支**：

| 现象 | 原因 | 处理 |
|---|---|---|
| `gcc: command not found` | 装的是 MSVC 版 Rust 或没装 MSYS2 | 装 MSYS2：`pacman -S mingw-w64-x86_64-gcc`，把 `mingw64\bin` 加 PATH |
| `go: cannot find GOROOT` | Go 装坏 / PATH 顺序 | 重装 Go，`go env GOROOT` 自检 |
| `linker 'x86_64-w64-mingw32-gcc' not found` | 用了 windows-gnu 但 PATH 里只有 MSVC | 同上，把 mingw64\bin 提前 |

MSVC 坚持要用时的兜底（高级，非推荐）：

```powershell
# 从 .dll 生成 import lib，再让 MSVC 找到它
gendef.exe target\release\build\netbird-embed-*\out\netbird_embed.dll
dlltool -d netbird_embed.def -l netbird_embed.lib -D netbird_embed.dll
# 把 netbird_embed.lib 放进同一个 out\ 目录
```

---

## 1. 三条命令（快速路径）

```powershell
# ① 构建（第一次会 go mod download 拉 netbirdio/netbird，需要网络，几分钟）
cargo build --release -p motif-probe --features mesh

# ② 体积 + 单 runtime 双闸
pwsh -File scripts\build-win-mesh.ps1
bash scripts/check-single-go-runtime.sh          # git-bash；或 pwsh -File scripts\check-single-go-runtime.ps1

# ③ 端到端（先设好 NetBird 环境变量，见 §2.3）
.\target\release\motif-probe.exe --with-mesh --motif-target 100.64.0.2:7777 --json-stdout
```

第 ③ 条成功时，`artifacts\motif-probe-report.json` 里应当同时出现：

```json
{
  "layers": {
    "ping":              {"status": "ok", "http_status": 200, "version": "<motifd 版本>"},
    "rpc_session_list":  {"status": "ok", "http_status": 200, "sessions": 0}
  },
  "mesh": {"enabled": true, "direct_peer_count": 1, "proxy_port": 53124}
}
```

---

## 2. 逐步执行

### 2.1 让依赖落地（go-lib 从哪来）

```powershell
cargo fetch
```

`netbird-embed 0.3.1` 的 Go 源码在 crate 目录里（`go-lib/`），它的 `build.rs` 会：
1. `cd go-lib && go build -buildmode=c-shared -o $OUT_DIR\netbird_embed.dll .`
2. 生成 `ffi_bindings.rs`，并 `cargo:rustc-link-search` + `link-lib=dylib=netbird_embed`

`go-lib` 位置（脚本按此顺序找）：
1. `vendor\netbird-embed\go-lib`（若已 vendor）
2. `%USERPROFILE%\.cargo\registry\src\<registry>\netbird-embed-0.3.1\go-lib`
3. `-GoLib <path>` 显式指定

**注意**：`go build` 可能会改写 `go.sum`，所以 `build-win-mesh.ps1` 会先把 `go-lib`
复制到 `artifacts\go-build\` 再构建，绝不直接写 cargo registry。

### 2.2 构建

```powershell
cargo build --release -p motif-probe --features mesh
```

**预期**（关键行）：

```
   Compiling netbird-embed v0.3.1
   Compiling crossdesk-mesh v0.1.0 (...\crates\mesh)
   Compiling motif-probe v0.1.0 (...\crates\motif-probe)
    Finished `release` profile [optimized] target(s) in 3~10m
```

产物：
- `target\release\motif-probe.exe`
- `target\release\build\netbird-embed-<hash>\out\netbird_embed.dll`

**运行前必须把 DLL 拷到 exe 同级**（cargo 不会替 bin target 做这件事；Windows loader 只找
exe 所在目录 / PATH，不会去 `build\*/out` 里捞）：

```powershell
$dll = (Get-ChildItem target\release\build -Recurse -Filter netbird_embed.dll |
        Sort-Object LastWriteTime -Descending)[0]
Copy-Item $dll.FullName target\release\ -Force
```

不加这一步，直接跑 exe 会在启动瞬间失败（`STATUS_DLL_NOT_FOUND` / `error 126`）。

**失败分支**：

| 报错 | 含义 | 处理 |
|---|---|---|
| `failed to run 'go build'`（build.rs panic） | PATH 里没有 go | 开新终端让 PATH 生效，`go version` 自检 |
| `cgo: C compiler "x86_64-w64-mingw32-gcc" not found` | 缺 mingw gcc | 见 §0 失败分支 |
| `error LNK1181: cannot open input file 'netbird_embed.lib'` | 用了 MSVC toolchain | 换 `stable-x86_64-pc-windows-gnu`（§0） |
| `go: downloading netbirdio/netbird ... timeout` | 首次拉 Go 依赖失败 | 配 GOPROXY（如 `$env:GOPROXY="https://goproxy.cn,direct"`）后重试 |
| `error: failed to select a version for netbird-embed` | 版本漂移 | 根 `Cargo.toml` 必须是 `=0.3.1`（已锁死，勿改） |

### 2.3 只验传输层（第 1 层：`GET /ping`）

`motifd` 的探测端点是 **`GET /ping`，不需要鉴权**（来源：motif `docs/rpc.md` §1.7 步骤 2）。
这一层只证明"隧道通 + 对端确实是 motifd"，不掺任何 token 变量。

先拿到本次的 proxy 端口（**每次启动都会变**）：

```powershell
.\target\release\motif-probe.exe --with-mesh --motif-target 100.64.0.2:7777 --quiet
# 报告里看 mesh.proxy_port，或者用摘要行里的 "proxy 端口"
```

或者分两步（自己起 mesh 后单独跑 probe）：

```powershell
.\target\release\motif-probe.exe --proxy-port 53124
```

**预期**：

```
motif-probe → http://127.0.0.1:53124
  [1/2] GET  /ping             ok        HTTP 200      38ms  version=<x.y.z>
  [2/2] POST /rpc/session.list skipped_no_token
  mesh: 未启用（未请求 --with-mesh）
  报告：artifacts\motif-probe-report.json
  第 2 层：没有 bearer token（--token / MOTIF_BEARER / MOTIF_TOKEN），跳过鉴权层。…
```

**失败分支**（第 1 层失败 = 传输层问题，按顺序排查）：

| 现象 | 最可能原因 | 处理 |
|---|---|---|
| `连不上 127.0.0.1:53124` | 端口是上一次启动的 | 用本次 `start_proxy()` 的返回值；端口随机是设计而非 bug |
| `连不上` 且端口是本次的 | 目标机 motifd 没监听 7777 | 在目标机 `curl http://127.0.0.1:7777/ping` 自测 |
| `HTTP 404` | 目标机端口上不是 motifd | 确认 motifd 在跑、端口对（`--tailscale`/`--port` 参数） |
| `不是 HTTP 响应，首行是 ...` | 撞到了别的服务 / WS 端口 | 用 `/ping` 的端口，不是 `/pty` 的 |
| proxy 根本没起来（`mesh.proxy(...) 失败`） | 目标 peer 不在同一 overlay | `peers()` 里确认目标 fqdn/ip 存在且 `connected=true` |
| `mesh 未连通：...state=connecting` | management/signal 连不上 | 查 setup key、出网、公司代理；`NB_LOG_LEVEL=debug` 重跑 |

### 2.4 验鉴权（第 2 层：`POST /rpc/session.list`）

`session.list` 需要 Bearer，但**不需要** `X-Motif-Session`（来源：`docs/rpc.md` §5.1）。
bearer 不是 psk 原文，而是从配对 psk 派生的（motif `rzv::derive_bearer`，写进
`motif://pair` 链接）。P0-A 阶段直接用 motifd/配对流程给出的那个串：

```powershell
$env:MOTIF_BEARER = "<psk 派生的 bearer>"
.\target\release\motif-probe.exe --proxy-port 53124 --json-stdout
```

**预期**：

```
  [2/2] POST /rpc/session.list ok        HTTP 200       21ms  sessions=0
```

退出码含义：`0` 通过 / `1` 第 1 层（传输）失败 / `2` 第 2 层（鉴权）失败 / `3` 参数或环境错误。

**失败分支**：

| 现象 | 含义 | 处理 |
|---|---|---|
| `skipped_no_token` | 没给 token，第 2 层主动跳过 | 设 `MOTIF_BEARER`；**不要**用假 token 硬打（401 会被误判成隧道故障） |
| `HTTP 401` | bearer 不对 | 确认是 psk **派生**值；loopback/tailscale-only 且无 psk 时 motifd 是 `TokenStore::Disabled`（此时不带 token 也能过） |
| `HTTP 409` NotAttached | 这条路由要求 `X-Motif-Session` | 按文档 `session.list` 不该要求；若真拿到 409，说明 motifd 行为变了 → 拿它的版本号重新对拍 `docs/rpc.md` §5.1 |
| `HTTP 404` | 方法名/版本不匹配 | 对拍 motifd 版本与 `docs/rpc.md` 的方法表 |

### 2.5 验 `direct=true` 与端口随机（gate-A 的另两条）

```powershell
# 第 1 次
.\target\release\motif-probe.exe --with-mesh --motif-target 100.64.0.2:7777
# 期望摘要里：peers 里目标那条 direct=True relayed=False latency=<n>ms

# 退出再跑第 2 次，比对两次的 proxy 端口
.\target\release\motif-probe.exe --with-mesh --motif-target 100.64.0.2:7777
```

**预期**：两次 `mesh.proxy_port` 不同（同端口概率极低）；`direct_peer_count == 1`。

**失败分支**：

| 现象 | 含义 | 处理 |
|---|---|---|
| `direct=False relayed=True` | 走 relay 了 | 两端 UDP 不通（NAT/防火墙）；gate-A 要求 P2P，先修 51820/STUN，或明确记录"降级 relay"结论 |
| `direct=False connected=False` | 目标 peer 没上线 | 目标机 mesh 没起 / 不在同一个 setup key |
| 两次端口相同 | 不可能但真出现了 | 记下证据（这是 gate-A 反证项），并检查是否复用了上一次进程 |
| `peers` 为空 | 还没同步 peer 列表 | 等 5~10s 再跑；`NB_LOG_LEVEL=debug` 看 signal 状态 |

### 2.6 `session.attach` 的 409 语义（写进失败分支，避免踩）

P0-A 只用到 `/ping` 和 `/rpc/session.list`，但下一步接 UI 时会立刻用到 attach：

1. `POST /rpc/session.attach` → 200 + 响应头 **`X-Motif-Session: <sid>`** + 响应体里的
   `last_seq` / `ptys` / `views` 快照。
2. 后续所有需要会话上下文的 `/rpc/*` 必须回带该头；`/events?session=<sid>`、
   `/pty/<id>?session=<sid>` 用 query 带同一个 sid。
3. **409 `NotAttached`**（code `-32009`）= 头缺失或该 entry 已被清（`session.detach`、
   进程重启、ring 过期）。**处理：重新 attach 拿新 sid，绝不复用死 sid 重试** —
   复用只会稳定吃 409。
4. `session.attach` 传空的 `X-Motif-Session` 头且 entry 仍存活时会复用同一个 `client_id`
   （这是重连的正确姿势）；entry 已死则服务端铸新 entry。

---

## 3. 体积与"单 Go runtime"双闸

### 3.1 体积（plan-v3 §5）

```powershell
pwsh -File scripts\build-win-mesh.ps1
```

**预期**：

```
  netbird_embed.dll  plain        <A> MB
  netbird_embed.dll  stripped     <B> MB  (saved <pct>%)
  target-linked dll               <A'> MB  <- replace with stripped build
  motif-probe.exe                 <C> MB
  package total (dll + exe)       <T> MB / budget 120 MB  -> OK
```

并写出 `artifacts\size-report.json`（含 `-s -w` 前后两份、压缩率、预算判定）。

### 3.2 体积对齐（为什么 cargo 产出的那份是"肥"的）

`netbird-embed 0.3.1` 的 `build.rs` 里 `go build` **没有** `-ldflags="-s -w"`，而且 cargo
无法把 flag 透传给它：`GOFLAGS` 是按空格切分的单 flag 列表，`-trimpath` 这种能放，
**`-ldflags=-s -w` 不行**（会被切成两个参数，Go 报 unknown flag）。所以：

- `target\...\out\netbird_embed.dll` = 未 strip 的那份；
- `artifacts\netbird_embed.dll` = 脚本用 `-ldflags="-s -w" -trimpath` 重建的那份。

**P0-A 的临时对齐**（strip 只去符号/DWARF，不改代码，替换安全）：

```powershell
$out = (Get-ChildItem target\release\build -Recurse -Filter netbird_embed.dll | Sort-Object LastWriteTime -Descending)[0]
Copy-Item artifacts\netbird_embed.dll $out.FullName -Force
```

**根治**：按 plan-v3 §3.3 做 vendor + 在 `build.rs` 的 `go build` 里加
`-trimpath`、`-ldflags=-s -w`（fork 面就 1 行）。

### 3.3 单 Go runtime 闸

```bash
bash scripts/check-single-go-runtime.sh            # 扫 artifacts/ + target/
bash scripts/check-single-go-runtime.sh --expect-name netbird_embed artifacts/
bash scripts/check-single-go-runtime.sh --self-test   # 自检检测逻辑（本机已跑通）
```

```powershell
pwsh -File scripts\check-single-go-runtime.ps1 -ExpectName netbird_embed
```

**预期（正常）**：

```
=== 单 Go runtime 检查 =======================================
  扫描范围：.../artifacts .../target
  [GO]  .../netbird_embed.dll        <size>  go1.* + runtime.*

  OK：只有 1 份 Go runtime —— .../netbird_embed.dll
```

**预期（异常，必须 exit 1）**：

```
  !! 发现 2 份 Go runtime —— 同一进程加载两份会导致 GC 损坏：
       - .../libnetbird_second.dll
       - .../netbird_embed.dll
```

**失败分支**：

| 现象 | 含义 | 处理 |
|---|---|---|
| 扫到 0 份 | 产物没构建 / 扫错目录 | 先 `cargo build`；或显式传路径；确认不是只看 `target\release` 外层 |
| 扫到 2 份 | 真的链了两份 Go 库（或 vendor 里有一份旧的） | 只留 `netbird_embed.dll`；旧的 `.dll` 从打包目录清掉 |
| `--expect-name` 不匹配 | 命中的是别的 Go 库 | 找出来它从哪来（`cargo tree | findstr /i go`） |

---

## 4. 记录 gate-A 的 golden 输出（回灌 P0-B 对拍）

跑通后请把下面四项贴回任务/issue：

1. `motifd` 版本号（`ping.version`）；
2. `ping` 原始 `body`（`report.layers.ping.body`）——这是 P0-B 的 B1 对拍基线；
3. `sessions` 数量与一个 `session.list` 的成功响应体；
4. 两次 `proxy_port` 与 `peers[].direct` 的截图/JSON 片段。

> 这些同时是 `docs/design/mesh-fork-surface.md` §2「上游符号清单」的实证来源
> （见附录 A）。

---

## 附录 A：本 crate 实际用到的上游符号

> 已并入 `docs/design/mesh-fork-surface.md` §2（含 FFI `nb_*` 触达表与 fork 成本核算），
> 那里是**权威版本**；本节保留精简版，方便实机排障时就地查。

| 上游符号 | 用在哪 | 备注 |
|---|---|---|
| `netbird_embed::Client::new(ClientOptions)` | `Mesh::start` | |
| `ClientOptions` 字段：`setup_key` / `management_url` / `device_name` / `state_path` / `log_level` / `wireguard_port` | `client_options()` | 其余字段走 `Default` |
| `Client::start()` | `Mesh::start` | |
| `Client::stop()` | `Mesh::stop` | 显式 stop，不依赖 Drop |
| `Client::status()` → `Status{state, ip, fqdn, management_state, signal_state, peers, error}` | `Mesh::status` | 轮询，无回调 |
| `Client::peers()` → `Vec<Peer>`，`Peer{ip, fqdn, conn_status, relayed, latency}` + `Peer::is_connected()` | `Mesh::peers` | `direct = is_connected() && !relayed` |
| `Client::start_proxy(&str)` → `u16` | `Mesh::proxy` | Windows 唯一数据面 |
| `netbird_embed::ConnectionState`（含 `#[serde(other)] Unknown`） | 状态映射 | 未知值一律按未连接 |
| `Client::drop` → `nb_free`（Go 侧 Stop，可能阻塞） | 只在 `NetbirdMesh::drop` 里 warn | 见 crate 文档约束 2 |

**未使用（白名单禁止）**：`dial` / `listen` / `listen_udp` / `start_reverse_proxy` /
`set_log_level` / `token` / `private_key` / `pre_shared_key` / `config_path`。

## 附录 B：本清单里哪些是"未验证"（诚实清单，交付口径）

**统一口径：Rust/Go 代码未编译。** 本机（构建这个仓库的容器）没有 cargo / rustc / go /
PowerShell，只有 gcc / clang / nm / strip，所以下面每一条都标了"验到哪一步"。

| 项 | 状态 | 说明 |
|---|---|---|
| `crossdesk-mesh` / `motif-probe` 源码语法 | **已静态验证** | tree-sitter-rust 解析全部 8 个 `.rs` 文件，0 个 ERROR/MISSING 节点（只证明语法，不证明类型） |
| `cargo build -p crossdesk-mesh` / `-p motif-probe --features mesh` | **未编译** | 需 Rust 1.88 + Go 1.25 + mingw gcc |
| `cargo test -p crossdesk-mesh`（11 个单测） | **未运行** | 覆盖：Go runtime 三态（free/claimed/poisoned）互斥抢占与正常归还、**poisoned 为终态且不被 guard 的 drop 抹掉**、**poisoned 与"被占用"两种错误文案可分**、**poisoned 进程里 start() 命中专用错误**、double-stop 幂等、proxy 端口不写死、连接态映射、direct 判定、启动前校验、Debug 脱敏 |
| `cargo test -p motif-probe`（13 个单测） | **未运行** | 覆盖：HTTP 状态行/头/body 解析、chunked 解帧（含 trailer）、残缺 body 拒绝、非 HTTP 拒绝、空 body、目标解析、版本号抽取（平铺/嵌套/数字）、capabilities/session 计数、无 token 跳过鉴权、退出码分层、peers 文件合并、摘要渲染 |
| `build-win-mesh.ps1` | **未执行** | 本机无 PowerShell；仅做过逻辑复核 |
| `build-win-mesh.sh` | **流程已走通（fake go）** | 用替身 `go` 跑完整流程：两次构建、体积对比、`size-report.json` 落盘且为合法 JSON、预算判定与退出码正确；**真实 Go 构建未执行** |
| `check-single-go-runtime.sh` | **已通过自检** | `--self-test` 全绿：单 Go 通过 / Go+Rust 通过 / 两个 Go → exit 1 / `--expect-name` 命中与不命中 / `--strict` 空目录 → exit 1 / gcc 造真二进制走符号表兜底路径 |
| `check-single-go-runtime.ps1` | **未执行** | 本机无 PowerShell |
| 真实 NetBird overlay / motifd 对拍 | **待实机** | 需要目标机（motifd）+ 第二个 peer + setup key |

跑完 §2~§3 后请把附录 A/B 的"未验证"逐条改成实测结果（含时间、机器、输出片段），
这是 gate-A 的验收证据。

## 附录 C：三个最容易踩的坑

1. **端口是随机的。** `start_proxy()` 每次返回新端口；把它写进配置/文档时写"从返回值取"，
   不要写死 7777/8080。probe 的 `target.proxy_port` 就是给这一步留的证据。
2. **`Client::drop` 会阻塞，且"drop 未 stop"是单程票。** 关窗/退出路径上必须 `stop()`；
   `NetbirdMesh` 的 `Drop` 只打 warn（不会替你在 UI 线程上拆隧道），**并且会把本进程的
   Go runtime 钉成 `poisoned`**：之后任何 `start()` 都返回专用错误，只能重启进程。
   看到 "poisoned" 别去查"谁占用了 runtime" —— 那是另一条错误信息，排查方向完全不同。
3. **一进程一份 Go runtime。** 不要为了"两个 overlay"在同一进程里 `NetbirdMesh::new()`
   两次；`start()` 会直接报错。要两个 → 拆独立进程 + IPC（trait 边界就是进程边界）。
