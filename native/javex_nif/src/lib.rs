//! NIF bindings. The worker executable uses the same core without these bindings.

mod compiler;
mod output;
mod sandbox;

use rustler::{Atom, Binary, Encoder, Env, NifResult, OwnedBinary, ResourceArc, Term};
use sandbox::{Budgets, CacheOptions, CacheStats, Control, Execution, Progress, Runtime};
use sha2::{Digest, Sha256};
use std::sync::Mutex;

mod atoms {
    rustler::atoms! { ok, error, dynamic, continue_, static_ = "static" }
}

rustler::init!("Elixir.Javex.Native");

pub struct RuntimeResource(Runtime);
pub struct ControlResource(Control);
pub struct ExecutionResource(Mutex<Option<Execution>>);

#[rustler::resource_impl]
impl rustler::Resource for RuntimeResource {}
#[rustler::resource_impl]
impl rustler::Resource for ControlResource {}
#[rustler::resource_impl]
impl rustler::Resource for ExecutionResource {}

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
fn run_start<'a>(
    env: Env<'a>,
    runtime: ResourceArc<RuntimeResource>,
    wasm: Binary<'a>,
    input: Binary<'a>,
    opts: Budgets,
    control: ResourceArc<ControlResource>,
) -> NifResult<Term<'a>> {
    match Execution::start(
        &runtime.0,
        wasm.as_slice(),
        input.as_slice(),
        &opts,
        control.0.clone(),
    ) {
        Ok(execution) => advance(
            env,
            ResourceArc::new(ExecutionResource(Mutex::new(Some(execution)))),
            b"[]",
        ),
        Err((kind, message)) => {
            Ok((atoms::error(), (Atom::from_str(env, kind)?, message)).encode(env))
        }
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn run_step<'a>(
    env: Env<'a>,
    execution: ResourceArc<ExecutionResource>,
    completion: Binary<'a>,
) -> NifResult<Term<'a>> {
    advance(env, execution, completion.as_slice())
}

fn advance<'a>(
    env: Env<'a>,
    execution: ResourceArc<ExecutionResource>,
    completion: &[u8],
) -> NifResult<Term<'a>> {
    let mut slot = execution.0.try_lock().map_err(|_| rustler::Error::BadArg)?;
    let result = slot
        .as_mut()
        .ok_or(rustler::Error::BadArg)?
        .advance(completion);
    match result {
        Ok(Progress::Done(bytes)) => {
            *slot = None;
            Ok((atoms::ok(), binary(env, &bytes)?).encode(env))
        }
        Ok(Progress::Pending(bytes)) => {
            drop(slot);
            Ok((atoms::continue_(), execution, binary(env, &bytes)?).encode(env))
        }
        Err((kind, message)) => {
            *slot = None;
            Ok((atoms::error(), (Atom::from_str(env, kind)?, message)).encode(env))
        }
    }
}

fn binary<'a>(env: Env<'a>, bytes: &[u8]) -> NifResult<Binary<'a>> {
    let mut binary = OwnedBinary::new(bytes.len()).ok_or(rustler::Error::BadArg)?;
    binary.as_mut_slice().copy_from_slice(bytes);
    Ok(Binary::from_owned(binary, env))
}
