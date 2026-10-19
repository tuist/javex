//! Synchronous, bounded JSON hostcalls supplied to the Javy provider.

use crate::sandbox::{Budgets, StoreContext};
use wasmtime::{Caller, Linker, Memory};

const NAMESPACE: &str = "javex_host_v1";

pub type Dispatch = Box<dyn FnMut(&[u8]) -> anyhow::Result<Vec<u8>> + Send>;

pub struct Callbacks {
    dispatch: Option<Dispatch>,
    remaining: u64,
    max_input: usize,
    max_output: usize,
    response: Vec<u8>,
    pub failure: Option<(&'static str, String)>,
}

impl Callbacks {
    pub fn new(opts: &Budgets, dispatch: Option<Dispatch>) -> Self {
        Self {
            dispatch,
            remaining: opts.max_callback_calls,
            max_input: opts.max_callback_input,
            max_output: opts.max_callback_output,
            response: Vec::new(),
            failure: None,
        }
    }

    fn fail<T>(&mut self, kind: &'static str, message: &str) -> anyhow::Result<T> {
        self.failure = Some((kind, message.to_owned()));
        anyhow::bail!("{message}")
    }

    fn call(&mut self, request: &[u8]) -> anyhow::Result<()> {
        if self.remaining == 0 {
            return self.fail("callback_limit", "callback call limit exceeded");
        }
        self.remaining -= 1;
        if request.len() > self.max_input {
            return self.fail("callback_limit", "callback input limit exceeded");
        }
        let response = match self.dispatch.as_mut() {
            Some(dispatch) => dispatch(request)?,
            None => {
                br#"["error",{"code":"callback_denied","message":"Callback not granted"}]"#.to_vec()
            }
        };
        // Envelopes have a small fixed overhead beyond the result budget.
        if response.len() > self.max_output.saturating_add(1024) {
            return self.fail("callback_limit", "callback output limit exceeded");
        }
        // BEAM owns the envelope. Only terminal errors need inspecting here;
        // reparsing user data would impose serde_json's unrelated depth limit.
        if response.starts_with(br#"["abort","#) {
            let value: serde_json::Value = serde_json::from_slice(&response)?;
            let kind = match value[1]["code"].as_str() {
                Some("callback_timeout") => "callback_timeout",
                Some("cancelled") => "cancelled",
                _ => "callback_limit",
            };
            return self.fail(
                kind,
                value[1]["message"].as_str().unwrap_or("Callback aborted"),
            );
        }
        self.response = response;
        Ok(())
    }
}

fn memory(caller: &mut Caller<'_, StoreContext>) -> anyhow::Result<Memory> {
    caller
        .get_export("memory")
        .and_then(|export| export.into_memory())
        .ok_or_else(|| anyhow::anyhow!("missing caller memory"))
}

pub(crate) fn add_to_linker(linker: &mut Linker<StoreContext>) -> anyhow::Result<()> {
    linker.func_wrap(
        NAMESPACE,
        "dispatch",
        move |mut caller: Caller<'_, StoreContext>, ptr: u32, len: u32| -> wasmtime::Result<u32> {
            let result = (|| -> anyhow::Result<u32> {
                caller.data().control.check()?;
                let memory = memory(&mut caller)?;
                if len as usize > caller.data().callbacks.max_input {
                    return caller
                        .data_mut()
                        .callbacks
                        .fail("callback_limit", "callback input limit exceeded");
                }
                let mut bytes = vec![0; len as usize];
                memory.read(&caller, ptr as usize, &mut bytes)?;
                caller.data_mut().callbacks.call(&bytes)?;
                caller.data().control.check()?;
                Ok(u32::try_from(caller.data().callbacks.response.len())?)
            })();
            result.map_err(wasmtime::Error::from_anyhow)
        },
    )?;
    linker.func_wrap(
        NAMESPACE,
        "read_response",
        move |mut caller: Caller<'_, StoreContext>, ptr: u32, len: u32| -> wasmtime::Result<()> {
            let result = (|| -> anyhow::Result<()> {
                caller.data().control.check()?;
                let memory = memory(&mut caller)?;
                let bytes = std::mem::take(&mut caller.data_mut().callbacks.response);
                anyhow::ensure!(
                    len as usize == bytes.len(),
                    "invalid callback response length"
                );
                memory.write(&mut caller, ptr as usize, &bytes)?;
                Ok(())
            })();
            result.map_err(wasmtime::Error::from_anyhow)
        },
    )?;
    Ok(())
}
