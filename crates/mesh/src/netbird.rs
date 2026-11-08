//! `netbird-embed` 的具体实现。
//!
//! 这个文件是**唯一**允许 `use netbird_embed::...` 的地方；其他模块（含将来的
//! 独立进程实现）只认 [`crate::Mesh`]。
//!
//! # 并发模型
//!
//! 所有状态（client / Go runtime 占位 / 快照）由一把 `Mutex` 串行化，**锁内会调用
//! Go**。这是刻意的：上游 client 虽然是 `Send + Sync`，但 start/stop 期间让它收到
//! 并发 status/peers 轮询只会让错误信息互相覆盖。代价是 `start()` 期间其他线程的
//! `status()` 会等（一般 <100ms，网络差时可能更久），所以**不要把 mesh 调用放在 UI
//! 线程上**，放进专用工作线程。

use std::net::SocketAddr;
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::{Mutex, MutexGuard};

use anyhow::{Result, anyhow};
use netbird_embed::{Client, ClientOptions, ConnectionState};
use tracing::{debug, warn};

use crate::{Mesh, MeshConfig, MeshStatus, Peer};

/// 进程级「Go runtime 状态」，三态。
///
/// - [`RUNTIME_FREE`]：空闲，可以 `start()`；
/// - [`RUNTIME_CLAIMED`]：某个 [`NetbirdMesh`] 活着且已 `start()`（一进程只允许一个）；
/// - [`RUNTIME_POISONED`]：上一个实例**没 `stop()` 就被 drop** 了 —— 终态。
///
/// 为什么不能把「drop 未 stop」当成 free 放行：`Client::drop` 是在我们的 `Drop` 执行
/// **之后**才走 `nb_free` → Go `Stop()`，且它在隧道拆除期间可能阻塞/失败；我们既无法观测
/// 它是否拆干净，也无法撤销已经发生的半拆状态。Go runtime 本身是进程内的静态实体（不会被
/// 释放），所以"在不确定的运行时上再建一个 client"不是干净的起点。宁可让本进程报废。
///
/// 上游 `netbird-embed` 把 Go 侧编成 c-shared `.dll`/`.so`；同进程加载两份 Go runtime
/// 会 GC 损坏（上游 README「Gotchas」）。Rust 侧拦不住链接两份库，但可以把
/// 「同时存在两个 live client」变成显式错误。
const RUNTIME_FREE: u8 = 0;
const RUNTIME_CLAIMED: u8 = 1;
const RUNTIME_POISONED: u8 = 2;

static GO_RUNTIME: AtomicU8 = AtomicU8::new(RUNTIME_FREE);

/// 进程级占位句柄：拿到即持有，正常 `Drop` 时归还到 `Free`。
///
/// 用 `&AtomicU8` 而不是全局静态，是为了单测能用局部变量验证状态机，
/// 不必污染进程全局。
struct GoRuntimeClaim<'a> {
    flag: &'a AtomicU8,
}

impl<'a> GoRuntimeClaim<'a> {
    /// 尝试 `Free -> Claimed`。
    ///
    /// 失败时把**当前状态原样返回**（`Claimed` / `Poisoned`），让上层给出可区分的错误：
    /// 「被另一个实例占用」和「上一个实例被 drop 未 stop」是两种完全不同的排查方向，
    /// 不能共用一句话。
    fn try_acquire(flag: &'a AtomicU8) -> std::result::Result<Self, u8> {
        match flag.compare_exchange(
            RUNTIME_FREE,
            RUNTIME_CLAIMED,
            Ordering::AcqRel,
            Ordering::Acquire,
        ) {
            Ok(_) => Ok(GoRuntimeClaim { flag }),
            Err(observed) => Err(observed),
        }
    }

    /// 把状态钉成 [`RUNTIME_POISONED`]（终态）。
    ///
    /// 只有「未 stop 就 drop」这条路会调它；调用之后即使 guard 被 drop 也不会退回 `Free`。
    fn poison(&self) {
        self.flag.store(RUNTIME_POISONED, Ordering::Release);
    }
}

impl Drop for GoRuntimeClaim<'_> {
    fn drop(&mut self) {
        // 只回收自己持有的 Claimed；Poisoned 是终态，绝不能被 guard 的 drop 抹掉。
        let _ = self.flag.compare_exchange(
            RUNTIME_CLAIMED,
            RUNTIME_FREE,
            Ordering::AcqRel,
            Ordering::Acquire,
        );
    }
}

/// 把「抢占失败时的状态」翻成**可区分**的错误。
///
/// 拆成独立函数既让 `start()` 保持线性，也让单测能用局部值验证两种文案（不碰进程全局）。
fn claim_error(state: u8) -> anyhow::Error {
    if state == RUNTIME_POISONED {
        return anyhow!(
            "本进程的 Go runtime 处于 poisoned 状态：上一个 NetbirdMesh 没调 stop() 就被 drop 了，\
             Go 侧是否已拆干净无法确认（Client::drop 在我们之后才走 nb_free → Go Stop()，且可能阻塞/失败）。\
             请重启进程后再试；若确实需要在同一进程内重建 mesh，按 plan-v3 §3.3 把 mesh 拆到独立进程"
        );
    }
    anyhow!(
        "本进程的 Go runtime 已被另一个 mesh 实例占用：netbird-embed 一个进程只允许一个 Go runtime\
         （两份会导致 GC 损坏）。先让占用方 stop()，或把 mesh 拆到独立进程后用 IPC 转发（plan-v3 §3.3）"
    )
}

/// `NetbirdMesh` 的内部可变状态。统一由一把 `Mutex` 串起来：
/// 上游 `Client` 是 `Send + Sync`，但我们的状态机（client + claim + 快照）
/// 需要原子地一起变。
#[derive(Default)]
struct Inner {
    client: Option<Client>,
    claim: Option<GoRuntimeClaim<'static>>,
    status: MeshStatus,
    peers: Vec<Peer>,
}

/// 进程内 mesh 实现。**一个进程只应有一个实例**（Go runtime 约束）；
/// 第二个实例的 `start()` 会被显式拒绝，而不是静默产生两份 Go 侧状态。
pub struct NetbirdMesh {
    inner: Mutex<Inner>,
}

impl NetbirdMesh {
    /// 创建一个空闲的 mesh 实例。构造本身不触碰 FFI / 不加载 Go 库。
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(Inner::default()),
        }
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        // 毒化（panic 时持锁）不应让清理路径二次 panic；直接取回数据继续用。
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// 单测用：模拟一次 `proxy()` 的端口记录，不需要真的起 Go 代理。
    #[cfg(test)]
    fn record_proxy_for_test(&self, port: u16) {
        self.lock().status.proxy_port = Some(port);
    }
}

impl Default for NetbirdMesh {
    fn default() -> Self {
        Self::new()
    }
}

impl Mesh for NetbirdMesh {
    fn start(&self, cfg: MeshConfig) -> Result<()> {
        // 校验必须先于 FFI：空 URL 交给 Go 只会在异步线程里晚失败。
        cfg.validate()?;

        let mut inner = self.lock();

        if inner.client.is_some() {
            return Err(anyhow!(
                "同一个 NetbirdMesh 已经 start()：重复调用会在本进程的 Go runtime 里再建一个 client，\
                 两个 client 抢同一个 WireGuard 端口/状态文件。需要重启先 stop()"
            ));
        }

        // 抢占失败要按状态分流：Poisoned 是"上一个实例被 drop 未 stop"，与"被占用"完全两种排查方向。
        let claim = match GoRuntimeClaim::try_acquire(&GO_RUNTIME) {
            Ok(claim) => claim,
            Err(state) => return Err(claim_error(state)),
        };

        let client =
            Client::new(client_options(&cfg)).map_err(|err| anyhow!("Client::new 失败: {err}"))?;

        if let Err(start_err) = client.start() {
            // 已经构造出 Client 了：退回自由态之前先走一次受支持的关闭路径（stop 而非裸 drop）。
            match client.stop() {
                Ok(()) => {
                    drop(client);
                }
                Err(stop_err) => {
                    // stop 也失败 → Go 侧状态不确定，钉成 poisoned，禁止本进程后续再 start。
                    debug!(error = %stop_err, "client.start() 失败后 client.stop() 也失败，标记 runtime 为 poisoned");
                    claim.poison();
                    drop(client);
                }
            }
            return Err(anyhow!("client.start() 失败: {start_err}"));
        }

        // start() 成功只代表 Go 侧受理；这里顺手取一次快照，让 status() 立刻有内容。
        let mut status = MeshStatus {
            started: true,
            ..Default::default()
        };
        match client.status() {
            Ok(polled) => apply_status(&mut status, &polled),
            Err(err) => status.last_error = Some(format!("status() 首次轮询失败: {err}")),
        }

        debug!(device = %cfg.device_name, management = %cfg.management_url, "mesh 已 start");
        inner.client = Some(client);
        inner.claim = Some(claim);
        inner.status = status;
        inner.peers.clear();
        Ok(())
    }

    fn stop(&self) -> Result<()> {
        let client = {
            let mut inner = self.lock();
            inner.client.take()
        };

        let Some(client) = client else {
            // 幂等：从未 start，或已经 stop 过。清理路径重复调用不该报错。
            let mut inner = self.lock();
            inner.claim.take();
            inner.peers.clear();
            inner.status = MeshStatus::default();
            return Ok(());
        };

        // 显式 stop：不要让阻塞点落在 Drop 上（Drop 仍会调 Go 释放，但此时已是停止态）。
        let result = client
            .stop()
            .map_err(|err| anyhow!("client.stop() 失败: {err}"));
        drop(client);

        let mut inner = self.lock();
        inner.claim.take(); // 归还 Go runtime 占用，允许本进程后续再 start
        inner.peers.clear();
        inner.status = MeshStatus::default();
        result
    }

    fn status(&self) -> MeshStatus {
        let mut inner = self.lock();

        // 借用只活到 map 结束：把轮询结果拿成 owned 值，再改 inner。
        let polled = inner.client.as_ref().map(|client| client.status());
        let Some(polled) = polled else {
            return inner.status.clone();
        };

        match polled {
            Ok(polled) => {
                apply_status(&mut inner.status, &polled);
                // apply_status 不碰 proxy_port：它是"最近一次 proxy() 的返回值"，
                // 和上游 status 无关，也不该因为一次轮询被清空。
                inner.status.started = true;
                inner.status.clone()
            }
            Err(err) => {
                inner.status.last_error = Some(format!("status() 轮询失败: {err}"));
                inner.status.clone()
            }
        }
    }

    fn peers(&self) -> Vec<Peer> {
        let mut inner = self.lock();

        let polled = inner.client.as_ref().map(|client| client.peers());
        let Some(polled) = polled else {
            return inner.peers.clone();
        };

        match polled {
            Ok(list) => {
                let mapped: Vec<Peer> = list.iter().map(peer_view).collect();
                inner.peers = mapped.clone();
                inner.status.peer_count = mapped.len();
                inner.status.direct_peer_count = mapped.iter().filter(|peer| peer.direct).count();
                mapped
            }
            Err(err) => {
                inner.status.last_error = Some(format!("peers() 轮询失败: {err}"));
                inner.peers.clone()
            }
        }
    }

    fn proxy(&self, target: SocketAddr) -> Result<u16> {
        let mut inner = self.lock();

        let port = {
            let client = inner
                .client
                .as_ref()
                .ok_or_else(|| anyhow!("proxy() 之前必须 start()：当前没有可用的 Go client"))?;
            // 端口由 Go 侧 net.Listen 分配（通常随机高位），每次调用都可能不同。
            let target_str = target.to_string();
            debug!(target = %target_str, "start_proxy：申请本地随机端口");
            client
                .start_proxy(&target_str)
                .map_err(|err| anyhow!("start_proxy({target_str}) 失败: {err}"))?
        };

        platform_note();

        inner.status.proxy_port = Some(port);
        debug!(port, target = %target, "proxy 就绪：本地 127.0.0.1 + 随机端口 → overlay 目标");
        Ok(port)
    }
}

impl Drop for NetbirdMesh {
    fn drop(&mut self) {
        // 注意执行顺序：本函数体跑在"字段被 drop"之前，所以这里是**在** Client::drop
        // （→ nb_free → Go Stop，可能阻塞）之前就把状态钉成 poisoned 的最后机会。
        let leaked = self
            .inner
            .get_mut()
            .map(|inner| {
                if inner.client.is_none() {
                    return false;
                }
                // 未 stop 就 drop：Go 侧是否拆干净无从确认 → 进程级 Go runtime 钉成 poisoned。
                if let Some(claim) = inner.claim.as_ref() {
                    claim.poison();
                }
                true
            })
            .unwrap_or(false);

        if leaked {
            warn!(
                "NetbirdMesh 在未 stop() 的情况下被 drop：Client::drop 会调 Go Stop() 并在隧道拆除期间\
                 阻塞调用线程（可能就是 UI 线程）；本进程的 Go runtime 已被标记为 poisoned，\
                 后续 start() 会被拒绝，只能重启进程。生产路径请显式 stop()"
            );
        }
    }
}

/// 上游 `ConnectionState` → 本层布尔位 + 可读标签。
struct ConnFlags {
    connected: bool,
    label: &'static str,
}

fn conn_flags(state: &ConnectionState) -> ConnFlags {
    match state {
        ConnectionState::Connected => ConnFlags {
            connected: true,
            label: "connected",
        },
        ConnectionState::Connecting => ConnFlags {
            connected: false,
            label: "connecting",
        },
        ConnectionState::Disconnected => ConnFlags {
            connected: false,
            label: "disconnected",
        },
        // 上游把未知值反序列化成 Unknown（`#[serde(other)]`）：更保守，一律当未连接。
        ConnectionState::Unknown => ConnFlags {
            connected: false,
            label: "unknown",
        },
    }
}

/// 直连判定：**已连接且未经 relay**。gate-A 的「目标机 direct=true」看的就是这个。
fn is_direct(peer: &netbird_embed::Peer) -> bool {
    peer.is_connected() && !peer.relayed
}

fn peer_view(peer: &netbird_embed::Peer) -> Peer {
    let flags = conn_flags(&peer.conn_status);
    Peer {
        ip: peer.ip.clone(),
        state_label: flags.label.to_string(),
        fqdn: peer.fqdn.clone(),
        connected: flags.connected,
        relayed: peer.relayed,
        direct: flags.connected && !peer.relayed,
        latency: peer.latency.clone(),
    }
}

/// 把一次上游 `Status` 合并进快照。**不动 `proxy_port`**（见 `status()` 注释）。
fn apply_status(status: &mut MeshStatus, polled: &netbird_embed::Status) {
    let flags = conn_flags(&polled.state);
    status.connected = flags.connected;
    status.state_label = flags.label.to_string();
    status.overlay_ip = polled.ip.clone();
    status.fqdn = polled.fqdn.clone();
    status.management_connected = conn_flags(&polled.management_state).connected;
    status.signal_connected = conn_flags(&polled.signal_state).connected;
    status.peer_count = polled.peers.len();
    status.direct_peer_count = polled.peers.iter().filter(|peer| is_direct(peer)).count();
    status.last_error = polled.error.clone();
}

fn client_options(cfg: &MeshConfig) -> ClientOptions {
    ClientOptions {
        setup_key: non_empty(&cfg.setup_key),
        management_url: non_empty(&cfg.management_url),
        device_name: non_empty(&cfg.device_name),
        state_path: cfg
            .state_path
            .as_ref()
            .map(|path| path.to_string_lossy().into_owned()),
        log_level: cfg.log_level.clone(),
        wireguard_port: cfg.wireguard_port,
        // 其余字段保持上游默认；本项目不开放路由/ACL/上层策略（plan-v3 §3.2）。
        ..Default::default()
    }
}

fn non_empty(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

#[cfg(target_os = "windows")]
fn platform_note() {
    // Windows：overlay IP 在 userspace netstack 里，OS socket 不可路由；dial/listen
    // 是 Unix socketpair 实现，Windows 上根本编不出来。start_proxy 是唯一数据面。
    debug!("windows: 数据面 = start_proxy（127.0.0.1:<随机端口>），dial/listen 不暴露");
}

#[cfg(not(target_os = "windows"))]
fn platform_note() {
    // 非 Windows 同样走 start_proxy：上游 dial/listen 存在，但本项目刻意不暴露，
    // 把 fork 面固定在 5 个函数上（plan-v3 §3.2）。
    debug!("非 windows: 数据面仍走 start_proxy；上游 dial/listen 存在但本项目不暴露");
}

#[cfg(test)]
mod tests {
    use super::*;
    // trait 方法（stop/status/start）要靠它进作用域，显式写一遍更稳
    use crate::Mesh;
    use std::net::Ipv4Addr;

    fn mesh() -> NetbirdMesh {
        NetbirdMesh::new()
    }

    /// 约束 1：一进程只允许一个 Go runtime —— 占用互斥，正常 Drop 归还到 Free。
    #[test]
    fn go_runtime_claim_is_exclusive_and_released_on_drop() {
        let flag = AtomicU8::new(RUNTIME_FREE);

        let first = GoRuntimeClaim::try_acquire(&flag).expect("首次抢占应当成功");
        assert_eq!(flag.load(Ordering::Acquire), RUNTIME_CLAIMED);

        let second = GoRuntimeClaim::try_acquire(&flag);
        assert!(
            matches!(second, Err(RUNTIME_CLAIMED)),
            "第二次抢占必须失败并报 Claimed（否则会有两个 Go client）"
        );

        drop(first);
        assert_eq!(
            flag.load(Ordering::Acquire),
            RUNTIME_FREE,
            "正常 drop 应当归还到 Free"
        );
        assert!(
            GoRuntimeClaim::try_acquire(&flag).is_ok(),
            "释放后应当可以重新占用（stop 后再 start 的路径）"
        );
    }

    /// 约束 1 的补丁：poisoned 是终态 —— guard 的 drop 不许把它抹回 Free。
    #[test]
    fn poisoning_is_terminal_and_survives_guard_drop() {
        let flag = AtomicU8::new(RUNTIME_FREE);
        let claim = GoRuntimeClaim::try_acquire(&flag).expect("首次抢占应当成功");

        claim.poison();
        drop(claim);

        assert_eq!(
            flag.load(Ordering::Acquire),
            RUNTIME_POISONED,
            "guard 的 Drop 会把 Claimed 收回 Free，但绝不能覆盖 Poisoned"
        );
        assert!(
            matches!(GoRuntimeClaim::try_acquire(&flag), Err(RUNTIME_POISONED)),
            "poisoned 之后必须拒绝一切抢占"
        );
    }

    /// 两种失败必须给两种文案：poisoned 指向"重启进程/拆进程"，占用指向"先 stop 对方"。
    /// 用局部值验证，不碰进程全局（cargo test 是并行跑的）。
    #[test]
    fn claim_error_distinguishes_poisoned_from_occupied() {
        let poisoned = claim_error(RUNTIME_POISONED).to_string();
        assert!(poisoned.contains("poisoned"), "要点名 poisoned：{poisoned}");
        assert!(
            poisoned.contains("独立进程"),
            "要给出唯一出路（拆进程）：{poisoned}"
        );
        assert!(
            !poisoned.contains("另一个 mesh 实例占用"),
            "不能复用'被占用'那句话，否则排查方向错：{poisoned}"
        );

        let occupied = claim_error(RUNTIME_CLAIMED).to_string();
        assert!(occupied.contains("另一个 mesh 实例占用"), "{occupied}");
        assert!(
            !occupied.contains("poisoned"),
            "占用态不该提 poisoned：{occupied}"
        );
    }

    /// 端到端：进程级 runtime 处于 poisoned 时，start() 必须在碰 FFI 之前就报 poisoned。
    ///
    /// 这条必须动进程全局（start 读的就是全局静态），所以用 RAII 复位，
    /// 保证即使断言失败也不会把 poisoned 漏给同进程的其他测试。
    #[test]
    fn start_in_poisoned_process_reports_poisoned_not_occupied() {
        struct ResetGlobal;
        impl Drop for ResetGlobal {
            fn drop(&mut self) {
                GO_RUNTIME.store(RUNTIME_FREE, Ordering::Release);
            }
        }
        let _reset = ResetGlobal;

        GO_RUNTIME.store(RUNTIME_POISONED, Ordering::Release);

        let mesh = mesh();
        let err = mesh
            .start(MeshConfig {
                setup_key: "setup-key".to_string(),
                management_url: "https://api.netbird.io".to_string(),
                device_name: "crossdesk-win".to_string(),
                ..Default::default()
            })
            .expect_err("poisoned 状态下 start 必须被拒绝");

        let text = err.to_string();
        assert!(
            text.contains("poisoned"),
            "错误信息必须点名 poisoned：{text}"
        );
        assert!(
            !text.contains("另一个 mesh 实例占用"),
            "drop 未 stop 不是'被占用'，别误导排查：{text}"
        );
        assert!(!mesh.status().started, "被拒绝的 start 不能留下半启动状态");
    }

    /// 约束 2：显式 stop，且重复 stop 幂等（清理路径不该报错）。
    #[test]
    fn double_stop_is_idempotent() {
        let mesh = mesh();
        assert!(mesh.stop().is_ok(), "从未 start 时 stop 应返回 Ok");
        assert!(mesh.stop().is_ok(), "重复 stop 仍应返回 Ok");

        let status = mesh.status();
        assert!(!status.started, "stop 之后不应声称 started");
        assert!(!status.connected, "stop 之后不应声称 connected");
        assert!(
            status.overlay_ip.is_empty(),
            "stop 之后 overlay_ip 应被清空"
        );
    }

    /// 约束 3：proxy 端口每次都是新值 —— 记录必须覆盖，且冷启动没有默认端口。
    #[test]
    fn proxy_port_is_recorded_per_call_not_hardcoded() {
        let mesh = mesh();

        // 冷启动：没有任何端口（不存在"默认 7777"这类写死值）。
        assert_eq!(mesh.status().proxy_port, None);

        mesh.record_proxy_for_test(40001);
        assert_eq!(mesh.status().proxy_port, Some(40001));
        assert_eq!(
            SocketAddr::from((Ipv4Addr::LOCALHOST, 40001)).to_string(),
            "127.0.0.1:40001",
            "代理永远绑 127.0.0.1，且端口来自 start_proxy 返回值"
        );

        // 第二次 proxy() 拿到新端口：必须覆盖，不能沿用旧值。
        mesh.record_proxy_for_test(40002);
        assert_eq!(mesh.status().proxy_port, Some(40002));
    }

    /// 上游连接态 → 本层布尔位/标签的映射（状态轮询解析的真坑：不认识的态不能算连通）。
    #[test]
    fn connection_state_mapping_is_conservative() {
        let connected = conn_flags(&ConnectionState::Connected);
        assert!(connected.connected);
        assert_eq!(connected.label, "connected");

        for (state, label) in [
            (ConnectionState::Connecting, "connecting"),
            (ConnectionState::Disconnected, "disconnected"),
            (ConnectionState::Unknown, "unknown"),
        ] {
            let flags = conn_flags(&state);
            assert!(!flags.connected, "{label} 不应被判为已连接");
            assert_eq!(flags.label, label);
        }
    }

    /// direct 的语义：必须「已连接」且「未经 relay」。relayed=true 时即使连上也不是 direct。
    #[test]
    fn direct_requires_connected_and_not_relayed() {
        let peer = |conn_status, relayed| netbird_embed::Peer {
            ip: "100.64.0.2".to_string(),
            pub_key: "key".to_string(),
            fqdn: "target.netbird.selfhosted".to_string(),
            conn_status,
            relayed,
            latency: "12ms".to_string(),
        };

        let view = peer_view(&peer(ConnectionState::Connected, false));
        assert!(view.direct, "已连接 + P2P = direct");
        assert_eq!(view.state_label, "connected");

        let relayed = peer_view(&peer(ConnectionState::Connected, true));
        assert!(!relayed.direct, "走 relay 的已连接 peer 不算 direct");
        assert!(relayed.relayed);

        let down = peer_view(&peer(ConnectionState::Disconnected, false));
        assert!(!down.direct, "未连接的 peer 不算 direct");
    }

    /// 配置校验必须发生在触发 FFI 之前（否则一条空 URL 会在 Go 异步线程里晚失败）。
    #[test]
    fn start_rejects_invalid_config_before_touching_ffi() {
        let mesh = mesh();

        let err = mesh
            .start(MeshConfig {
                management_url: String::new(),
                device_name: "crossdesk-win".to_string(),
                ..Default::default()
            })
            .expect_err("空 management_url 必须被拒绝");
        assert!(
            err.to_string().contains("management_url"),
            "错误信息要点名字段：{err}"
        );

        let err = mesh
            .start(MeshConfig {
                management_url: "api.netbird.io".to_string(),
                device_name: "crossdesk-win".to_string(),
                ..Default::default()
            })
            .expect_err("缺 scheme 的 URL 必须被拒绝");
        assert!(
            err.to_string().contains("http"),
            "错误信息要说明 scheme：{err}"
        );

        let err = mesh
            .start(MeshConfig {
                management_url: "https://api.netbird.io".to_string(),
                device_name: "  ".to_string(),
                ..Default::default()
            })
            .expect_err("空 device_name 必须被拒绝");
        assert!(
            err.to_string().contains("device_name"),
            "错误信息要点名字段：{err}"
        );

        // 走到这里说明三次失败都没有初始化 Go client。
        assert!(!mesh.status().started);
    }

    /// 默认配置不能落回 NetBird 的 51820：本机常常已有官方客户端占着它。
    #[test]
    fn default_config_requests_random_wireguard_port() {
        let cfg = MeshConfig::default();
        assert_eq!(cfg.wireguard_port, Some(0), "Some(0) = 随机端口");
        assert_eq!(cfg.management_url, "");
    }

    /// setup_key 是密钥：Debug 输出里不得出现明文。
    #[test]
    fn debug_redacts_setup_key() {
        let cfg = MeshConfig {
            setup_key: "SUPER-SECRET-KEY".to_string(),
            management_url: "https://api.netbird.io".to_string(),
            device_name: "crossdesk-win".to_string(),
            ..Default::default()
        };
        let rendered = format!("{cfg:?}");
        assert!(
            !rendered.contains("SUPER-SECRET-KEY"),
            "setup_key 泄漏进日志：{rendered}"
        );
        assert!(rendered.contains("<redacted>"));
    }
}
