# NetBird 许可边界：BSD-3 与 AGPLv3

> 一手取证：2026-11-08，`api.github.com/repos/netbirdio/netbird/license` + 四个目录各自的 `LICENSE`（base64 解码后逐份核对）。
> 性质：工程侧风险评估。本文只描述事实形态与可执行动作，不作法律定性。

---

## 1. 一句话

NetBird 主仓**默认 BSD-3**，但 `management/` `signal/` `relay/` `combined/` 四个目录被**明文划出**改授 **AGPLv3**。我们的产品只碰**客户端 + embed**（BSD-3），因此合规负担很轻；一旦把这四个目录的代码或镜像塞进我方分发物，整个分发物的许可策略就会被拖进 AGPL。

---

## 2. 一手证据

### 2.1 主 `LICENSE`（1,788 字节，首段即边界条款）

原文（逐字）：

```
This BSD-3-Clause license applies to all parts of the repository except for the directories management/, signal/, relay/ and combined/.
Those directories are licensed under the GNU Affero General Public License version 3.0 (AGPLv3). See the respective LICENSE files inside each directory.

BSD 3-Clause License

Copyright (c) 2022-2026 NetBird GmbH & AUTHORS
...
```

要点：

- **边界写在主 LICENSE 的第一句**，不是藏在 README 或某份 CLA 里 —— 归属链条清晰，不存在"我不知道这段是 AGPL"的辩解空间；
- 版权人 = `NetBird GmbH & AUTHORS`，年份区间 `2022-2026`（**注意是区间，随附时不可简写成 2026**）。

### 2.2 四个 AGPL 目录（逐份核实）

| 目录 | `LICENSE` 大小 | 首行 | 判定 |
|---|---|---|---|
| `management/` | 34,523 B | `GNU AFFERO GENERAL PUBLIC LICENSE` | AGPLv3 全文 |
| `signal/` | 34,523 B | `GNU AFFERO GENERAL PUBLIC LICENSE` | AGPLv3 全文 |
| `relay/` | 34,523 B | `GNU AFFERO GENERAL PUBLIC LICENSE` | AGPLv3 全文 |
| `combined/` | 34,523 B | `GNU AFFERO GENERAL PUBLIC LICENSE` | AGPLv3 全文 |

四份字节数完全一致（34,523），即**标准 AGPLv3 全文**（版本行 `Version 3, 19 November 2007`），无附加条款、无例外条款（no additional permissions / no linking exception）。

> 这条很重要：AGPLv3 的 `§7` 允许附加条款，若存在例外（例如允许链接闭源代码），负担会不同。**这里没有例外**，按纯 AGPLv3 处理。

---

## 3. 义务对照

### 3.1 BSD-3-Clause（客户端 / `netbird-embed` / `flutter_netbird`）

| 义务 | 具体要求 | 我们的落地 |
|---|---|---|
| 保留版权声明 | 源码再分发须保留版权声明、条件列表、免责声明 | 随包 `third_party/netbird/LICENSE`（原样全文） |
| 二进制再分发同义务 | 须在文档/随附材料中**复现**上述内容 | 同上，且"关于"界面可读 |
| 不得用名背书 | 第 3 条：不得用 `NetBird GmbH` 或其贡献者名义为我方产品背书 | 产品名/宣传语**不得**暗示 NetBird 官方认可；描述性引用如 "built on NetBird" 需附上游链接 |

**BSD-3 没有**：源码公开义务、专利授权、商标授权、修改标注义务。负担极轻。

### 3.2 AGPLv3（`management/` `signal/` `relay/` `combined/`）

按**行为**而非按"用不用"分档：

| 我们的行为 | 触发条款 | 义务 | 判定 |
|---|---|---|---|
| 只在内部自建、不对外提供服务、不分发 | 无外部触发 | 无（AGPL 的义务由"分发"或"网络提供服务"激活） | ✅ 最轻 |
| 自建并对**外部用户**提供该服务 | `§13` 远程网络交互 | 须向使用者提供**对应源代码**（含我们的修改），通过明显方式（URL/界面入口） | ⚠️ 可做，须建源码出口 |
| 把镜像/二进制**分发给客户**自行部署 | `§4/§5/§6` | 整体按 AGPLv3 分发：提供源码、许可副本、保留声明、标注修改 | ⚠️ 可做，交付物形态须重组 |
| 修改其源码后仍提供网络服务 | `§13` | 修改版源码也必须对使用者可得 | ⚠️ 同上 |
| **把代码并入我方闭源产品 / 静态链接进我方进程 / 改造成我方模块** | `§5`（基于该程序的作品） | 我方该部分须整体 AGPLv3 化 | ❌ **不做** |

### 3.3 关键区分：聚合（aggregation）vs 衍生

AGPLv3 `§5` 末段允许把 AGPL 程序与其他程序**聚合成一个分发媒介**，前提是二者不是"基于 AGPL 程序的作品"。工程上的判据是**耦合方式**，不是"在不在同一个压缩包里"：

| 耦合方式 | 判定 |
|---|---|
| 独立进程 / 独立容器 / 独立仓库，通过标准网络协议（gRPC / REST / relay 线协议）通信 | **聚合** —— 各自许可独立成立 |
| 共享内存 / 静态链接 / 同进程内函数调用 / 共享内部数据结构 | **衍生** —— 传染 |
| 我方 Go 代码 `import "github.com/netbirdio/netbird/management/..."` | **衍生** —— 传染（Go 是静态链接模型） |

**Go 的静态链接模型让这条红线特别容易踩**：`netbird-embed` 是 Go c-shared FFI，只要它的 `go.mod` 依赖闭包里有那四个目录，它们就被**编进 `.so/.dll` 再进我们的安装包**。这就是下面 §4 第 2 条要做符号级核对的原因。

---

## 4. 「只分发客户端 + embed」可执行清单

> 目标：我方安装包内只有 **BSD-3 侧**的 NetBird 成分；AGPL 四个目录**零字节**进入我方分发物。

### 4.1 依赖面隔离

- [ ] `netbird-embed 0.3.1`（crates.io，BSD-3 侧）只用于客户端/embed 能力；`Cargo.toml` 中不得引入任何指向 `netbirdio/netbird/{management,signal,relay,combined}` 的依赖
- [ ] 若 vendor / fork `netbird-embed`：核对其 `go.mod` + `go.sum`，确认依赖闭包不含上述路径
- [ ] `flutter_netbird`（客户端 FFI 包装）同样只走客户端侧

### 4.2 产物级核对（**必做**，不能只信 manifest）

在能构建 `libnetbird_embed` 的机器上：

```sh
# ① Go 依赖闭包里不得出现 AGPL 目录
cd <netbird-embed-src>
go list -deps ./... | grep -E 'netbirdio/netbird/(management|signal|relay|combined)' \
  && echo "FAIL: AGPL 目录进入依赖闭包" || echo "PASS: 依赖闭包干净"

# ② 产物符号里不得出现 AGPL 侧特征包路径（Go 会把 import path 编进二进制）
strings libnetbird_embed.so | grep -E 'netbirdio/netbird/(management|signal|relay|combined)' \
  && echo "FAIL: 产物含 AGPL 包符号" || echo "PASS: 产物干净"

# ③ 记录 .so/.dll 的 SHA-256 与 go.sum 摘要，进 artifacts/
```

`②` 是真正的把关点：Go 二进制里保留了模块路径字符串，`strings` 就能扫出来，成本极低但能挡住"manifest 看起来干净、实际链接进来了"的情况。

### 4.3 随包许可物

- [ ] `third_party/netbird/LICENSE` —— BSD-3 **原样全文**（含 `Copyright (c) 2022-2026 NetBird GmbH & AUTHORS` 与"四目录例外"首段，不要删首段，它同时是**对我们有利**的边界声明）
- [ ] `third_party/netbird/SOURCE.md` —— 上游 URL、锁定 tag/commit、我们用的是哪一侧、明确写"未包含 management/signal/relay/combined"
- [ ] 安装包"关于/Licenses"界面可读
- [ ] 产品名与文案不使用 NetBird 标识作为我方品牌；描述性引用附上游链接

### 4.4 若同时自托管服务端（形态 C2）

- [ ] 服务端**独立分发物**：独立容器镜像 / 独立仓库 / 独立版本号 / 独立许可证声明，与我方安装包**无共享层**
- [ ] 镜像内 `/LICENSE` = AGPLv3 全文；`/SOURCE` 写明上游 tag + 我方 patch（若有）获取地址
- [ ] 若对外提供服务（`§13`）：在用户可见处（登录页/文档/CLI `--version`）给出**对应源代码获取地址**
- [ ] 我方 patch 单独维护为 patch 系列（`0001-*.patch`），随源码出口一并提供
- [ ] 安装包的第三方组件清单里**不得**出现这四个目录的任何条目

### 4.5 红线（任一为真即视为 gate-0 不通过）

- ❌ 四个目录的任何源码/二进制进入我方安装包或主仓
- ❌ 我方 Go/Rust 代码静态链接这四个目录的包
- ❌ 把 management/relay 改造成我方"内置服务"并随产品分发
- ❌ 以 NetBird 名义做产品背书式宣传

---

## 5. 与 `decision.md` 决策表的对应

| `decision.md` §7.3 | 本文对应 | 结论 |
|---|---|---|
| C1 自托管 motif 自带 relay（`motif-push-relay`/`motif-rendezvous`） | **不属本文范围** —— 那是 Motif 上游 crate，`license.workspace = true` → `MIT OR Apache-2.0` | 可分发（附条件 G1/G2） |
| C2 自托管 NetBird 四目录 | 本文 §4.4 | 可部署；分发须整体 AGPL |
| C3 四目录入我方包 | 本文 §4.5 | **不分发** |

> 两条 relay 别混为一谈：Motif 自己的 push relay 是 MIT/Apache，NetBird 的 relay 目录是 AGPLv3。名字都叫 "relay"，许可差了整整一个量级。

---

## 6. 未取得一手 / 待复核

| 项 | 状态 |
|---|---|
| `netbird-embed 0.3.1` 的 BSD-3 声明原文 | **未取得一手**（crates.io API 在取证时段间歇超时，多次重试未成功）。旁证：crates.io 元数据标注其描述为 "Rust bindings for NetBird's client/embed"，与 NetBird 主仓 BSD-3 侧一致。**须在用户侧网络补核一次**（`cargo metadata` 或 crates.io 页面） |
| `flutter_netbird` 版本与许可 | pub.dev API 取到 `1.0.5`（2026-03-17 发布）；其 `pubspec.yaml` **未声明 `license` 字段**、无 `repository`/`homepage`；tarball 33 MB 拉取超时，LICENSE 原文**未取得一手** |
| NetBird 各目录当前 tag 与我们锁定的版本对应关系 | 需在构建机登记（本文未锁定具体 tag） |
