//! Workbench seam — the second of the two host seams (the other is `Mesh`).
//!
//! This crate deliberately contains **no transport code**. It is the contract
//! between "a remote session exists" and "the UI can attach to it", and nothing
//! else. That matters because the transport is the part of this project most
//! likely to change under us:
//!
//! - Windows reaches `motifd` through `netbird-embed`'s local CONNECT-ish proxy
//!   (`start_proxy` → `127.0.0.1:<random>`);
//! - iOS reaches it through `flutter_netbird`'s `startProxy()` CONNECT port, or
//!   via Motif's own embedded tsnet, or via its rendezvous relay.
//!
//! Three different transports, one attach model. Keeping the seam honest is what
//! makes the P0-B fallback decision (plan-v3 §1.2) a configuration change rather
//! than a rewrite.
//!
//! ## Motif transport facts this contract is shaped around
//!
//! Taken from upstream `docs/rpc.md` (verified 2026-11-08 — see plan-v3 §0.4):
//!
//! | path | method | direction |
//! |---|---|---|
//! | `/rpc/{method}` | HTTP POST | request/response |
//! | `/events` | WS GET | server → client events |
//! | `/pty/{pty_id}` | WS GET | **bidirectional raw bytes** |
//!
//! Sessions are bound server-side: `POST /rpc/session.attach` returns the opaque
//! id in the `X-Motif-Session` response header; every later `/rpc/*` call echoes
//! it there, while the two WS channels pass it as `?session=`. A stale id yields
//! HTTP 409 `NotAttached`, which is the reconnect signal — hence
//! [`Workbench::sessions`] and [`Workbench::attach`] are separate: after a
//! transport drop you re-list, then re-attach, rather than replaying a dead id.

use std::future::Future;
use std::pin::Pin;

use anyhow::Result;

pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// Opaque, server-assigned session identifier (`X-Motif-Session`).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct SessionId(pub String);

impl SessionId {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// What a client can see about a session before attaching.
#[derive(Clone, Debug)]
pub struct SessionInfo {
    /// Server-opaque session id.
    pub id: SessionId,
    /// Human label (workdir basename, or whatever `motifd` reports).
    pub title: String,
    /// Number of live PTYs the session currently owns.
    pub pty_count: usize,
    /// Whether another client is attached right now. Motif mirrors live PTYs
    /// across clients, so co-attach is normal — this is informational only.
    pub attached_elsewhere: bool,
}

/// Handle to one attached session. Dropping it must **not** detach implicitly;
/// call [`Workbench::detach`] so the server's registry entry is cleared
/// deliberately (a bare WS drop only clears that channel's subscriptions).
pub struct AttachHandle {
    pub session: SessionId,
    /// Local channel for the raw PTY byte stream once this handle is bound.
    /// `None` until the caller opens `/pty/{id}` on its own transport.
    pub pty: Option<usize>,
}

/// The seam. Three methods, no transport, no auth, no retry policy.
pub trait Workbench: Send + Sync {
    /// List sessions currently exposed by the server.
    fn sessions(&self) -> Vec<SessionInfo>;

    /// Attach by id. Fails with a *typed* error when the id is no longer known
    /// (server said 409) so callers can distinguish "re-attach" from "network
    /// down" without string matching.
    fn attach(&self, id: &SessionId) -> BoxFuture<'_, Result<AttachHandle>>;

    /// Detach. Clears the server-side registry entry for this client.
    fn detach(&self, handle: AttachHandle) -> BoxFuture<'_, Result<()>>;
}

/// Well-known `motifd` routes, so no crate hardcodes strings twice.
pub mod routes {
    pub const RPC_PREFIX: &str = "/rpc/";
    pub const EVENTS: &str = "/events";
    pub const PTY_PREFIX: &str = "/pty/";
    /// Cheapest possible liveness probe: **no auth required**, returns the
    /// motifd version. This is the P0 acceptance probe (gate-A, gate-B1)
    /// because it isolates "is the tunnel up" from "is the bearer right".
    ///
    /// Verified against upstream `docs/rpc.md` §1.7 — there is no
    /// `/rpc/version` method; `/ping` is the one that reports version.
    pub const PING: &str = "/ping";
    pub const PING_CAPABILITIES: &str = "/ping.capabilities";
    pub const SESSION_LIST: &str = "/rpc/session.list";
    pub const SESSION_ATTACH: &str = "/rpc/session.attach";
    pub const SESSION_DETACH: &str = "/rpc/session.detach";
    /// Response header carrying the opaque session id.
    pub const HDR_SESSION: &str = "x-motif-session";
    /// HTTP status meaning "this session id is no longer registered".
    pub const STATUS_NOT_ATTACHED: u16 = 409;
}

#[cfg(test)]
mod tests {
    use super::routes;

    #[test]
    fn route_constants_are_absolute_paths() {
        for p in [
            routes::PING,
            routes::EVENTS,
            routes::SESSION_LIST,
            routes::SESSION_ATTACH,
            routes::SESSION_DETACH,
        ] {
            assert!(p.starts_with('/'), "{p} must be an absolute path");
        }
        // /ping is NOT under /rpc/ — it deliberately bypasses the RPC dispatcher
        // and the token check. If this ever starts failing, the probe semantics
        // have changed upstream.
        assert!(routes::PING.starts_with("/ping"));
        assert!(!routes::PING.starts_with(routes::RPC_PREFIX));
        assert!(routes::SESSION_LIST.starts_with(routes::RPC_PREFIX));
        assert!(routes::PTY_PREFIX.ends_with('/'));
    }
}
