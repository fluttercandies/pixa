use crate::cache::now_millis;

/// Runtime pipeline stage mirrored by Dart observer/progress events.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RuntimeProgressStage {
    Request,
    CacheLookup,
    Fetch,
    Decode,
    Process,
    CacheWrite,
    Complete,
    Cancel,
}

/// Lightweight runtime progress event emitted from Rust hot paths.
#[derive(Clone, Debug)]
pub struct RuntimeProgressEvent {
    pub stage: RuntimeProgressStage,
    pub name: String,
    pub received_bytes: Option<usize>,
    pub expected_bytes: Option<usize>,
    pub message: Option<String>,
    pub preview_bytes: Option<Vec<u8>>,
    pub timestamp_ms: i64,
}

impl RuntimeProgressEvent {
    /// Creates a named progress event.
    pub fn new(stage: RuntimeProgressStage, name: impl Into<String>) -> Self {
        Self {
            stage,
            name: name.into(),
            received_bytes: None,
            expected_bytes: None,
            message: None,
            preview_bytes: None,
            timestamp_ms: now_millis(),
        }
    }

    /// Attaches byte counters to the event.
    pub fn with_bytes(mut self, received_bytes: usize, expected_bytes: Option<usize>) -> Self {
        self.received_bytes = Some(received_bytes);
        self.expected_bytes = expected_bytes;
        self
    }

    /// Attaches a redacted message to the event.
    pub fn with_message(mut self, message: impl Into<String>) -> Self {
        self.message = Some(message.into());
        self
    }

    /// Attaches runtime-owned progressive preview bytes to the event.
    pub fn with_preview_bytes(mut self, bytes: Vec<u8>) -> Self {
        self.preview_bytes = Some(bytes);
        self
    }
}

/// Thread-safe sink used by the runtime boundary or plugin hosts.
pub trait RuntimeProgressSink: Sync {
    fn emit(&self, event: RuntimeProgressEvent);
}

/// Emits an event when a sink is installed.
pub fn emit_progress(sink: Option<&dyn RuntimeProgressSink>, event: RuntimeProgressEvent) {
    if let Some(sink) = sink {
        sink.emit(event);
    }
}
