//! 一次性 smoke：用 setup key 真入网，打印 status / peers，然后 stop。
//!
//! 凭据纪律：
//! - setup key **只从环境变量 `NB_SETUP_KEY` 读**，不落盘、不打印、不进 git；
//! - 状态文件写到 `NB_STATE_PATH`（默认 `/tmp`），跑完可删；
//! - `MeshConfig` 的 `Debug` 已脱敏 setup_key，这里也不手写 println! 打它。
//!
//! 用法：
//! ```sh
//! NB_SETUP_KEY=xxxx cargo run -p crossdesk-mesh --example netbird_join
//! ```
//!
//! 退出码：0 已连接（打印 peers）；1 未能在超时内连上；2 用法/配置错误。

use std::time::{Duration, Instant};

use crossdesk_mesh::{Mesh, MeshConfig, NetbirdMesh};

fn main() -> anyhow::Result<()> {
    let key = match std::env::var("NB_SETUP_KEY") {
        Ok(k) if !k.trim().is_empty() => k,
        _ => {
            eprintln!("需要环境变量 NB_SETUP_KEY（不要写进命令行参数，避免进 shell 历史）");
            std::process::exit(2);
        }
    };
    let mgmt = std::env::var("NB_MGMT").unwrap_or_else(|_| "https://api.netbird.io".to_string());
    let name = std::env::var("NB_NAME").unwrap_or_else(|_| "crossdesk-p0-linux".to_string());
    let state = std::env::var("NB_STATE_PATH")
        .unwrap_or_else(|_| "/tmp/crossdesk-nb-state.json".to_string());
    let wait_s: u64 = std::env::var("NB_WAIT_S")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(90);

    let mesh = NetbirdMesh::new();
    let cfg = MeshConfig {
        setup_key: key,
        management_url: mgmt.clone(),
        device_name: name.clone(),
        state_path: Some(state.clone().into()),
        log_level: Some("info".to_string()),
        wireguard_port: Some(0), // 随机端口，避免与宿主已有的 WireGuard 抢 51820
    };

    println!("[join] mgmt={mgmt} name={name} state={state}");
    mesh.start(cfg)?;
    println!("[join] start() 已受理，开始轮询（最多 {wait_s}s）");

    let deadline = Instant::now() + Duration::from_secs(wait_s);
    let mut last_line = String::new();
    let mut connected_at: Option<Instant> = None;

    while Instant::now() < deadline {
        let s = mesh.status();
        let line = format!(
            "started={} connected={} mgmt={} signal={} ip={:?} fqdn={:?} peers={} direct={} err={:?}",
            s.started,
            s.connected,
            s.management_connected,
            s.signal_connected,
            s.overlay_ip,
            s.fqdn,
            s.peer_count,
            s.direct_peer_count,
            s.last_error
        );
        if line != last_line {
            println!("[status] {line}");
            last_line = line;
        }
        if s.connected {
            if connected_at.is_none() {
                connected_at = Some(Instant::now());
                println!("[join] 已连接，overlay_ip={}", s.overlay_ip);
            }
            // 连接后再等一小会儿让 peer 表稳定
            if connected_at.is_some_and(|t| t.elapsed() > Duration::from_secs(8)) {
                break;
            }
        }
        std::thread::sleep(Duration::from_secs(2));
    }

    let peers = mesh.peers();
    println!("[peers] 共 {} 个", peers.len());
    for p in &peers {
        println!(
            "  {} fqdn={:?} connected={} direct={} relayed={} rtt={:?}",
            p.ip, p.fqdn, p.connected, p.direct, p.relayed, p.latency
        );
    }

    let ok = mesh.status().connected;
    mesh.stop()?;
    println!("[join] stopped（Go 侧已显式关停，未依赖 Drop）");

    if ok {
        Ok(())
    } else {
        eprintln!("未在 {wait_s}s 内连上 overlay");
        std::process::exit(1);
    }
}
