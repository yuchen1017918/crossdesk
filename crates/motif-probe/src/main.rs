//! `motif-probe`：P0-A 对拍器。
//!
//! 两层探针（`GET /ping` 无鉴权 → `POST /rpc/session.list` Bearer），输出一份 JSON
//! 报告，包含：版本、耗时、proxy 端口、peers 的 direct 标志、每层的失败原因。
//!
//! 用法（Windows 实机细节见 `docs/p0/win-p0a-runbook.md`）：
//!
//! ```text
//! # 1) 只验隧道：用本次 mesh 启动拿到的随机端口
//! motif-probe --proxy-port 53124
//!
//! # 2) 连鉴权一起验
//! set MOTIF_BEARER=<psk 派生的 bearer>
//! motif-probe --proxy-port 53124 --json-stdout
//!
//! # 3) 一条命令打通全链路（需要 --features mesh）
//! motif-probe --with-mesh --motif-target 100.64.0.2:7777
//! ```
//!
//! 退出码：`0` 两层都通过（或第 2 层按预期跳过）；`1` 第 1 层失败（传输层）；
//! `2` 第 2 层失败（鉴权/协议层）；`3` 参数或环境错误。

mod http;
mod probe;

#[cfg(feature = "mesh")]
mod mesh_live;

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, anyhow, bail};
use serde::{Deserialize, Serialize};

const SCHEMA: &str = "crossdesk.motif-probe/1";
const DEFAULT_OUT: &str = "artifacts/motif-probe-report.json";

fn main() -> ExitCode {
    match run() {
        Ok(code) => code,
        Err(err) => {
            eprintln!("motif-probe 失败：{err:#}");
            ExitCode::from(3)
        }
    }
}

fn run() -> Result<ExitCode> {
    let Some(args) = parse_args()? else {
        return Ok(ExitCode::SUCCESS); // --help
    };
    let timeout = Duration::from_millis(args.timeout_ms.max(1));

    // ---- 目标解析（优先级：显式 base > 显式/环境端口 > mesh 现起 proxy 的端口）----
    let mut base_spec = args.base.clone();
    // 只有 `mesh` feature 打开时才会被改写；默认 feature 下保持 `mut` 会触发 unused_mut。
    // 为让两套 feature 共用同一份主流程，这里显式豁免，而不是拆两份代码。
    #[allow(unused_mut)]
    let mut mesh_port: Option<u16> = None;
    let mut mesh_report = MeshReport::skipped("未请求 --with-mesh");

    #[cfg(feature = "mesh")]
    let mut live_mesh: Option<mesh_live::LiveMesh> = None;

    #[cfg(feature = "mesh")]
    if args.with_mesh {
        let live = mesh_live::LiveMesh::start(&args)?;
        mesh_port = live.proxy_port();
        mesh_report = live.report().clone();
        if base_spec.is_none() {
            if let Some(port) = mesh_port {
                base_spec = Some(format!("https://127.0.0.1:{port}"));
            }
        }
        live_mesh = Some(live);
    }

    #[cfg(not(feature = "mesh"))]
    if args.with_mesh {
        bail!(
            "本二进制没编 mesh feature。用 `cargo build -p motif-probe --features mesh`\
             （需要 Go 1.25+ 与平台 gcc）；或先手工起 mesh，再 `--proxy-port <本次端口>`"
        );
    }

    if base_spec.is_none() {
        // 端口必须来自本次启动的 start_proxy() 返回值，不接受任何写死默认值。
        if let Some(port) = args.proxy_port.or(mesh_port) {
            base_spec = Some(format!("https://127.0.0.1:{port}"));
        }
    }
    let recorded_port = args.proxy_port.or(mesh_port);

    let Some(spec) = base_spec else {
        bail!(
            "没有探测目标：给 --base / --proxy-port / MOTIF_PROBE_BASE / MOTIF_PROXY_PORT，\
             或用 --with-mesh 现起一条 proxy（probe 不会猜默认端口）"
        );
    };
    let target = probe::resolve_base(&spec, recorded_port)?;

    if let Some(path) = &args.peers_file {
        mesh_report.merge_peers_from_file(path)?;
    }

    // ---- 两层探针 ----
    let ping = probe::run_ping(&target, timeout);
    let session_list = probe::run_session_list(&target, args.token.as_deref(), timeout);

    let report = Report {
        schema: SCHEMA,
        generated_at_unix_ms: now_unix_ms(),
        tool: ToolInfo {
            name: "motif-probe",
            version: env!("CARGO_PKG_VERSION"),
        },
        target: TargetInfo {
            base: target.base.clone(),
            host: target.host.clone(),
            addr: target.addr.to_string(),
            proxy_port: target.proxy_port,
            timeout_ms: args.timeout_ms,
        },
        layers: Layers {
            ping: ping.clone(),
            rpc_session_list: session_list.clone(),
        },
        mesh: mesh_report.clone(),
        expected: Expected {
            ping: "HTTP 200 + 含版本号的 JSON（无需鉴权）",
            rpc_session_list: "HTTP 200 + {\"sessions\":[…] }（需要 bearer；无 token 时 skipped_no_token）",
        },
    };

    // 报告先落盘，再释放 mesh：这样即使 stop 阻塞，证据也已经在磁盘上。
    let rendered = serde_json::to_string_pretty(&report)?;
    write_report(&args.out, &rendered)?;

    // 只在编了 mesh feature 的构建里存在 `live_mesh`。
    #[cfg(feature = "mesh")]
    if let Some(live) = live_mesh.as_mut() {
        live.stop();
    }

    let summary = summary_text(&args, &target, &ping, &session_list, &mesh_report);
    if args.json_stdout {
        // 机器读：JSON 独占 stdout，摘要让到 stderr，方便管道直接喂 jq。
        println!("{rendered}");
        if !args.quiet {
            eprint!("{summary}");
        }
    } else if !args.quiet {
        print!("{summary}");
    }

    Ok(ExitCode::from(exit_code(&ping, &session_list)))
}

/// 退出码：1 = 传输层（第 1 层）失败，2 = 鉴权层（第 2 层）失败。
///
/// 用 `u8` 而不是 `ExitCode` 返回，是为了让单测能直接断言数值
/// （`ExitCode` 的 `PartialEq` 在不同平台上不保证可用）。
fn exit_code(ping: &probe::Layer, session_list: &probe::Layer) -> u8 {
    if ping.status == probe::STATUS_FAILED {
        return 1;
    }
    if session_list.status == probe::STATUS_FAILED {
        return 2;
    }
    0
}

// ---------------------------------------------------------------------------
// 报告结构（用结构体而不是 json! 宏：字段名/类型在编译期就能查）
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize)]
struct Report {
    schema: &'static str,
    generated_at_unix_ms: u64,
    tool: ToolInfo,
    target: TargetInfo,
    layers: Layers,
    mesh: MeshReport,
    expected: Expected,
}

#[derive(Debug, Serialize)]
struct ToolInfo {
    name: &'static str,
    version: &'static str,
}

#[derive(Debug, Serialize)]
struct TargetInfo {
    base: String,
    host: String,
    addr: String,
    proxy_port: Option<u16>,
    timeout_ms: u64,
}

#[derive(Debug, Serialize)]
struct Layers {
    ping: probe::Layer,
    rpc_session_list: probe::Layer,
}

#[derive(Debug, Serialize)]
struct Expected {
    ping: &'static str,
    rpc_session_list: &'static str,
}

/// mesh 侧证据（gate-A 的 `direct=true` 就看这里）。
#[derive(Debug, Clone, Serialize, Default)]
pub struct MeshReport {
    /// 是否真的起了进程内 mesh。
    pub enabled: bool,
    /// 起/不起的原因（失败时是错误摘要）。
    pub reason: String,
    /// 本次 `proxy()` 分配到的本地端口（每次启动都会变）。
    pub proxy_port: Option<u16>,
    /// 本机 overlay IP。
    pub overlay_ip: Option<String>,
    /// 本机 fqdn。
    pub fqdn: Option<String>,
    /// 已连接且非 relay 的 peer 数。
    pub direct_peer_count: usize,
    pub peers: Vec<PeerReport>,
}

impl MeshReport {
    fn skipped(reason: &str) -> Self {
        Self {
            enabled: false,
            reason: reason.to_string(),
            ..Default::default()
        }
    }

    /// 从 `--peers-file` 合并 peers：允许在没有 Go 工具链的机器上，把别处采到的
    /// peers 快照塞进同一份报告里对拍。
    fn merge_peers_from_file(&mut self, path: &std::path::Path) -> Result<()> {
        let text = std::fs::read_to_string(path)
            .with_context(|| format!("读 peers 文件失败：{}", path.display()))?;
        let peers: Vec<PeerReport> = serde_json::from_str(&text)
            .with_context(|| format!("peers 文件不是 JSON 数组：{}", path.display()))?;
        self.direct_peer_count = peers.iter().filter(|peer| peer.direct).count();
        self.peers = peers;
        if self.reason.is_empty() {
            self.reason = format!("peers 来自 {}", path.display());
        }
        Ok(())
    }
}

/// 报告里的 peer 视图。`direct` = 已连接且非 relay（gate-A 判定位）。
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct PeerReport {
    #[serde(default)]
    pub ip: String,
    #[serde(default)]
    pub fqdn: String,
    #[serde(default)]
    pub connected: bool,
    #[serde(default)]
    pub relayed: bool,
    #[serde(default)]
    pub direct: bool,
    #[serde(default)]
    pub latency: String,
    #[serde(default)]
    pub state: String,
}

// ---------------------------------------------------------------------------
// 参数
// ---------------------------------------------------------------------------

#[derive(Debug)]
struct Args {
    base: Option<String>,
    proxy_port: Option<u16>,
    token: Option<String>,
    timeout_ms: u64,
    out: PathBuf,
    json_stdout: bool,
    quiet: bool,
    with_mesh: bool,
    /// 仅在 `--features mesh` 下被读取。
    #[cfg_attr(not(feature = "mesh"), allow(dead_code))]
    mesh_wait_ms: u64,
    /// 仅在 `--features mesh` 下被读取。
    #[cfg_attr(not(feature = "mesh"), allow(dead_code))]
    motif_target: Option<String>,
    peers_file: Option<PathBuf>,
}

fn parse_args() -> Result<Option<Args>> {
    let mut args = Args {
        base: env_first(&["MOTIF_PROBE_BASE", "MOTIF_BASE"]),
        proxy_port: env_first(&["MOTIF_PROXY_PORT", "CROSSDESK_PROXY_PORT"])
            .and_then(|value| value.trim().parse::<u16>().ok()),
        token: env_first(&["MOTIF_BEARER", "MOTIF_TOKEN"]),
        timeout_ms: env_first(&["MOTIF_PROBE_TIMEOUT_MS"])
            .and_then(|value| value.trim().parse::<u64>().ok())
            .unwrap_or(2_000),
        out: PathBuf::from(
            std::env::var("MOTIF_PROBE_OUT").unwrap_or_else(|_| DEFAULT_OUT.to_string()),
        ),
        json_stdout: false,
        quiet: false,
        with_mesh: false,
        mesh_wait_ms: 20_000,
        motif_target: env_first(&["MOTIF_TARGET"]),
        peers_file: None,
    };

    let mut iter = std::env::args().skip(1);
    while let Some(flag) = iter.next() {
        match flag.as_str() {
            "-h" | "--help" => {
                print_usage();
                return Ok(None);
            }
            "--base" => args.base = Some(next_value(&mut iter, "--base")?),
            "--proxy-port" => {
                let raw = next_value(&mut iter, "--proxy-port")?;
                args.proxy_port =
                    Some(raw.trim().parse::<u16>().with_context(|| {
                        format!("--proxy-port 要 0-65535 的整数，拿到 {raw:?}")
                    })?);
            }
            "--token" => args.token = Some(next_value(&mut iter, "--token")?),
            "--timeout-ms" => {
                let raw = next_value(&mut iter, "--timeout-ms")?;
                args.timeout_ms = raw
                    .trim()
                    .parse::<u64>()
                    .with_context(|| format!("--timeout-ms 要整数，拿到 {raw:?}"))?;
            }
            "--out" => args.out = PathBuf::from(next_value(&mut iter, "--out")?),
            "--json-stdout" => args.json_stdout = true,
            "--quiet" => args.quiet = true,
            "--with-mesh" => args.with_mesh = true,
            "--mesh-wait-ms" => {
                let raw = next_value(&mut iter, "--mesh-wait-ms")?;
                args.mesh_wait_ms = raw
                    .trim()
                    .parse::<u64>()
                    .with_context(|| format!("--mesh-wait-ms 要整数，拿到 {raw:?}"))?;
            }
            "--motif-target" => args.motif_target = Some(next_value(&mut iter, "--motif-target")?),
            "--peers-file" => {
                args.peers_file = Some(PathBuf::from(next_value(&mut iter, "--peers-file")?))
            }
            other => bail!("未知参数 {other:?}（--help 看用法）"),
        }
    }

    Ok(Some(args))
}

fn next_value(iter: &mut impl Iterator<Item = String>, flag: &str) -> Result<String> {
    iter.next().ok_or_else(|| anyhow!("{flag} 后面要跟一个值"))
}

fn env_first(names: &[&str]) -> Option<String> {
    names.iter().find_map(|name| std::env::var(name).ok())
}

fn print_usage() {
    println!(
        "\
motif-probe —— P0-A 对拍器（motifd 两层探针）

用法：
  motif-probe --proxy-port <port> [--token <bearer>] [选项]
  motif-probe --base http://127.0.0.1:<port> [选项]
  motif-probe --with-mesh --motif-target <overlay_ip:port>   # 需 --features mesh

目标（三选一）：
  --base <url>                显式 base，如 http://127.0.0.1:53124
  --proxy-port <port>         本次 mesh start_proxy() 返回的端口（环境变量 MOTIF_PROXY_PORT / CROSSDESK_PROXY_PORT）
  --with-mesh                 probe 自己起 mesh，再 proxy 到 --motif-target

鉴权（可选，缺了就跳过第 2 层）：
  --token <bearer>            psk 派生的 bearer（环境变量 MOTIF_BEARER / MOTIF_TOKEN）
                              注意：不是 psk 原文

选项：
  --timeout-ms <n>            单请求超时，默认 2000
  --out <path>                报告路径，默认 {DEFAULT_OUT}
  --peers-file <json>         把别处采到的 peers 数组并进报告
  --json-stdout               把完整 JSON 打到 stdout
  --quiet                     只落盘，不打印摘要
  --mesh-wait-ms <n>          mesh 等连通的上限，默认 20000
  -h, --help                  本帮助

退出码：0 通过 / 1 第 1 层失败（传输） / 2 第 2 层失败（鉴权） / 3 参数或环境错误
"
    );
}

// ---------------------------------------------------------------------------
// 输出
// ---------------------------------------------------------------------------

fn write_report(path: &std::path::Path, rendered: &str) -> Result<()> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("建报告目录失败：{}", parent.display()))?;
        }
    }
    std::fs::write(path, rendered).with_context(|| format!("写报告失败：{}", path.display()))?;
    Ok(())
}

fn summary_text(
    args: &Args,
    target: &probe::Target,
    ping: &probe::Layer,
    session_list: &probe::Layer,
    mesh: &MeshReport,
) -> String {
    use std::fmt::Write as _;

    let mut out = String::new();
    let _ = writeln!(out, "motif-probe → {}", target.base);
    let _ = writeln!(out, "  [1/2] GET  /ping             {}", render_layer(ping));
    let _ = writeln!(
        out,
        "  [2/2] POST /rpc/session.list {}",
        render_layer(session_list)
    );

    if mesh.enabled {
        let _ = writeln!(
            out,
            "  mesh: proxy 端口 {:?} / overlay {} / peers {}（direct {}）",
            mesh.proxy_port,
            mesh.overlay_ip.as_deref().unwrap_or("-"),
            mesh.peers.len(),
            mesh.direct_peer_count
        );
        for peer in &mesh.peers {
            let _ = writeln!(
                out,
                "        {} {} direct={} relayed={} latency={}",
                peer.ip,
                peer.fqdn,
                peer.direct,
                peer.relayed,
                if peer.latency.is_empty() {
                    "-"
                } else {
                    peer.latency.as_str()
                }
            );
        }
    } else {
        let _ = writeln!(out, "  mesh: 未启用（{}）", mesh.reason);
    }

    let _ = writeln!(out, "  报告：{}", args.out.display());

    if let Some(detail) = &ping.detail {
        let _ = writeln!(out, "  第 1 层：{detail}");
    }
    if let Some(detail) = &session_list.detail {
        let _ = writeln!(out, "  第 2 层：{detail}");
    }
    out
}

fn render_layer(layer: &probe::Layer) -> String {
    let status = format!("{:<17}", layer.status);
    let http = layer
        .http_status
        .map(|code| format!("HTTP {code}"))
        .unwrap_or_else(|| "HTTP -".to_string());
    let mut extras = Vec::new();
    if let Some(version) = &layer.version {
        extras.push(format!("version={version}"));
    }
    if let Some(count) = layer.sessions {
        extras.push(format!("sessions={count}"));
    }
    let extras = if extras.is_empty() {
        String::new()
    } else {
        format!("  {}", extras.join(" "))
    };
    format!("{status} {http:<9} {:>5}ms{extras}", layer.elapsed_ms)
}

fn now_unix_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn layer(layer: &str, status: &str) -> probe::Layer {
        probe::Layer {
            layer: layer.to_string(),
            status: status.to_string(),
            http_status: None,
            elapsed_ms: 0,
            detail: None,
            version: None,
            capabilities: None,
            sessions: None,
            body: None,
        }
    }

    #[test]
    fn exit_codes_separate_transport_from_auth() {
        let ok = layer(probe::LAYER_PING, probe::STATUS_OK);
        let skipped = layer(probe::LAYER_SESSION_LIST, probe::STATUS_SKIPPED_NO_TOKEN);
        assert_eq!(exit_code(&ok, &skipped), 0, "跳过鉴权层算通过");

        let ping_dead = layer(probe::LAYER_PING, probe::STATUS_FAILED);
        let auth_dead = layer(probe::LAYER_SESSION_LIST, probe::STATUS_FAILED);
        // 第 1 层挂 → 传输问题优先报（1），不能被第 2 层的 2 盖掉
        assert_eq!(exit_code(&ping_dead, &auth_dead), 1);
        assert_eq!(exit_code(&ok, &auth_dead), 2);
    }

    #[test]
    fn peers_file_round_trips_and_counts_direct() {
        let dir = std::env::temp_dir().join("motif-probe-test-peers");
        std::fs::create_dir_all(&dir).expect("建临时目录");
        let path = dir.join("peers.json");
        std::fs::write(
            &path,
            r#"[
                {"ip":"100.64.0.2","fqdn":"target.netbird.selfhosted","connected":true,"relayed":false,"direct":true,"latency":"12ms"},
                {"ip":"100.64.0.3","fqdn":"relay.netbird.selfhosted","connected":true,"relayed":true,"direct":false}
            ]"#,
        )
        .expect("写 peers 文件");

        let mut report = MeshReport::skipped("test");
        report.merge_peers_from_file(&path).expect("合并 peers");
        assert_eq!(report.peers.len(), 2);
        assert_eq!(
            report.direct_peer_count, 1,
            "direct 只数已连接且非 relay 的那条"
        );
        assert_eq!(report.peers[1].latency, "", "缺字段要能默认成空串");

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn summary_line_renders_without_panicking_on_missing_fields() {
        let rendered = render_layer(&layer(probe::LAYER_PING, probe::STATUS_FAILED));
        assert!(rendered.contains("failed"));
        assert!(rendered.contains("HTTP -"));
    }
}
