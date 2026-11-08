# netbird-embed fork 面记录（P0-A 填写）

> 目的：把「上游停更就 fork」从口号变成可核算的面积。本文件只记**当前实现实际依赖的上游符号**，不记潜在能力。

## 1. 白名单（契约，不可扩）

| 方法 | 上游对应 | 平台 |
|---|---|---|
| `start(cfg)` | `Client::new` + `client.start()` | 全平台 |
| `stop()` | `client.stop()` | 全平台 |
| `status()` | 状态 JSON（轮询） | 全平台 |
| `peers()` | peer 列表 JSON（轮询） | 全平台 |
| `proxy(addr)` | `client.start_proxy("ip:port")` | 全平台 |

## 2. 上游符号清单（P0-A 实测清点）

> **状态**：Rust 安全层符号**已逐条清点完毕** —— 依据 `crates/mesh/src/netbird.rs` 的实际
> import 与调用点，对照 netbird-embed **0.3.1 发布源码**（`docs.rs/crate/netbird-embed/0.3.1/source/src/lib.rs`
> 与同版本 `build.rs`）逐项核对，字段名/方法名均取自上游源码而非记忆。
> **仍缺一列**：`nm -D --defined-only` 的导出符号实测（需先构建出 `.dll`，本机无 cargo/go，
> 见 plan-v3 §6.1）。补齐办法见 §2.4，目标机跑一条命令即可。

### 2.1 Rust 安全层（`netbird_embed::*`）—— 13 个符号

| # | 上游符号 | 用在哪 | 备注 |
|---|---|---|---|
| 1 | `Client::new(ClientOptions) -> Result<Client, Error>` | `Mesh::start` | 唯一构造入口 |
| 2 | `ClientOptions`（只设 6 个字段） | `client_options()` | 设 `setup_key` / `management_url` / `device_name` / `state_path` / `log_level` / `wireguard_port`；其余走 `..Default::default()` |
| 3 | `Client::start()` | `Mesh::start` | 成功只代表 Go 侧受理，不代表隧道通 |
| 4 | `Client::stop()` | `Mesh::stop` | **显式**调用；`Client::drop` 会阻塞，不作为关闭路径 |
| 5 | `Client::status() -> Result<Status, Error>` | `Mesh::status` | 轮询；上游没有事件回调 |
| 6 | `Status` 的 7 个字段：`state` / `ip` / `fqdn` / `management_state` / `signal_state` / `peers` / `error` | `apply_status()` | 未读 `pub_key` |
| 7 | `Client::peers() -> Result<Vec<Peer>, Error>` | `Mesh::peers` | |
| 8 | `Peer` 的 5 个字段：`ip` / `fqdn` / `conn_status` / `relayed` / `latency` | `peer_view()` | 未读 `pub_key`；`direct = is_connected() && !relayed` |
| 9 | `Peer::is_connected()` | `is_direct()` | 等价于 `conn_status == Connected` |
| 10 | `Client::start_proxy(&str) -> Result<u16, Error>` | `Mesh::proxy` | **Windows 唯一数据面**；返回端口每次启动随机 |
| 11 | `ConnectionState`（`Connected` / `Connecting` / `Disconnected` / `Unknown`） | `conn_flags()` | `Unknown` 来自上游 `#[serde(other)]`；一律判未连接（保守） |
| 12 | `netbird_embed::Error`（thiserror 枚举） | 只 `format!("{err}")` 进 `anyhow` | **不 match 变体** → fork 时错误类型可自由重构，零影响 |
| 13 | `Client::drop` → FFI `nb_free` → Go `Stop()` | 仅 `NetbirdMesh::drop`：打 `warn` 并把进程级 runtime 置 `poisoned` | 已知阻塞点（约束 2），**不是关闭路径**；未 `stop()` 就 drop → 终态 poisoned，之后 `start()` 直接拒绝（需重启进程），所以不能把它当兜底关闭手段 |

### 2.2 明确**未使用**的上游符号（白名单禁止，将来也不许加）

- ❌ `Client::dial` / `Client::listen` / `Client::listen_udp` —— Unix socketpair 实现，Windows 目标无关
- ❌ `Client::start_reverse_proxy` —— 反向把本机服务暴露进 overlay，纯攻击面，P0 用不到
- ❌ `Client::set_log_level` —— 日志级别只在启动时经 `MeshConfig.log_level` 传一次
- ❌ `Listener`（Unix-only 类型）
- ❌ `ClientOptions` 的其余字段：`token` / `private_key` / `pre_shared_key` / `config_path` / `disable_client_routes` / `block_inbound` / `no_userspace`

### 2.3 FFI 边界（`build.rs` 生成的 `nb_*`，非本 crate 直接依赖）

上游 `build.rs` 把 Go 侧导出写成手写 `extern "C"` 绑定（共 **14** 个）。本项目**实际触达 9 个**：

| C 导出 | 触达路径 |
|---|---|
| `nb_new` | `Client::new` |
| `nb_create_errmsg` | `Client::new` 失败时取错误文本 |
| `nb_start` | `Client::start` |
| `nb_stop` | `Client::stop`（以及 `nb_free` 内部） |
| `nb_status` | `Client::status`（JSON 写调用方 buffer，`ERANGE` 自动扩 buffer 重试） |
| `nb_peers` | `Client::peers` |
| `nb_proxy` | `Client::start_proxy` |
| `nb_errmsg` | 各方法失败时取错误文本 |
| `nb_free` | `Client::drop` |

**不触达（5 个，与 §2.2 一一对应）**：`nb_dial` / `nb_listen` / `nb_listen_udp` /
`nb_reverse_proxy` / `nb_set_log_level`。

### 2.4 待目标机实测（编译后一条命令补齐）

```powershell
# 期望：14 个 nb_* 导出；且整个进程只加载一份 Go runtime（配套脚本见 §3.4）
nm -D --defined-only target\release\netbird_embed.dll | Select-String ' nb_' | Measure-Object

# 期望：netbird-embed v0.3.1（pin 生效）+ serde / serde_json / libc / thiserror 四个传递依赖
cargo tree -p crossdesk-mesh
```

把两条命令的输出贴在本节下方即可关闭"待实测"。

> **2026-11-08 已实测（Windows amd64 交叉编译产物）**：`libnetbird_embed.dll` 导出 **14 个 `nb_*`**，与 §2.3 的
> 预测一致；`-trimpath -ldflags="-s -w"` 重建后符号集**完全相同**（`diff` 为空），体积 57.9 → 29.4 MiB。
> 即：这条"待实测"只剩 `cargo tree` 一项（传递依赖清单）未贴。

### 2.5 fork 成本核算（据此确认 ≤5 函数体的目标）

- **真实接触面 = 13 个符号**，但**真正的函数体只有 6 个**：`new` / `start` / `stop` / `status` / `peers` / `start_proxy`（`drop` 是第 7 个但只做 `nb_free`）。
- 其余 7 项都是类型/字段/枚举：fork 时只需保留 `Status` 与 `Peer` 两个结构定义 + `ConnectionState` 枚举即可让 `crates/mesh` **零改动**。
- **字段是"只读契约"（限定：仅当上游"只增字段"时成立）**：上游**新增**字段不影响我们
  （我们只读已知字段，上游已用 `#[serde(default)]` 兜住缺字段）。但上游若**改名/改类型**
  （非纯增），我们的 `Status`/`Peer` 映射会直接编译失败 —— 这也是契约的一部分，不是
  "字段随便变都不影响"。所以它只覆盖"上游演进时不会平白制造编译错误"这一半；真正触发
  fork 的仍是 6 个函数之一的**语义**坏了。

## 3. 若需 fork：最小 patch 面

- **目标**：≤7 个函数体 + 2 个结构定义（`Status`/`Peer`）+ 1 个枚举（`ConnectionState`）。
  对齐关系：5 个白名单方法 ↔ `new`/`start`/`stop`/`status`/`peers`/`start_proxy` 六个上游函数（`start` 拆 `new`+`start`），外加 `drop`。依据见 §2.5。
- **1b. 先于 fork 的补丁（P0-A 实测，对应 plan-v3 §3.3 "第一个已知 patch 项"）**：
  给上游 `build.rs` 的 `go build` 调用补 `-trimpath -ldflags=-s -w`。
  理由：cargo 无法把该 flag 透传给 build.rs（`GOFLAGS` 按空格切分，`-ldflags=-s -w` 被切成两个参数），
  所以直编出来的 `.dll` 永远是"肥"的，plan-v3 §5 的体积达标依赖这一行。
  **即使不 fork 也值得做**，成本 = vendor 后改一行。
- **触发条件**：上游 12 个月无 release / 关键 bug 不修 / Go 版本冲突无法解
- **步骤**：pin → vendor → 只改这 5 个函数 → 保留上游 crate 名与签名（caller 零改动）
- **配套硬闸**：`scripts/check-single-go-runtime.sh`（三层证据：`go1.` buildinfo / `runtime.` 符号 /
  nm+objdump 兜底），产物里出现第二个 Go runtime 即 exit 1。
