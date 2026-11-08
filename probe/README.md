# probe/ —— P0-B 的两个探针

| 目录 | 是什么 | 能不能在本机跑 |
|---|---|---|
| `sim/` | motifd 协议级仿真：假 motifd + CONNECT 代理（6 形态）+ 跑批器，输出 JSON 报告 | **能**（纯 python3 标准库，已实跑，报告在 `sim/reports/`） |
| `ios-connect/` | iOS 真机探针：Flutter/Dart，经 flutter_netbird 的 `startProxy()` 走 CONNECT 跑同一套 B1–B4 | **不能**（本机无 dart/flutter，pub.dev 不可达；只交付代码） |

两边输出**同一 schema**（`crossdesk.p0b.probe/1`），键名一致，可直接逐字段对拍
（脚本见 `ios-connect/README.md` 末节）。

## 谁看哪份

- 想知道"CONNECT 到底行不行、坑在哪、数字多少" → `sim/README.md`（有六 profile 实跑表）。
- 想知道"iOS 上怎么跑、要准备什么、后台存活怎么记" → `docs/p0/ios-p0b-runbook.md`。
- 想知道"不达标怎么办、tsnet 还是 relay" → `docs/p0/ios-fallback-decision.md`。

## 复现

```bash
cd probe/sim && ./run-all.sh          # 快速档，~5 min
cd probe/sim && ./run-all.sh --soak   # 追加 5 分钟长连接档，~11 min
```
