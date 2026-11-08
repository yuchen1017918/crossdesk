# crossdesk — 跨端远程开发工作台（P0 进行中）

一个 host 用两种 overlay 形态把 Windows / iOS 客户端接到远端 `motifd` 上：
mesh 层只暴露 5 个方法，workbench 层只管 attach/detach，传输怎么走由平台决定。

> 方案：[`docs/plan-v3.md`](docs/plan-v3.md)（v3 = v2 核实版 + 用户三点补充 + 本轮新取证）
> 本仓库当前处于 **P0 阶段**，P0-A（Windows mesh 通道）与 P0-B（iOS CONNECT 承载）并行。

> **收口口径（2026-11-08 决策）**：协议层已验证、合规条件通过、实机未编译。
> 已定：安装包**不打包 `motifd`**（首启下载，形态 B）、iOS 定义为**前台使用**（不做 PacketTunnelProvider）。
> 详见 [`docs/plan-v3.md`](docs/plan-v3.md) §8、[`docs/p0/verification-report.md`](docs/p0/verification-report.md) §7。

## Gate 状态

| Gate | 内容 | 状态 | 证据 |
|---|---|---|---|
| **gate-0** | Motif 再分发合规 | 🟡 **条件通过** | 仓库声明 `MIT OR Apache-2.0`（Cargo manifest + README），但**无 LICENSE 正本** → 选 MIT 分支 + 自备全文 + 记录来源。详见 [`docs/licensing/decision.md`](docs/licensing/decision.md) |
| **gate-A** | Windows `start_proxy` → motifd | ⏳ **待实机**（代码就绪，本机无 Rust/Go 工具链） | `crates/mesh`、`crates/motif-probe`、[`docs/p0/win-p0a-runbook.md`](docs/p0/win-p0a-runbook.md) |
| **gate-B** | iOS CONNECT 能否承载 motifd | 🟢 **协议层已验证** / ⏳ 待真机 | 6 profile × 5 层全 pass；真机只剩「设备/后台」两件事 |
| 体积 | 安装包预算 | ⏳ 待实测 | `scripts/build-win-mesh.ps1` 会写 `artifacts/size-report.json` |

## 两个已用一手证据推翻的假设

1. **「iOS 上裸 TCP 到 `100.x` 不通 → 拓扑不成立」→ 前提不成立。**
   `motifd` 不是裸 TCP 服务，是 **HTTP + WebSocket 三通道**（`POST /rpc/{method}`、`GET /events` WS、`GET /pty/{id}` WS 双向）。CONNECT 隧道跑的就是 HTTP/1.1 + WS 升级，协议上可承载。见 plan-v3 §0.4。
2. **「打通 motifd = `curl /rpc/version`」→ 该 method 不存在。**
   真实探测端点是无鉴权的 **`GET /ping`**（回版本号）。鉴权/业务通道要单独用 `POST /rpc/session.list` + Bearer 验。分层验的理由：失败时能立刻区分「隧道不通」还是「token 不对」。见 plan-v3 §0.4.1。

## P0-B 协议仿真实测（真跑，非估算）

`probe/sim/` 用 Python 标准库起「假 motifd（三通道）+ HTTP CONNECT 代理 + 经隧道客户端」，6 个代理实现 profile 各跑一轮：

| profile | 代理特征 | B1 `/ping` p50 | raw 吞吐 | framed-zlib 吞吐 | 结论 |
|---|---|---|---|---|---|
| direct | 直连（基线） | 0.61 ms | 52.7 Mbps | 32.3 Mbps | 基线 |
| standard | 64 KiB 缓冲 | 1.52 ms | 55.7 Mbps | 32.4 Mbps | 理想 CONNECT 实现 |
| tinybuf | 1 KiB 缓冲 | 1.63 ms | 7.3 Mbps | 14.3 Mbps | 帧边界跨 recv 拼接正确（F2） |
| laggy | 4 KiB/chunk + 2ms | 2.19 ms | 1.88 Mbps | 1.86 Mbps | **relay 路径天花板 ≈2 MB/s**（F3） |
| lossy | 朴素代理（多读丢字节） | 1.68 ms | 46.0 Mbps | 24.6 Mbps | **F1：乐观流水线 5/5 挂死** |
| nohalf | 不传播半关闭 | 1.68 ms | 42.9 Mbps | 20.4 Mbps | **F4：`close` 后 2s 收不到 EOF** |

另跑一档 **5 分钟长连接**（`soak-07d31f91`）：events 1146、Ping 15/15、seq 零洞、无 close → **隧道空闲期不会自己断**，真机断连只可能来自系统挂起。

四条必须带进 iOS 实现的结论：

- **F1（medium，已复现）**：客户端若在 CONNECT 之后不等 `200` 就发首请求，朴素代理会丢掉已读进缓冲的多余字节，请求永久挂起。→ **dart:io `HttpClient` 默认等 200，别自己写裸 CONNECT 握手**。
- **F2（info）**：1 KiB 读缓冲下全过 → 不要写「一次 read 恰等于一个 WS 帧」这种假设（反之客户端已经是对的）。
- **F3（info）**：relay 路径 **1.88 MB/s + 335 ms 帧 RTT** 是量级上限 → 大输出场景要么走直连，要么换通路（见 `docs/p0/ios-fallback-decision.md`）。
- **F4（medium，已复现）**：代理不传播 `shutdown(SHUT_WR)` 时，`Connection: close` 之后 **2 s 收不到 EOF**。→ **按 `Content-Length`/chunked 判正文结束，不要依赖 EOF**。
- **F6（info，反直觉）**：`pty_compress=zlib` 对不可压缩载荷**净亏**（55.7 → 32.4 MB/s）；TUI 文本压缩比 14.16:1 才划算。→ **只对文本型下行开 framed zlib**。

Lead 已独立复跑 `--profiles standard,lossy` 交叉验证，F1 稳定复现（`pipelined_ok=fail`）。

## 目录

```
crates/
  host/         (service, realm) 精确槽位注册表 + LIFO dispose（cordis 零硬依赖）
  mesh/         overlay 唯一接口面：start/stop/status/peers/proxy 五方法
  workbench/    attach/detach seam + motifd 路由常量（transport-agnostic）
  motif-probe/  两层探针：GET /ping（无鉴权）→ POST /rpc/session.list（Bearer）
probe/
  sim/          协议仿真：假 motifd + CONNECT 代理 + 6 profile 基准（可复现）
  ios-connect/  Dart 探针（裸 CONNECT + 自写 WS 客户端，输出同 schema）
docs/
  plan-v3.md    方案 v3
  p0/           Windows / iOS 实机执行清单
  licensing/    gate-0：再分发判定、许可模板、第三方清点
scripts/        Go c-shared 构建（-s -w + 体积上报）、单 Go runtime 扫描、
                preflight-release.sh（发版闸门：AGPL 目录 / 宿主不得链 motifd / 许可附件 / commit 锁定）
```

## 环境要求

| 用途 | 需要 |
|---|---|
| 编译宿主 | Rust **1.88**（edition 2024）、Go **≥1.25**（c-shared） |
| **国内网络必备** | `GOPROXY=https://goproxy.cn,direct`（否则 `netbird-embed` 的 build.rs 拉 `proxy.golang.org` 必超时，见 plan-v3 A5）、`GOSUMDB=sum.golang.google.cn` |
| 跑协议仿真 | 只要 Python 3.10+，零第三方依赖 |
| iOS 真机 | Flutter 3.x + 真机（`flutter_netbird`），需 `Info.plist` 加 `NSLocalNetworkUsageDescription` |
| 目标机 | 一台能跑 `motifd` 的机器（Windows/macOS/Linux），开放 7777 |

## 现在就能跑的东西

```bash
# 协议仿真（本机即可，约 5 分钟，产出 JSON 报告）
cd probe/sim && python3 bench.py --tag fast

# 发版闸门自检（本机零依赖，3/3 应通过）
bash scripts/preflight-release.sh --self-test

# Rust 侧（本机已实跑：4/4 crate 编译、32 测试全绿）
export GOPROXY=https://goproxy.cn,direct          # mesh 的 Go 部分必需
cargo test --workspace                            # 32 passed
cargo clippy --workspace --all-targets -- -D warnings
cargo build -p motif-probe && ./target/debug/motif-probe --base http://127.0.0.1:17777 --token <bearer>
```

## 诚实边界

- **Rust 侧已在本机真编译真跑**（2026-11-08，Rust 1.88.0 + Go 1.25.4）：4/4 crate 编译通过、**32 个单测全绿**、clippy `-D warnings` 零告警、fmt 干净、探针对 sim 端到端跑通（分层诊断 0/1/2 退出码均按设计）。Windows 交叉编译产物在 `dist/win/`（654 KiB exe + 29.4 MiB stripped dll）。
- **Dart 侧**：不依赖 Flutter 的三个文件（`wire.dart` / `probe.dart` / `bin/probe.dart` = 1240 行）已 `dart analyze` → **No issues found**（首轮抓出 18 个编译阻断错误，含一处「局部变量遮蔽同名函数」的真 bug）。Flutter 侧 307 行仍需 Flutter SDK。
- **iOS 编译**：Linux 上编不出——`ipeddle` 的 Limitations 明写「SwiftPM only，不吃 xcodeproj/CocoaPods」，而 Flutter 的 iOS 工程正是 xcodeproj + CocoaPods。走 `.github/workflows/ios-dart.yml` 的 macOS runner（`flutter build ios --no-codesign`）。
- 协议仿真验的是**协议与代理实现的行为**，不是 iOS 系统行为：后台挂起、锁屏、真实 netbird 用户的 netstack 都只能在真机上验。清单见 `docs/p0/ios-p0b-runbook.md`。
