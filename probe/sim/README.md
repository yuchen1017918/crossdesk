# probe/sim —— motifd 协议级仿真（P0-B 的"可判定"部分）

本目录回答一个问题：**motifd 的 HTTP + WebSocket 三通道，能不能原样穿过一条
HTTP CONNECT 隧道**——以及穿不过去时，是"隧道不行"还是"某一侧的实现有坑"。

它是 `docs/p0/ios-p0b-runbook.md` 的前置：真机只剩「设备/系统/后台」三件事要验，
协议层在这里先跑出数字。

## 结论速览（2026-11-08 实跑，非推演）

- **CONNECT 在协议层承载 motifd：成立**。HTTP 请求/响应、WS 升级（101 + `Sec-WebSocket-Accept`）、
  64 KiB 二进制帧双向、20 s 服务端 Ping、close code —— 六种代理形态里，字节透明的两种
  与直连的差异只有 RTT +0.9 ms、吞吐 −0~5%。
- **但有三类代理缺陷会让它"功能对、体验坏/挂死"**，且都能在仿真里复现并量化：
  小读缓冲（吞吐 55.7 → 7.3 MB/s）、relay 型分片（1.88 MB/s 天花板 + 335 ms 帧 RTT）、
  不传播半关闭（等 EOF 的读取方 2 s 超时）。
- **客户端侧有一条硬纪律**：CONNECT 之后必须等 `200 Connection Established` 再发首个请求。
  乐观流水线在朴素代理上 5/5 挂死（丢 260 字节，请求永久无响应）。

## 组成

| 文件 | 作用 |
|---|---|
| `motifd_sim.py` | 最小 motifd 假服务：`GET /ping`（无鉴权）、`POST /rpc/{method}`（Bearer / 401 / 404 / 409 NotAttached / attach 下发 `X-Motif-Session`）、`GET /events`（WS，20 s Ping、45 s 空闲 Close、`seq` 单调）、`GET /pty/{id}`（WS 双向，首帧 Text meta，之后 Binary，raw 或 framed zlib） |
| `connect_proxy.py` | HTTP CONNECT 代理，5 种形态（见下表），字节透明中继 |
| `probe_client.py` | 隧道 / HTTP / WS 客户端（纯标准库），含载荷生成与统计 |
| `bench.py` | 跑批器：B1 / B1' / B2 / B3 / B4 + perf，输出 JSON |
| `reports/` | 实跑报告（`fast-*.json` / `soak-*.json` / `latest-*.json`） |
| `logs/` | 跑批 stdout（含每 profile 的耗时与判定） |

依赖：**python3 标准库，零第三方包**（协议实现全部手写，连 `websockets` 都没装）。

## 跑

```bash
cd probe/sim
python3 motifd_sim.py --port 17777 --token p0b-sim-token     # 单跑假服务
python3 connect_proxy.py --profile standard --port 18080     # 单跑代理

python3 bench.py --tag fast                                  # 正式跑批（~5 min）
python3 bench.py --tag soak --profiles standard,direct --b2-seconds 300 --b1-requests 50
```

`--tag` 决定报告文件名；跑完会打印 summary 并把完整 JSON 落 `reports/`。

## 六种代理形态

| profile | 读缓冲 | 额外行为 | 想撞坏什么 |
|---|---|---|---|
| `direct` | — | 不经代理 | 基线（排除代理变量） |
| `standard` | 64 KiB | — | 理想代理 |
| `tinybuf` | 1 KiB | — | "一次 read 只拿几百字节"的实现 |
| `laggy` | 4 KiB | 每 chunk +2 ms | relay 型路径的吞吐/延迟上限 |
| `lossy` | 64 KiB | 一次 `recv(4096)` 读 CONNECT 头，多余字节丢弃 | 乐观流水线客户端 |
| `nohalf` | 64 KiB | 不 `shutdown(SHUT_WR)` | 依赖 EOF 判结束的读取方 |

## 实跑结果（`--tag fast`，run `fast-9cde57bd`，2026-11-08 15:29–15:35）

环境：WSL2 / Linux 6.18 / x86_64 / 12 vCPU / Python 3.10.12；全部 loopback。
参数：B1 200 次、B2 45 s、B3 1 MiB、B4 3 轮。

| profile | B1 RTT p50/p95 (ms) | WS 升级 (ms) | pty 1 MiB raw (MB/s) | pty TUI raw (MB/s) | pty TUI framed-zlib (MB/s) | 压缩比 | 帧 RTT p50 (ms) | close 语义 | 乐观流水线 |
|---|---|---|---|---|---|---|---|---|---|
| direct   | 0.61 / 0.94 | 0.83 | 52.7 | 66.5 | 55.6 | 14.16:1 | 12.1 | pass | n/a |
| standard | 1.52 / 2.07 | 2.91 | 55.7 | 66.6 | 58.4 | 14.16:1 | 13.9 | pass | pass |
| tinybuf  | 1.63 / 2.32 | 2.61 | **7.34** | **8.82** | **28.2** | 14.16:1 | **103.9** | pass | pass |
| laggy    | 2.19 / 2.74 | 2.21 | **1.88** | 1.85 | 1.85 | 14.16:1 | **335.3** | pass | pass |
| lossy    | 1.68 / 2.21 | 2.13 | 46.0 | 57.9 | 44.4 | 14.16:1 | 19.7 | pass | **FAIL 5/5** |
| nohalf   | 1.68 / 2.26 | 1.78 | 42.9 | 82.3 | 44.4 | 14.16:1 | 18.5 | **FAIL** | pass |

两侧计数一致（无静默丢字节）：server 侧 `pty_bytes_up = 4194304`（= 4 组 × 1 MiB），
客户端 8 组 B3 全部 `sha256(送) == sha256(回)`；`/events` 服务端发 179 条、
B2 客户端收 173 条（差额来自 B4 重连时另开的两条 WS），`seq` 无洞。

B4（409 重连）：6 个 profile 各 3 轮，`observed_409 = 3/3`、`recovered = 3/3`，
重 attach 到 `/events` 可用 p50 = 5.3 ms（直连）~ 14.9 ms（经代理）。

### 5 分钟长连接档（`--tag soak`，run `soak-07d31f91`）

| profile | B2 时长 | events | Ping 观测/期望 | seq 空洞 | close | B1 RTT p50/p95 (ms) |
|---|---|---|---|---|---|---|
| standard | 300 s | 1146 | **15 / 15** | 0 | 无 | 1.82 / 2.39 |
| direct   | 300 s | 1145 | **15 / 15** | 0 | 无 | 0.74 / 1.03 |

20 s Ping 在 5 分钟窗口里 15 次全部到达、pong 全部回达（服务端 `pongs_recv` 对齐），
`seq` 无洞、连接未被服务端 45 s 空闲规则掐 —— **隧道自身不会断连**；真机若掉线，
是 iOS 系统挂起/网络切换，不是协议层。

## 六条结论（对应 `findings` 字段）

1. **F0 — CONNECT 协议层可用**（standard vs direct）：RTT 0.61 → 1.52 ms（+0.9 ms 是
   一次 CONNECT 往返 + 中继线程），吞吐 52.7 → 55.7 MB/s（差异在噪声内）。WS 升级、
   二进制帧、ping/pong、close 全部原样通过。**拓扑在协议层成立。**
2. **F2 — 小读缓冲只伤性能、不伤功能**：1 KiB 缓冲下五层全 pass，但吞吐 55.7 → 7.3 MB/s、
   帧 RTT 13.9 → 103.9 ms。**这是"看起来能用、打字发涩"的那一类故障**，只能靠数字发现，
   靠功能测试发现不了。缓解：客户端开 framed zlib（下行 8.8 → 28.2 MB/s）。
3. **F3 — relay 型路径有 2 MB/s 量级天花板**：4 KiB/chunk + 2 ms 延迟 → 1.88 MB/s、
   帧 RTT 335 ms。iOS 若走 relay（非直连），`ls -R` / 大文件 `cat` 会明显卡；
   交互打字（<1 KB/次）仍然可接受。
4. **F1 — 乐观流水线会挂死**：不等 CONNECT 200 就发请求，在 `lossy` 上 5/5 超时
   （代理丢掉 260 字节）。**客户端纪律：等 200**。dart:io 的 `HttpClient` 默认就是等，
   自研隧道代码必须显式遵守。
5. **F4 — 半关闭不传播会把"读到 EOF 为止"的读方挂住**：`nohalf` 上 2 s 内收不到 EOF。
   客户端应按 `Content-Length` / `chunked` / WS close code 判结束，**不要靠 EOF**；
   自研代理必须 `shutdown(SHUT_WR)`。
6. **F6 — framed zlib 对不可压缩载荷是净亏**：`standard` 下 random 载荷
   raw 55.7 MB/s → framed 32.4 MB/s（压缩比 1.00，等于白烧一遍压缩）。
   本机实测 `zlib.compress(64 KiB, level 6)`：随机数据 **2.62 ms/帧**（单核上限 23.8 MB/s，
   压缩后并不更小），终端文本 **0.60 ms/帧**（74.4 KiB → 5.2 KiB，14.19:1）。
   结论：framed zlib 必须按内容决定开不开，不能无条件 opt-in；motifd 侧"压完发现没变小
   再发原样"的写法仍然付了 CPU 成本，客户端应先用小样本判断可压缩性。
7. **F5 — framed zlib 的真实收益是"下行大输出"**：TUI 载荷压缩比 14.16:1；
   但本测是对称回显（上行永远是 raw），所以 `laggy` 下端到端吞吐两种模式都是 1.85 MB/s——
   **瓶颈在上行**。真实 PTY 场景下行占主导（`cat`/`ls`/编译日志），压缩收益会显现；
   交互场景（等键盘回显）收益接近 0，但多一层 zlib 也只增加 0.03~0.4 ms（`meta_ms`）。

## 局限（别过度解读）

- **全程 loopback**：没有真实 RTT/丢包/MTU/TLS。CONNECT 隧道在 loopback 上没有
  "代理进程被调度/被限速"以外的不确定性；真机的移动网络、iOS 后台挂起、NEProvider
  都不在这里。
- **PTY 是"回显"模型**：server 收到 binary 帧就原样吐回，不是真 PTY。它验证的是
  "字节双向不损坏"，不是终端语义（OSC 777 标记、VT 状态、回放 cursor 都不涉及）。
- **Python GIL**：`tinybuf` 的绝对吞吐偏低有一部分是解释器开销（每秒上万次
  `recv(1024)`），所以看**相对比例**（7.3 vs 55.7），不要当绝对上限。
- **没有 TLS**：真实 iOS 若在隧道里再叠 TLS/HTTP2，还要多一层记录边界。

## 与 Dart 探针的对拍

`probe/ios-connect/` 输出的 JSON 与这里**同 schema**（`crossdesk.p0b.probe/1`），
`acceptance.B1_ping / B1p_auth_session / B2_events_ws / B3_pty_bidirectional /
B4_reconnect_409` 与 `perf.*` 键名一一对应，可直接 diff。
