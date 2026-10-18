//! Host-side output buffers have their own quotas, independent of Wasm memory.

use std::io;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};

use bytes::Bytes;
use tokio::io::AsyncWrite;
use wasmtime_wasi::async_trait;
use wasmtime_wasi::cli::{IsTerminal, StdoutStream};
use wasmtime_wasi::p2::{OutputStream, Pollable, StreamError};

#[derive(Clone)]
pub struct Output {
    capacity: usize,
    state: Arc<Mutex<State>>,
}

#[derive(Default)]
struct State {
    bytes: Vec<u8>,
    exceeded: bool,
}

impl Output {
    pub fn new(capacity: usize) -> Self {
        Self {
            capacity,
            state: Arc::new(Mutex::new(State::default())),
        }
    }

    pub fn exceeded(&self) -> bool {
        self.state.lock().unwrap().exceeded
    }

    pub fn contents(&self) -> Vec<u8> {
        self.state.lock().unwrap().bytes.clone()
    }

    fn append(&self, bytes: &[u8]) -> io::Result<usize> {
        let mut state = self.state.lock().unwrap();
        let available = self.capacity - state.bytes.len();
        let count = available.min(bytes.len());
        state.bytes.extend_from_slice(&bytes[..count]);
        if count < bytes.len() {
            state.exceeded = true;
            return Err(io::Error::other("output limit exceeded"));
        }
        Ok(count)
    }
}

impl IsTerminal for Output {
    fn is_terminal(&self) -> bool {
        false
    }
}

impl StdoutStream for Output {
    fn async_stream(&self) -> Box<dyn AsyncWrite + Send + Sync> {
        Box::new(self.clone())
    }

    fn p2_stream(&self) -> Box<dyn OutputStream> {
        Box::new(self.clone())
    }
}

#[async_trait]
impl Pollable for Output {
    async fn ready(&mut self) {}
}

#[async_trait]
impl OutputStream for Output {
    fn write(&mut self, bytes: Bytes) -> Result<(), StreamError> {
        self.append(&bytes)
            .map(|_| ())
            .map_err(|error| StreamError::trap(&error.to_string()))
    }

    fn flush(&mut self) -> Result<(), StreamError> {
        Ok(())
    }

    fn check_write(&mut self) -> Result<usize, StreamError> {
        let state = self.state.lock().unwrap();
        let available = self.capacity - state.bytes.len();
        // WASI also checks readiness after flushing an exact-capacity write.
        // Only an actual extra write exceeds the quota. Offer one byte when
        // full so a subsequent write fails promptly rather than waiting forever.
        Ok(available.max(1))
    }
}

impl AsyncWrite for Output {
    fn poll_write(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        Poll::Ready(self.append(bytes))
    }

    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_capacity_succeeds_but_the_next_write_fails_without_growing() {
        let mut output = Output::new(3);
        OutputStream::write(&mut output, Bytes::from_static(b"abc")).unwrap();
        assert_eq!(output.contents(), b"abc");
        OutputStream::flush(&mut output).unwrap();
        assert!(OutputStream::check_write(&mut output).is_ok());
        assert!(!output.exceeded());
        assert!(OutputStream::write(&mut output, Bytes::from_static(b"d")).is_err());
        assert_eq!(output.contents(), b"abc");
        assert!(output.exceeded());
    }

    #[test]
    fn cloned_streams_share_the_quota_and_preserve_a_diagnostic_prefix() {
        let mut first = Output::new(5);
        let mut second = first.clone();
        OutputStream::write(&mut first, Bytes::from_static(b"ab")).unwrap();
        assert!(OutputStream::write(&mut second, Bytes::from_static(b"cdef")).is_err());
        assert_eq!(first.contents(), b"abcde");
        assert!(first.exceeded());
    }
}
