# P0 整合验收报告（Lead）

> 生成时间：2026-11-08 · 对应方案：[`../plan-v3.md`](../plan-v3.md)
> 口径：**"已验证" = 本机真跑过并留有产物**；**"待实机" = 代码/清单就绪但本机不具备验证条件**。本报告不含任何未经执行就跑通的声明。

---

## 1. Gate 总览

| Gate | 判定 | 依据 |
|---|---|---|
| **gate-0** 再分发合规 | 🟡 **条件通过** | `docs/licensing/decision.md`：`MIT OR Apache-2.0` 双许可二选一（Cargo manifest + README 双处声明），但**无许可证正本** → 选 MIT 分支 + 自备全文（`templates/LICENSE-MIT` 已备好）+ commit 锁定 `5f25f81`。三形态决策表已给，**C3（NetBird 四目录进包）为唯一硬红线**。依赖面：56/61 直接依赖已核清，传递闭包待构建机 `cargo deny` 确认（`third-party.md` §5/§6）。 |
| **gate-A** Windows mesh 通道 | ⏳ **待实机** | `crates/mesh`（238 行，5 方法白名单）、`crates/motif-probe`（两层探针）、`scripts/build-win-mesh.*`、`docs/p0/win-p0a-runbook.md`。本机无 cargo/go，**未编译**。 |
| **gate-B** iOS CONNECT 承载 | 🟢 **协议层已验证** / ⏳ 待真机 | `probe/sim` 6 profile × 5 层全 pass，含 4 条 findings（其中 2 条复现出真实缺陷）；真机只剩设备/后台两类变量。 |
| 体积预算 | ⏳ 待实测 | `scripts/build-win-mesh.ps1` 产出 `artifacts/size-report.json`（`-s -w` 前后各一份）。 |

---

## 2. 本机真跑过的证据（可复现）

### 2.1 P0-B 协议仿真 `probe/sim`

命令与产物：

```bash
cd probe/sim && python3 bench.py --tag fast        # 约 5 分钟，6 profile
# → reports/fast-9cde57bd.json（75 KB，含每 profile 每层指标）
```

| profile | 代理特征 | B1 `/ping` p50 | raw Mbps | framed-zlib Mbps | B2 events/pings | 判定 |
|---|---|---|---|---|---|---|
| direct | 直连基线 | 0.61 ms | 52.7 | 32.3 | 174 / 2 | pass |
| standard | 64 KiB 缓冲 | 1.52 ms | 55.7 | 32.4 | 173 / 2 | pass |
| tinybuf | 1 KiB 缓冲 | 1.63 ms | 7.3 | 14.3 | 173 / 2 | pass（F2） |
| laggy | 4 KiB/chunk + 2ms | 2.19 ms | 1.88 | 1.86 | 173 / 2 | pass（F3） |
| lossy | 朴素代理（多读丢字节） | 1.68 ms | 46.0 | 24.6 | 173 / 2 | pass + **F1** |
| nohalf | 不传播半关闭 | 1.68 ms | 42.9 | 20.4 | 172 / 2 | pass + **F4** |

B2 观测窗口 45 s、服务端 Ping 周期 20 s → `pings=2` 符合预期（不是心跳缺失）。B3 每 profile 跑 5 个子测：`random/tui × legacy-raw/framed-zlib` + `pty_not_found_should_404`，全部 sha256 校验通过（1 MiB 双向 × 8 组，服务端 `pty_bytes_up=4194304` 与客户端对齐，无静默丢字节）。

**加跑一档 5 分钟长连接（`soak-07d31f91`）**：B2 300 s → events 1146、**Ping 15/15**、seq 零洞、无 close、pong 与服务端计数对齐。结论：**隧道自身不会在空闲期断连**，真机上的断连只可能来自系统挂起（后台/锁屏），不是协议层。

### 2.2 Lead 独立复跑（交叉验证，不复用队友结论）

```bash
python3 bench.py --tag lead-verify --profiles standard,lossy --b2-seconds 8 --b3-bytes 262144
```

结果：两 profile 的 B1–B4 全 pass，**F1 稳定复现**（`lossy: pipelined_ok=fail`）。→ 队友报告可复现，不是一次性偶然。

### 2.3 Lead 代码复核：发现并修复 1 个真缺陷（附 1 次我自己判断被纠正）

复核 `crates/mesh/src/netbird.rs` 的 Go runtime 占用逻辑时，我判断存在"drop 未 stop → 占用标记永不释放 → 进程内不可恢复"的问题。**这个判断的实际方向是错的**，由实现方指出：

- 旧实现里 `GoRuntimeClaim::Drop` **无条件**把标记抹回 `free`，而 `Inner.claim` 随 `NetbirdMesh` 一起 drop；
- 所以真实症状是**静默放行**——在 Go 侧未确认拆干净的 runtime 上再建一个 client（比卡死更隐蔽，正是这条闸要防的重叠设备/状态文件风险）；
- 我要求的"三态 + 终态"，恰好把两个方向一起堵死，于是方案保留、理由改写。

已落地修复：

| 项 | 改动 |
|---|---|
| 状态机 | `AtomicBool` → `AtomicU8` 三态 `FREE / CLAIMED / POISONED`；`Poisoned` 为终态 |
| guard | 只做 `CAS(CLAIMED→FREE)`，不会把 Poisoned 抹掉 |
| `NetbirdMesh::Drop` | 有 client 时先 `poison()` 再 warn（函数体在字段 drop 之前跑 = 赶在 `Client::drop` 阻塞前的最后机会） |
| 错误分流 | `claim_error(state)`：poisoned 给专用文案（重启进程 / 拆独立进程），与"被另一实例占用"互相反证 |
| 同源漏洞 | `Client::new` 成功但 `client.start()` 失败时，原来裸 drop 也算"未经 stop 的 drop"；改为先 `stop()`，`stop` 也失败则 `poison()` |
| 测试 | 8 → **11** 个单测（新增 3：终态不被 guard 抹除 / 错误分流纯值 / poisoned 进程内 start 报专用错误） |

**未覆盖的接线（诚实标注）**：`NetbirdMesh::Drop → poison` 本身需要真 Go/FFI 才能触发，目前只有"代码审查 + `claim_error` 纯值测试"，那 3 行未运行。实现方建议不为测试让路去重构，我同意，已记进 runbook 附录 B。

### 2.4 `scripts/check-single-go-runtime.sh --self-test`

本机真跑：**7/7 通过**（含"两个 Go 产物 → exit 1"和"gcc 造的真二进制符号识别"）。这意味着"一进程一 Go runtime"这条一级约束有了可执行的 CI 卡口，而不是文档纪律。

---

### 2.5 真编译与端到端（2026-11-08 补跑，本轮把"未编译"清零）

本机装上了 **Rust 1.88.0** + **Go 1.25.4** 后，四个 crate 全部真编译、真跑测试：

| crate | 编译 | 单测 | 备注 |
|---|---|---|---|
| `crossdesk-host` | ✅ | **4 passed** | 精确槽位 / 无回退 / 双重注册拒绝 / LIFO 逆序 + 不中断 |
| `crossdesk-workbench` | ✅ | **1 passed** | 路由常量约束（含"/ping 不在 /rpc 下"） |
| `motif-probe` | ✅ | **16 passed** | 手写 HTTP + 两层探针 + 报告 + 退出码 |
| `crossdesk-mesh` | ✅ | **11 passed** | 三态 Go runtime 闸 / 幂等 stop / 脱敏 / 保守连接态 |

合计 **32 个测试全过**；`cargo clippy --workspace --all-targets -- -D warnings` **零告警**；`cargo fmt --check` **干净**。

**端到端真跑**（探针 → `probe/sim` 的假 motifd，非 mock 断言）：

| 场景 | 结果 | 退出码 |
|---|---|---|
| 正确 token | `/ping` 3 ms HTTP 200 version=sim-0.9.0；`/rpc/session.list` 2 ms HTTP 200 sessions=1 | **0** |
| 无 token | 第 2 层 `skipped_no_token`，并提示"不要用假 token 硬打" | **0** |
| 错 token | `/ping` ok，`/rpc/session.list` **failed 401** | **2**（鉴权层） |
| 错端口 | `/ping` **failed**，detail 直指"端口每次启动都会变" | **1**（传输层） |

→ 分层诊断按设计工作：**失败能立刻区分"隧道不通"与"token 不对"**，这正是 gate-A 要在实机上提供的能力。

#### 端到端跑出来的真 bug（静态测试抓不到）

首次端到端跑，`POST /rpc/session.list` 耗时 **2008 ms**（≈默认读超时 2000 ms）；同一请求 `curl` 只要 **3.7 ms**。

根因：探针发了 `Connection: close`，但 motifd 回 **`Connection: keep-alive` + `Content-Length`** 且不关连接；探针的读循环只在 **EOF / 超时** 时停止，于是一直阻塞到超时。**这正是 P0-B findings 里 F4「不能靠 EOF 判结束」的同一类错误——我们自己的探针也犯了。**
修复：按帧判完整性（`Content-Length` 收齐、或 chunked 终止块出现）立即收手，不等 EOF。**2008 ms → 2 ms**。已补 3 个回归测试（CL 收齐/未收齐/chunked 终止块/无长度回落 EOF）。

### 2.5b Windows 产物交叉编译（2026-11-08）

装上 `mingw-w64` + Rust `x86_64-pc-windows-gnu` std（走 rsproxy 镜像）后，**Windows 产物真编出来了**：

| 产物 | 大小 | 说明 |
|---|---|---|
| `dist/win/motif-probe.exe` | 654 KiB | PE32+，含 `mesh` feature，release+strip，只依赖系统 DLL |
| `dist/win/netbird_embed.dll` | **29.4 MiB** | Go c-shared，已 `-trimpath -ldflags="-s -w"` |

**A2 被实测证实**：上游 `build.rs` 的 `go build` **不带** `-trimpath/-s -w`，cargo 直编产物 **57.9 MiB**；
手动加后 **29.4 MiB**，**省 28.5 MiB / 49.2%**，且导出符号集 `diff` 为空（14 个 `nb_*` 完全一致）。
→ 这坐实了"patch build.rs 一行 = 省掉近一半体积"的结论，也让 §5 的体积预算从估算变成实测。

**口径**：交叉编译只证明"能链接出 PE"，**没有在任何 Windows 机器上运行过**。DLL 搜索路径、Go runtime 加载、
防火墙行为都未验。

### 2.5c Dart 静态分析：18 个编译阻断错误 → 0（2026-11-08）

装上 Dart SDK 3.12.2 后（`storage.flutter-io.cn` 镜像，1.2 MB/s），把**不依赖 Flutter** 的三个文件
（`lib/src/wire.dart` 443 行、`lib/src/probe.dart` 697 行、`bin/probe.dart` 100 行 = **1240 行**）
拆成最小工程跑 `dart analyze`。

**首次结果：18 个 error。** 三个根因（全部是编译阻断级）：

| # | 位置 | 错误 | 根因 |
|---|---|---|---|
| 1 | `probe.dart:232` | `illegal_async_return_type` + 连带 15 个 `unchecked_use_of_nullable_value` | 局部函数 `withTunnel` 声明返回 `Tunnel?`，但 `async` 且实际 `return r`（`RawResponse`）→ 返回类型补 `Future<RawResponse>` 后，15 个空安全错误一并消失 |
| 2 | `probe.dart:505` | `argument_type_not_assignable`（`int?` → `num`） | `tFirst` 在循环里被 `??=` 赋值，类型提升跨该边界不成立 → 显式 `!` 并捕获到局部变量 |
| 3 | `probe.dart:622` | `invocation_of_non_function_expression` | **局部变量 `b3` 遮蔽了同名顶层函数 `b3(...)`**，`await b3(...)` 实际在"调用一个 Map" → 局部变量改名 `b3res` |

修复后：**`No issues found!`**（1240 行全过）。

**仍未验证的**：`netbird_bridge.dart`(101) + `main.dart`(206) 依赖 Flutter SDK，纯 Dart 环境无法分析
（合计 307 / 1447 行 = 21%）。

**关于"Linux 上编 iOS"**（本轮查证结论，全部一手）：

| 方案 | 对 Flutter 是否可行 | 依据 |
|---|---|---|
| `ipeddle`（PyPI 0.1.0，真实存在） | ❌ **明确不支持** | 其 README `## Limitations` 原文：**"SwiftPM projects only. `.xcodeproj` / `.xcworkspace` projects are not read. CocoaPods are not supported"** —— Flutter 的 iOS 工程恰恰是 xcodeproj + CocoaPods |
| `Ripley`（资料提到的 Darwin 交叉编译器） | ❓ **查不到** | GitHub 搜索 `ripley ios linux cross` → `total_count: 0` |
| macOS 本机 / 云 macOS runner | ✅ **唯一可行** | 见 `.github/workflows/ios-dart.yml`：`macos-latest` + `flutter build ios --no-codesign` |
| 免费 Apple ID 7 天签名 | ✅ 与方案一致 | Sideloadly/AltStore 重签；与 `decision.md` §4 的"不自建即签"一致 |

→ **结论修正**：iOS 编译不是"绝对不可能"，而是"必须在 macOS 上"；**Linux 侧能做的是把需要 macOS 的部分交给
GitHub 的 macOS runner**，本地只跑 Dart 静态分析与协议仿真。已落 `ios-dart.yml` 两档流水线。

### 2.6 NetBird 真实入网（2026-11-08，用真实 setup key 跑通链路）

用真实 setup key 在本机（Linux/WSL2）跑通 `NetbirdMesh` 全链路：

```
Netbird engine started, the IP is: 100.79.x.242/16
connected to the Management Service stream
[status] started=true connected=true mgmt=true signal=true ip="100.79.x.242/16"
[peers] 共 0 个
[join] stopped（Go 侧已显式关停，未依赖 Drop）
→ "ensuring wt0 is removed, Netbird engine context cancelled"
```

**已证实的**（这几条之前只是"待实机"）：
- `netbird-embed` 的 Go c-shared 在 Linux userspace 能起（**无需 root / TUN 设备**）；
- setup key 注册成功，拿到 overlay IP，management 与 signal 双通道连通；
- 我们自己的 `NetbirdMesh` 封装能正确解析 `Status`（`connected/mgmt/signal/ip/fqdn`）；
- `stop()` 是有效关闭路径：日志确认 `wt0` 被移除、engine context 被取消，**无残留**。

**暴露的两个真实运维约束**（都影响实机验收节奏）：

| 现象 | 一手证据 | 处置 |
|---|---|---|
| **setup key 一次性消耗** | 第二次运行报 `PermissionDenied: couldn't add peer: setup key is invalid` | 实机反复验收请建 **reusable** setup key；一次性 key 每验一轮烧一把 |
| **状态文件未落盘 → 身份不持久** | 指定 `/tmp/crossdesk-nb-state.json` 与默认路径下均无文件生成 | 每次 `start()` 都是新设备注册。**实机 runbook 必须显式验证 state 文件是否真的生成**，否则"跨重启复用身份"这个承诺不成立（疑为 embed 模式的内存态，待有 key 时补验） |

**仍缺的**：`peers=0` —— 该租户里没有第二台机器，所以 `start_proxy` 无目标可代理，gate-A 的"经 proxy 打通 motifd"这一步**还没验**。需要：① 一把 available 的 setup key；② 一台在**同一 NetBird 网络**里跑着 `motifd` 的目标机。

---

## 3. 四条必须带进 iOS 实现的结论

| ID | 严重度 | 现象（实测） | 实现要求 |
|---|---|---|---|
| **F1** | medium（复现） | 客户端在 CONNECT 之后不等 `200` 就发首请求 → 朴素代理丢掉已读进缓冲的多余字节，**请求永久挂起**（5/5 timeout） | 必须等 CONNECT `200` 再发数据；`dart:io HttpClient` 默认如此，**不要自己手写裸 CONNECT 握手** |
| **F2** | info | 1 KiB 读缓冲代理下 B1/B2/B3 全过 | 客户端已正确处理"一帧跨多次 recv"；新增代码不得引入"一次 read = 一帧"假设 |
| **F3** | info | 4 KiB/chunk + 2ms 的 relay 型路径吞吐天花板 **≈1.9 MB/s** | PTY 大流量场景优先直连；否则必须用 `pty_frame=v1&pty_compress=zlib` |
| **F4** | medium（复现） | 代理不传播 `shutdown(SHUT_WR)` 时，服务端 `Connection: close` 后 **2 s 收不到 EOF**，读取方挂到超时 | 按 `Content-Length`/chunked 判正文结束，**不依赖 EOF**；自研代理必须传播半关闭 |
| **F6** | info（反直觉） | `pty_frame=v1&pty_compress=zlib` 对**不可压缩**载荷净亏：55.7 → 32.4 MB/s（每 64 KiB 压缩耗 2.62 ms 白烧）；TUI 文本压缩比 14.16:1 才划算 | **只对文本型下行开 framed zlib**，不要全局默认开 |

---

## 4. 三处被一手证据推翻的假设（v2 遗留）

| 原假设 | 事实 | 影响 |
|---|---|---|
| 「iOS 裸 TCP 到 100.x 不通 → 拓扑不成立，P2 要重画」 | `motifd` 是 **HTTP + WS 三通道**（`/rpc/*`、`/events`、`/pty/{id}`），CONNECT 隧道跑的是 HTTP/1.1 + WS 升级 | 拓扑成立，风险降级为「隧道质量」；P2 不需要重画，P0-B 即可判定 |
| 「打通 = `curl /rpc/version`」 | **该 method 不存在**；真实探测端点是无鉴权的 `GET /ping`（回版本号） | 验收标准重建为两层（`/ping` 无鉴权验隧道 → `session.list` + Bearer 验鉴权），失败可定位到层 |
| 「`DOUVO_LICENSE.txt` 是自有许可、`libtailscale` 是 BSD-3」 | DOUVO 是**标准 MIT**（且属客户端代码，不进 motifd）；`libtailscale 0.2.2` 是 **MIT** | 第三方义务清单缩小；`third-party.md` 按实际值更新 |

---

## 5. 未验证清单（诚实边界，不要对外说成已验证）

| 项 | 为什么没验 | 谁/何时 |
|---|---|---|
| ~~Rust 编译（4 个 crate）~~ | **已消除**（2026-11-08）：4/4 编译通过、32 测试全绿、clippy/fmt 干净 | — |
| ~~Go c-shared 成品体积~~ | **已实测**（§2.5b）：57.9 → 29.4 MiB，-49.2% | — |
| `start_proxy` 真代理到 motifd | **已证入网**（§2.6），但租户内无第二台 peer，`start_proxy` 无目标 | 需要 reusable key + 一台同网目标机 |
| Dart 探针编译与运行 | **纯 Dart 部分已 `dart analyze` 全过**（1240/1447 行，§2.5c）；Flutter 侧 307 行仍需 SDK | `ios-dart.yml` 的 macOS job 或本机 Mac |
| iOS 后台存活（5/15/30 min）、锁屏、弱网切换 | 必须真机 + Network Extension 语义 | `docs/p0/ios-p0b-runbook.md` §R7/R8 |
| 真实 psk → bearer 派生 | 需真实 pair 材料 | runbook §3 |
| 实际 motifd 版本对拍、`peers()` 的 `direct=true` | 需目标机在线 | runbook §4 |
| 510 个三方 crate 许可闭包完整性 | 部分包查询超时/限流 | `docs/licensing/third-party.md` 附录标注已扫描比例 |

---

## 6. 用户侧启动三步

```bash
# ① 看一眼合规结论（1 分钟，决定要不要把 motifd 打进安装包）
open docs/licensing/decision.md        # 走形态 A 则需先完成 G1-G3

# ② P0-B 在你机器上复现协议结论（5 分钟，零依赖）
cd probe/sim && python3 bench.py --tag fast

# ③ P0-A 上 Windows 目标机（按清单逐步执行，每步记录输出）
open docs/p0/win-p0a-runbook.md
```

---

## 7. 收口口径与两个已拍板的决策

> **对外统一表述：协议层已验证、合规条件通过、实机未编译。**
> 不得说成"P0 已完成/已跑通"。最大口径风险是"Rust 与 Dart 一次都没编译过"，消除它的是 gate-A 实机编译，不是更多文档。

### 7.1 决策 1：安装包**不打包** `motifd`（形态 B，首启下载）

三条理由叠加，其中第 3 条是本轮新发现的硬约束：

1. **合规义务面**：`MIT OR Apache-2.0` 无正本 → 选 MIT + 自备全文虽可接受，但随包附件清单已增至 `ring`（**Apache-2.0 AND ISC**，两条都要）、`subtle`、`if-addrs`；漏任何一个不是"许可不对"而是"缺附件"。
2. **体积与链接面**：`motifd` 默认静态链接 `libtailscale`（Go c-shared）与 `libghostty-vt`。
3. **双 Go runtime 的第二个来源（关键）**：`motif-server` 的 `default = ["tailscale-bundled"]` 会把 libtailscale 的 Go runtime 编进 `motifd`。**一旦 `motifd` 被当库链进宿主进程或 `dlopen`，就与 `netbird-embed` 的 Go runtime 撞红线**。所以即便将来改判形态 A，`motifd` 也只能是**独立二进制、经 HTTP/WS 访问**，绝不能链进宿主。

形态 B 下 G2 降级为：发布页许可声明 + 下载物 SHA-256 校验 + commit 记录。

### 7.2 决策 2：iOS 产品定义为**前台使用**

不做 `PacketTunnelProvider` 就没有系统级常驻；常驻是 10–15 人日的独立项目，不混进 P0。用"到期提醒 + 快速重连"覆盖运维场景，后台挂起断隧道的代价显式接受。

### 7.3 三条硬点已做成可执行闸门（不靠人记）

`scripts/preflight-release.sh`（自检 3/3 通过，可跑）：

| 闸 | 检查 | 判定 |
|---|---|---|
| R1 | 安装包内出现 `netbird/{management,signal,relay,combined}` | 命中即 FAIL；另用 34523B 的 LICENSE 大小特征兜底告警 |
| R2 | 宿主 workspace 依赖 `motif-server`；安装包里多份 Go 产物 | 依赖即 FAIL；`motifd` 之外出现第二份 Go 产物即 FAIL |
| R3 | 随包附件齐全（含 `ring` 的 `LICENSE-APACHE` + `LICENSE-ISC` 双份） | 缺任一即 FAIL（这正是"缺附件"而非"许可错"的拦截点） |
| R4 | `motif` 源码 HEAD 是否仍为 `5f25f81` | 漂移即 FAIL（版权行会失效） |

### 7.4 下一步顺序

1. **gate-A 实机编译优先**（消除"未编译"这一最大未知）→ 再谈 attach 闭环。
2. **gate-B 真机**（设备/后台五件事）。
3. **G2 只在改判形态 A 时做**。
4. **P1 暂停**，直到上面两条落定 —— 放包与否改变构建与分发拓扑。
