//! Host-side infrastructure for crossdesk.
//!
//! Two things live here, and only two:
//!
//! 1. [`RealmRegistry`] — exact-slot service lookup keyed by `(service, realm)`.
//!    Mirrors cordis's `Service` semantics: **no fallback**. Asking for
//!    `(SshSession, host-a)` never yields host-b's instance, and asking for an
//!    unregistered realm is an error rather than a silent miss.
//! 2. [`DisposeStack`] — LIFO teardown. cordis (`≤0.11`) has no runtime-level
//!    shutdown API, so every host that spawns plugins must unwind them itself,
//!    in reverse spawn order, and must not stop unwinding when one step fails.
//!
//! Neither type knows about NetBird, Motif, or iOS. Keeping them seam-agnostic
//! is what lets `crates/mesh` and `crates/workbench` be swapped (or forked)
//! without touching lifecycle code.

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};

use anyhow::{Result, anyhow};

/// A boxed, non-`'static`-bounded future. Hand-rolled so this crate needs no
/// `futures` dependency just for a type alias.
pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

// ---------------------------------------------------------------------------
// Realm-scoped exact-slot registry
// ---------------------------------------------------------------------------

/// Identity of a registered instance: one service kind, in one realm.
///
/// `realm` is what keeps two target machines' SSH credentials and PTY sessions
/// from ever resolving into each other. It is **not** a naming convention to be
/// respected by callers (plan-v3 §2.1) — it is enforced here, at lookup.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct SlotKey {
    pub service: &'static str,
    pub realm: Arc<str>,
}

impl SlotKey {
    pub fn new(service: &'static str, realm: impl Into<Arc<str>>) -> Self {
        Self {
            service,
            realm: realm.into(),
        }
    }
}

/// Exact-slot registry. Cloning is cheap (`Arc` inside).
#[derive(Clone, Default)]
pub struct RealmRegistry {
    inner: Arc<Mutex<HashMap<SlotKey, Arc<dyn std::any::Any + Send + Sync>>>>,
}

impl RealmRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Register one instance for `(service, realm)`.
    ///
    /// Re-registering the same slot is a hard error: silently overwriting would
    /// hide a double-spawn bug, which is exactly the class of bug this layer
    /// exists to catch.
    pub fn register<T: std::any::Any + Send + Sync>(
        &self,
        key: SlotKey,
        instance: Arc<T>,
    ) -> Result<()> {
        let mut map = self
            .inner
            .lock()
            .map_err(|_| anyhow!("registry poisoned"))?;
        if map.contains_key(&key) {
            return Err(anyhow!(
                "slot already registered: service={} realm={}",
                key.service,
                key.realm
            ));
        }
        map.insert(key, instance as Arc<dyn std::any::Any + Send + Sync>);
        Ok(())
    }

    /// Resolve `(service, realm)` **exactly**. No fallback, no default realm.
    pub fn resolve<T: std::any::Any + Send + Sync>(&self, key: &SlotKey) -> Result<Arc<T>> {
        let map = self
            .inner
            .lock()
            .map_err(|_| anyhow!("registry poisoned"))?;
        let any = map.get(key).ok_or_else(|| {
            anyhow!(
                "no instance for service={} realm={} (exact-slot lookup, no fallback)",
                key.service,
                key.realm
            )
        })?;
        any.clone().downcast::<T>().map_err(|_| {
            anyhow!(
                "type mismatch for service={} realm={}",
                key.service,
                key.realm
            )
        })
    }

    /// Drop one slot (used when a realm's target machine is removed).
    pub fn remove(&self, key: &SlotKey) -> bool {
        self.inner
            .lock()
            .map(|mut m| m.remove(key).is_some())
            .unwrap_or(false)
    }

    /// Realms currently holding at least one service. Used by the P4 isolation
    /// acceptance check ("two tenants cannot see each other").
    pub fn realms(&self) -> Vec<Arc<str>> {
        let Ok(map) = self.inner.lock() else {
            return Vec::new();
        };
        let mut out: Vec<Arc<str>> = map.keys().map(|k| k.realm.clone()).collect();
        out.sort();
        out.dedup();
        out
    }
}

// ---------------------------------------------------------------------------
// LIFO dispose stack
// ---------------------------------------------------------------------------

/// One disposable resource. `dispose` takes `&mut self` because several upstream
/// clients (notably netbird-embed's `Client`) must be explicitly stopped before
/// drop — a bare `Drop` can block, and a dropped handle is not a stopped one.
pub trait Disposable: Send {
    fn label(&self) -> &str;
    fn dispose(&mut self) -> BoxFuture<'_, Result<()>>;
}

/// Reverse-order teardown with failure aggregation.
///
/// Contract:
/// - runs strictly LIFO (last spawned = first disposed);
/// - a failing dispose is recorded and teardown continues (a stuck PTY must not
///   leave the Go runtime running);
/// - `shutdown` is idempotent: second call is a no-op returning `Ok(())`.
pub struct DisposeStack {
    entries: Vec<Box<dyn Disposable>>,
    torn_down: bool,
}

impl Default for DisposeStack {
    fn default() -> Self {
        Self::new()
    }
}

impl DisposeStack {
    pub fn new() -> Self {
        Self {
            entries: Vec::new(),
            torn_down: false,
        }
    }

    /// Push in spawn order. Disposal happens in exactly reverse order.
    pub fn push(&mut self, d: Box<dyn Disposable>) {
        self.entries.push(d);
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Unwind everything. Returns the failures joined by `;` — teardown never
    /// aborts early, so a single error cannot mask the rest.
    pub async fn shutdown(&mut self) -> Result<()> {
        if self.torn_down {
            return Ok(());
        }
        self.torn_down = true;

        let mut errors: Vec<String> = Vec::new();
        while let Some(mut entry) = self.entries.pop() {
            let label = entry.label().to_owned();
            match entry.dispose().await {
                Ok(()) => tracing::debug!(target: "crossdesk.host", %label, "disposed"),
                Err(e) => {
                    tracing::error!(target: "crossdesk.host", %label, error = %e, "dispose failed, continuing");
                    errors.push(format!("{label}: {e}"));
                }
            }
        }

        if errors.is_empty() {
            Ok(())
        } else {
            Err(anyhow!(
                "{} dispose failure(s): {}",
                errors.len(),
                errors.join("; ")
            ))
        }
    }
}

impl Drop for DisposeStack {
    /// Best-effort guard: if a caller forgets `shutdown`, we at least log how
    /// much leaked. Actual async unwinding cannot happen in `Drop`, which is
    /// precisely why `shutdown` is explicit — same trap as cordis `drop != dispose`.
    fn drop(&mut self) {
        if !self.torn_down && !self.entries.is_empty() {
            tracing::warn!(
                target: "crossdesk.host",
                leaked = self.entries.len(),
                "DisposeStack dropped without shutdown(); resources likely still running"
            );
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct Recorder {
        label: String,
        order: Arc<Mutex<Vec<String>>>,
        fail: bool,
    }

    impl Disposable for Recorder {
        fn label(&self) -> &str {
            &self.label
        }
        fn dispose(&mut self) -> BoxFuture<'_, Result<()>> {
            let label = self.label.clone();
            let order = self.order.clone();
            let fail = self.fail;
            Box::pin(async move {
                order.lock().unwrap().push(label);
                if fail { Err(anyhow!("boom")) } else { Ok(()) }
            })
        }
    }

    #[test]
    fn exact_slot_lookup_has_no_fallback() {
        let reg = RealmRegistry::new();
        let a = SlotKey::new("SshSession", "host-a");
        reg.register(a.clone(), Arc::new(1u32)).unwrap();

        assert!(reg.resolve::<u32>(&a).is_ok());
        let b = SlotKey::new("SshSession", "host-b");
        assert!(
            reg.resolve::<u32>(&b).is_err(),
            "must not fall back to host-a"
        );

        // wrong type in a valid slot is a type error, not a silent miss
        assert!(reg.resolve::<String>(&a).is_err());
    }

    #[test]
    fn double_register_is_rejected() {
        let reg = RealmRegistry::new();
        let k = SlotKey::new("Mesh", "local");
        reg.register(k.clone(), Arc::new(1u32)).unwrap();
        assert!(reg.register(k, Arc::new(2u32)).is_err());
    }

    #[tokio::test]
    async fn dispose_runs_lifo_and_does_not_abort_on_error() {
        let order = Arc::new(Mutex::new(Vec::new()));
        let mut stack = DisposeStack::new();
        for (i, fail) in [(0usize, false), (1, true), (2, false)] {
            stack.push(Box::new(Recorder {
                label: format!("p{i}"),
                order: order.clone(),
                fail,
            }));
        }

        let err = stack.shutdown().await.unwrap_err();
        assert!(
            err.to_string().contains("p1:"),
            "failing step must be reported: {err}"
        );

        let seen = order.lock().unwrap().clone();
        assert_eq!(
            seen,
            vec!["p2", "p1", "p0"],
            "teardown must be reverse spawn order"
        );

        // idempotent
        assert!(stack.shutdown().await.is_ok());
    }

    #[tokio::test]
    async fn shutdown_times_measured_sanity() {
        // guard against regressing to a per-entry serial sleep in the hot path
        let counter = Arc::new(AtomicUsize::new(0));
        struct Counting(Arc<AtomicUsize>);
        impl Disposable for Counting {
            fn label(&self) -> &str {
                "counting"
            }
            fn dispose(&mut self) -> BoxFuture<'_, Result<()>> {
                let c = self.0.clone();
                Box::pin(async move {
                    c.fetch_add(1, Ordering::SeqCst);
                    Ok(())
                })
            }
        }
        let mut stack = DisposeStack::new();
        stack.push(Box::new(Counting(counter.clone())));
        stack.shutdown().await.unwrap();
        assert_eq!(counter.load(Ordering::SeqCst), 1);
    }
}
