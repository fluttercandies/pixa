use std::io::{self, Write};

/// In-memory writer that never grows beyond a caller-provided byte limit.
#[derive(Debug)]
pub struct BoundedBytesWriter {
    bytes: Vec<u8>,
    limit: usize,
}

impl BoundedBytesWriter {
    /// Creates an empty writer with a hard byte limit.
    pub fn new(limit: usize) -> Self {
        Self {
            bytes: Vec::new(),
            limit,
        }
    }

    /// Returns the bytes written so far.
    pub fn as_slice(&self) -> &[u8] {
        &self.bytes
    }

    /// Consumes the writer and returns its bounded output.
    pub fn into_inner(self) -> Vec<u8> {
        self.bytes
    }
}

impl Write for BoundedBytesWriter {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        let next_len = self
            .bytes
            .len()
            .checked_add(buffer.len())
            .ok_or_else(storage_full)?;
        if next_len > self.limit {
            return Err(storage_full());
        }
        self.bytes.extend_from_slice(buffer);
        Ok(buffer.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn storage_full() -> io::Error {
    io::Error::new(
        io::ErrorKind::StorageFull,
        "encoded output exceeds configured byte limit",
    )
}
