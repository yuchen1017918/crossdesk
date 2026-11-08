//! `--with-mesh`：在**同一个进程**里起 NetBird、proxy 到 motifd，再把本地端口交给探针。
//!
//! 这就是 gate-A 的真实路径：
//!
//! ```text
//! Client::new → start() → 等 connected → start_proxy("overlay_ip:7777")
//!   → 127.0.0.1:<随机端口> → GET /ping → POST /rpc/session.list
//! ```
//!
//! # 约束
//!
//! - 一进程只允许一个 Go runtime：本模块只持有一个 [`NetbirdMesh`]，且 `Drop` 里
//!   必定 `stop()`（幂等），不会把 Go 侧留给 `Client::drop` 去阻塞。
//! - 端口是**本次** `start_proxy()` 的返回值，写进报告；不要跨次复用。
//! - 等连通是忙等（250ms 轮询）：这是 CLI，不是 UI 线程；不引 async 运行时。

use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow, bail};
use crossdesk_mesh::{Mesh, MeshConfig, NetbirdMesh};

use crate::{Args, MeshReport, PeerReport};

/// 一个活着的进程内 mesh。报告在启动阶段就填好，后续只做只读。
pub struct LiveMesh {
    mesh: NetbirdMesh,
    report: MeshReport,
    proxy_port: Option<u16>,
}

impl LiveMesh {
    /// 起 mesh、等连通、开 proxy。任何一步失败都会先 `stop()` 再返回错误
    /// （不把半启动状态留给 `Drop` 去阻塞）。
    pub fn start(args: &Args) -> Result<Self> {
        let target_spec = args
            .motif_target
            .clone()
            .or_else(|| std::env::var("MOTIF_TARGET").ok())
            .ok_or_else(|| {
                anyhow!(
                    "--with-mesh 需要 --motif-target <overlay_ip:port>\
                     （例：100.64.0.2:7777；也可设 MOTIF_TARGET）"
                )
            })?;
        // `self:PORT` / `auto:PORT` —— 让探针在 mesh 连通后自己填本次的 overlay IP。
        //
        // 为什么必须要有这个：netbird-embed 的状态文件在某些形态下**不落盘**（实测
        // Windows 上 /tmp、LOCALAPPDATA 都没有生成），于是每跑一次就是一台**新设备**，
        // overlay IP 每次都变。硬编码 --motif-target 永远追不上上一轮的 IP。
        let self_port: Option<u16> = if let Some(rest) = target_spec
            .strip_prefix("self:")
            .or_else(|| target_spec.strip_prefix("auto:"))
        {
            Some(rest.parse::<u16>().with_context(|| {
                format!("self: 后面要跟端口，例如 self:7777，拿到 {rest:?}")
            })?)
        } else {
            None
        };
        let early_target: Option<SocketAddr> = match self_port {
            Some(_) => None,
            None => Some(target_spec.parse().with_context(|| {
                format!(
                    "--motif-target 要 IP:port 形式的 overlay 地址（不是 127.0.0.1），或 self:<port>（表示本次 mesh 连通后自动取本机 overlay IP），拿到 {target_spec:?}"
                )
            })?),
        };

        let config = MeshConfig {
            setup_key: std::env::var("NB_SETUP_KEY").unwrap_or_default(),
            management_url: env_or("NB_MANAGEMENT_URL", "https://api.netbird.io"),
            device_name: std::env::var("MESH_DEVICE_NAME")
                .unwrap_or_else(|_| default_device_name()),
            state_path: std::env::var("NB_STATE_PATH").ok().map(PathBuf::from),
            log_level: std::env::var("NB_LOG_LEVEL").ok(),
            // 随机 WireGuard 端口：本机很可能同时跑着 NetBird 官方客户端，51820 必然打架。
            wireguard_port: Some(0),
        };

        let mesh = NetbirdMesh::new();
        mesh.start(config).map_err(|err| {
            anyhow!("mesh.start() 失败（查 setup key / management URL / 出网能力）：{err:#}")
        })?;

        let mut status = mesh.status();
        let deadline = Instant::now() + Duration::from_millis(args.mesh_wait_ms.max(1));
        while !status.connected && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(250));
            status = mesh.status();
        }
        if !status.connected {
            let reason = format!(
                "{}ms 内没连上 overlay；state={} last_error={:?}",
                args.mesh_wait_ms, status.state_label, status.last_error
            );
            let _ = mesh.stop();
            bail!("mesh 未连通：{reason}");
        }

        // 到这里 mesh 已连上，`status.overlay_ip` 是本轮真值（形如 100.79.190.102/16）
        let target: SocketAddr = match early_target {
            Some(t) => t,
            None => {
                let port = self_port.expect("self_port 与 early_target 二选一");
                let ip = status.overlay_ip.split('/').next().unwrap_or("").trim().to_string();
                if ip.is_empty() {
                    let _ = mesh.stop();
                    bail!("mesh 已连通但 overlay_ip 为空，无法解析 self:{port}");
                }
                format!("{ip}:{port}")
                    .parse()
                    .with_context(|| format!("拼不出 self 目标地址：{ip}:{port}"))?
            }
        };

        let port = match mesh.proxy(target) {
            Ok(port) => port,
            Err(err) => {
                let _ = mesh.stop();
                return Err(err.context(format!(
                    "mesh.proxy({target}) 失败：目标 peer 在不在同一个 overlay 里？"
                )));
            }
        };

        let peers = mesh.peers();
        let report = MeshReport {
            enabled: true,
            reason: format!("进程内 mesh 已连通；proxy 127.0.0.1:{port} → {target}"),
            proxy_port: Some(port),
            overlay_ip: Some(status.overlay_ip.clone()),
            fqdn: Some(status.fqdn.clone()),
            direct_peer_count: peers.iter().filter(|peer| peer.direct).count(),
            peers: peers.iter().map(peer_report).collect(),
        };

        Ok(Self {
            mesh,
            report,
            proxy_port: Some(port),
        })
    }

    pub fn report(&self) -> &MeshReport {
        &self.report
    }

    pub fn proxy_port(&self) -> Option<u16> {
        self.proxy_port
    }

    /// 显式停止（幂等）。Go 侧彻底释放后再让进程退出，避免 `Client::drop` 卡在退出路径。
    pub fn stop(&mut self) {
        if let Err(err) = self.mesh.stop() {
            eprintln!("mesh.stop() 失败：{err:#}");
        }
    }
}

impl Drop for LiveMesh {
    fn drop(&mut self) {
        // 兜底：`stop()` 幂等，重复调用只是走一次空清理。
        let _ = self.mesh.stop();
    }
}

fn peer_report(peer: &crossdesk_mesh::Peer) -> PeerReport {
    PeerReport {
        ip: peer.ip.clone(),
        fqdn: peer.fqdn.clone(),
        connected: peer.connected,
        relayed: peer.relayed,
        direct: peer.direct,
        latency: peer.latency.clone(),
        state: peer.state_label.clone(),
    }
}

fn env_or(name: &str, fallback: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| fallback.to_string())
}

fn default_device_name() -> String {
    let host = std::env::var("COMPUTERNAME")
        .or_else(|_| std::env::var("HOSTNAME"))
        .unwrap_or_else(|_| "crossdesk".to_string());
    format!("{host}-crossdesk")
}
