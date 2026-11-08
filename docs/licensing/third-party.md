# `motifd` 第三方依赖清点

> 取证：2026-11-08。来源三类，逐项标注：**① GitHub API/raw 直取上游文件**、**② crates.io API `license` 字段**、**③ 本机计算（Cargo.lock 图遍历）**。
> 范围：随 `motifd` 分发的一切 —— 含静态链接进二进制、并以文件资源形式内嵌的内容。
> 方法学限制：本机**无 Rust 工具链**（`cargo`/`rustc` MISSING），无法 `cargo tree`/`cargo metadata`。全树为 `Cargo.lock` 依赖边的图闭包（**上界**，含 dev-dependency 才引入、永不进 release 二进制的 crate），不等于 feature 解析后的真实链接集。
> 作用域声明（重要）：本文件结论**只覆盖已核实的 56/61 个直接依赖**；传递闭包未逐项核实，不得对外表述为"全树无 copyleft"。

---

## 1. 判定一句话

`motifd` 的许可面以 **MIT / Apache-2.0 系宽松许可**为主；**未发现 GPL/AGPL 等传染性许可混入已核实的依赖层**。需要单独随附许可的义务方共 **6 个**（§2），其中需要额外注意的只有两点：`libghostty-vt`（vendored，许可原文在仓库内）与 `ring`（`Apache-2.0 AND ISC`，是"且"不是"或"）。

---

## 2. 必须单独随附许可的组件（逐项核实）

| 组件 | 版本 | 许可 | 进 `motifd`？ | 随包附什么 | 取证 |
|---|---|---|---|---|---|
| **Motif 本体**（`motif-server` 等自有 crate） | 1.0.93 / commit `5f25f81` | `MIT OR Apache-2.0`（我方走 **MIT 分支**） | — 就是本体 | `third_party/motif/LICENSE-MIT` + `SOURCE.md` | ① 见 `decision.md` E4/E5/E6 |
| **`libghostty-vt`** | 0.2.1（path dep） | **MIT**，`Copyright (c) 2026 Uzair Aftab, Leah Amelia Chen` | ✅ **链接**：非 Windows 目标静态链接；Windows 目标以 `features = ["link-dynamic"]` 引入（`motif-server/Cargo.toml` 的 `cfg(not(windows))` 与 `cfg(windows)` 两个 target 段都有，**全平台都进**，只是链接方式不同） | 原样拷上游 `crates/libghostty-vt/LICENSE` | ① raw 直取，1,086 B |
| **`libghostty-vt-sys`** | 0.2.1（path dep） | **MIT**（同上） | ✅ 静态链接（构建 `libghostty-vt` 的 sys 层） | 同上（**两份许可证文件内容 `diff` 完全一致**，可合并为一个文件随包，不必放两份） | ① 直接 `diff` 两文件 → identical（各 1,086 B） |
| **`apps/flutter/ghostty`**（git submodule） | 跟随 `ghostty-org/ghostty` main | Ghostty 项目自体为 **MIT** | ❌ 不进 `motifd`（供 `libghostty-vt-sys` 构建期使用） | 不需随包；`SOURCE.md` 提一句即可 | ① `.gitmodules` 直读 |
| **`libtailscale`** / **`libtailscale-sys`** | 0.2.2 | **MIT** | ✅ **默认静态链接**：`motif-server` 的 `default = ["tailscale-bundled"]` → `motif-net/tailscale-bundled` → `motif-tailscale/bundled` → `libtailscale`（Go c-shared，经 `libtailscale-sys` 的 `build.rs` 编进二进制）。只有显式 `--no-default-features` 才是 stub、才不链接 | MIT 全文 + 版权行 | ② crates.io API `license: "MIT"`（两个 crate 均如此）；链接关系 ① 由 `motif-server`/`motif-net`/`motif-tailscale` 三份 `Cargo.toml` 的 feature 链核对 |
| **`xcap`** | 0.9.7 | **Apache-2.0** | ⚠️ 仅 `screen-capture` feature（**非** `motifd` 默认；Flutter desktop host 走 `motif-embed` 默认打开） | 若打包 `motif-embed`：附 Apache-2.0 全文 | ② crates.io API |

> **更正记录 1（相对 plan-v3 §2.3）**：`libtailscale` 是 **MIT 不是 BSD-3**（crates.io 0.2.2 元数据）。
> **更正记录 2**：曾写"`libtailscale` 条件性链接、默认 stub 不链接"——**该判断有误**。`motif-server` 的 `default = ["tailscale-bundled"]`，即**默认构建就静态链接**；stub 只出现在 `--no-default-features` 的构建里。以本表为准。

### 2.1 客户端侧（**不进** `motifd`，但发行物含，列此备查）

| 组件 | 版本 | 许可 | 进 `motifd`？ | 说明 |
|---|---|---|---|---|
| `doubao_asr`（`DOUVO_LICENSE.txt`） | 仓库内 | **标准 MIT**，`Copyright (c) 2026 rhinoc` | ❌ | 路径 `apps/flutter/lib/motif/platform/doubao_asr/`，只属 Flutter 客户端。**更正**：计划文档记为"自有许可"，实为标准 MIT 全文 |
| `netbird-embed` | 0.3.1 | **BSD-3-Clause** | ❌（是 crossdesk 侧 mesh 依赖，不进 `motifd`） | 上游 `github.com/tham-le/netbird-embed-rs`；随我方产品分发，须附 BSD-3 全文 + `Copyright` 行 |
| `flutter_netbird` | 1.0.5（2026-03-17） | **未取得一手** ⚠️ | ❌ | 见 §4 |

> **硬红线**：NetBird 的 `management/` `signal/` `relay/` `combined/` 四目录 —— 各含 **34,523 B 标准 AGPLv3 全文、无例外条款**，主 `LICENSE` 首句即明写豁免范围。**任何字节都不得进包**，详见 `netbird-agpl.md`。
> 注意区分：Motif 自带的 `motif-push-relay` / `motif-rendezvous` 属上游 workspace（`license.workspace = true` → MIT/Apache），**可分发**，与 NetBird 四目录不是一回事——名字都叫 "relay"，许可差一个量级。

---

## 3. `motifd` 直接依赖许可表（56/61 已核实）

`motif-server/Cargo.toml` 的非 dev 依赖共 **61 个**（去掉 4 个 workspace path 依赖后），逐项经 crates.io API 取 `license` 表达式：

| 许可表达式 | 数量 | crate |
|---|---|---|
| `MIT` | 20 | `axum` `bytes` `dashmap` `file_icon_provider` `http-body-util` `hyper` `hyper-util` `libtailscale` `libtailscale-sys` `mime_guess` `objc2` `portable-pty` `rmp-serde` `rmpv` `rust-embed` `sysinfo` `tokio` `tokio-tungstenite` `tokio-util` `tower-http` `tracing` `tracing-subscriber` `ulid` `which` |
| `MIT OR Apache-2.0` | 13 | `anyhow` `base64` `clap` `dirs` `flate2` `futures-util` `getrandom` `hex` `http` `libc` `parking_lot` `qrcode` `rcgen` `serde` `serde_json` `sha2` `tempfile` `thiserror` `time` `unicode-segmentation` `notify-debouncer-full` `zeroize` |
| `Apache-2.0` | 2 | `xcap`（可选 feature） |
| `Apache-2.0 OR MIT` | 1 | `aes-gcm` |
| `Apache-2.0 OR ISC OR MIT` | 2 | `rustls` `hyper-rustls` |
| **`Apache-2.0 AND ISC`** | 1 | **`ring`** —— 注意是 **"且"不是"或"**：须**同时**满足 Apache-2.0 与 ISC 两套义务。粗扫成 "Apache-2.0" 会漏掉 ISC 侧的保留声明要求。`ring` 自身随源码带 `LICENSE`/`LICENSE-*`，按 Apache-2.0 附全文即可。**这行是全表最容易做漏的一处，因为它长得像常见的 "A OR B" 双许可** |
| `MIT OR BSD-3-Clause` | 1 | `if-addrs` |
| `BSD-3-Clause`（单一，非"或"） | 1 | `subtle` → 须附 BSD-3 全文 + 版权行；不要套用 Apache 分支习惯 |
| `Zlib OR Apache-2.0 OR MIT` | 3 | `objc2-app-kit` `objc2-core-foundation` `objc2-core-graphics`（macOS-only，Windows 构建不参与） |
| **`CC0-1.0`** | 1 | **`notify`** —— 公共领域奉献，**无随附义务**（不需附全文，也不需版权行；仍建议随包致谢） |
| **`Unlicense/MIT`** | 1 | **`walkdir`** —— 双选择；走 MIT 侧附全文即可 |

> 三条例外（`ring` 的 `AND`、`subtle` 的单一 BSD-3、`notify` 的 CC0 与 `walkdir` 的 Unlicense）是逐项拉取元数据后才浮现的。靠"生态惯例"推断会全部猜错：`notify` 按惯例会以为是 MIT/Apache（实际 CC0），`ring` 按惯例会以为是 `OR`（实际 `AND`）。

**未取到（3 个，标注未取得一手）**：`untrusted 0.9.0`、`webpki-roots 1.0.7`、`windows-sys 0.61.2` —— crates.io API 在该时段对该三个请求持续超时/失败（重试 3 次）。三者均为 Rust 生态极常见组件，按公开常识分别为 ISC / MPL-2.0 / MIT-OR-Apache-2.0，但**本文不将其作为已核实结论**，见 §5 复核命令。

---

## 4. `flutter_netbird`：未取得一手（明确标记）

| 项 | 结果 |
|---|---|
| pub.dev 可达性 | **可达**（取证时段实测 HTTP 200；计划文档"pub.dev 不可达"的约束已不成立） |
| 版本 | `1.0.5`，发布于 2026-03-17 |
| `pubspec.yaml` 的 `license` 字段 | **不存在**；同时**无** `repository` / `homepage`（值为 `null`） |
| tarball（`/api/archives/flutter_netbird-1.0.5.tar.gz`） | 33 MB，本机 60 s 超时仅取到 2.3 MB，**LICENSE 原文未取到** |
| GitHub 兜底 | `api.github.com/search/repositories?q=flutter_netbird+in:name` → **total_count = 0**，无同名公开仓库可作替代源 |
| 结论 | **未取得一手。** 计划文档中的 "MIT" 是转述而非核实结果，**不得**作为已核实事实引用 |

**用户侧补核（二选一，1 分钟）**
```sh
# A. 直接看 pub.dev 页面的 License 段
#    https://pub.dev/packages/flutter_netbird  → 右侧 "License" 一栏
# B. 本地拉包后读 LICENSE
dart pub cache add flutter_netbird --version 1.0.5
ls ~/.pub-cache/hosted/pub.dev/flutter_netbird-1.0.5/LICENSE*
```
补到后回填本表并把 `netbird-agpl.md` §6 的对应行划掉。

---

## 5. 完整树待用户侧生成（本机无工具链）

```sh
# 在装好 Rust 工具链的机器上、锁定 commit 5f25f81 处执行
git clone https://github.com/xiachufang/motif && cd motif
git checkout 5f25f81655765147b5156bff2aacb4260806a41d

# ① 真实链接集（feature 解析后，非 lock 上界）
cargo tree -p motif-server -e normal --prefix none | sort -u > /tmp/realtree.txt

# ② 逐包许可（与本文 §3 对差）
cargo install cargo-license --locked
cargo license -p motif-server --avoid-build-deps --avoid-dev-deps --do-not-fail

# ③ 许可策略闸门（建议进 CI）—— 这一条同时覆盖传递闭包
cargo install cargo-deny --locked
cargo deny check licenses     # deny.toml 里配 allow = ["MIT","Apache-2.0","BSD-3-Clause","ISC","Zlib","CC0-1.0","Unlicense","MPL-2.0"]
```
对差结果回写本文 §3；若 `cargo deny` 报出未允许的许可，先补进 §2 的义务表，再重跑。
`cargo deny check licenses` 通过 = §6 的三类缺口一起关闭；在此之前，对外的准确表述是"**直接依赖层已核清，传递闭包待 `cargo deny` 在构建机确认**"。

---

## 6. 附录：传递依赖许可扫描（部分完成）

| 指标 | 值 |
|---|---|
| 上游 `Cargo.lock` 包总数 | **530**（`[[package]]` 计数） |
| 从 `motif-server` 起算的传递闭包 | **515** 个节点（含 7 个 workspace 本地 crate） |
| 其中三方 registry crate | **510** |
| 已取得许可元数据的 | **56**（= `motifd` 直接依赖层，见 §3） |
| 未取得一手 | **454**（间接依赖）+ 3（直接依赖中请求失败的）= **457** |
| 扫描结论 | **在已核实的 56 个直接依赖中，未发现 GPL/AGPL 等传染性（copyleft）许可**。间接依赖层**未逐项核实**，不能据本文断言全树干净 —— 该断言需 `cargo deny check licenses`（§5 ③）在构建机产出 |

> 口径纪律：本节结论的**作用域**只有"已核实的直接依赖层"。对外表述时不要压缩成"全树无 copyleft"，那是 `cargo deny` 的活。

**已知需要留意的间接依赖（按生态常识，非本文核实结论）**

| crate | 出现在闭包中 | 需要留意什么 |
|---|---|---|
| `webpki-roots` | ✅（`motif-net`/`motif-server` 经 rustls 引入） | 若为 MPL-2.0：文件级弱 copyleft，**仅在我们修改其文件时**才需公开该文件；原样使用只需保留声明 |
| `ring` | ✅（rustls 的 crypto provider） | 已在 §3 列为 `Apache-2.0 AND ISC`，须两条都满足 |
| `glib` / `gtk` / `cairo-rs` / `pango` / `pipewire` / `wayland-*` / `zbus` | ✅（`xcap` 的 Linux 后端闭包） | 均为 MIT 系；但**体积与随附清单**影响大，若打包 `motif-embed` 需一并附 |

---

## 7. 随包目录建议形态

```
third_party/
├── motif/
│   ├── LICENSE-MIT          ← 见 templates/LICENSE-MIT（必带，G2）
│   └── SOURCE.md            ← 见 templates/SOURCE.md（必带，G3）
├── libghostty-vt/LICENSE    ← 上游原文，原样（-sys 版与此一致，不必重复放）
├── libtailscale/LICENSE     ← MIT 全文（默认就链接）
├── ring/LICENSE-APACHE      ← Apache-2.0 全文（AND 义务）
├── subtle/LICENSE           ← BSD-3 全文
├── if-addrs/LICENSE         ← 走 MIT 分支
├── netbird-embed/LICENSE    ← BSD-3 全文（Windows 客户端随包）
├── flutter-netbird/LICENSE  ← 取得后追加
└── THIRD-PARTY.md           ← 本文件的可分发摘要版
```

`THIRD-PARTY.md` 由本文件 §2 + §3 生成，**只留"名称/版本/许可/版权行"四列**，去掉取证批注与内部分析。
