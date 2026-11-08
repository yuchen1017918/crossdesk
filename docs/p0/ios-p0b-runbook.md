# P0-B 实机 Runbook —— iOS CONNECT 承载 motifd

> 适用：`probe/ios-connect/`（真机探针）+ `probe/sim/`（协议级仿真的前置结论）
> 版本：v1，2026-11-08。撰写人：p0-ios-connect。**本文件是清单，不是"已验证"声明。**
> 前置事实：协议层仿真已跑出数字（`probe/sim/README.md`）——CONNECT 隧道能承载
> HTTP/WS/64 KiB 二进制帧；真机只剩「设备 / 系统 / 后台」三件事没验。

---

## 0. 一分钟版

```
材料：motifd 的 --listen 地址 + motif://pair 链接里的 psk + management/setup-key（netbird）
跑：  flutter test integration_test/probe_test.dart -d <device> --dart-define=...
判：  B1 ✓ B1' ✓ B2 ✓ B3 ✓ B4a ✓ → 后台/锁屏/弱网三项人肉记录 → 通过
坏：  任一 B* 挂 → 按 §6 排查 → 仍挂 → 转 docs/p0/ios-fallback-decision.md
```

---

## 1. 这台机器已经证明了什么（真机不用再重复）

| 已验证（本机，loopback） | 数字 | 来源 |
|---|---|---|
| CONNECT 里跑 HTTP/1.1 keep-alive | 200/200 请求 200 OK，RTT p50 1.52 ms | sim `standard` |
| CONNECT 里 WS 升级 | 101 + `Sec-WebSocket-Accept` 正确，升级 2.9 ms | sim `standard` |
| CONNECT 里双向 64 KiB 二进制帧 | 1 MiB sha256 一致，55.7 MB/s，帧 RTT 13.9 ms | sim `standard` |
| 20 s 服务端 Ping 穿透隧道 | 45 s 窗口 2/2，pong 计数对齐 | sim `B2` |
| 409 NotAttached → 重 attach 恢复 | 3/3 轮，恢复 p50 5.3–14.9 ms | sim `B4` |
| 小缓冲/relay 型代理的量化损失 | 7.3 MB/s / 1.88 MB/s + 335 ms | sim `tinybuf`/`laggy` |

**真机唯一新增的变量**：iOS 的 netbird 是 userspace（不接管系统路由）、进程会被后台挂起、
移动网络有真实 RTT/丢包/切换。所以真机只需验「设备能起隧道」「系统会不会掐」「后台/锁屏怎么死再怎么活」。

---

## 2. 材料清单（缺一项就先把这项补上再上真机）

| # | 材料 | 从哪拿 | 校验方法 |
|---|---|---|---|
| M1 | motifd 可达地址/端口 | 宿主 `motifd --listen 0.0.0.0:7777` 等；经 overlay 看到的是 `100.x:7777` | 宿主上 `curl http://127.0.0.1:7777/ping` |
| M2 | **psk**（配对密钥） | motifd 启动日志里的 `motif://pair?…` 链接（`--listen` 走网络监听时才有） | 链接里有 `psk=` 字段 |
| M3 | **bearer**（由 M2 派生） | 见 §3；真机先用手工派生的 bearer | `POST /rpc/session.list` 返回 200 |
| M4 | netbird management URL + setup key | netbird 控制台（或自托管 management） | 桌面端同 key 能上线 |
| M5 | 设备 UDID / 开发者证书 | Xcode | `flutter devices` 能看到 |
| M6 | 同一 tailnet/netbird 网络里的目标机 | — | 设备 `getFullStatus()` 里 peer 列表含目标机 |

> ⚠️ **M2/M3 的边界**：仿真里的 Bearer 是**本地 stub token**，只证明"头能原样穿过隧道、
> 401/409/404 语义正确"。**psk→bearer 派生本身没被仿真验证过**，必须真机对拍（§3）。
> 报告里 `B1p_auth_session.used_stub_auth=true` / `real_psk_derivation_verified=false` 就是标记这个。

---

## 3. psk → bearer 派生（真机第一件要落实的事）

已取证的事实（`crates/motif-server/src/auth.rs`，本轮直取）：

- `TokenStore::Required(t)` 做常时间比对 `Authorization: Bearer <t>`；
- 注释明确：**网络 `--listen` 一定会拿到 psk 派生的 bearer**（`Required`）；
  `loopback / embed / tailscale-only` 没有 psk 时是 `TokenStore::Disabled`（接受一切请求）；
- `generate_token()` 是另一条路（embed 宿主自己 mint）：32 字节 OS RNG → base64url 无填充（43 字符）；
- WS 升级额外接受 `?token=`（浏览器构造函数不能设头），**但 `/rpc/*` 不支持 query token**。

派生函数 `crates/motif-server/src/rzv.rs::derive_bearer` **已取到源码并完成交叉验证**（2026-11-08）：

```
AUTH_BEARER_INFO = b"motif-auth-bearer-v1"
TOKEN_INFO       = b"motif-rzv-token-v1"      # relay 会合用，与 bearer 不同

hkdf_expand_label(psk, info) =
    prk  = HMAC-SHA256(salt = 32×0x00, psk)
    T(1) = HMAC-SHA256(prk, info || 0x01)      # L == 32，单块，不需要 T(2)

bearer = base64url_nopad( hkdf_expand_label(psk, b"motif-auth-bearer-v1") )
```

**自备工具**：`scripts/derive-bearer.py`

```bash
python3 scripts/derive-bearer.py --self-test          # 4/4 通过（对上游固定向量）
python3 scripts/derive-bearer.py --pair-uri 'motif://pair?v=1&host=...&port=7777&psk=...'
# → bearer : sV99nJC0JWcfL9azFYStaLPxd6c7vH5J-8iCUF4ynd8
# 把它填进 --token / MOTIF_BEARER
```

**验证口径**：上游 `rzv.rs` 的 `#[cfg(test)]` 里有两个跨语言固定向量（`psk = 0..31`）：

| 用途 | 期望 hex |
|---|---|
| relay token | `bb48b13937710e30c1fffa843593313a7d403c44236eb01d6c86842e43bfa7da` |
| **access bearer** | `b15f7d9c90b425671f2fd6b31584ad68b3f177a73bbc7e49fbc882505e329ddf` |

本工具的 Python 实现与这两个向量**逐字节一致**，因此真机上只需比对"motifd 接受 / 拒绝"，
不必再从源码猜算法。

拿到实现后，用同一份 psk 在本地算出 bearer，与 motifd 实际接受的值比对：

```bash
# 判定：两条命令一个 200 一个非 200 → 派生不对/多了一层编码
curl -sS -o /dev/null -w '%{http_code}\n' \
  -X POST http://127.0.0.1:7777/rpc/session.list \
  -H "Authorization: Bearer $MY_BEARER" -d '{}'
```

**这一段必须产出**：`docs/p0/ios-p0b-runbook.md` 追加一行「派生算法：<一句话> / 对拍命令：<命令> /
结果：200」。在此之前 iOS 侧只能拿手工 bearer 跑探针。

> 边界情况：如果目标 motifd 以 `--tailscale`（tailnet-only）或纯 loopback 起，**可能压根没有 bearer**
> （`TokenStore::Disabled`）。这时 `B1'` 的 401 用例会失败而 200 用例通过——**不是隧道问题**，
> 在报告 `notes` 里记 `auth_mode=disabled` 即可。

---

## 4. 真机执行清单（按顺序，逐步留证）

### R1 构建与安装

```bash
cd probe/ios-connect
flutter pub get
flutter devices                      # 记下 <device-id>
flutter run -d <device-id> --dart-define=PROBE_HOST=<100.x 或 hostname> ...
```

首次构建如果 `flutter_netbird` 的 API 与 `lib/src/netbird_bridge.dart` 不符，
按文件里的 `ADAPT(1..4)` 改这一处（**只改这一个文件**），再构建。

### R2 单跑 B1（只验隧道，排除鉴权变量）

```bash
flutter test integration_test/probe_test.dart -d <device-id> \
  --dart-define=PROBE_HOST=<host> --dart-define=PROBE_TOKEN= \
  --dart-define=PROBE_B2_SECONDS=30
```

判据：`B1_ping.status == pass`，`ok == requests == 200`，`versions == ["<motifd 版本>"]`。

### R3 跑 B1'（鉴权 + 会话语义）

带上 `PROBE_TOKEN=<bearer>` 再跑一次。判据：6 项全 true，其中
`session_list_no_bearer_401` 必须真的 401（若 200，说明该 motifd 是 `TokenStore::Disabled`，见 §3 末尾）。

### R4 跑 B2（`/events` 长连接）

```bash
--dart-define=PROBE_B2_SECONDS=300     # 正式档：5 分钟
```

判据：`events > 0`、`seq_gaps == 0`、`ping_observed >= ping_expected_by_window`（300 s / 20 s = 15）、
`close_code == null`、`errors` 为空。
**注意**：iOS 前台常亮 5 分钟即可；这一项**不要求**锁屏/后台。

### R5 跑 B3（`/pty` 双向 1 MiB）

判据：四组（random/tui × raw/framed）全部 `match == true`、`bytes_down == bytes_up`；
记下 `throughput_mbps` 与 `frame_rtt_ms.p50`（决定性的两个数，见 §5 阈值）。

### R6 跑 B4a（409 → 重 attach）

判据：`observed_409 == cycles`、`recovered == cycles`。
这一步在探针里是程序化的（detach → 旧 sid 的 `/events` 必须 409 → 重新 attach → 恢复）。

### R7 后台存活（B4b，5 / 15 / 30 分钟，人肉）

1. App 里跑完一轮，记下 `proxy_port` 与当前时间；
2. **Home 键**把 App 切后台，计时 5 分钟（**不要**锁屏，先单独测后台）；
3. 回前台 → 看 `lifecycle` 里是否追加了 `resume_probe`，`ok` 是否为 true，`ms` 多少；
4. 重复 15 分钟、30 分钟；
5. 再做一轮**锁屏**（后台 + 锁屏 5 分钟），同上。

记录表（回填到报告 `lifecycle` 或本文件附表）：

| 场景 | 时长 | 回前台首次探测 | 隧道还活着？ | 备注 |
|---|---|---|---|---|
| 后台 | 5 min | ___ ms | ok / error | |
| 后台 | 15 min | | | |
| 后台 | 30 min | | | |
| 后台+锁屏 | 5 min | | | |

**预期**（写在前面，避免事后找理由）：iOS 会在 App 进后台后挂起进程，
WS 通常**几秒内**就会被系统断掉或冻结（`resume_probe` 报 error / 超时）。
若真是如此，这**不算失败**——它意味着产品设计必须"回前台重连"，
而重连语义已由 B4a 覆盖。只有当你打算做后台常连（BGTaskScheduler / NetworkExtension）时，
这组数据才是硬门槛。

### R8 弱网与切换

- 用 Xcode 的 Network Link Conditioner（或设备开发者设置）配 3G/高丢包（loss 3% / 300 ms RTT）重跑 R5；
- 跑的过程中切一次 WiFi ↔ 蜂窝；
- 记录：B3 是否仍 `match`、B2 是否掉线、掉线后 `errors`/`close_code`。

### R9 打包证据

```
<device>-<date>/
  probe-report.json            # integration_test 写出的那份
  console.txt                  # flutter logs / Console.app 抓的 netbird + motif 日志
  lifecycle.json               # flutter run 模式的 lifecycle 数组
  runbook-§7-表.md             # 后台/锁屏/弱网记录
  motif-ping.txt               # 宿主上 curl /ping 的输出（证明版本号对得上）
```

---

## 5. 判定阈值（与 `docs/p0/ios-fallback-decision.md` 同源）

| 指标 | 通过 | 可接受（记风险） | 不达标 → 转兜底 |
|---|---|---|---|
| B3 吞吐（raw） | ≥ 8 MB/s | 2–8 MB/s | < 2 MB/s |
| B3 帧 RTT p50 | ≤ 60 ms | 60–150 ms | > 150 ms |
| B2 5 min 内掉线 | 0 次 | 1 次 | ≥ 2 次 |
| B2 Ping 观测 | ≥ 窗口折算值 | 少 1 次 | 缺 ≥ 2 次 |
| B4a 409 恢复 | 3/3 | 2/3 | ≤ 1/3 |
| 后台存活 | （不作为 gate，只记录） | — | 若做后台常连则 ≥ 30 min |

> 参照：仿真里 `standard` = 55.7 MB/s / 13.9 ms（理想代理），`tinybuf` = 7.3 MB/s / 104 ms
> （"发涩"的量级），`laggy` = 1.88 MB/s / 335 ms（"不能忍"的量级）。真机若落在 tinybuf
> 附近，先开 framed zlib 再判（仿真里小缓冲下 framed 把下行从 8.8 提到 28.2 MB/s）。

---

### 5.1 四条 findings 的 iOS 落地含义（真机上必须防，数字来自 `probe/sim` 实跑）

| finding | 仿真里长什么样 | iOS 侧要防什么 |
|---|---|---|
| **F1 乐观流水线** | `lossy` profile：CONNECT 后不等 200 就发首请求 → **5/5 挂死**，代理丢弃 260 字节 | **必须等 `HTTP/1.1 200 Connection Established` 再发第一个请求**。`dart:io HttpClient` 默认满足；自研隧道（`wire.dart`）也要显式等——不要为省一次 RTT 做猜测式流水线 |
| **F2 小读缓冲** | `tinybuf`：功能全过，但 55.7 → **7.34 MB/s**，帧 RTT 13.9 → **103.9 ms**（能用但发涩） | **不要假设一次 read 等于一个 WS 帧**。帧头/长度/载荷必须循环读满；`dart:io WebSocket` 已处理，自研 socket 路径要自己拼。iOS 上 netbird 代理内部缓冲不可控，这条一定踩得到 |
| **F3 relay 上限** | `laggy`（4 KiB/chunk + 2 ms）：**1.88 MB/s**、帧 RTT **335 ms** | 先看 `getFullStatus()`：peer 是 **relayed（非 direct）** 就直接按 §5 的 T1/T2 判，别再调客户端参数。relayed 下交互可用、大输出不可用；framed zlib 只省带宽、不救上行 |
| **F4 半关闭不传播** | `nohalf`：`Connection: close` 后 **2 s 收不到 EOF** | **按 `Content-Length` / `chunked` / WS close code 判结束，绝不靠 EOF**；HTTP 读完长度就停。反过来，若我们要写代理/NE，必须把 `shutdown(SHUT_WR)` 传播出去 |

> 另两条见 `probe/sim/README.md`：**F6** framed zlib 对不可压缩载荷是净亏

### 5.2 性能验收项（F2 只能靠数字发现，功能测试看不见）

功能全过不等于可用。真机报告里必须同时填这两个数，否则本 gate 不算过：

| 项 | 采法 | 合格 | 可接受 | 触线 |
|---|---|---|---|---|
| `/pty` 1 MiB 双向 raw 吞吐 | 探针 B3 输出 `throughput_mb_s` | ≥ 8 MB/s | 2–8 MB/s | **< 2 MB/s**（sim `laggy` 实测 1.88） |
| 64 KiB 帧 RTT p50 | 探针 B3 输出 `frame_rtt_ms.p50` | ≤ 60 ms | 60–150 ms | **> 150 ms**（sim `tinybuf` 103.9 属"能用但发涩"，`laggy` 335.3 已触线） |

判据与 `docs/p0/ios-fallback-decision.md` 的 T1/T2 同源，不要另立阈值。**注意 `tinybuf` 是"功能全过但发涩"的典型**：sha256 一致、各级都 200，只有这两个数会露馅。
> （random 55.7 → 32.4 MB/s，压缩 2.62 ms/64 KiB 白烧）——所以 §2 的 M1 只对文本型输出开。

## 6. 失败排查树（按层定位，不要一上来就怀疑隧道）

```
B1 挂（/ping 经隧道不通）
├── 隧道根本没起来：proxy_port 为空 / NetbirdHttpOverrides 没接上 → 看 NetbirdBridge.bootstrap 异常
├── CONNECT 被代理拒绝（非 200）→ netbird startProxy 的目标地址写法（是否要 "100.x:7777" 而非 hostname）
└── 起来了但 0 字节 → 换 probe/sim 的 lossy profile 复现思路：客户端是否在等 200？（F1）

B1 通过、B1' 挂（鉴权）
├── 401：bearer 不对 → §3 派生；或该 motifd 是 TokenStore::Disabled（此时不该有 401 用例）
├── 409：X-Motif-Session 没回带 / 已被 detach
└── 404：方法名写错（注意没有 /rpc/version，探测用 GET /ping）

B2 挂（/events）
├── 升级就被拒（非 101）→ 401（token 放 query 还是 header？iOS 可以放 header）
├── 升级成功但 0 事件 → since 太大 / session 不对
└── 升级成功但几十秒后 close → 代理空闲回收（F2/F3 类），或者服务端 45 s 无帧判死（客户端要回 pong）

B3 挂（/pty）
├── sha256 不一致 → 帧拼接/掩码/压缩 flag 处理错；先用 64 KiB 单帧复现
├── 吞吐低但正确 → 见 §5 阈值。**先别急着开 zlib**（F6）
├── 开了 zlib 反而更慢 → **F6：不可压缩载荷下 zlib 是净亏**（55.7→32.4 MB/s，每 64 KiB 白烧 2.62 ms）。
│   只有文本型下行才开（TUI 实测压缩比 14.16:1）；二进制/随机载荷不要开
├── 收不到 meta 帧 → 服务端第一帧必须是 Text meta（客户端别把它当数据）
└── 读挂住 / 卡到超时 → **F4：代理没传播 shutdown(SHUT_WR)**，`Connection: close` 后 2 s 等不到 EOF。
    改成按 Content-Length / chunked / WS close code 判结束，别靠 EOF

B4 挂（重连）
├── detach 后旧 sid 仍 101 → 服务端没清 registry（不是客户端问题）
└── 新 attach 后 /events 仍 409 → attach 与 /events 不是同一条隧道连接？
```

---

## 7. 回填与交付

真机跑完后，**只改这几处**（避免和仿真报告混淆）：

1. `probe/ios-connect/reports/device-<date>.json`（新建目录，放真机 JSON）；
2. 本文件 §4 的记录表；
3. 若触发兜底：`docs/p0/ios-fallback-decision.md` §5「实测触发记录」；
4. 若发现新的代理/客户端缺陷：追加到 `probe/sim/README.md` 的 findings 段，
   并在 `bench.py` 里补一个能复现它的 profile。

---

## 8. 真机上仍然"只有人能做"的五件事（本清单的全部价值）

1. **netbird 在 iOS 上真的能 up 并起代理**（`initialize / up / startProxy` 三连）——
   仿真用不到 flutter_netbird，这里是第一处真机依赖。
2. **psk→bearer 派生对不对**（§3）——仿真用的是 stub token。
3. **后台 / 锁屏 / 切网时隧道怎么死**（§4 R7/R8）——iOS 的进程挂起策略无法在桌面上模拟。
4. **framed zlib 的收益在真实 PTY 输出上有多大**（仿真只有合成载荷 + 回显模型）。
5. **`NetbirdHttpOverrides` 是否覆盖了 `WebSocket.connect`**——
   若没有，App 里所有 WS 都得走自建裸 socket + CONNECT（`probe` 就是这么做的，
   但产品代码要统一口径）。

以上五件事之外，协议层的问题在 `probe/sim/` 里都已经被量化过了，不必在真机上重跑。
