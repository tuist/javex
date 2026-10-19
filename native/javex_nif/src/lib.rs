//! NIF bindings. The worker executable uses the same core without these bindings.

mod callbacks;
mod compiler;
mod output;
mod sandbox;

use rustler::{Atom, Binary, Encoder, Env, NifResult, OwnedBinary, OwnedEnv, ResourceArc, Term};
use sandbox::{Budgets, CacheOptions, CacheStats, Control, Runtime};
use sha2::{Digest, Sha256};
use std::sync::{Mutex, mpsc};
use std::time::Duration;

mod atoms {
    rustler::atoms! { ok, error, dynamic, static_ = "static", native_callback, native_result }
}

rustler::init!("Elixir.Javex.Native");

pub struct RuntimeResource(Runtime);
pub struct ControlResource(Control);
pub struct CallbackReplyResource(Mutex<Option<mpsc::SyncSender<Vec<u8>>>>);

#[rustler::resource_impl]
impl rustler::Resource for RuntimeResource {}
#[rustler::resource_impl]
impl rustler::Resource for ControlResource {}
#[rustler::resource_impl]
impl rustler::Resource for CallbackReplyResource {}

#[rustler::nif]
fn control_new(timeout_ms: u64) -> NifResult<ResourceArc<ControlResource>> {
    let control = Control::new(timeout_ms).map_err(|_| rustler::Error::BadArg)?;
    Ok(ResourceArc::new(ControlResource(control)))
}

#[rustler::nif]
fn cancel(control: ResourceArc<ControlResource>) -> Atom {
    control.0.cancel();
    atoms::ok()
}

#[rustler::nif]
fn runtime_stats(runtime: ResourceArc<RuntimeResource>) -> CacheStats {
    runtime.0.stats()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn runtime_new<'a>(env: Env<'a>, plugin: Binary<'a>, limits: CacheOptions) -> NifResult<Term<'a>> {
    match sandbox::build_runtime(plugin.as_slice(), limits) {
        Ok(runtime) => Ok((atoms::ok(), ResourceArc::new(RuntimeResource(runtime))).encode(env)),
        Err(error) => Ok((atoms::error(), format!("{error:#}")).encode(env)),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn compile<'a>(
    env: Env<'a>,
    plugin: Binary<'a>,
    source: Binary<'a>,
    mode: Atom,
    opts: Budgets,
    control: ResourceArc<ControlResource>,
) -> NifResult<Term<'a>> {
    if mode != atoms::dynamic() && mode != atoms::static_() {
        return Err(rustler::Error::BadArg);
    }
    match compiler::compile(
        plugin.as_slice(),
        source.as_slice(),
        mode == atoms::static_(),
        &opts,
        control.0.clone(),
    ) {
        Ok(bytes) => {
            let hash = if mode == atoms::dynamic() {
                Sha256::digest(plugin.as_slice()).to_vec()
            } else {
                Vec::new()
            };
            Ok((atoms::ok(), (binary(env, &bytes)?, binary(env, &hash)?)).encode(env))
        }
        Err(error) => Ok((atoms::error(), format!("{error:#}")).encode(env)),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn run<'a>(
    env: Env<'a>,
    runtime: ResourceArc<RuntimeResource>,
    wasm: Binary<'a>,
    input: Binary<'a>,
    opts: Budgets,
    control: ResourceArc<ControlResource>,
) -> NifResult<Term<'a>> {
    match sandbox::run(
        &runtime.0,
        wasm.as_slice(),
        input.as_slice(),
        &opts,
        control.0.clone(),
    ) {
        Ok(bytes) => Ok((atoms::ok(), binary(env, &bytes)?).encode(env)),
        // Kinds are constants in the execution core, never guest-controlled strings.
        Err((kind, message)) => {
            Ok((atoms::error(), (Atom::from_str(env, kind)?, message)).encode(env))
        }
    }
}

// Execution with hostcalls runs on its own bounded-admission thread. Waiting
// for HTTP or BEAM messages must never occupy a dirty CPU scheduler.
#[rustler::nif(schedule = "DirtyCpu")]
fn run_start(
    env: Env<'_>,
    runtime: ResourceArc<RuntimeResource>,
    wasm: Binary<'_>,
    input: Binary<'_>,
    opts: Budgets,
    control: ResourceArc<ControlResource>,
) -> NifResult<Atom> {
    let wasm = wasm.as_slice().to_vec();
    let input = input.as_slice().to_vec();
    let pid = env.pid();
    std::thread::Builder::new()
        .name("javex-run".into())
        .spawn(move || {
            let check = control.0.clone();
            let dispatch: callbacks::Dispatch = Box::new(move |request| {
                check.check()?;
                let (sender, receiver) = mpsc::sync_channel(1);
                let reply = ResourceArc::new(CallbackReplyResource(Mutex::new(Some(sender))));
                OwnedEnv::new()
                    .send_and_clear(&pid, |env| {
                        (
                            atoms::native_callback(),
                            reply,
                            binary(env, request).unwrap(),
                        )
                            .encode(env)
                    })
                    .map_err(|_| anyhow::anyhow!("callback owner stopped"))?;
                loop {
                    check.check()?;
                    match receiver.recv_timeout(Duration::from_millis(5)) {
                        Ok(response) => return Ok(response),
                        Err(mpsc::RecvTimeoutError::Timeout) => (),
                        Err(_) => anyhow::bail!("callback reply channel closed"),
                    }
                }
            });
            let result = sandbox::run_with_callbacks(
                &runtime.0,
                &wasm,
                &input,
                &opts,
                control.0.clone(),
                Some(dispatch),
            );
            let _ = OwnedEnv::new().send_and_clear(&pid, |env| {
                let result = match result {
                    Ok(bytes) => (atoms::ok(), binary(env, &bytes).unwrap()).encode(env),
                    Err((kind, message)) => (
                        atoms::error(),
                        (Atom::from_str(env, kind).unwrap(), message),
                    )
                        .encode(env),
                };
                (atoms::native_result(), result).encode(env)
            });
        })
        .map_err(|_| rustler::Error::Term(Box::new("native execution thread unavailable")))?;
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn callback_reply(reply: ResourceArc<CallbackReplyResource>, bytes: Binary<'_>) -> Atom {
    if let Some(sender) = reply.0.lock().unwrap().take() {
        let _ = sender.send(bytes.as_slice().to_vec());
    }
    atoms::ok()
}

fn binary<'a>(env: Env<'a>, bytes: &[u8]) -> NifResult<Binary<'a>> {
    let mut binary = OwnedBinary::new(bytes.len()).ok_or(rustler::Error::BadArg)?;
    binary.as_mut_slice().copy_from_slice(bytes);
    Ok(Binary::from_owned(binary, env))
}
