# G1–G4 动作清单（gate-0 落地项）

> 对应 `decision.md` §2（证据）、§5–§7（判定与决策）。本文件是**执行台账**：每项给出状态、验收口径、以及"怎么算做完"。
> 判定基线：`MIT OR Apache-2.0` 双许可、选 **MIT 分支**（G1）。目标产品形态：**形态 A（内嵌 motifd 打包）**。

**汇总**

| # | 动作 | 状态 | 阻塞发行？ |
|---|---|---|---|
| G1 | 选定 MIT 分支（不以 Apache-2.0 分发） | ✅ **Done** | 否 |
| G2 | 自备 MIT 全文 + 版权行，随包分发 | 🟡 **文本 Done / 接线 Todo** | **是** |
| G3 | 向上游提 issue 求补正本；补上前用 `SOURCE.md` 记录来源 | 🟡 **草稿 Done / 提交 Todo** | 否（有替代记录即可） |
| G4 | 传递依赖清点 | 🟢 **直接依赖+已知第三方 Done / 全树待用户侧生成** | 否（但有未登记风险） |

---

## G1 —— 选定 MIT 分支

| 项 | 内容 |
|---|---|
| **状态** | ✅ Done |
| **决定** | 以 MIT 分支履行再分发义务；不以 Apache-2.0 分支分发 |
| **依据** | `decision.md` §5。核心三条：① MIT 只有"附全文+附版权声明"两项实质义务；② Apache `§4(b)` 要求标注被修改文件，而我们是自行构建产物、拿不到逐文件 diff 口径，做漏概率高；③ 上游无 `NOTICE`，走 MIT 后该缺口变成无关项 |
| **代价（已接受）** | MIT 无明示专利授权（亦无专利报复条款）。详见 §改选触发条件 |
| **改选触发** | `decision.md` §8 三条件之一出现时重评 |
| **验收** | 本行 + `decision.md §5` 存在，且 `third_party/motif/LICENSE-MIT` 的许可名与此一致 → 已满足 |

---

## G2 —— 自备 MIT 全文 + 版权行

| 项 | 内容 |
|---|---|
| **状态** | 🟡 文本已就绪（`templates/LICENSE-MIT`），**随包接线未完成** |
| **交付物（已落盘）** | `docs/licensing/templates/LICENSE-MIT` —— 标准 MIT 全文，版权行已填实 |
| **版权行** | `Copyright (c) 2026 Motif contributors` / `https://github.com/xiachufang/motif` / `pinned commit: 5f25f81655765147b5156bff2aacb4260806a41d (Motif 1.0.93)` |
| **版权行依据** | 上游 `Cargo.toml` `[workspace.package] authors = ["Motif contributors"]`（一手，E4）。上游**未提供**版权行，此行由我们依该字段构造并标注推断性质 —— 不得对外宣称为上游原文 |
| **commit 锁定方式** | 构建时取 `git -C <motif-checkout> rev-parse HEAD`，写入 `third_party/motif/SOURCE.md`，与该文件中的 SHA 必须一致；不一致即构建失败（见下方校验脚本要求） |
| **待办（Todo）** | ① 把 `templates/LICENSE-MIT` 拷到安装包 `third_party/motif/LICENSE-MIT`；② 安装包内"关于/Licenses"界面能打开该文件；③ 构建脚本加 SHA 一致性断言 |
| **验收口径** | 安装包内**路径存在且内容可读**（不是只在磁盘躺着）——plan-v3 §2.2 原文要求 |
| **不做会怎样** | 我们分发的是"声明 MIT 但未附全文"的产物，属**未完整履行 MIT 条款**的分发形态。此状态下不发行，改走形态 B（`decision.md §7.2`） |
| **接线 Todo 的验收命令** | `unzip -p <installer> third_party/motif/LICENSE-MIT \| head -3` 应输出 `MIT License` + 版权行 |

**建议加进构建脚本的断言（伪代码）**

```sh
PINNED=5f25f81655765147b5156bff2aacb4260806a41d
ACTUAL=$(git -C "$MOTIF_SRC" rev-parse HEAD)
[ "$PINNED" = "$ACTUAL" ] || { echo "gate-0: motif commit drift"; exit 1; }
grep -q "$PINNED" docs/licensing/templates/LICENSE-MIT || { echo "gate-0: LICENSE-MIT SHA stale"; exit 1; }
```

---

## G3 —— 上游补正本 + 过渡期记录

| 项 | 内容 |
|---|---|
| **状态** | 🟡 issue 草稿已就绪（`upstream-issue-draft.md`），**尚未提交**（本机无 gh 认证，需用户侧提交） |
| **过渡期记录** | `docs/licensing/templates/SOURCE.md` —— 模板已就绪，随包落到 `third_party/motif/SOURCE.md` |
| **必须记录的四项** | ① 上游仓库 URL + 锁定 commit SHA + 对应 release tag（`1.0.93`）；② 上游声明的许可表达式与其**位置**（`Cargo.toml` / `README.md`）；③ 正本缺失的事实与我们的补正方式（自备标准 MIT 文本 + 构造版权行）；④ 取证日期 |
| **不做会怎样** | 安装包里出现一个"来路不明、无许可全文"的二进制。功能上无影响，但一旦被下游客户或采购流程问到，无法自证 —— 这是 G3 的真实价值，不是形式主义 |
| **验收** | `SOURCE.md` 落包 + issue 有编号（编号回填到 `upstream-issue-draft.md` 文末跟踪表） |
| **谁提交 issue** | **用户侧**（需 GitHub 账号；本机无凭据，agent 不代发） |

---

## G4 —— 传递依赖清点

| 项 | 内容 |
|---|---|
| **状态** | 🟢 直接依赖 + 已知第三方已清点（`third-party.md`）；全树为**机器计算的上界**，待用户侧 `cargo metadata` 复核 |
| **已完成** | ① `motif-server/Cargo.toml` 直接依赖逐条过；② 三个已知第三方 LICENSE 读原文（`libghostty-vt`、`libghostty-vt-sys`、`DOUVO_LICENSE.txt`）；③ `libtailscale`/`libtailscale-sys`/`netbird-embed` 走 crates.io 元数据；④ 对上游 `Cargo.lock` 做图闭包（从 `motif-server` 起算 515 个节点，其中三方 crate 510 个），用于扫"有无 GPL/AGPL 混入" |
| **方法学声明** | 本机**无 Rust 工具链**（`cargo`/`rustc` MISSING），无法 `cargo tree`/`cargo metadata`。闭包是在 `Cargo.lock` 的 `dependencies` 边上做的图遍历 —— 它是**上界**（含 dev-dependency 才引入、永不进 release 二进制的 crate），不等于 feature 解析后的真实链接集 |
| **待办（用户侧）** | 在装有工具链的机器上跑 `cargo metadata --filter-platform <target> --format-version 1` + `cargo tree -e normal --prefix none`，与 `third-party.md` 的清单对差 |
| **验收** | `third-party.md` 覆盖 motifd 实际链接的依赖树，且**每个非 MIT/Apache 的依赖都有单独的归属说明** |

---

## 落地顺序（发行前 checklist）

```
[ ] G2 接线：LICENSE-MIT 进安装包 + Licenses 界面可读 + SHA 断言
[ ] G3 落包：SOURCE.md 进安装包
[ ] G3 提交：issue（用户侧），编号回填
[ ] G4 复核：cargo metadata 对差，差异回写 third-party.md
[ ] 复核 decision.md §7.1 的"必带文件"清单在安装包里逐一存在
```

全绿 → gate-0 通过，形态 A 可发行。
任一未绿 → 发行物**不含 motifd**，走形态 B（`decision.md §7.2`），产品差异写进 README。
