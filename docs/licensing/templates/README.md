# `templates/` 用法说明 —— 随包许可证文件的来源与填写规则

本目录存放**随安装包分发**的许可证文件模板。`LICENSE-MIT` 是可直接拷进安装包的成品件；本文件说明它为什么长这样、换版本时怎么改。

---

## 1. 清单

| 文件 | 用途 | 是否直接随包 |
|---|---|---|
| `LICENSE-MIT` | 上游 Motif 的 MIT 分支许可全文（G2 交付物） | ✅ 是，落到 `third_party/motif/LICENSE-MIT` |
| `SOURCE.md` | 上游来源与版本锁定说明（G3 交付物） | ✅ 是，落到 `third_party/motif/SOURCE.md` |

## 2. 为什么版权行是"构造"的，而不是抄的

上游 `xiachufang/motif` **没有提供版权声明行**（仓库无 `LICENSE`/`COPYING`，E2；仅有的三个 license 文件都属第三方 vendored 组件，E3）。因此这一行由我们依上游可考字段构造：

| 字段 | 取值 | 依据 |
|---|---|---|
| 版权人 | `Motif contributors` | 上游 `Cargo.toml` → `[workspace.package] authors = ["Motif contributors"]`（E4，一手） |
| 年份 | `2026` | 该 manifest 当前有效年份；首次公开 push 为 2026-11-02（E1） |
| 可追溯锚点 | 仓库 URL + 锁定 commit SHA | 使这一行可被任何人回溯校验，避免"凭空署名" |

> **表述纪律**：这一行是"依据上游 `authors` 字段构造的归属声明"，**不是**上游原文。`SOURCE.md` 中必须如实写明这一点（模板里已有该句），不要伪装成上游提供的版权行。

## 3. 占位符形态（换版本 / 换上游时用）

需要重新生成时，把成品件第一段替换为下面这个形态，再按 §2 的规则填实：

```
MIT License

Copyright (c) {{YEAR}} {{COPYRIGHT_HOLDER}}
{{UPSTREAM_URL}}
pinned commit: {{COMMIT_SHA}}
```

填写规则：

- `{{YEAR}}` —— 取锁定 commit 的年份（`git show -s --format=%cs <sha>`），不是"当前年份"。
- `{{COPYRIGHT_HOLDER}}` —— 优先取上游 `Cargo.toml` 的 `authors`；若上游改为 `license-file` 或补上 `LICENSE-MIT`，**立即改为直接引用上游文件**（届时本模板作废，见 §5 退出条件）。
- `{{UPSTREAM_URL}}` —— 固定为 `https://github.com/xiachufang/motif`。换了上游仓库就换这里，同时改 `SOURCE.md`。
- `{{COMMIT_SHA}}` —— 必须是**完整 40 位 SHA**，且与实际构建所用代码一致。取法：在打安装包的那次构建里执行 `git -C <motif-checkout> rev-parse HEAD`，把输出写进 `SOURCE.md` 并同步到这行的短 SHA。

## 4. 随包放置位置（与 decision.md §7.1 对齐）

```
<安装包根>/
└── third_party/
    └── motif/
        ├── LICENSE-MIT      ← 本目录同名文件拷贝
        ├── SOURCE.md        ← 本目录同名模板填实
        └── (可选) NOTICE.md ← 上游第三方位与 Ghostty 子模块的简短归属说明
```

同时要求：安装包内的"关于 / Licenses"界面能**打开并读到**该文件（不是只在磁盘里躺着）。gate-0 验收口径是"路径存在且内容可读"。

## 5. 退出条件（上游补正后）

一旦上游合并了 `LICENSE-MIT` / `LICENSE-APACHE` 正本：

1. **停止使用本模板的版权行**，改为原样拷贝上游文件；
2. `SOURCE.md` 保留"曾自行构造版权行"的历史说明（审计连续性）；
3. 本目录的 `LICENSE-MIT` 标记为 `deprecated`，但在移除前至少保留一个发布周期。

触发条件与 issue 编号登记在 `docs/licensing/upstream-issue-draft.md` 文末的跟踪表。
