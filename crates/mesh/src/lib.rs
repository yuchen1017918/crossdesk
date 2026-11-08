//! crossdesk 的 overlay 抽象层：**全项目唯一的 mesh 接口面**。
//!
//! 本 crate 把 [`netbird_embed`]（Rust 安全层 → `extern "C"` → Go c-shared）
//! 收敛成 5 个方法，其余能力一律不暴露。上游若停更，替换实现只需重新满足
//! 这 5 个签名（`docs/design/mesh-fork-surface.md` §3）。
//!
//! ```text
//! start(cfg)  -> 加入 overlay（Client::new + client.start()）
//! stop()      -> 显式离开 overlay（client.stop()，不依赖 Drop）
//! status()    -> 连接态 + 本机 overlay IP + last_error 摘要（轮询，无回调）
//! peers()     -> fqdn / ip / direct|relayed（轮询，无回调）
//! proxy(addr) -> 127.0.0.1:<随机端口>，本地 TCP+UDP 转发到 overlay 目标
//! ```
//!
//! # 四条硬约束（改代码前先读完）
//!
//! 1. **一进程只允许一个 Go runtime。**
//!    `netbird-embed` 0.3.1 的 Go 侧是 c-shared `.dll`/`.so`，同一进程里出现
//!    两份 Go runtime 会导致 GC 损坏（上游 README「Gotchas」）。本 crate 用一个
//!    进程级三态标记（`free` / `claimed` / `poisoned`）把「同时存在两个 client」
//!    变成硬错误：`start()` 抢 `claimed`，`stop()` 是唯一回到 `free` 的路径；
//!    未 `stop()` 就 drop 则进入终态 `poisoned`（见约束 2）。
//!    若将来真需要两个 overlay，**拆独立进程**（plan-v3 §3.3），不要在进程内加
//!    第二个 client。
//! 2. **`Client::drop` 会阻塞，因此 drop 不是关闭路径。** 上游 `Drop` 调 Go `Stop()`，
//!    隧道拆除期间可能卡住调用线程（最坏情况是 UI 线程）。`NetbirdMesh::stop()` 是唯一
//!    正常的关闭路径：显式 `client.stop()`，之后才让 `Client` 自然 `drop`（此时 Go 侧已是
//!    停止态）。
//!
//!    **未 `stop()` 就 drop 会把进程钉成 `poisoned`（终态）**：[`NetbirdMesh`] 的 `Drop`
//!    会在字段被 drop（= `Client::drop` → `nb_free` → Go `Stop()`）**之前**把进程级 Go
//!    runtime 状态置为 poisoned 并 `warn`。之后本进程任何 `start()` 都会给出**专用错误**
//!    （"上一个实例被 drop 未 stop，请重启进程 / 按 plan-v3 §3.3 拆独立进程"），而不是
//!    复用"被另一个实例占用"那句话 —— 因为两者的排查方向完全不同，且 Go 侧是否拆干净
//!    无从确认，不能假装没事继续用。
//!
//! 3. **proxy 端口每次启动都是随机值，禁止写死。**
//!    `start_proxy()` 返回 Go 侧 `net.Listen` 拿到的本地端口（通常随机高位端口），
//!    每次进程重启都可能不同。调用方必须用返回值，不得缓存成常量、不得假定 7777/8080
//!    之类的固定值。
//! 4. **Cargo 侧版本锁死 `=0.3.1`。** 依赖声明在根 `Cargo.toml` 的
//!    `[workspace.dependencies]`（单人维护的上游 crate，禁止漂移）。本 crate 只
//!    写 `netbird-embed.workspace = true`。
//!
//! # 平台形态
//!
//! | 平台 | 数据面形态 | 说明 |
//! |---|---|---|
//! | Windows | `start_proxy("overlay_ip:port")` → `127.0.0.1:<随机端口>` | userspace netstack，overlay IP 不对 OS socket 可路由，proxy 是**唯一**通路 |
//! | Linux / macOS | 同上 | 上游另有 `dial`/`listen`/`listen_udp`（socketpair，Unix-only），本项目**刻意不接**：一是 Windows 上没有，二是会让 fork 面从 5 个函数涨到 9 个 |
//!
//! # 不暴露清单（防止后来者「顺手」扩面，plan-v3 §3.2）
//!
//! - ❌ `dial` / `listen` / `listen_udp`（Unix-only，Windows 目标无关）
//! - ❌ 路由 / ACL / 策略管理 / DNS 配置
//! - ❌ 事件回调流（上游只有 JSON 轮询；要「变化通知」就自己 poll + diff 封一层）
//! - ❌ 多客户端 / 多账号 / 多 overlay 实例
//! - ❌ 日志流直通（只在 [`MeshStatus::last_error`] 里带一个摘要）
//! - ❌ `start_reverse_proxy`（反向暴露本机服务，P0 用不到，且是攻击面）

#![warn(missing_docs)]
#![forbid(unsafe_code)]

use std::fmt;
use std::net::SocketAddr;
use std::path::PathBuf;

use serde::Serialize;

mod netbird;

pub use netbird::NetbirdMesh;

/// mesh 的启动参数。字段与上游 `ClientOptions` 一一对应，刻意不夹带策略类配置。
///
/// `Debug` 是手写的：`setup_key` 会被脱敏成 `<redacted>`，避免日志里泄漏注册密钥。
#[derive(Clone)]
pub struct MeshConfig {
    /// NetBird setup key（headless 注册用）。空字符串 = 不传（改走配置/状态文件里已有的身份）。
    pub setup_key: String,
    /// management server URL，例如 `https://api.netbird.io`。必填。
    pub management_url: String,
    /// 设备名（出现在 NetBird 面板与 `peers()` 的 fqdn 里）。必填，建议带 `-win-` 之类后缀便于区分。
    pub device_name: String,
    /// NetBird 状态文件路径（跨重启复用设备身份，避免每次注册成新设备）。
    pub state_path: Option<PathBuf>,
    /// 日志级别：`panic|fatal|error|warn|info|debug|trace`。
    pub log_level: Option<String>,
    /// WireGuard 监听端口。
    ///
    /// - `Some(0)`（**默认**）：随机端口，避免与机器上已有的 WireGuard/NetBird 抢 51820；
    /// - `Some(n)`：指定端口；
    /// - `None`：交回 NetBird 默认（51820，冲突时启动会失败）。
    pub wireguard_port: Option<i32>,
}

impl Default for MeshConfig {
    fn default() -> Self {
        Self {
            setup_key: String::new(),
            management_url: String::new(),
            device_name: String::new(),
            state_path: None,
            log_level: None,
            // 默认随机端口：本机可能同时有 NetBird 官方客户端，固定 51820 是真实的踩坑点。
            wireguard_port: Some(0),
        }
    }
}

impl fmt::Debug for MeshConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let key = if self.setup_key.is_empty() {
            "<empty>"
        } else {
            "<redacted>"
        };
        f.debug_struct("MeshConfig")
            .field("setup_key", &key)
            .field("management_url", &self.management_url)
            .field("device_name", &self.device_name)
            .field("state_path", &self.state_path)
            .field("log_level", &self.log_level)
            .field("wireguard_port", &self.wireguard_port)
            .finish()
    }
}

impl MeshConfig {
    /// 校验必填项。**必须在触碰 FFI 之前调用**：上游把参数原样交给 Go，
    /// 空 URL 会在 Go 侧异步失败，错误信息既晚又难读。
    pub(crate) fn validate(&self) -> anyhow::Result<()> {
        if self.management_url.trim().is_empty() {
            anyhow::bail!("MeshConfig.management_url 不能为空（例：https://api.netbird.io）");
        }
        if !(self.management_url.starts_with("http://")
            || self.management_url.starts_with("https://"))
        {
            anyhow::bail!(
                "MeshConfig.management_url 必须以 http:// 或 https:// 开头，拿到的是 {:?}",
                self.management_url
            );
        }
        if self.device_name.trim().is_empty() {
            anyhow::bail!("MeshConfig.device_name 不能为空（它会成为 peers() 里的 fqdn 前缀）");
        }
        Ok(())
    }
}

/// 一次 `status()` 轮询的快照。
///
/// 上游没有回调、没有事件流，所有字段都是**轮询取值**，可能滞后于真实网络状态
/// （一般 <1s）。别把它当状态机用。
#[derive(Debug, Clone, Default, Serialize)]
pub struct MeshStatus {
    /// 是否已经 `start()` 且尚未 `stop()`（本地视角，不代表隧道已通）。
    pub started: bool,
    /// 本机是否处于 overlay 已连接态（上游 `ConnectionState::Connected`）。
    pub connected: bool,
    /// 上游连接态的可读标签：`connected` / `connecting` / `disconnected` / `unknown`。
    pub state_label: String,
    /// 本机 overlay IP（如 `100.64.0.7`）。未连接时为空字符串。
    pub overlay_ip: String,
    /// 本机 fqdn（如 `my-pc-win.netbird.selfhosted`）。
    pub fqdn: String,
    /// management server 是否连上（注册/密钥下发通道）。
    pub management_connected: bool,
    /// signal server 是否连上（P2P 打洞信令通道）。
    pub signal_connected: bool,
    /// 已知 peer 数（含未连接）。
    pub peer_count: usize,
    /// 已连接且非 relay 的 peer 数 —— gate-A 要求目标机在这里恰好为 1。
    pub direct_peer_count: usize,
    /// 最近一次 [`Mesh::proxy`] 拿到的本地端口。
    ///
    /// **每次启动都会变**（Go 侧随机 listen），这里只记录"最近一次"，
    /// 不是可供其他模块依赖的常量。
    pub proxy_port: Option<u16>,
    /// 错误摘要（轮询失败或上游 `Status.error`）。完整日志不上行。
    pub last_error: Option<String>,
}

/// 一个 overlay peer 的轮询快照。
#[derive(Debug, Clone, Default, Serialize)]
pub struct Peer {
    /// overlay IP。
    pub ip: String,
    /// 本机对这个 peer 的连接态标签（同 [`MeshStatus::state_label`]）。
    pub state_label: String,
    /// peer 的 fqdn。
    pub fqdn: String,
    /// 是否已连接。
    pub connected: bool,
    /// 是否走 relay（`true` = 中继，`false` = 直连/P2P）。
    pub relayed: bool,
    /// 直连判定：**已连接且未经 relay**。gate-A 验收用的就是这一位。
    pub direct: bool,
    /// RTT 的可读字符串（上游原样透传，如 `"12ms"`；未知时为空）。
    pub latency: String,
}

/// overlay 的 5 方法白名单。实现可以是进程内（[`NetbirdMesh`]）或独立进程 + IPC，
/// 因为 trait 边界就是进程边界（plan-v3 §3.3 第 3 条）。
pub trait Mesh: Send + Sync {
    /// 加入 overlay。
    ///
    /// # 平台与生命周期约束
    ///
    /// - **一进程只允许一个 Go runtime**：本进程已有另一个 mesh 实例持有时，
    ///   返回 `Err`（不要重试，应该先 `stop()` 对方，或把 mesh 拆到独立进程）。
    /// - **进程被 `poisoned` 时**（上一个实例未 `stop()` 就被 drop）：返回**专用** `Err`，
    ///   唯一出路是重启进程（或改走独立进程方案）。这是终态，不要试图用 `stop()` 自救。
    /// - 重复对**同一实例**调用 `start()` 返回 `Err`（不是幂等操作：上游会再建
    ///   一个 Go client，抢同一个 WireGuard 端口）。
    /// - `start()` 成功只代表"Go 侧已受理"，不代表隧道已通；连通性请轮询
    ///   [`Mesh::status`] 的 `connected`。
    fn start(&self, cfg: MeshConfig) -> anyhow::Result<()>;

    /// 显式离开 overlay，并释放进程级 Go runtime 占用。
    ///
    /// **必须显式调用**：上游 `Client::drop` 会调 Go `Stop()` 并可能阻塞，
    /// 依赖 drop 等于把阻塞点放到不确定的位置（并且会让进程进入 `poisoned`，见 [`Mesh::start`]）。
    /// 未 `start()` 或已 `stop()` 时调用是幂等的（返回 `Ok`），这是刻意的——清理路径不该因为
    /// 重复调用而报错。
    ///
    /// `stop()` 是**唯一**能把进程级 Go runtime 状态从 `claimed` 收回 `free` 的路径。
    fn stop(&self) -> anyhow::Result<()>;

    /// 轮询当前状态。永不返回 `Err`：错误折叠进 [`MeshStatus::last_error`]。
    ///
    /// 未 `start()` 时返回上一次快照（`started == false`）。
    fn status(&self) -> MeshStatus;

    /// 轮询 peer 列表。失败时返回上一次成功缓存（可能是空），并把原因写进
    /// 下一次 [`Mesh::status`] 的 `last_error`。
    fn peers(&self) -> Vec<Peer>;

    /// 在 `127.0.0.1:<随机端口>` 起一个本地 TCP+UDP 代理，转发到 overlay 上的
    /// `target`（如 `100.64.0.2:7777`），返回**本次**分配到的本地端口。
    ///
    /// # 平台与约束
    ///
    /// - Windows 上这是**唯一**数据面（userspace netstack，overlay IP 不可被 OS
    ///   socket 路由）；非 Windows 同样走这条路（上游 `dial/listen` 是 Unix-only，
    ///   本项目不暴露）。
    /// - 返回的端口**每次调用都可能不同**，调用方必须使用返回值，禁止写死端口。
    /// - 未 `start()` 时返回 `Err`。
    /// - 同一 target 重复调用会再起一个代理并拿到新端口；旧代理由 Go 侧持有到
    ///   进程结束或 `stop()`，本层不提供关闭单个代理的方法（保持 5 方法面）。
    fn proxy(&self, target: SocketAddr) -> anyhow::Result<u16>;
}
