//! 两层探针：把「隧道通不通」和「motifd 认不认我」分开验。
//!
//! | 层 | 请求 | 鉴权 | 能证明什么 |
//! |---|---|---|---|
//! | 1 | `GET /ping` | **不需要** | 隧道通、对端确实是 motifd、版本号；失败即传输层问题 |
//! | 2 | `POST /rpc/session.list` | `Authorization: Bearer` | 鉴权通道通（bearer 被认），且 `/rpc/*` 路由可达 |
//!
//! 第 2 层没有 token 时**跳过**（`skipped_no_token`），绝不用假 token 硬打：
//! 假 token 必然 401，会把"鉴权没配好"污染成"隧道挂了"，正好毁掉分层诊断的意义。
//!
//! 事实来源：`motif/docs/rpc.md` §1.2（鉴权）、§1.7（接入流程先 `GET /ping`）、
//! §5.1（`session.list` 不需要 `X-Motif-Session`）。

use std::net::{SocketAddr, ToSocketAddrs};
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use serde::Serialize;
use serde_json::Value;

use crate::http;

/// 第 1 层：`GET /ping`
pub const LAYER_PING: &str = "ping";
/// 第 2 层：`POST /rpc/session.list`
pub const LAYER_SESSION_LIST: &str = "rpc.session.list";

/// 层状态：通过
pub const STATUS_OK: &str = "ok";
/// 层状态：失败（detail 里是原因）
pub const STATUS_FAILED: &str = "failed";
/// 层状态：没有 token，主动跳过
pub const STATUS_SKIPPED_NO_TOKEN: &str = "skipped_no_token";

/// 解析后的探测目标。
#[derive(Debug, Clone)]
pub struct Target {
    /// 规范化后的 base，如 `http://127.0.0.1:53124`（写进报告用）。
    pub base: String,
    /// `Host:` 头与报告里用的 authority。
    pub host: String,
    /// 实际连接的地址。
    pub addr: SocketAddr,
    /// 若 base 来自 mesh proxy，这里记本次分配到的端口（每次启动都会变）。
    pub proxy_port: Option<u16>,
    /// 是否用 TLS 连接。motifd 的网络监听默认自签 TLS（`pk=` 是证书 pin），
    /// 经 proxy 到 overlay 时目标也是 https，所以这不再是"永远 false"。
    pub tls: bool,
}

/// 把用户给的目标规范化。
///
/// 接受 `127.0.0.1:53124`、`http://…`、`https://…`（自签证书放行）。
///
/// 两种形态都有意义：
/// - `http://` → mesh proxy 出来的**明文**本地端口；
/// - `https://` → motifd 自己监听的**自签 TLS** 端口（`--listen` 默认就带 TLS，
///   `motif://pair` 里的 `pk` 就是它的证书 pin）。
///
/// 不写 scheme 时按 `http` 处理（保持旧行为）。
pub fn resolve_base(spec: &str, proxy_port: Option<u16>) -> Result<Target> {
    let spec = spec.trim();
    if spec.is_empty() {
        bail!("目标为空");
    }
    let (scheme, rest) = if let Some(r) = spec.strip_prefix("https://") {
        ("https", r)
    } else if let Some(r) = spec.strip_prefix("http://") {
        ("http", r)
    } else {
        // 裸 authority 默认明文：这是 mesh proxy 端口最常见的用法
        ("http", spec)
    };
    // 丢掉 path 前缀（motifd 的 `/ping` 在根上，base 里带 path 没有意义）
    let authority = rest.split('/').next().unwrap_or(rest).trim();
    if authority.is_empty() {
        bail!("目标缺少 host:port：{spec:?}");
    }

    let addr = authority
        .to_socket_addrs()
        .with_context(|| {
            format!("解析 {authority:?} 失败（要 host:port 形式，例如 127.0.0.1:53124）")
        })?
        .next()
        .ok_or_else(|| anyhow!("{authority:?} 解析不出可用地址"))?;

    Ok(Target {
        base: format!("{scheme}://{authority}"),
        host: authority.to_string(),
        addr,
        proxy_port,
        tls: scheme == "https",
    })
}

/// 一层的探测结果，直接进 JSON 报告。
#[derive(Debug, Clone, Serialize)]
pub struct Layer {
    /// 层名（[`LAYER_PING`] / [`LAYER_SESSION_LIST`]）。
    pub layer: String,
    /// 状态（[`STATUS_OK`] / [`STATUS_FAILED`] / [`STATUS_SKIPPED_NO_TOKEN`]）。
    pub status: String,
    /// HTTP 状态码（没连上时为 `null`）。
    pub http_status: Option<u16>,
    /// 该层耗时毫秒（连不上时是失败耗时）。
    pub elapsed_ms: u64,
    /// 失败/跳过原因（成功时为 `null`）。
    pub detail: Option<String>,
    /// 从响应里抠出来的 motifd 版本（`/ping` 层）。
    pub version: Option<String>,
    /// `/ping.capabilities`（原样，便于对拍 P0-B 的截图能力）。
    pub capabilities: Option<Vec<String>>,
    /// `/rpc/session.list` 返回的 session 数量。
    pub sessions: Option<usize>,
    /// 原始响应体（JSON 可解析时）。形状不确定时它才是唯一可信证据。
    pub body: Option<Value>,
}

impl Layer {
    fn new(layer: &str) -> Self {
        Self {
            layer: layer.to_string(),
            status: STATUS_FAILED.to_string(),
            http_status: None,
            elapsed_ms: 0,
            detail: None,
            version: None,
            capabilities: None,
            sessions: None,
            body: None,
        }
    }

    fn transport_failure(layer: &str, err: &anyhow::Error, elapsed_ms: u64) -> Self {
        Self {
            elapsed_ms,
            detail: Some(format!("{err:#}")),
            ..Self::new(layer)
        }
        .with_status(STATUS_FAILED)
    }

    fn with_status(mut self, status: &str) -> Self {
        self.status = status.to_string();
        self
    }
}

/// 第 1 层：`GET /ping`（不需要鉴权）。
pub fn run_ping(target: &Target, timeout: Duration) -> Layer {
    let started = std::time::Instant::now();
    match http::request(
        target.addr,
        "GET",
        "/ping",
        &target.host,
        None,
        None,
        timeout,
        target.tls,
    ) {
        Ok(response) => {
            let body = response.json().ok();
            let version = body.as_ref().and_then(extract_version);
            let capabilities = body.as_ref().and_then(extract_capabilities);
            let mut layer = Layer {
                layer: LAYER_PING.to_string(),
                status: STATUS_OK.to_string(),
                http_status: Some(response.status),
                elapsed_ms: millis(response.elapsed),
                detail: None,
                version,
                capabilities,
                sessions: None,
                body,
            };
            if response.status != 200 {
                layer.status = STATUS_FAILED.to_string();
                layer.detail = Some(format!(
                    "HTTP {} {}：能连上但目标不是正常 motifd。若 404，确认对端跑的是 motifd 而不是别的服务",
                    response.status, response.reason
                ));
            }
            layer
        }
        Err(err) => Layer::transport_failure(LAYER_PING, &err, millis(started.elapsed())),
    }
}

/// 第 2 层：`POST /rpc/session.list`（Bearer；不需要 `X-Motif-Session`）。
pub fn run_session_list(target: &Target, bearer: Option<&str>, timeout: Duration) -> Layer {
    let Some(token) = bearer.map(str::trim).filter(|token| !token.is_empty()) else {
        return Layer {
            detail: Some(
                "没有 bearer token（--token / MOTIF_BEARER / MOTIF_TOKEN），跳过鉴权层。\
                 不要用假 token 硬打：401 会被误读成隧道故障"
                    .to_string(),
            ),
            ..Layer::new(LAYER_SESSION_LIST).with_status(STATUS_SKIPPED_NO_TOKEN)
        };
    };

    let started = std::time::Instant::now();
    // `session.list` 的 params 是 `{}`；HTTP 路径会把 body 直接当 params。
    let payload = b"{}".to_vec();
    match http::request(
        target.addr,
        "POST",
        "/rpc/session.list",
        &target.host,
        Some(token),
        Some(("application/json", payload)),
        timeout,
        target.tls,
    ) {
        Ok(response) => {
            let body = response.json().ok();
            let mut layer = Layer {
                layer: LAYER_SESSION_LIST.to_string(),
                status: STATUS_OK.to_string(),
                http_status: Some(response.status),
                elapsed_ms: millis(response.elapsed),
                detail: None,
                version: None,
                capabilities: None,
                sessions: body.as_ref().and_then(extract_session_count),
                body,
            };
            match response.status {
                200 => {}
                401 => {
                    layer.status = STATUS_FAILED.to_string();
                    layer.detail = Some(
                        "HTTP 401：bearer 不被接受。bearer 由配对 psk 派生（rzv::derive_bearer），\
                         不是 psk 原文；motifd 用 loopback/tailscale-only 且无 psk 时才是 Disabled"
                            .to_string(),
                    );
                }
                409 => {
                    layer.status = STATUS_FAILED.to_string();
                    layer.detail = Some(
                        "HTTP 409 NotAttached：这条路由要求 X-Motif-Session。session.list 按文档不该要求它，\
                         拿到 409 说明 motifd 行为已变，需重新对拍 docs/rpc.md §5.1"
                            .to_string(),
                    );
                }
                other => {
                    layer.status = STATUS_FAILED.to_string();
                    layer.detail = Some(format!(
                        "HTTP {other} {}：body 里应有 JSON-RPC error 对象（code 才是业务码）",
                        response.reason
                    ));
                }
            }
            layer
        }
        Err(err) => Layer::transport_failure(LAYER_SESSION_LIST, &err, millis(started.elapsed())),
    }
}

/// 从任意形状的 `/ping` 响应里抠版本号。
///
/// 字段名随 motifd 版本可能变，所以按优先级试多个 key，并且容忍包一层（`{"server":{...}}`）。
/// 抠不到就留 `null` —— 报告里同时保留了原始 `body`，人工可读。
pub fn extract_version(body: &Value) -> Option<String> {
    const KEYS: [&str; 5] = [
        "version",
        "motifd_version",
        "server_version",
        "protol_version",
        "build_version",
    ];
    KEYS.iter().find_map(|key| scalar_at_depth(body, key, 2))
}

/// `{"capabilities": ["screen_capture_v1"]}` 之类。
pub fn extract_capabilities(body: &Value) -> Option<Vec<String>> {
    fn dig(value: &Value, key: &str, depth: usize) -> Option<Vec<String>> {
        if depth == 0 {
            return None;
        }
        let map = value.as_object()?;
        if let Some(Value::Array(items)) = map.get(key) {
            return Some(
                items
                    .iter()
                    .filter_map(|item| item.as_str().map(str::to_string))
                    .collect(),
            );
        }
        map.values()
            .filter(|nested| nested.is_object())
            .find_map(|nested| dig(nested, key, depth - 1))
    }
    dig(body, "capabilities", 2)
}

/// `session.list` 的返回：文档说是**裸 result** `{"sessions":[...]}`，
/// 兼容被 JSON-RPC 包一层 `{"result":{"sessions":[...]}}` 的形态。
pub fn extract_session_count(body: &Value) -> Option<usize> {
    if let Some(Value::Array(items)) = body.get("sessions") {
        return Some(items.len());
    }
    body.get("result")
        .and_then(|result| result.get("sessions"))
        .and_then(Value::as_array)
        .map(|items| items.len())
}

fn scalar_at_depth(value: &Value, key: &str, depth: usize) -> Option<String> {
    if depth == 0 {
        return None;
    }
    let map = value.as_object()?;
    match map.get(key) {
        Some(Value::String(text)) => return Some(text.clone()),
        // 有些服务把 version 写成数字（如 proto 版本 3）
        Some(Value::Number(number)) => return Some(number.to_string()),
        _ => {}
    }
    map.values()
        .filter(|nested| nested.is_object())
        .find_map(|nested| scalar_at_depth(nested, key, depth - 1))
}

fn millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn resolves_bare_and_prefixed_targets() {
        let bare = resolve_base("127.0.0.1:53124", Some(53124)).expect("裸 host:port 应当可用");
        assert_eq!(bare.base, "http://127.0.0.1:53124");
        assert_eq!(bare.host, "127.0.0.1:53124");
        assert_eq!(bare.addr.port(), 53124);
        assert_eq!(bare.proxy_port, Some(53124));

        // 末尾斜杠 / 带 path 前缀都要吃掉，否则拼接出的 URL 会变成 //ping
        let prefixed = resolve_base("http://127.0.0.1:53124/", None).expect("带斜杠应当可用");
        assert_eq!(prefixed.base, "http://127.0.0.1:53124");

        let with_path =
            resolve_base("127.0.0.1:53124/some/prefix", None).expect("带 path 应当可用");
        assert_eq!(with_path.base, "http://127.0.0.1:53124");
    }

    #[test]
    fn rejects_https_and_missing_port() {
        assert!(
            resolve_base("https://127.0.0.1:53124", None).map(|t| t.tls).unwrap_or(false),
            "https 应当被接受且 tls=true"
        );
        assert!(resolve_base("127.0.0.1", None).is_err(), "缺端口应当被拒");
        assert!(resolve_base("   ", None).is_err(), "空目标应当被拒");
    }

    #[test]
    fn extracts_version_from_flat_and_nested_bodies() {
        assert_eq!(
            extract_version(&json!({"version": "0.4.2"})).as_deref(),
            Some("0.4.2")
        );
        // 包一层：{"server": {"version": ...}}
        assert_eq!(
            extract_version(&json!({"server": {"version": "0.4.2"}})).as_deref(),
            Some("0.4.2")
        );
        // 数字版本号
        assert_eq!(
            extract_version(&json!({"protol_version": 3})).as_deref(),
            Some("3")
        );
        assert_eq!(extract_version(&json!({"ok": true})), None);
    }

    #[test]
    fn extracts_capabilities_and_session_counts() {
        let ping =
            json!({"version": "0.4.2", "capabilities": ["screen_capture_v1", "pty_frame_v1"]});
        assert_eq!(
            extract_capabilities(&ping).unwrap(),
            vec!["screen_capture_v1".to_string(), "pty_frame_v1".to_string()]
        );
        assert_eq!(extract_capabilities(&json!({"ok": true})), None);

        // 文档形态：裸 result
        assert_eq!(
            extract_session_count(&json!({"sessions": [{}, {}, {}]})),
            Some(3)
        );
        // 兼容 JSON-RPC 包一层
        assert_eq!(
            extract_session_count(&json!({"result": {"sessions": [{}]}})),
            Some(1)
        );
        assert_eq!(extract_session_count(&json!({"sessions": []})), Some(0));
        assert_eq!(
            extract_session_count(&json!({"error": {"code": -32009}})),
            None
        );
    }

    #[test]
    fn skips_auth_layer_without_token() {
        let target = resolve_base("127.0.0.1:1", None).expect("解析不该依赖端口是否开着");
        let layer = run_session_list(&target, None, Duration::from_millis(50));
        assert_eq!(layer.status, STATUS_SKIPPED_NO_TOKEN);
        assert!(layer.http_status.is_none(), "跳过的层不能伪造 HTTP 状态");
        assert!(layer.detail.unwrap().contains("跳过"));

        // 空字符串 / 纯空白 token 同样视为没有，不许硬打
        let blank = run_session_list(&target, Some("   "), Duration::from_millis(50));
        assert_eq!(blank.status, STATUS_SKIPPED_NO_TOKEN);
    }
}
