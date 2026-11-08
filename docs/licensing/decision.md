# gate-0 判定：Motif / `motifd` 再分发合规

> 状态：**条件通过（conditional pass）** —— 可以把 `motifd` 打进安装包再分发，前提是 G1–G3 三项动作同时成立。
> 取证时间：2026-11-08。取证方式：GitHub API / raw 直取 + crates.io API + pub.dev API（本机 curl）。
> 本文性质：**工程侧法律风险评估**，不是法律意见书。凡涉及"是否构成违约/侵权"的判断，本文只描述事实形态与风险方向，不作出法律定性；正式对外发行前应经法务复核。

---

## 1. 结论（一句话）

上游以 **`MIT OR Apache-2.0` 双许可、二选一** 的方式作出了明确的许可声明，但**仓库内没有任何许可证正本文件**；这不影响授权的存在，只影响"按许可要求随分发物附全文"这一步——**该项属于可由分发方自行修复的形式瑕疵**，故判定为条件通过而非阻塞。

---

## 2. 证据链（E1–E6）

| # | 证据 | 取法 | 观察 |
|---|---|---|---|
| E1 | `github.com/xiachufang/motif` 有效，`default_branch=main`，`language=Dart`，`pushed 2026-11-02`；仓库级 `license` 字段为 **`null`** | `GET /repos/xiachufang/motif` | 仓库有效；GitHub 未能从文件识别出许可证（与其"无正本"一致） |
| E2 | 根目录清单中**无 `LICENSE` / `COPYING` / `NOTICE`** | `GET /contents/` | 无许可证正本、无 NOTICE |
| E3 | 递归 tree 中 license 类文件仅 3 个：`crates/libghostty-vt-sys/LICENSE`、`crates/libghostty-vt/LICENSE`、`apps/flutter/lib/motif/platform/doubao_asr/DOUVO_LICENSE.txt` | `GET /git/trees/main?recursive=1` | 三者均为**第三方 vendored 组件的许可**，不是项目自身的许可 |
| E4 | 上游 `Cargo.toml` 的 `[workspace.package]`：`license = "MIT OR Apache-2.0"`，`authors = ["Motif contributors"]` | raw `Cargo.toml` | 作者书面声明双许可；`authors` 是**版权归属的唯一一手线索** |
| E5 | `crates/motif-server/Cargo.toml`：`license.workspace = true`，`[[bin]] name = "motifd"` | raw | 产物 `motifd` 继承同一双许可声明 |
| E6 | `README.md` 第 225–227 行 `## License` → `MIT OR Apache-2.0.` | raw `README.md` | 与 manifest 一致，两处声明互相印证 |

**补强（本轮新增，均为一手）**

| # | 证据 | 观察 |
|---|---|---|
| E7 | `crates/motif-net/Cargo.toml`、`crates/motif-tailscale/Cargo.toml` 均 `license.workspace = true` | 双许可声明覆盖 workspace 全部自有 crate，不止 `motif-server` |
| E8 | `.gitmodules`：`apps/flutter/ghostty` → `https://github.com/ghostty-org/ghostty.git` (branch main) | 存在 git submodule；子模块本身另有许可（Ghostty = MIT），不改变 motif 项目自身许可 |
| E9 | 上游 `Cargo.lock` 515 个三方 crate 的传递闭包（见 `third-party.md`） | 未发现 GPL/AGPL 类传染性许可混入 `motifd` 链接面 |

---

## 3. 形态认定

- **不是**"分目录许可"（不是 `src/` MIT、`tools/` Apache 这类切分）。
- **是** `MIT OR Apache-2.0` 的**二选一**（SPDX 表达式 `OR` 语义）：被许可方（我们）**可以任选其一**履行，不必同时满足两者。
- 该声明由 `Cargo.toml`（机器可读的 manifest 元数据）+ `README`（人可读的声明）双处作出，指向明确、无歧义。

## 4. 缺陷认定（克制表述）

| 缺陷 | 事实形态 | 影响 | 是否可修复 |
|---|---|---|---|
| 无 `LICENSE-MIT` / `LICENSE-APACHE` 正本 | 仓库内不存在许可证全文文件 | "随分发物附许可全文 + 版权声明"这一步**没有现成文件可附** | **可修复**：MIT 是 SPDX 唯一对应的标准文本，可由分发方自行补齐，不存在"猜作者意图"的空间 |
| 无 `NOTICE` | 仓库内不存在 NOTICE | Apache-2.0 分支的 NOTICE 随附义务**无从触发**（上游未提供 NOTICE 内容，我们也不应凭空生成） | 走 MIT 分支即绕开 |
| 无明示版权行（`Copyright (c) …`） | E3 的三个许可都属第三方；项目自身无版权声明 | 版权声明需由我们依 E4 的 `authors` 字段构造并标注其推断性质 | 见 G2 |

> 表述边界：上述均为**元数据/分发物完备性**层面的瑕疵。上游以 manifest + README 作出的许可声明本身是清楚的；缺正本并不等于"未授权"。对外沟通时避免使用可能被解读为指控的措辞。

---

## 5. G1：选定 MIT 分支（决策）

**决定：以 MIT 分支履行，不以 Apache-2.0 分支分发。**

理由（按权重）：

1. **义务面最小**：MIT 只有"附全文 + 附版权声明"两项实质义务；Apache-2.0 还要求 `§4(b)` 在修改过的文件上放置显著变更声明、`§4(a)` 随附 NOTICE（若上游有）、`§4(d)` 特定情形下的机器可读元数据。
2. **我们确实会修改或至少重新构建产物**（`--no-default-features` / feature 组合、strip、静态链接顺序）。`§4(b)` 的"标注被修改文件"在"我们分发的是自己构建的二进制、拿不到逐文件 diff 口径"的场景下成本高且容易做漏。
3. **NOTICE 缺失天然无害**：走 MIT 分支后，上游无 NOTICE 这件事从"缺口"变成"无关项"。
4. **代价**：MIT **不含明示专利授权**（也无专利报复条款）。Apache-2.0 分支才有 `§3` 的专利许可与终止机制。考虑到本项目不涉及专利密集领域、上游为应用层工具，判定该代价可接受；若后续上游被大厂收购或出现专利主张，可**单方改选 Apache-2.0 分支**（双许可允许随时切换分支，切换只需补齐对应义务）。切换点与触发条件记入本文 §8。

> 注意：选择 MIT 分支**不授予商标权**。Apache-2.0 `§6` 明文不授予商标权，MIT 亦然（默示）。产品名、图标、分发渠道文案**不得使用 "Motif" 作为我方产品名或暗示官方背书**；描述性引用（"based on Motif"）应保留并注明上游仓库地址。

---

## 6. MIT 分支 vs Apache-2.0 分支：义务差异

| 义务项 | MIT 分支 | Apache-2.0 分支 | 对本项目的实际差异 |
|---|---|---|---|
| 附许可全文 | **必须** | **必须** | 相同；均需我们自带文本（G2） |
| 附版权声明 | **必须**（版权人 + 年份 + 许可名） | **必须**（含 `§4(c)` 保留所有版权/专利/商标/归属声明） | 相同，但 Apache 要求保留的范围更宽 |
| NOTICE 文件 | 无此概念 | 上游若有 NOTICE 须随附并保留其内容 | 上游无 NOTICE → 两者实际负担相同 |
| 标注修改过的文件 | **无要求** | `§4(b)`：须在修改文件上放显著变更声明 | **MIT 显著更省事**，这是我们选 MIT 的主因 |
| 专利授权 | 无明示（仅"AS IS"免责） | `§3` 明示专利许可 + 专利报复终止 | 我们的**风险敞口差异**，不是义务差异 |
| 商标 | 未授予 | `§6` 明文不授予 | 相同（都不得用作产品名） |
| 源码公开 | 不要求 | 不要求 | 相同（二者都不是 copyleft） |
| 私有化修改 | 允许且无需公开 | 允许且无需公开 | 相同 |

**一句话**：两条分支在"要不要开源"上没有区别，区别只在 **Apache 多一层专利保护、但要求标注改动并管理 NOTICE**。我们选"义务轻、保护弱"的 MIT。

---

## 7. 决策表：三种产品形态

> 判定列用词：**可分发** / **可分发（附条件）** / **不分发**。"附带物"指必须随安装包或分发渠道提供的文件。

### 7.1 形态 A：内嵌 `motifd`，打进我方安装包

| 项 | 内容 |
|---|---|
| 分发行为 | 我们在自己的安装包内再分发 `motifd` 二进制（及其静态链接的三方库） |
| 判定 | **可分发（附条件）** —— 条件即 G1+G2+G3 全部成立 |
| 触发义务 | ① 附 MIT 全文；② 附版权声明；③ 记录来源与版本锁定（commit SHA） |
| 必带文件 | `third_party/motif/LICENSE-MIT`、`third_party/motif/SOURCE.md`、`third_party/<每个 vendored 组件>/LICENSE*`（见 `third-party.md` 清单） |
| 不做会怎样 | 缺 G2 时，我们分发的是一个"声明了 MIT 但没附全文"的产物 —— 属于**未完整履行 MIT 条款**的分发形态，风险方向明确，**不应在这个状态下发行** |
| 备注 | 本形态必须锁定 commit；不得跟随 `main` 漂移，否则 SOURCE.md 记录的来源失效 |

### 7.2 形态 B：不打包，首启由用户从官方 Releases 下载 `motifd`

| 项 | 内容 |
|---|---|
| 分发行为 | 我方只分发"下载器/引导逻辑"，`motifd` 二进制由用户浏览器或客户端从**固定发布页** `github.com/xiachufang/motif/releases/tag/1.0.93`（commit `5f25f81`）取得；我们不构成该二进制的分发方 |
| 判定 | **可分发** —— 不触发 G2/G3 的随附义务（我们不是再分发方） |
| 触发义务 | 仅**提示与记录**：在 UI/README 说明 `motifd` 的来源、**精确版本号（不是 `latest`）**、SHA-256 校验值，以及其许可为 `MIT OR Apache-2.0`；不得缓存后二次分发 |
| 必带文件 | 建议仍附 `third_party/motif/SOURCE.md`（说明来源与许可），非强制 |
| 版本纪律 | 引导逻辑**必须写死 `1.0.93` + commit `5f25f81` + 产物 SHA-256**，不得指向 `releases/latest`：① `latest` 意味着我们无法预测用户拿到哪个许可状态；② 上游任何一次推送都会改变用户实际运行的内容，而我们已在自己的文档里记录过某个版本的行为；③ 校验值缺失等于放弃供应面完整性 |
| 风险点 | 若我们做"下载后缓存到 CDN/企业内网镜像并对外提供"，**就重新构成再分发**，退回形态 A 的义务集 |
| 备注 | 与形态 A 的产品差异（首启联网、版本不可控、离线不可用）须写进 README；这是 gate-0 的**兜底路径**，G2 未完成时只能走这条 |

### 7.3 形态 C：自托管 relay / 自托管管理面

| 子形态 | 分发行为 | 判定 | 说明 |
|---|---|---|---|
| C1 自托管 **motif 自带** push relay / rendezvous（`crates/motif-push-relay`、`crates/motif-rendezvous`） | 我方自行部署服务，或分发给客户部署 | **可分发（附条件）** | 这两个 crate 同属上游 workspace，`license.workspace = true` → 同样 `MIT OR Apache-2.0`，走 G1/G2 即可。它们**不含** AGPL 成分 |
| C2 自托管 **NetBird** `management/` `signal/` `relay/` `combined/` | 我方或客户部署这些服务端组件 | **服务可部署；但我们**不得把这些目录的代码并入我方分发物** | 这四个目录是 **AGPLv3**（一手证据见 `netbird-agpl.md`）。AGPL 允许我们**部署**，也允许我们**分发**——但一旦分发（含把镜像/二进制交给客户），须整体按 AGPLv3 提供对应源码。**独立进程 + 独立分发物 + 不改动 = 可接受的最简形态** |
| C3 把 C2 的组件**打进我方安装包**，或改造成我方产品的一部分 | 内嵌/魔改 management/relay 并随产品分发 | **不分发** | 这是本决策表里唯一的"不做"格。AGPLv3 的传染面覆盖"基于该程序的作品"以及"通过网络提供服务时的源码提供义务"；把它塞进我方闭源安装包会把整个分发物的许可策略拖进 AGPL。**这不是法律定性，是工程上不可接受的风险置换** |

> C 形态的关键操作纪律：**客户端（嵌入 `netbird-embed` / `flutter_netbird`，BSD-3/MIT）+ 服务端（AGPLv3）永远分仓、分产物、分版本号、分许可证声明。** 详见 `netbird-agpl.md` §4 的可执行清单。

### 7.4 一页速查

```
内嵌 motifd 打包        → 可分发（附条件：G1+G2+G3）   ← 目标形态
首启从官方 Releases 下载 → 可分发（无随附义务，需提示来源） ← 兜底形态
自托管 motif relay      → 可分发（附条件：G1+G2）        ← 与 A 同源许可
自托管 NetBird 四目录    → 可部署；分发则整体 AGPL      ← 独立产物，绝不内嵌
NetBird 四目录入我方包  → 不分发                        ← 唯一的硬红线
```

---

## 8. Apache 分支的改选触发条件（预留）

出现以下任一情形，重新评估切换到 Apache-2.0 分支（同一批文件，换义务集，无需上游同意）：

1. 上游补上 `LICENSE-APACHE` 并附 NOTICE（届时 Apache 分支的 NOTICE 义务有明确对象，成本可算）；
2. 我方产品进入有专利主张风险的行业客户采购流程，需要 `§3` 明示专利授权作为合同附件；
3. 出现针对 `motifd` 或其依赖的专利主张。

切换动作：补齐 `LICENSE-APACHE` + `NOTICE` + 修改文件变更声明，重发 `third_party/motif/` 目录，`decision.md` 记一次变更。

---

## 9. 与 gate 的对应

| gate-0 验收项（plan-v3 §7） | 本文对应 | 状态 |
|---|---|---|
| `docs/licensing/decision.md` 存在，含 G1–G4 四项状态 | 本文 + `G-actions.md` | ✅ 已落盘 |
| G2：安装包内 `third_party/motif/LICENSE-MIT` 存在且可读 | `templates/LICENSE-MIT` 已提供全文；**打包路径尚未接入构建脚本** | ⚠️ 文本已就绪，接线待办 |
| 未完成 → 安装包不含 `motifd` | 本文 §7.2 即该兜底路径 | ✅ 已定义 |

**当前判定不阻塞 P0-A / P0-B 开发**：开发期不对外分发二进制，gate-0 的影响面在"首个对外安装包"这一刻。发行前须复核 `G-actions.md` 全部为 Done。
