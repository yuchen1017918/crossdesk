# P0-B 兜底决策树 —— CONNECT 不达标时 iOS 走哪条路

> 版本 v1，2026-11-08。作者：p0-ios-connect。
> 上游依据：`docs/plan-v3.md` §0.4/§1.2、Motif 上游 `docs/rpc.md` 与 `docs/tailscale.md`（本轮直取，
> 见文末"证据"）、本仓库 `probe/sim/` 的实跑数字。
> **本文件当前给的是判据与工作量，不是结论**——结论要等真机 B1–B4 的数字回填 §5。

---

## 1. 什么时候才需要兜底（先定门槛，免得事后找理由）

触发兜底 = 真机报告里**任一硬门槛**不达标，且 §2 的低成本缓解手段已经试过。

| # | 门槛 | 通过 | 可接受（记风险） | 触发兜底 |
|---|---|---|---|---|
| T1 | B3 `/pty` 1 MiB 双向吞吐（raw） | ≥ 8 MB/s | 2–8 MB/s | **< 2 MB/s**（fast 实测：relay 型 `laggy` = **1.88 MB/s**） |
| T2 | B3 帧 RTT p50（64 KiB 帧回显） | ≤ 60 ms | 60–150 ms | **> 150 ms**（fast 实测：`tinybuf` = 103.9 ms 属可接受但发涩，`laggy` = 335.3 ms 已触线） |
| T3 | B2 5 分钟窗口掉线 | 0 次 | 1 次 | **≥ 2 次**（fast B2 45 s：events 172–174、seq_gaps 0、ping 2/2 —— 隧道侧不会自己掉，真机若掉就是系统掐的） |
| T4 | B1 `/ping` RTT p95 | ≤ 100 ms | 100–300 ms | **> 300 ms**（fast 实测：直连 0.94 ms / 经代理 2.07–2.74 ms；真机只剩 overlay RTT 一项） |
| T5 | B4a 409→重 attach 恢复 | 3/3 | 2/3 | **≤ 1/3**（fast 实测：6 profile 全 3/3，恢复 p50 5.3–14.9 ms） |
| T6 | 后台 30 min 后只能靠重连恢复 | 可接受 | — | 仅当产品要求"后台常连"时才成为门槛 |

锚点（来自 `probe/sim` 实跑，loopback）：

| 形态 | 吞吐 | 帧 RTT p50 | 主观对应 |
|---|---|---|---|
| 直连 / 字节透明代理 | 52.7 / 55.7 MB/s | 12.1 / 13.9 ms | 与本地终端无差别 |
| 小读缓冲代理（1 KiB） | 7.34 MB/s | 103.9 ms | 能用，但打字"发涩"、大输出有拖影 |
| relay 型（4 KiB / +2 ms） | 1.88 MB/s | 335.3 ms | `ls -R` / 编译日志明显卡；已到 T1 红线 |

> 真机若落在 7–8 MB/s、100 ms 附近，**先做 §2 的缓解再判**，不要直接换拓扑。

---

## 2. 换拓扑之前必须先试的三件事（成本从低到高）

| # | 缓解 | 依据 | 预期收益 | 成本 |
|---|---|---|---|---|
| M1 | 客户端开 `pty_frame=v1&pty_compress=zlib` | sim：小缓冲代理下 TUI 下行 8.8 → 28.2 MB/s（压缩比 14.16:1） | 下行带宽 ÷10~14；帧 RTT 降 | ~0（已实现，改个 query） |
| M2 | PTY 订阅策略改「单活跃」（只给当前 tab 保 `/pty`） | `docs/rpc.md` §1.7 步骤 6 明确两种策略 | 并发 WS 数 ÷N，弱网下掉线率降 | 0.5 天（客户端状态机） |
| M3 | 回前台强制重连 + `since` 补回放 | 仿真 B4a：恢复 p50 5.3–14.9 ms；上游 snapshot fallback 语义 | 把"后台掉线"变成"回前台 0.3 s 内补齐" | 1 天 |

如果 M1–M3 之后仍不达标，再进 §3。

---

## 3. 三条兜底路径

### A. iOS 用**官方 Tailscale App** + motifd 开 `--tailscale`（OS 级 100.x，彻底绕开 CONNECT）

**为什么它一定解决传输层问题**：Tailscale 的 iOS App 是 `NEPacketTunnelProvider`，
会给 100.64/10 装系统路由——**任何 App（包括我们的 Flutter App）直接 `Socket.connect("100.x", 7777)`
就能通**，不需要 CONNECT 代理、不需要 userspace 转发。协议层回到仿真里的 `direct` 档
（52.7 MB/s / 12.1 ms）。

**宿主要做的事**（上游已支持，见 `docs/tailscale.md` §8.1）：motifd 默认就编进了
`tailscale-bundled`，直接加参数即可，**不改代码**：

```bash
motifd --listen 0.0.0.0:7777 \            # 保留：Windows/netbird 路径继续用
       --tailscale --tailscale-hostname motifd-laptop \
       --tailscale-port 7777 \
       --tailscale-authkey "$(cat /etc/motif/ts.authkey)"
```

**iOS 侧改动**：删掉对 `startProxy()` 的依赖，`ProbeConfig.transport` 从 `connect` 换成 `direct`；
UI 加一句"需要安装 Tailscale 并加入同一 tailnet"。

| 维度 | 评估 |
|---|---|
| 传输性能 | 等于直连档（仿真 52.7 MB/s / 12.1 ms） |
| 后台存活 | **仍是 iOS 限制**：App 进后台照样会被挂起 → 仍要 M3 的回前台重连。不解决 T6 |
| 工作量 | **1–2 人日**（motifd 参数 + 客户端 transport 切换 + 设置页文案 + 文档） |
| 运维/产品代价 | 用户要装 Tailscale、要有 tailnet；**两套 overlay**（Windows=netbird，iOS=Tailscale）或整体迁到 Tailscale |
| 许可/合规 | 客户端 App 是官方分发，我们自己不打包；若自托管用 Headscale（BSD-3） |
| 风险 | 低。协议层用回 `direct`，已仿真验证 |

### B. 自建 rendezvous relay（本项目 `deploy/rendezvous/`）

> ⚠️ 现状：本仓库**没有** `deploy/rendezvous/README.md`（P0 阶段未建），上游 `docs/rendezvous.md`
> 取回是 404。所以这条是"要自建"的路径，不是"已有现成方案"。上游可确认的只有配对链路：
> `motif://pair` 链接 + `rzv::derive_bearer`（psk→bearer），见 `crates/motif-server/src/auth.rs`。

**形态**：一台公网 relay（TLS 终结），iOS 用普通 `https/wss` 连 relay，relay 按
pair token 把连接转发到宿主上的 motifd。传输层只要求"出站 443 可用"——iOS 上最不容易被掐。

| 维度 | 评估 |
|---|---|
| 传输性能 | 单跳中继，RTT ≈ 客户端→relay→宿主；带宽受 relay 出口限制。**做不到 A 的直连档** |
| 后台存活 | 同样受 iOS 挂起限制；`wss` 心跳 + 回前台重连（M3） |
| 工作量 | 服务端 5–8 人日（连接鉴权/配额/可观测/部署）+ 客户端 3 人日（配对流程 UX）+ 运维 |
| 代价 | 持续带宽/机器成本；多一个公网攻击面；psk 泄露风险要单独评审 |
| 风险 | 中高（要自己运维一条"所有 iOS 用户都经过"的链路） |

**什么时候选 B**：如果产品不接受"用户必须装第三方 VPN"，且 T1/T2 只差一档（例如真机 3 MB/s，
M1 之后 6 MB/s），B 比 C 快。

### C. 把 netbird 的 packet tunnel 打包进 App（继续用 netbird，但要 NetworkExtension）

**形态**：用 netbird 的移动端实现（其 iOS App 同样是 `NEPacketTunnelProvider`）做成我们 App 的
extension，拿到 entitlements，App 直接连 100.x。效果与 A 相同（OS 级路由），但**只保留一套 overlay**。

| 维度 | 评估 |
|---|---|
| 传输性能 | 等于直连档（内核转发，非 userspace 代理） |
| 后台存活 | NetworkExtension **可以在后台存活更久**（系统按需唤醒），是唯一可能满足 T6 的路径 |
| 工作量 | **10–15 人日**：gomobile 产 framework 10–15 MB 级、Swift NE 骨架、entitlement 申请、真机联调、崩溃/耗电调优 |
| 代价 | App Store 审核要求（Network Extension 需说明用途）；App 体积 +10~20 MB；耗电与系统策略调优 |
| 风险 | 中（工程量大但不是技术未知）；一旦做成，netbird 的 5 方法白名单可以扩到"系统级直连"，CONNECT 那套代码整体删除 |

**什么时候选 C**：如果 iOS 是长期一等公民、且不接受两套 overlay——这是最"正确"的终局，只是贵。

### D.（不推荐）SSH port-forward 退化路径

Motif 支持 `ssh-tunnel.md` 描述的 forward 形态，但 iOS 上要自带 libssh/密钥管理，
体验与运维都不如 A/B/C，仅作为"演示环境救急"。

---

## 4. 判据矩阵（一句话版）

| 判据 | A（Tailscale） | B（自建 relay） | C（NetworkExtension） |
|---|---|---|---|
| T1 吞吐 | ✅ 直连档 | ⚠️ 受 relay 出口限制 | ✅ 直连档 |
| T2 帧 RTT | ✅ | ⚠️ +1 跳 | ✅ |
| T3 掉线率 | ✅ 低 | ⚠️ 中 | ✅ 低 |
| T6 后台常连 | ❌ 仍挂起 | ❌ | ✅ 唯一可行 |
| 交付速度 | **1–2 天** | 8–11 天 | 10–15 天 |
| 用户成本 | 装 Tailscale + tailnet | 无感（我们运维） | 无感 |
| 团队长期负担 | 两套 overlay 的心智 | 一条公网链路的 SLA | 一套 overlay + NE 维护 |
| 失败风险 | 低 | 中高 | 中 |

**推荐顺序**：先做 M1–M3（0.5–1.5 天，且无论走哪条路都要做）→ 真机数据回来 →
若 T1/T2 触线选 **A**（本周可交付）；若产品否决第三方 VPN，选 **C**；
**B 只在"必须自建且 C 排不进本期"时使用**。

---

## 5. 实测触发记录（真机回来后填）

| 日期 | 设备 | B3 吞吐 | B3 帧 RTT p50 | B2 掉线 | 触发门槛 | 选定路径 | 备注 |
|---|---|---|---|---|---|---|---|
| — | — | — | — | — | — | — | 待真机 |

---

## 6. 需要产品/用户拍板的三件事

1. **iOS 用户能不能被要求安装 Tailscale**（决定 A 是否可用）；
2. **iOS 是否必须"后台常连"**（决定要不要为 C 付 10–15 人日）；
3. **是否接受一条自运维公网 relay**（决定 B 的运维成本是否可承担）。

在这三个问题有答案之前，工程侧只做 M1–M3 + 真机取数，不做拓扑改造。

---

## 证据（本轮直取，命令与返回）

| 结论 | 来源 |
|---|---|
| motifd = HTTP + WS 三通道（`/ping`、`/rpc/{method}`、`/events`、`/pty/{id}`），非裸 TCP | `https://raw.githubusercontent.com/xiachufang/motif/main/docs/rpc.md`（38 777 B，§1.1–1.7） |
| 网络 `--listen` 一定有 psk 派生 bearer；loopback/tailnet-only 为 `TokenStore::Disabled` | `crates/motif-server/src/auth.rs`（3 991 B，`TokenStore` 注释 + `verify_header`） |
| `Authorization: Bearer` 常时间比对；WS 额外允许 `?token=`；`/rpc/*` 不支持 query token | 同上 `auth.rs::verify_header_or_query` + `rpc.md` §1.2 |
| motifd 默认编进 `tailscale-bundled`，`--tailscale*` 开箱即用 | `docs/tailscale.md` §4.2（"motifd 默认开启 tailscale-bundled"） |
| iOS / native client 用 `TsServer::dial_tcp("motifd-laptop:7777")` | `docs/tailscale.md` §8.3 |
| 含 bundled tailscale 的 motifd ≈ 30 MB，strip 后 motif-tui ≈ 18 MB | `docs/tailscale.md` §10 |
| CONNECT 承载 HTTP/WS/大帧的实测量级 | `probe/sim/README.md`（6 profile 实跑表） |
