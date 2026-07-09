use std::fmt;
use std::io;

/// Runtime result type.
pub type RuntimeResult<T> = Result<T, RuntimeError>;

/// Stage-classified runtime error.
#[derive(Clone, Debug)]
pub struct RuntimeError {
    pub stage: &'static str,
    pub retryable: bool,
    pub message: String,
}

impl RuntimeError {
    /// Creates a runtime error.
    pub fn new(stage: &'static str, retryable: bool, message: impl Into<String>) -> Self {
        Self {
            stage,
            retryable,
            message: message.into(),
        }
    }
}

impl fmt::Display for RuntimeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.stage, self.message)
    }
}

impl std::error::Error for RuntimeError {}

impl From<io::Error> for RuntimeError {
    fn from(error: io::Error) -> Self {
        Self::new("io", true, error.to_string())
    }
}
