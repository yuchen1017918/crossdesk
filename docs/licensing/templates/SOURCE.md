# 第三方组件来源与许可说明 —— Motif (`motifd`)

> 本文件随安装包分发，路径：`third_party/motif/SOURCE.md`
> 生成日期：{{BUILD_DATE}}　　构建编号：{{BUILD_ID}}

## 1. 组件是什么

本安装包内含 `motifd`，一个远程开发代理进程，来自开源项目 **Motif**。

| 项 | 值 |
|---|---|
| 上游仓库 | https://github.com/xiachufang/motif |
| 上游版本 | Motif `1.0.93`（release tag `1.0.93`） |
| 锁定 commit | `5f25f81655765147b5156bff2aacb4260806a41d` |
| commit 日期 | 2026-11-02 |
| 构建方式 | 我方从上述 commit 自行编译（`cargo build --release -p motif-server`），未对源码做功能性修改 |
| 产物 | `motifd`（Rust 二进制） |

> 若实际构建参数与上表不符（例如启用/关闭了 feature 组合），**必须在此如实改写**。这份文件的价值在于可追溯，不在于好看。

## 2. 许可

上游在以下两处以书面形式声明了双许可（二选一）：

| 位置 | 原文 |
|---|---|
| 仓库根 `Cargo.toml` → `[workspace.package]` | `license = "MIT OR Apache-2.0"` |
| `README.md` → `## License` | `MIT OR Apache-2.0.` |

我方**选择按 MIT 分支**履行再分发义务，依据如下：

- SPDX 表达式中的 `OR` 语义允许被许可方择一履行，无需同时满足两条；
- MIT 分支的义务为「附许可全文 + 附版权声明」，Apache-2.0 分支另需标注被修改文件并处理 `NOTICE`；本项目分发自行构建的二进制，前者义务面更小、更可验证。

许可全文见同目录 `LICENSE-MIT`。

## 3. 关于版权行的重要说明（请勿误读）

**上游仓库未提供任何版权声明行**（根目录无 `LICENSE` / `COPYING` / `NOTICE`）。`LICENSE-MIT` 中的

```
Copyright (c) 2026 Motif contributors
```

是**我方依上游 `Cargo.toml` 中 `[workspace.package] authors = ["Motif contributors"]` 字段构造**的归属声明，用于满足 MIT「随分发物附版权声明」的要求，**并非上游原文件中的句子**。我方不做任何超出该字段的归属主张。

年份取自锁定 commit 的日期（2026-11-02），非安装包构建年份。

## 4. 已知的上游元数据缺失

| 缺失项 | 状态 | 我方处置 |
|---|---|---|
| `LICENSE-MIT` / `LICENSE-APACHE` 正本文件 | 上游仓库中不存在 | 自备标准 MIT 文本（本目录 `LICENSE-MIT`），并向上下游提交补正请求 |
| `NOTICE` | 上游仓库中不存在 | 走 MIT 分支，该义务不适用 |
| 项目级版权声明 | 上游仓库中不存在 | 依 `authors` 字段构造，见 §3 |

## 5. 随包的第三方组件

`motifd` 二进制内静态链接了若干第三方开源组件，其中需要在分发时单独附许可的组件清单，见同目录 `THIRD-PARTY.md`（由 `docs/licensing/third-party.md` 生成）。

其中 `libghostty-vt` / `libghostty-vt-sys` 为上游 vendored 组件（MIT，Copyright (c) 2026 Uzair Aftab, Leah Amelia Chen），上游仓库内已有其许可原文，我方原样随附。

## 6. 联系与补正

如对本说明有异议，或发现归属信息有误，请通过 {{CONTACT_EMAIL}} 联系。我方承诺在收到合理异议后 30 日内更正并重新发布。
