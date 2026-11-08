# 跨端远程开发工作台 方案 v3（P0 双轨 + 合规前置 + 接口面收敛）

> 基线：v2 核实版（2026-11-08）
> 本版改动来源：用户三点补充（P0 双轨 / LICENSE 前置 / netbird-embed 收敛）+ 本轮新增一手取证（2 条，见 §0.4、§0.5）
> 取证时间：2026-11-08，取证执行人：Lead（本机 curl 直取，命令与返回见各节脚注）

---

## 0. v3 相对 v2 的四处硬改动

### 0.1 P0 从单轨拆成双轨并行（用户补充 1）

v2 的 P0 只写「Windows 打通 motifd」，iOS 排到 P2。v3 改为 **P0-A / P0-B 同周并行，互为独立 gate**。理由不变且更强：iOS 通路若在传输层不成立，拓扑要重画，越晚发现返工越大。

### 0.2 LICENSE 从 P1 事务提前到 P0 准入条件（用户补充 2）

v3 把「Motif 仓库/LICENSE」列为 **P0 准入门（gate-0）**：未完成取证，安装包不得包含 motifd 二进制。本轮已取证，结论见 §2 —— **条件通过（conditional pass）**，不是阻塞，但有三个必做动作。

### 0.3 netbird-embed 收敛到 5 方法白名单 + 体积入预算（用户补充 3）

v3 明确 Go 侧接口面 = `start / stop / status / peers / proxy` 五个，Rust 侧 `Mesh` trait 只加 `proxy_to` 一个便捷封装。新增「不暴露清单」与「fork 预案（vendor + 最小 patch 面）」。体积预算单列（§5）。

### 0.4 新增一手取证：motifd 传输层 = HTTP + WebSocket，**不是裸 TCP**

v2 §2.2 的「裸 TCP 不通 → iOS 拓扑可能要重画」这条风险，**前置条件不成立**：

- 来源：`https://raw.githubusercontent.com/xiachufang/motif/main/docs/rpc.md`（文档自称 "wire-level 唯一权威"）
- 原文要点：Motif RPC = **JSON-RPC 2.0 形状的 HTTP + WebSocket 三通道协议**
  - `POST /rpc/{method}` —— 所有 JSON-RPC 请求/响应（HTTP）
  - `GET /events` —— WS，服务端→客户端结构化事件（JSON-RPC Notification 或 msgpack）
  - `GET /pty/{pty_id}` —— **WS 双向**，上行 stdin raw，下行默认 raw，可 opt-in framed zlib
  - `GET /`、`/assets/{*p}` —— 内嵌 Web UI 静态资源（HTTP）
- 鉴权：`Authorization: Bearer`（WS 因浏览器限制额外允许 `?token=`）；`/rpc/*` 不支持 query token
- 会话绑定：`POST /rpc/session.attach` 返回响应头 `X-Motif-Session: <sid>`，后续请求回带；`/events?session=` `&pty?id?session=` 用 query 带；找不到 entry → HTTP 409 `NotAttached`

### 0.4.1 补正：探测端点不是 `/rpc/version`，是**无鉴权的 `GET /ping`**

v2/v3 初稿把"打通 motifd"写成 `curl /rpc/version`，**该 method 不存在**。上游 `docs/rpc.md` §1.7 给出的接入流程中：

- `GET /ping` —— **不需要鉴权**，用于确认目标确实是 motifd **以及版本号**；`/ping.capabilities` 带能力声明
- `session.list` / `session.create` —— 不要求 `X-Motif-Session`
- `POST /rpc/session.attach` —— 成功后必须保存响应头 `X-Motif-Session` **和** 响应体里的 `last_seq`（作事件回放游标）
- `GET /events?session=<sid>&since=<seq>` —— WS
- `GET /pty/<id>?session=<sid>&since=<cursor>` —— WS 双向；新客户端推荐同时带 `pty_frame=v1&pty_compress=zlib`，且**只有 meta 确认后才按 framed zlib 解码**，否则按 legacy raw

这条对验收影响很大：**用 `/ping` 做隧道验证最干净**（无鉴权变量），鉴权/业务通道单独作为下一层验收项，这样一旦失败能立刻定位是"隧道不通"还是"token 不对"。

**推论（改写 v2 的结论）**：
- iOS 的 CONNECT 代理**理论上能承载 motifd**，因为隧道内跑的是 HTTP/1.1 + WS 升级，不是 100.x 上的裸 TCP 连接。
- 但**风险没有消失，只是换位**：从"拓扑不成立"变成"隧道质量是否够跑 PTY 双向字节流"。新的 P0-B 验收点见 §1.2。
- 附带修正 v2 §2.2 表格里 `tailscale://7777` 的语义：Motif 有一等公民的嵌入式 tsnet（`crates/motif-tailscale`，vendor `libtailscale`），iOS 若 CONNECT 不达标，**可直接用 Motif 自带 tsnet/relay**，不必等 P2 重做。这与用户补充 1 的兜底方向一致，且现在有代码级依据（`docs/tailscale.md`）。

### 0.5 新增一手取证：Motif 仓库已定位，LICENSE = 声明式双许可 + **缺正本**

见 §2 完整证据链。一句话：`[workspace.package] license = "MIT OR Apache-2.0"` + README §License 同口径，但**仓库递归 1094 个文件里没有任何项目级 LICENSE 文件**。判定为「可再分发（选 MIT 分支）+ 三项补偿动作」。

---

## 1. P0 双轨（同周，两条独立 gate）

```
Week 1
├── P0-A  Windows  mesh 通道                        [gate-A]
│    cordis-rs host → netbird-embed start → start_proxy("100.x:7777")
│    → curl http://127.0.0.1:{port}/ping          （无鉴权，仅验隧道+身份）
│    → curl -H "Authorization: Bearer ..." -X POST .../rpc/session.list（验鉴权+业务）
│    验收：/ping 返回 motifd 版本；session.list 返回 200；peers() 目标机 direct=true；
│          proxy 端口随每次启动变化
│
├── P0-B  iOS  CONNECT 承载能力                     [gate-B]
│    前提（已完成，非待办）：motifd = HTTP + WS 三通道（§0.4、§0.4.1）
│    flutter_netbird up() → startProxy() → NetbirdHttpOverrides
│    验收五条（逐条可测，分层失败定位）：
│      B1 GET /ping 经隧道返回 200 + 版本号        （只验隧道，无鉴权变量）
│      B1' POST /rpc/session.list + Bearer 200     （验鉴权通道；失败即 psk→bearer 派生问题）
│      B2 GET /events?session=<sid> WS 升级成功且 5min 不掉（服务端每 20s Ping）
│      B3 GET /pty/<id>?session=<sid> WS 双向 raw 吞吐 ≥1MB 不损坏（sha256 校验）
│      B4 后台 5/15/30min：getFullStatus() 连通态 + WS 存活；掉线后
│         /rpc/session.attach 返 409 → 重新 attach（勿复用死 sid），since=last_seq 续传
│    兜底（同一周必须至少摸一条）：Motif 自带 tsnet(`--tailscale`) 或 rendezvous relay
│
└── gate-0  合规（P0 准入，已完成取证，动作项待办）
```

**两条轨的独立性**：A 失败不影响 B 的结论；B 若 B3 不达标，iOS 转 tsnet/relay，**不重排 P2**。两轨共用同一份 `motifd` 版本与同一套鉴权材料（psk → bearer 派生），因此 P0-A 的 golden 输出（版本号、`/rpc/*` 响应样例）要回灌给 P0-B 做对拍。

### 1.1 P0-A 交付物

1. `crates/mesh/`：`Mesh` trait + `NetbirdMesh` 实现（5 方法白名单，§3）
2. `scripts/build-win-mesh.ps1`（Go c-shared 构建 + `-ldflags="-s -w"` + 体积上报）
3. `crates/motif-probe/`：**两层**对拍器（`GET /ping` 无鉴权 → `POST /rpc/session.list` + Bearer），输出 JSON 报告
4. 一份「Windows 实机执行清单」（本机无 Rust/Go 工具链，见 §6）

#### 1.1.1 P0-A 实施期发现的三个结构性问题（已纳入实现）

| # | 问题 | 影响 | 处置 |
|---|---|---|---|
| A1 | **Windows 必须 `x86_64-pc-windows-gnu`，不能 MSVC**。上游 `build.rs` 只发 `rustc-link-lib=dylib=netbird_embed`，而 `go build -buildmode=c-shared` 在 Windows 只产 `.dll`+`.h`，**不产 MSVC 需要的 `.lib` 导入库** → MSVC 链接必挂 `LNK1181` | 工具链选型错误会在链接阶段浪费半天 | runbook §0 写死 GNU toolchain；MSVC 兜底（gendef/dlltool 生成 import lib）作为附录 |
| A2 | **上游 `build.rs` 不带 `-s -w`，且 cargo 无法透传**：`GOFLAGS` 按空格切分，`-trimpath` 能放、`-ldflags=-s -w` 不行 | 直接 `cargo build` 出来的 DLL 是"肥"的，§5 的体积预算永远压不下来 | 构建脚本改用独立 `go build` 两次（plain vs stripped）实测差值；**根治需 vendor + patch `build.rs` 一行**（见 §3.3 P1） |
| A4 | **双 Go runtime 的第二个来源（比 netbird-embed 更隐蔽）**：`motifd` 默认 feature 是 `tailscale-bundled`，经 `motif-net → motif-tailscale → libtailscale-sys` 的 `build.rs` 把 libtailscale 的 Go c-shared **静态链接进 motifd 二进制**。若有人把 `motifd` 当 **库** 链进宿主进程（或 `dlopen`），就会与 `netbird-embed` 的 Go runtime 在同一进程里撞"单 Go runtime"红线 | 宿主侧永远不能链接 `motif-server`/`motifd`；`motifd` **只能作为独立二进制分发、经 HTTP/WS 访问**（这也正好是它的天然形态）。硬闸：`scripts/preflight-release.sh` R2 | 已核（`crates/motif-server/Cargo.toml` 的 `default = ["tailscale-bundled"]`） |
| A6 | **netbird userspace 不支持"本机访问自己的 overlay IP"**：`start_proxy(100.x:port)` 到自己时，netstack 直接 `connection was refused`（客户端侧表现为 WSAECONNRESET 10054），即使 motifd 正常监听 `0.0.0.0:7777` 且 `curl 127.0.0.1:7777` 成功 | **单机无法自闭环**：gate-A 必须有一台**第二设备**做目标；产品上「本机客户端 + 本机 motifd」这个用例不成立，motifd 必须跑在**另一台**机器 | 写进 runbook 与验收标准；诊断时先 `curl 127.0.0.1:7777` 排除服务端问题，再看 netbird 日志里的 `connection was refused` | 实测（2026-11-08，Windows + netbird-embed 0.3.1） |
| A5 | **国内网络下 `go build` 必然失败**：`netbird-embed` 的 build.rs 会拉 `proxy.golang.org`（`netbirdio/netbird`、`wireguard/wgctrl` 等），本机实测全部 **i/o timeout**。必须设 `GOPROXY=https://goproxy.cn,direct`（或阿里云镜像） | 不设就卡在"build.rs 失败"，且报错看起来像代码问题 | 写进 runbook §0 与 CI 环境变量；`GOSUMDB` 同理需换 `sum.golang.google.cn` | 实测 |
| A3 | 同进程第二个 `NetbirdMesh.start()` 被拒（直到前一个 `stop()`） | 这是"一 Go runtime"约束的直接体现，不是缺陷 | **保持严格语义**（Lead 决策）：多实例会让违规路径更隐蔽；P0 单 overlay 需求下无收益。要"变化通知"在 Rust 侧 poll+diff，不扩实例数 |

### 1.2 P0-B 交付物

1. `probe/ios-connect/`：Dart 探针（B1–B4 四条自动化到能一条命令跑完）
2. **协议级仿真**（本机可跑，不需真机）：`probe/sim/` —— 用 Python 起一个最小 HTTP+WS 服务器冒充 motifd，加一个 CONNECT 代理，验证「CONNECT 里跑 WS 升级 + raw 二进制双向」在协议层成立，并测出典型吞吐/延迟基线。这是把实机风险降到最低的前置（真机只补"设备/系统/后台"三件事）
3. 「iOS 实机执行清单」+ 兜底路径决策树（CONNECT 不达标 → tsnet / rendezvous relay）

---

## 2. LICENSE / 再分发合规（gate-0）

### 2.1 证据链（本轮直取）

| # | 证据 | 取法 | 结论 |
|---|---|---|---|
| E1 | `github.com/xiachufang/motif` 存在，`default_branch=main`，`language=Dart`，`license` 字段 **null**，4 stars，pushed 2026-11-02 | `GET /repos/xiachufang/motif` | 仓库有效但 GitHub 未识别到许可证 |
| E2 | 根目录文件清单：**无 LICENSE / COPYING / NOTICE** | `GET /contents/` | 无许可证正本 |
| E3 | 递归 1094 个路径，仅 3 个 LICENSE：`crates/libghostty-vt-sys/LICENSE`、`crates/libghostty-vt/LICENSE`、`apps/flutter/.../DOUVO_LICENSE.txt` | `GET /git/trees/main?recursive=1` | 均为第三方 vendored，非项目许可 |
| E4 | `Cargo.toml`：`[workspace.package] license = "MIT OR Apache-2.0"` | raw `Cargo.toml` | 作者书面声明双许可 |
| E5 | `crates/motif-server/Cargo.toml`：`license.workspace = true`（产物 `motifd`） | raw | motifd 继承双许可声明 |
| E6 | `README.md` §License：「MIT OR Apache-2.0.」 | raw README | 与 manifest 一致 |

### 2.2 判定

**形态**：`MIT OR Apache-2.0` 双许可（二选一），**不是**分目录许可。

**缺陷**：缺许可证正本与版权归属声明（无 `LICENSE-MIT` / `LICENSE-APACHE`、无 `NOTICE`）。这不改变"作者已明示许可"的性质，但让"按 MIT 要求随分发物附许可全文 + 版权声明"这一步**没有现成文件可附**。

**结论**：**条件通过（conditional pass）**——可以把 `motifd` 打进安装包再分发，但必须同时满足：

| 动作 | 负责 | 验收 |
|---|---|---|
| G1 选定 **MIT 分支**（不以 Apache-2.0 分支分发，避免专利条款/声明复杂度） | license-recon | 决策记录落 `docs/licensing/decision.md` |
| G2 自备 MIT 全文 + 版权行（`Copyright (c) Motif authors` + 仓库 URL + 锁定 commit + 日期），随安装包 `third_party/motif/LICENSE-MIT` 分发 | license-recon | 安装包内路径存在且内容可读 |
| G3 向仓库提 issue/PR 请求补 `LICENSE-MIT` / `LICENSE-APACHE` 正本；在其补上之前，版本锁定 commit 并在 `third_party/motif/SOURCE.md` 记录来源与缺失说明 | license-recon | 记录落盘 + issue 编号 |
| G4 传递依赖清点：`libghostty-vt`(MIT)、`doubao_asr`(自有)、以及 `motif-server` 的其他 crate 依赖 | license-recon | `docs/licensing/third-party.md` 覆盖 motifd 实际链接的依赖树 |

**若 G2 不执行 → 只能走"不打包"路径**：安装包不带 motifd，首启由用户从官方 Releases 下载（`github.com/xiachufang/motif/releases/latest`）。两条路径的产品差异要写进 README。

### 2.3 flutter_netbird 与 netbird-embed

| 组件 | 许可 | 再分发判定 |
|---|---|---|
| `netbird-embed` 0.3.1 | BSD-3-Clause（crates.io） | 可分发性好；附 BSD-3 全文 + 版权声明即可 |
| `flutter_netbird` 1.0.5 | MIT（pub.dev） | 附 MIT 全文；但维护度低（见 §4 风险） |
| NetBird 主仓 | BSD-3 为主，`management/ signal/ relay/ combined/` 为 **AGPLv3** | **只分发客户端/embed 部分，不打包自托管 management/relay**；若自托管，作为独立服务进程、独立分发物 |

> 注意 `pub.dev` 在本机不可达（curl 超时），`flutter_netbird` 的许可证需从 GitHub 镜像或用户侧网络复核 —— 列为 T3 的待办复核项。

---

## 3. netbird-embed 接口面收敛（用户补充 3 落地）

### 3.1 白名单：只此五个

```rust
// crates/mesh/src/lib.rs —— 对外唯一接口面
pub trait Mesh: Send + Sync {
    fn start(&self, cfg: MeshConfig) -> Result<()>;      // 加入 overlay
    fn stop(&self) -> Result<()>;                        // 显式停 Go 侧（勿依赖 drop）
    fn status(&self) -> MeshStatus;                      // 连接态 + 本机 overlay IP
    fn peers(&self) -> Vec<Peer>;                        // fqdn / ip / direct|relayed
    fn proxy(&self, target: SocketAddr) -> Result<u16>;  // → 127.0.0.1:<随机端口>
}
```

`proxy` 是唯一"做数据面"的方法，Windows/iOS 走各自形态（Windows `start_proxy`；iOS `startProxy`）。**上游 `dial/listen/listen_udp` 一律不暴露**（Unix-only，且与 Windows 目标无关）。

### 3.2 不暴露清单（写进 crate 文档，防止后续偷加）

- ❌ `dial` / `listen` / `listen_udp`（Unix-only）
- ❌ 路由 / ACL / 策略管理 / DNS 配置
- ❌ 事件回调流（上游只有 JSON 轮询，若要「变化通知」在 Rust 侧自己 poll + diff 封一层，不扩上游面）
- ❌ 多客户端 / 多账号 / 多 overlay 实例
- ❌ 日志流直通（只在 `status()` 内带一个 error 摘要）

理由：把 fork 面积控制在"5 个函数 + 1 个 JSON 结构"的量级。若上游停更，替换实现只需满足这 5 个签名。

### 3.3 fork 预案

1. **pin + vendor**：`Cargo.toml` 锁 `netbird-embed = "=0.3.1"`，`.cargo/config.toml` 预留 `[patch]` 段（注释态）
1b. **第一个已知 patch 项（来自 P0-A 实测）**：给上游 `build.rs` 的 `go build` 调用加上 `-trimpath -ldflags=-s -w`。这是唯一一条"即使上游不 fork 也想做"的改动 —— 它直接决定 §5 的体积能否达标。记录于 `docs/design/mesh-fork-surface.md` §3
2. **最小 patch 面记录**：`docs/design/mesh-fork-surface.md` 记录当前实现实际调用的上游符号清单（本轮由 P0-A 产出，Cargo 编译前为空壳，编译后自动 `nm`/`cargo tree` 补）
3. **进程边界预案**：若同进程第二个 Go runtime 冲突（v2 已识别的一级炸弹），mesh 拆独立进程 + 本地 IPC（Unix socket / Windows named pipe），接口面仍是这 5 个方法 —— 因为 trait 边界就是进程边界
4. **构建期硬上限**：`scripts/check-single-go-runtime.sh` 扫描产物符号，出现第二个 Go runtime 特征即 fail

---

## 4. 风险登记（v3 增量，只列变化的）

| 风险 | v2 状态 | v3 状态 | 变化原因 |
|---|---|---|---|
| userspace 只出 CONNECT → iOS 拓扑不成立 | 需实测，可能重画 | **降级**：motifd 是 HTTP+WS（§0.4），拓扑成立；剩「隧道质量」风险 | 一手 `docs/rpc.md` |
| iOS 需等 P2 才能接 | P2 才做 | **提前到 P0-B** | 用户补充 1 |
| Motif LICENSE 不明 | 待核 | **条件通过** + G1–G4 动作项 | 本轮取证 §2 |
| netbird-embed 停更 → fork 成本失控 | "预留 fork 预算" | **量化**：接口面 5 方法 + 不暴露清单 + 符号扫描 | 用户补充 3 |
| .so 体积 | 一句话提示 | **入安装包预算表**（§5）+ 构建脚本强制 `-s -w` | 用户补充 3 |
| flutter_netbird 许可证据 | 标 MIT | **待复核**（pub.dev 本机不可达） | 取证限制 |

---

## 5. 体积预算（安装包）

| 项 | 估算 | 说明 |
|---|---|---|
| `libnetbird_embed` (Go c-shared) | **实测（2026-11-08, Windows amd64）**：cargo 直编 **57.9 MiB** → `-trimpath -ldflags="-s -w"` **29.4 MiB**，省 **28.5 MiB / 49.2%**；导出符号集完全一致（14 个 `nb_*`） | Windows `.dll` 与 Linux `.so` 分别记。**A2 被实测证实**：上游 build.rs 不带 `-s -w`，直编出来就是两倍大，patch 一行即可省掉近一半 |
| `motifd`（Rust, release） | 待实测（形态 B 不打包 → 归零） | 打包路径见 §2.2；已定形态 B（首启下载），此项不计入安装包 |
| crossdesk 宿主探针 | **实测 654 KiB**（`motif-probe.exe`，含 mesh feature，release+strip） | 不含 mesh/motifd；真实 Windows 运行未验 |
| Flutter iOS app | 待实测 | iOS 走 xcframework（flutter_netbird） |
| **合计** | 待实测 | 产出一张"每项实测 vs 预算"的表，超 120MB 触发拆分进程/按需下载策略 |

构建脚本必须打印每一项 `du -h` 并写进 `artifacts/size-report.json`，CI 里做阈值告警。

---

## 6. 团队分工与写域（互不重叠）

| 角色 | 写域 | 交付 |
|---|---|---|
| Lead | `crossdesk/Cargo.toml`, `crates/host/`, `docs/plan-v3.md` | 方案 v3、workspace 骨架、整合验收 |
| `p0-win-mesh` | `crates/mesh/`, `scripts/build-win-mesh.ps1`, `scripts/check-single-go-runtime.sh` | P0-A 代码 + 构建/体积脚本 + Windows 实机清单 |
| `p0-ios-connect` | `probe/**`, `docs/p0/ios-*.md` | P0-B 探针 + 协议级仿真 + iOS 实机清单 + 兜底决策树 |
| `license-recon` | `docs/licensing/**` | gate-0 判定文档 + G1–G4 动作项 + 第三方依赖清点 |

### 6.1 本机环境事实（重要：约束产出形态）

| 能力 | 状态 |
|---|---|
| cargo / rustc / go / dart / flutter | **全部 MISSING** |
| gcc 14.3 / clang 14 / nm / strip | 可用 |
| github.com raw + api | 可达（200） |
| pub.dev | **不可达**（curl 超时） |
| iOS 真机 / Windows 目标机 | 无 |

**因此**：所有 Rust/Go/Dart 代码在本机**无法编译验证**。产出口径必须是「可编译、附实机执行清单」，**不得声称已跑通**。能本机真跑的是：协议级仿真（Python/C）、许可证与源码取证、脚本静态检查。

---

## 7. 验收（gate 汇总）

- [ ] **gate-0**：`docs/licensing/decision.md` 存在，含 G1–G4 四项状态；未完成 → 安装包不含 motifd
- [ ] **gate-A**：`/rpc/version` 经 Windows proxy 返回正确版本；`peers()` 目标机 `direct=true`；连续两次启动 proxy 端口不同
- [ ] **gate-B**：B1–B4 四条在 iOS 真机有记录；或触发兜底路径且兜底路径的 B1–B3 在真机通过
- [ ] 体积：`artifacts/size-report.json` 五项齐；`-s -w` 前后各一份
- [ ] 接口面：`crates/mesh` 公开符号 ⊆ 5 方法（`cargo doc` 或 `cargo public-api` 输出为准）
- [ ] 单 Go runtime：`scripts/check-single-go-runtime.sh` 在产物上通过


---

## 8. 收口记录（2026-11-08 决策）

### 8.1 两个拍板项（已定）

| 项 | 决策 | 理由 | 代价 |
|---|---|---|---|
| 安装包放不放 `motifd` | **形态 B：首启从官方 Releases 下载**（不打包） | ①MIT 正本缺失下"自备全文"仍可接受，但随包附件清单已增至 `ring`(Apache-2.0 **AND** ISC)/`subtle`/`if-addrs`；②`motifd` 默认静态链接 `libtailscale` 与 `libghostty-vt`（见 A4）；③首启下载零随附义务、更新灵活 | 离线不可用、版本不可控、首启依赖网络 |
| iOS 是否常驻后台 | **产品定义为"前台使用"** | 无 `PacketTunnelProvider` 就没有系统级常驻；常驻是另一个量级项目（10–15 人日），不混进 P0 | 后台挂起断隧道、attach 掉线；用"到期提醒 + 快速重连"覆盖运维场景 |

> 形态 B 下 G2 降级为：发布页的许可声明 + 下载物 SHA-256 校验 + commit 记录。**若将来改判为形态 A**，必须在上实机前完成 `templates/LICENSE-MIT` 接线、`ring` 双附件、commit SHA 断言，并跑 `scripts/preflight-release.sh` 全绿。

### 8.2 收口口径（对外统一表述）

> **协议层已验证、合规条件通过、实机未编译。**

不得表述为"P0 已完成"或"已跑通"。四个 gate 的准确状态见 `docs/p0/verification-report.md` §1。

### 8.3 下一步顺序（P1 暂不启动）

1. **gate-A 实机编译优先**：当前最大未知是"Rust 侧一次都没编译过"。先让 4 个 crate 在 Windows(windows-gnu) 上 `cargo build` 通过、11+13 个单测跑起来，再谈 attach 闭环。
2. **gate-B 真机**：协议层已过，只剩设备相关五件事（见 `docs/p0/ios-p0b-runbook.md` §8）。
3. **G2 仅当改判形态 A 时做**；形态 B 下不做随包接线。
4. **P1（Windows 闭环）在两个拍板项落定后再启动** —— 放包与否会改变构建与分发拓扑。
