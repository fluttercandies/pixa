use crate::{RuntimeError, RuntimeResult};
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, Weak};

static NEXT_CANCEL_ID: AtomicU64 = AtomicU64::new(1);
static CANCEL_TOKENS: OnceLock<Mutex<BTreeMap<u64, RuntimeCancelToken>>> = OnceLock::new();

/// Shared cancellation flag for runtime pipeline work.
#[derive(Clone, Debug)]
pub struct RuntimeCancelToken {
    inner: Arc<RuntimeCancelState>,
}

#[derive(Debug)]
struct RuntimeCancelState {
    cancelled: AtomicBool,
    wakers: Mutex<Vec<Weak<dyn RuntimeCancelWaker>>>,
}

/// Wait target that should be woken when a runtime cancellation token is set.
pub trait RuntimeCancelWaker: Send + Sync {
    /// Wakes any threads waiting on this runtime operation.
    fn wake_cancelled(&self);
}

impl RuntimeCancelToken {
    fn new() -> Self {
        Self {
            inner: Arc::new(RuntimeCancelState {
                cancelled: AtomicBool::new(false),
                wakers: Mutex::new(Vec::new()),
            }),
        }
    }

    /// Marks the token cancelled.
    pub fn cancel(&self) {
        self.inner.cancelled.store(true, Ordering::Release);
        let wakers = {
            let Ok(mut wakers) = self.inner.wakers.lock() else {
                return;
            };
            let mut live = Vec::with_capacity(wakers.len());
            wakers.retain(|weak| {
                if let Some(waker) = weak.upgrade() {
                    live.push(waker);
                    true
                } else {
                    false
                }
            });
            live
        };
        for waker in wakers {
            waker.wake_cancelled();
        }
    }

    /// Whether cancellation has been requested.
    pub fn is_cancelled(&self) -> bool {
        self.inner.cancelled.load(Ordering::Acquire)
    }

    /// Returns an error when the token is cancelled.
    pub fn ensure_not_cancelled(&self) -> RuntimeResult<()> {
        if self.is_cancelled() {
            return Err(cancelled_error());
        }
        Ok(())
    }

    /// Registers a wait target to be woken when this token is cancelled.
    pub fn register_waker<W>(&self, waker: &Arc<W>)
    where
        W: RuntimeCancelWaker + 'static,
    {
        if self.is_cancelled() {
            waker.wake_cancelled();
            return;
        }
        let waker_arc: Arc<dyn RuntimeCancelWaker> = waker.clone();
        let weak = Arc::downgrade(&waker_arc);
        let Ok(mut wakers) = self.inner.wakers.lock() else {
            return;
        };
        if self.is_cancelled() {
            drop(wakers);
            waker.wake_cancelled();
            return;
        }
        wakers.retain(|candidate| candidate.strong_count() > 0);
        wakers.push(weak);
    }
}

/// Creates and registers a runtime cancellation token.
pub fn create_cancel_token() -> RuntimeResult<u64> {
    let id = NEXT_CANCEL_ID.fetch_add(1, Ordering::Relaxed);
    token_registry()
        .lock()
        .map_err(|_| RuntimeError::new("cancel", true, "cancel token lock poisoned"))?
        .insert(id, RuntimeCancelToken::new());
    Ok(id)
}

/// Requests cancellation for a registered token.
pub fn cancel_token(id: u64) -> RuntimeResult<bool> {
    if id == 0 {
        return Ok(false);
    }
    let tokens = token_registry()
        .lock()
        .map_err(|_| RuntimeError::new("cancel", true, "cancel token lock poisoned"))?;
    if let Some(token) = tokens.get(&id) {
        token.cancel();
        return Ok(true);
    }
    Ok(false)
}

/// Removes a token from the registry.
pub fn free_cancel_token(id: u64) -> RuntimeResult<()> {
    if id == 0 {
        return Ok(());
    }
    token_registry()
        .lock()
        .map_err(|_| RuntimeError::new("cancel", true, "cancel token lock poisoned"))?
        .remove(&id);
    Ok(())
}

/// Returns a clone of a registered token.
pub fn cancel_token_handle(id: u64) -> RuntimeResult<Option<RuntimeCancelToken>> {
    if id == 0 {
        return Ok(None);
    }
    Ok(token_registry()
        .lock()
        .map_err(|_| RuntimeError::new("cancel", true, "cancel token lock poisoned"))?
        .get(&id)
        .cloned())
}

/// Returns a typed cancellation failure.
pub fn cancelled_error() -> RuntimeError {
    RuntimeError::new("cancel", false, "runtime image request was cancelled")
}

fn token_registry() -> &'static Mutex<BTreeMap<u64, RuntimeCancelToken>> {
    CANCEL_TOKENS.get_or_init(|| Mutex::new(BTreeMap::new()))
}
