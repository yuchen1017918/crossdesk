//! 极简 HTTP/1.1 客户端，只够打 motifd 用。
//!
//! # 为什么不引 `reqwest`
//!
//! 1. 目标只有两种形态：mesh proxy 出来的本地明文口，或 motifd 自己的
//!    **自签 TLS** 口（`pk=` 就是那个证书的 SHA-256 pin）。所以我们需要
//!    TLS，但不需要重定向 / 连接池 / HTTP2 / 证书链校验（自签证书链没法验，
//!    真正的身份保证靠 `pk` pin —— 见 [`tls`]）；
//! 2. P0-A 的产物体积与依赖树要尽量小（plan-v3 §5）；
//! 3. 没有网络依赖，`cargo test` 在任何机器上都跑得动。
//!
//! # 边界（写清楚，免得后来者当成通用客户端）
//!
//! - 只发 `HTTP/1.1`，只带 `Connection: close`，**读到自己关闭连接为止**；
//! - 支持 `Content-Length` 与 `Transfer-Encoding: chunked` 两种帧；
//! - 不跟随重定向、不处理 gzip、不复用连接、不解析 cookie。

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::sync::Arc;
use std::time::{Duration, Instant};

use rustls::client::danger::{
    HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier,
};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, ClientConnection, DigitallySignedStruct, SignatureScheme, StreamOwned};

use anyhow::{Context, Result, anyhow, bail};

/// 一次 HTTP 响应（body 已按帧解好）。
#[derive(Debug, Clone)]
pub struct Response {
    /// 状态码，例如 200 / 401 / 409。
    pub status: u16,
    /// reason phrase（可能为空）。
    pub reason: String,
    /// 头字段，名字已转小写。
    pub headers: Vec<(String, String)>,
    /// 解帧后的 body 字节。
    pub body: Vec<u8>,
    /// 从建连到读完 body 的耗时。
    pub elapsed: Duration,
}

impl Response {
    /// 按名字取响应头（大小写不敏感）。
    ///
    /// P0-A 的两层探针用不到响应头；留给下一步 `session.attach` 读
    /// `X-Motif-Session`（P0-B / UI 首次接入时用）。
    #[allow(dead_code)]
    pub fn header(&self, name: &str) -> Option<&str> {
        let want = name.to_ascii_lowercase();
        self.headers
            .iter()
            .find(|(key, _)| *key == want)
            .map(|(_, value)| value.as_str())
    }

    /// 把 body 当 JSON 解析。空 body 视为 `null`（不算错误）。
    pub fn json(&self) -> Result<serde_json::Value> {
        if self.body.is_empty() {
            return Ok(serde_json::Value::Null);
        }
        serde_json::from_slice(&self.body)
            .with_context(|| format!("响应体不是 JSON：{}", self.preview()))
    }

    /// body 的可读预览（限 240 字符，非法 UTF-8 用替换符），只用于错误信息与报告。
    pub fn preview(&self) -> String {
        let text = String::from_utf8_lossy(&self.body);
        text.chars().take(240).collect()
    }
}

/// 发一个请求并读回完整响应。
///
/// `body` 为 `Some((content_type, bytes))` 时按 POST 语义带 `Content-Length`。
/// 所有超时都按 `timeout` 设：`/ping` 打不通时应当**快速**失败（P0-A 的诊断价值
/// 就在于马上告诉你是隧道问题还是服务问题）。
pub fn request(
    addr: SocketAddr,
    method: &str,
    path: &str,
    host: &str,
    bearer: Option<&str>,
    body: Option<(&str, Vec<u8>)>,
    timeout: Duration,
    tls: bool,
) -> Result<Response> {
    let started = Instant::now();

    let mut stream = TcpStream::connect_timeout(&addr, timeout).with_context(|| {
        format!(
            "连不上 {addr}：motifd 没起？还是用了**上一次** launch 的 proxy 端口（端口每次启动都会变，必须用本次返回值）"
        )
    })?;
    stream.set_read_timeout(Some(timeout))?;
    stream.set_write_timeout(Some(timeout))?;
    stream.set_nodelay(true)?;
    let mut stream: Box<dyn ReadWrite> = if tls {
        Box::new(tls::wrap(stream, host, timeout)?)
    } else {
        Box::new(stream)
    };

    let mut head = format!(
        "{method} {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\nAccept: application/json\r\n"
    );
    if let Some(token) = bearer {
        head.push_str(&format!("Authorization: Bearer {token}\r\n"));
    }
    let mut payload: &[u8] = &[];
    if let Some((content_type, bytes)) = &body {
        head.push_str(&format!(
            "Content-Type: {content_type}\r\nContent-Length: {}\r\n",
            bytes.len()
        ));
        payload = bytes.as_slice();
    }
    head.push_str("\r\n");

    stream
        .write_all(head.as_bytes())
        .with_context(|| format!("写请求头失败（{addr}）"))?;
    if !payload.is_empty() {
        stream
            .write_all(payload)
            .with_context(|| format!("写请求体失败（{addr}）"))?;
    }
    stream.flush()?;

    let mut raw = Vec::new();
    let mut chunk = [0u8; 8192];
    loop {
        match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                raw.extend_from_slice(&chunk[..n]);
                // 按帧判完整性，**不要等 EOF**：我们发了 `Connection: close`，
                // 但代理/服务端可以无视它返回 keep-alive（实测 motifd 就返回
                // `Connection: keep-alive` + Content-Length）。等 EOF 会一直阻塞到
                // 读超时——20 个字节的响应白等 2 秒，还容易被误读成"链路慢"。
                // 这就是 P0-B findings 里 F4 的同一类错误，探针自己也要守。
                if response_is_complete(&raw) {
                    break;
                }
            }
            Err(err) if err.kind() == std::io::ErrorKind::Interrupted => continue,
            // 帧不完整才可能走到超时（真慢或对端半开）。交给 parse 报精确缺字节。
            Err(err)
                if matches!(
                    err.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                break;
            }
            Err(err) => return Err(err).with_context(|| format!("读响应失败（{addr}）")),
        }
    }

    parse_response(&raw, started)
}

/// 判断已读字节是否构成**完整响应**（头 + 按 Content-Length / chunked 收齐的 body）。
///
/// 返回 `false` 的两种含义要分清：
/// - 头还没收全 → 继续读；
/// - 头收全但没有长度信息（HTTP/1.0 式 EOF 定界）→ 只能继续读到 EOF 或超时。
fn response_is_complete(raw: &[u8]) -> bool {
    let Some(head_end) = find_subslice(raw, b"\r\n\r\n") else {
        return false;
    };
    let head = String::from_utf8_lossy(&raw[..head_end]);
    let body = &raw[head_end + 4..];

    let mut content_length: Option<usize> = None;
    let mut chunked = false;
    for line in head.lines().skip(1) {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        let value = value.trim();
        if name.eq_ignore_ascii_case("content-length") {
            content_length = value.parse::<usize>().ok();
        } else if name.eq_ignore_ascii_case("transfer-encoding")
            && value.to_ascii_lowercase().contains("chunked")
        {
            chunked = true;
        }
    }

    if chunked {
        // 终止块形如 `0\r\n\r\n`（允许 trailer 后置空行）
        return find_subslice(body, b"\r\n0\r\n").is_some() || body.ends_with(b"0\r\n\r\n");
    }
    match content_length {
        Some(len) => body.len() >= len,
        // 无长度：只能靠 EOF，返回 false 让循环继续读
        None => false,
    }
}

/// 解析完整响应字节（头 + 可能被分块的 body）。
fn parse_response(raw: &[u8], started: Instant) -> Result<Response> {
    if raw.is_empty() {
        bail!("服务器直接关了连接，一个字节都没返回（proxy 端口后面可能根本不是 motifd）");
    }

    let head_end = find_subslice(raw, b"\r\n\r\n").ok_or_else(|| {
        anyhow!(
            "响应头不完整（缺 CRLFCRLF）：{}",
            String::from_utf8_lossy(&raw[..raw.len().min(240)])
        )
    })?;
    let head = std::str::from_utf8(&raw[..head_end]).context("响应头不是 UTF-8")?;
    let body_bytes = &raw[head_end + 4..];

    let mut lines = head.split("\r\n");
    let status_line = lines.next().unwrap_or_default();
    let mut pieces = status_line.splitn(3, ' ');
    let version = pieces.next().unwrap_or_default();
    if !version.starts_with("HTTP/") {
        bail!(
            "不是 HTTP 响应，首行是 {status_line:?}（是不是把 WS 端口或别的服务当成了 motifd？）"
        );
    }
    let status: u16 = pieces
        .next()
        .unwrap_or_default()
        .parse()
        .with_context(|| format!("状态行解析不出状态码：{status_line:?}"))?;
    let reason = pieces.next().unwrap_or_default().trim().to_string();

    let mut headers = Vec::new();
    for line in lines {
        if line.is_empty() {
            continue;
        }
        let (name, value) = line
            .split_once(':')
            .ok_or_else(|| anyhow!("非法响应头：{line:?}"))?;
        headers.push((name.trim().to_ascii_lowercase(), value.trim().to_string()));
    }

    let chunked = header_of(&headers, "transfer-encoding")
        .map(|value| value.to_ascii_lowercase().contains("chunked"))
        .unwrap_or(false);

    let body = if chunked {
        decode_chunked(body_bytes)?
    } else if let Some(declared) = header_of(&headers, "content-length") {
        let declared: usize = declared
            .parse()
            .with_context(|| format!("Content-Length 非法：{declared:?}"))?;
        if body_bytes.len() < declared {
            bail!(
                "响应体不完整：声明 {declared} 字节，只读到 {} 字节",
                body_bytes.len()
            );
        }
        body_bytes[..declared].to_vec()
    } else {
        body_bytes.to_vec()
    };

    Ok(Response {
        status,
        reason,
        headers,
        body,
        elapsed: started.elapsed(),
    })
}

fn header_of<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(key, _)| key == name)
        .map(|(_, value)| value.as_str())
}

/// 解 `Transfer-Encoding: chunked`。忽略 chunk 扩展与 trailer（motifd 不用）。
fn decode_chunked(input: &[u8]) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    let mut rest = input;
    loop {
        let line_end =
            find_subslice(rest, b"\r\n").ok_or_else(|| anyhow!("chunked 帧缺 chunk 长度行"))?;
        let size_line = std::str::from_utf8(&rest[..line_end]).context("chunk 长度行不是 UTF-8")?;
        // 形如 "1a" 或 "1a;ext=val"
        let size_text = size_line.split(';').next().unwrap_or_default().trim();
        let size = usize::from_str_radix(size_text, 16)
            .with_context(|| format!("chunk 长度不是十六进制：{size_text:?}"))?;
        rest = &rest[line_end + 2..];
        if size == 0 {
            break;
        }
        if rest.len() < size {
            bail!(
                "chunked 帧数据不足：要 {size} 字节，只剩 {} 字节",
                rest.len()
            );
        }
        out.extend_from_slice(&rest[..size]);
        rest = &rest[size..];
        if let Some(after) = rest.strip_prefix(b"\r\n".as_slice()) {
            rest = after;
        } else {
            bail!("chunk 数据后缺 CRLF");
        }
    }
    Ok(out)
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}


/// 读+写的最小 trait 组合，用来统一「明文 socket」与「TLS socket」。
trait ReadWrite: Read + Write {}
impl<T: Read + Write> ReadWrite for T {}

/// 自签 TLS 的最小包装。
///
/// 身份保证**不在这里**，而在 `motif://pair` 里的 `pk`（证书 DER 的 SHA-256 pin）。
/// 本模块只负责"把字节发过去、把响应解出来"；pin 校验留给上层策略。
/// 原因：P0-A 要回答的是"隧道通不通、协议对不对"，不是防御中间人。
mod tls {
    use super::*;

    /// 接受任何服务端证书（等价 `curl -k`）。**仅诊断用**。
    #[derive(Debug)]
    struct AcceptAnyCert;

    impl ServerCertVerifier for AcceptAnyCert {
        fn verify_server_cert(
            &self,
            _end_entity: &CertificateDer<'_>,
            _intermediates: &[CertificateDer<'_>],
            _server_name: &ServerName<'_>,
            _ocsp_response: &[u8],
            _now: UnixTime,
        ) -> Result<ServerCertVerified, rustls::Error> {
            Ok(ServerCertVerified::assertion())
        }

        fn verify_tls12_signature(
            &self,
            _message: &[u8],
            _cert: &CertificateDer<'_>,
            _dss: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, rustls::Error> {
            Ok(HandshakeSignatureValid::assertion())
        }

        fn verify_tls13_signature(
            &self,
            _message: &[u8],
            _cert: &CertificateDer<'_>,
            _dss: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, rustls::Error> {
            Ok(HandshakeSignatureValid::assertion())
        }

        fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
            vec![
                SignatureScheme::RSA_PKCS1_SHA256,
                SignatureScheme::RSA_PKCS1_SHA384,
                SignatureScheme::RSA_PKCS1_SHA512,
                SignatureScheme::ECDSA_NISTP256_SHA256,
                SignatureScheme::ECDSA_NISTP384_SHA384,
                SignatureScheme::RSA_PSS_SHA256,
                SignatureScheme::RSA_PSS_SHA384,
                SignatureScheme::RSA_PSS_SHA512,
                SignatureScheme::ED25519,
            ]
        }
    }

    pub(super) fn wrap(
        sock: TcpStream,
        host: &str,
        timeout: Duration,
    ) -> Result<StreamOwned<ClientConnection, TcpStream>> {
        use std::sync::Once;
        // rustls 0.23 需要显式安装 crypto provider，否则首次握手会 panic
        static INIT: Once = Once::new();
        INIT.call_once(|| {
            let _ = rustls::crypto::ring::default_provider().install_default();
        });

        // `host` 可能形如 127.0.0.1:7777，SNI 只接受裸主机名/IP
        let bare = host.split(':').next().unwrap_or(host);
        let server_name = ServerName::try_from(bare.to_string())
            .map_err(|_| anyhow!("{bare:?} 不是合法的 TLS 服务器名（IP 或域名）"))?;
        let cfg = ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(AcceptAnyCert))
            .with_no_client_auth();
        let conn = ClientConnection::new(Arc::new(cfg), server_name)
            .map_err(|e| anyhow!("TLS 客户端初始化失败: {e}"))?;
        sock.set_read_timeout(Some(timeout))?;
        sock.set_write_timeout(Some(timeout))?;
        Ok(StreamOwned::new(conn, sock))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(raw: &[u8]) -> Result<Response> {
        parse_response(raw, Instant::now())
    }

    #[test]
    fn parses_status_headers_and_content_length_body() {
        let raw = b"HTTP/1.1 200 OK\r\nServer: motifd\r\nContent-Type: application/json\r\nContent-Length: 17\r\n\r\n{\"version\":\"0.4\"}";
        let response = parse(raw).expect("应当解析成功");

        assert_eq!(response.status, 200);
        assert_eq!(response.reason, "OK");
        assert_eq!(response.body.len(), 17);
        assert_eq!(response.json().unwrap()["version"], "0.4");
        // 头名字大小写不敏感（motifd 侧实际发送时大小写可能变）。
        assert_eq!(response.header("CONTENT-TYPE"), Some("application/json"));
        assert_eq!(response.header("content-type"), Some("application/json"));
        assert_eq!(response.header("x-not-there"), None);
    }

    #[test]
    fn decodes_chunked_body_with_trailer() {
        let raw = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n\
4\r\n{\"a\"\r\n\
8\r\n:\"hello\"\r\n\
1\r\n}\r\n\
0\r\n\r\n";
        let response = parse(raw).expect("chunked 应当解析成功");
        assert_eq!(response.preview(), "{\"a\":\"hello\"}");
    }

    #[test]
    fn rejects_incomplete_content_length_body() {
        // 只有一个 200 头，body 声明 100 字节却只给了 2 字节：必须报错而不是给出半截 JSON。
        let raw = b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n{}";
        let err = parse(raw).expect_err("不完整 body 必须报错");
        assert!(
            err.to_string().contains("不完整"),
            "错误信息要说清缺字节：{err}"
        );
    }

    #[test]
    fn rejects_non_http_payload() {
        // 典型踩坑：把 /pty 的 WS 端口或别的服务当成 motifd。
        let raw = b"\x16\x03\x01\x02\x00garbage\r\n\r\n";
        assert!(parse(raw).is_err());

        let raw = b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n";
        let response = parse(raw).expect("401 也是合法响应");
        assert_eq!(response.status, 401);
        assert!(response.body.is_empty());
        assert_eq!(response.json().unwrap(), serde_json::Value::Null);
    }

    #[test]
    fn parses_empty_body_response() {
        let raw = b"HTTP/1.1 204 No Content\r\n\r\n";
        let response = parse(raw).expect("空 body 也应当成功");
        assert_eq!(response.status, 204);
        assert!(response.body.is_empty());
    }

    // ---- 回归：不能被 keep-alive 拖到读超时 ----------------------------------
    //
    // 2026-11-08 实测事故：探针发 `Connection: close`，但 motifd 回
    // `Connection: keep-alive` + `Content-Length`，且**不关连接**。旧实现只在
    // EOF / 超时时停，于是 149 字节的响应白等 2000ms（正好等于读超时），跑出来
    // 像"链路慢"。修法是按帧判完整性立即收手。

    #[test]
    fn completeness_stops_at_content_length_without_eof() {
        let full =
            b"HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: keep-alive\r\n\r\nhello world!";
        assert!(response_is_complete(full), "CL 收齐即完整，无需 EOF");

        let short = b"HTTP/1.1 200 OK\r\nContent-Length: 12\r\n\r\nhello";
        assert!(!response_is_complete(short), "CL 未收齐必须继续读");

        let head_only = b"HTTP/1.1 200 OK\r\nContent-Length: 12";
        assert!(!response_is_complete(head_only), "头没到 CRLFCRLF 不算完整");
    }

    #[test]
    fn completeness_handles_chunked_terminator() {
        let done = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n";
        assert!(response_is_complete(done), "chunked 终止块出现即完整");

        let partial = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n";
        assert!(!response_is_complete(partial), "缺终止块要继续读");
    }

    #[test]
    fn completeness_falls_back_to_eof_without_length() {
        // 既无 CL 也无 chunked：只能靠 EOF 定界，此时不能提前判完
        let no_len = b"HTTP/1.1 200 OK\r\nConnection: keep-alive\r\n\r\nsome body bytes";
        assert!(!response_is_complete(no_len));
    }
}
