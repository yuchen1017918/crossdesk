# probe/ios-connect —— P0-B iOS 探针（B1–B4）

把「iOS userspace netbird 的 CONNECT 代理能不能承载 motifd」做成**一条命令跑完**的探针，
输出与 `probe/sim/bench.py` **同一 schema**（`crossdesk.p0b.probe/1`）的 JSON，便于
"仿真 baseline vs 真机"逐字段对拍。

## 状态（重要）

| 项 | 状态 |
|---|---|
| 代码 | 已写，**未编译**（交付机无 dart/flutter，pub.dev 不可达） |
| 真机 | **未跑过**。交付机无 dart/flutter（`docs/plan-v3.md` §6.1），**未编译、未运行**；任何"已通过"的说法都必须来自真机报告，本仓库内的 JSON 只有 sim 的 |
| flutter_netbird API | **未核对**签名（拉不到 1.0.5 源码）。全部接触面收在 `lib/src/netbird_bridge.dart`，用 `ADAPT(1..4)` 标出，预计改 4 处 |

> 口径来自 `docs/plan-v3.md` §6.1：本机 cargo/go/dart/flutter 全无，产出形态必须是
> 「可编译 + 附实机清单」，不得声称已跑通。这里遵守同一口径。

## 一条命令（真机）

```bash
flutter test integration_test/probe_test.dart -d <device-id> \
  --dart-define=PROBE_HOST=motifd-laptop \
  --dart-define=PROBE_TOKEN=<bearer> \
  --dart-define=NETBIRD_MGMT=https://api.netbird.io \
  --dart-define=NETBIRD_SETUP_KEY=<setup key> \
  --dart-define=MOTIF_PSK=<motif://pair 链接里的 psk> \
  --dart-define=PROBE_B2_SECONDS=300          # 正式跑用 300s（5 分钟心跳那档）
```

跑完会：

1. 往 stdout 打一段 `=== P0B REPORT BEGIN === ... END ===` 的 JSON；
2. 往 `Directory.systemTemp` 写一份同名 JSON（Xcode → Devices → Containers 可取）；
3. 用 `expect` 判定 B1/B1p/B2/B3/B4 五层，任一层不 pass 测试即失败。

图形化跑法（同一份逻辑，带生命周期记录）：

```bash
flutter run -d <device-id> --dart-define=PROBE_HOST=... --dart-define=PROBE_TOKEN=...
```

App 里点「跑 B1–B4」；**后台存活**靠 `WidgetsBindingObserver`：切后台 5/15/30 分钟再回前台，
每次回来追加一条 `resume_probe`（ok/error + 耗时），最后随报告一起导出。
iOS 会挂起进程，Dart 定时器在后台不执行，所以这里量的是"回前台时隧道是否还活"，
而不是"后台还能跑多久"——后者只有 BGTaskScheduler/NetworkExtension 才谈得上。

## 桌面端纯 Dart CLI（不需要 Flutter）

给自己一个本地代理端口（netbird 桌面版 `start_proxy`，或 `probe/sim/connect_proxy.py`）就能跑：

```bash
dart run bin/probe.dart \
  --host 127.0.0.1 --port 17777 \
  --proxy-host 127.0.0.1 --proxy-port 18080 \
  --token p0b-sim-token --out report.json
```

退出码：`0` 全 pass / `2` partial / `1` fail。这条路径**不经过 flutter_netbird**，
可以先在本机把协议层跑通，再去真机换 transport。

## 五层验收（与 sim 完全一致的口径）

| 层 | 动作 | 判据 | 失败定位 |
|---|---|---|---|
| B1 | `GET /ping` 经隧道 ×200 | 全部 200 且版本号一致 | 隧道/字节流本身 |
| B1' | `POST /rpc/session.list` + Bearer；另测 401/404/409、attach 头 | 6 项全过 | 鉴权头透传、会话语义（**不是** psk 派生） |
| B2 | `GET /events?session=` WS 升级 + 保持 N 秒 | 无 EOF/close、`events>0`、`seq` 无洞、Ping 数 ≥ 窗口折算值 | 长连接 / 心跳 / 代理空闲回收 |
| B3 | `GET /pty/pty-1?session=` 双向 1MB | sent/echoed `sha256` 相等；legacy raw 与 framed zlib 两档都要过 | 大块二进制、压缩帧、背压 |
| B4 | detach → 旧 sid `/events` 必须 409 → 重新 attach → 恢复 | 每轮都观测到 409 且能恢复 | 重连语义（真机还含后台存活） |

`B2` 报告里 `ping_observed` 与 `ping_expected_by_window` 必须成对看：服务端 20s 一次 Ping，
观测窗口 45s 时期望值 2；若窗口 < 20s，`ping_verdict` 会是 `window_too_short`，
**不代表心跳缺失**。

## 与 sim 对拍

两侧 JSON 的 `acceptance.*` / `perf.*` / `verdict.layers` 键名一致，可直接 diff：

```bash
python3 - <<'PY'
import json
sim = json.load(open('probe/sim/reports/latest-fast.json'))['profiles'][0]
dev = json.load(open('report.json'))
for k in ('B1_ping','B1p_auth_session','B2_events_ws','B3_pty_bidirectional','B4_reconnect_409'):
    print(k, 'sim=', sim['verdict']['layers'][k], 'device=', dev['verdict']['layers'][k])
PY
```

## 目录

```
lib/src/wire.dart            CONNECT 隧道 / HTTP / WS 裸实现（无 dart:io 高层封装）
lib/src/probe.dart           B1–B4 + 报告（schema 与 sim 一致）
lib/src/netbird_bridge.dart  flutter_netbird 唯一接触面（ADAPT 标出 4 处）
lib/main.dart                Flutter 宿主 + 后台存活记录
bin/probe.dart               纯 Dart CLI（跳过 Flutter）
integration_test/probe_test.dart  真机一条命令
```

## 已知取舍

- **不用 dart:io 的 WebSocket 跑 B2/B3**：`WebSocket.connect` 只认全局 `HttpOverrides`，
  不认 `findProxy`，中途换 transport 会污染结论。裸实现能保证"测的就是 CONNECT 隧道"。
  但 `HttpOverrides` 那条路也要有人验——`main.dart` 里装了 `NetbirdHttpOverrides` 之后，
  App 自身的 dart:io 请求会走它，真机上可以顺手对比。
- **sha256 用 `package:crypto`**：一个包、无传递依赖；替换成本低。
- **载荷生成用 xorshift32**：跨次运行可复现，但不追求与 Python 侧逐字节相同——
  校验(sent vs echoed)在各自进程内完成。
