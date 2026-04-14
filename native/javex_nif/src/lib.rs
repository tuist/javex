// Javex NIF
//
// Bridges Elixir <-> Javy (JS -> Wasm) and wasmtime (Wasm execution).
//
// Resources exposed to the BEAM:
//   - Runtime:     { Engine, plugin_module, plugin_import_name }
//   - Precompiled: { compiled user Wasm module }
//
// Dynamic linking model: the plugin is instantiated once per user-module
// instantiation and its exports are registered under its canonical
// import name so the user module's imports resolve. Static modules
// embed QuickJS themselves and do not need a plugin.

use std::sync::Mutex;
use std::time::Duration;

use rustler::{Atom, Binary, Env, NewBinary, NifResult, OwnedBinary, ResourceArc, Term};
use sha2::{Digest, Sha256};
use wasmtime::{Config, Engine, Linker, Module as WasmModule, Store};
use wasmtime_wasi::preview1::{self, WasiP1Ctx};
use wasmtime_wasi::WasiCtxBuilder;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        dynamic,
        static_ = "static",
        timeout,
        fuel_exhausted,
        oom,
        js_error,
        trap,
        timeout_ms,
        fuel,
        max_memory,
        env
    }
}

// ---- Resources ---------------------------------------------------------

pub struct RuntimeResource {
    engine: Engine,
    plugin_module: WasmModule,
    plugin_import_name: String,
}

pub struct PrecompiledResource {
    module: WasmModule,
}

// ---- NIF init ----------------------------------------------------------

fn load(env: Env, _info: Term) -> bool {
    rustler::resource!(RuntimeResource, env);
    rustler::resource!(PrecompiledResource, env);
    true
}

rustler::init!(
    "Elixir.Javex.Native",
    [compile, runtime_new, module_precompile, run],
    load = load
);

// ---- compile -----------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn compile<'a>(
    env: Env<'a>,
    plugin: Binary<'a>,
    source: Binary<'a>,
    mode: Atom,
) -> NifResult<Term<'a>> {
    let mode = decode_mode(mode)?;

    let result = if mode == Mode::Dynamic {
        compile_dynamic(plugin.as_slice(), source.as_slice())
    } else {
        compile_static(source.as_slice())
    };

    match result {
        Ok((wasm, hash)) => {
            let mut wasm_bin = OwnedBinary::new(wasm.len()).unwrap();
            wasm_bin.as_mut_slice().copy_from_slice(&wasm);

            let mut hash_bin = OwnedBinary::new(hash.len()).unwrap();
            hash_bin.as_mut_slice().copy_from_slice(&hash);

            let tuple = (Binary::from_owned(wasm_bin, env), Binary::from_owned(hash_bin, env));
            Ok((atoms::ok(), tuple).encode(env))
        }
        Err(e) => Ok((atoms::error(), format!("{e:#}")).encode(env)),
    }
}

#[derive(PartialEq)]
enum Mode {
    Dynamic,
    Static,
}

fn decode_mode(atom: Atom) -> NifResult<Mode> {
    if atom == atoms::dynamic() {
        Ok(Mode::Dynamic)
    } else if atom == atoms::static_() {
        Ok(Mode::Static)
    } else {
        Err(rustler::Error::BadArg)
    }
}

fn compile_dynamic(plugin: &[u8], source: &[u8]) -> anyhow::Result<(Vec<u8>, Vec<u8>)> {
    use javy_codegen::{Generator, LinkingKind, Plugin};

    let mut generator = Generator::new();
    generator
        .linking(LinkingKind::Dynamic)
        .plugin(Plugin::User {
            bytes: plugin.to_vec(),
        });

    let wasm = generator.generate(source)?;
    let hash = Sha256::digest(plugin).to_vec();
    Ok((wasm, hash))
}

fn compile_static(source: &[u8]) -> anyhow::Result<(Vec<u8>, Vec<u8>)> {
    use javy_codegen::{Generator, LinkingKind, Plugin};

    let mut generator = Generator::new();
    generator
        .linking(LinkingKind::Static)
        .plugin(Plugin::Default);

    let wasm = generator.generate(source)?;
    Ok((wasm, Vec::new()))
}

// ---- runtime_new -------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn runtime_new(env: Env, plugin: Binary) -> NifResult<Term> {
    match build_runtime(plugin.as_slice()) {
        Ok(runtime) => {
            let resource = ResourceArc::new(runtime);
            Ok((atoms::ok(), resource).encode(env))
        }
        Err(e) => Ok((atoms::error(), format!("{e:#}")).encode(env)),
    }
}

fn build_runtime(plugin: &[u8]) -> anyhow::Result<RuntimeResource> {
    let mut config = Config::new();
    config.consume_fuel(true);
    config.epoch_interruption(true);

    let engine = Engine::new(&config)?;
    let plugin_module = WasmModule::from_binary(&engine, plugin)?;
    let plugin_import_name = detect_plugin_name(&plugin_module)?;

    Ok(RuntimeResource {
        engine,
        plugin_module,
        plugin_import_name,
    })
}

/// Discover the canonical module name that dynamic user modules use to
/// import from this plugin. Javy plugins export themselves with a
/// versioned name like `javy_quickjs_provider_v3`. Rather than hardcode
/// a version we read it from the plugin's exports.
fn detect_plugin_name(module: &WasmModule) -> anyhow::Result<String> {
    for export in module.exports() {
        let name = export.name();
        if name.starts_with("javy_quickjs_provider") {
            return Ok(name.to_string());
        }
    }
    // Fall back to the convention used by recent Javy releases.
    Ok("javy_quickjs_provider_v3".to_string())
}

// ---- module_precompile -------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn module_precompile(env: Env, runtime: ResourceArc<RuntimeResource>, wasm: Binary) -> NifResult<Term> {
    match WasmModule::from_binary(&runtime.engine, wasm.as_slice()) {
        Ok(module) => {
            let resource = ResourceArc::new(PrecompiledResource { module });
            Ok((atoms::ok(), resource).encode(env))
        }
        Err(e) => Ok((atoms::error(), format!("{e:#}")).encode(env)),
    }
}

// ---- run ---------------------------------------------------------------

struct RunState {
    wasi: WasiP1Ctx,
}

#[rustler::nif(schedule = "DirtyCpu")]
fn run<'a>(
    env: Env<'a>,
    runtime: ResourceArc<RuntimeResource>,
    precompiled: ResourceArc<PrecompiledResource>,
    input: Binary<'a>,
    opts: Term<'a>,
) -> NifResult<Term<'a>> {
    let opts = RunOpts::decode(opts)?;

    match run_inner(&runtime, &precompiled, input.as_slice(), opts) {
        Ok(stdout) => {
            let mut bin = OwnedBinary::new(stdout.len()).unwrap();
            bin.as_mut_slice().copy_from_slice(&stdout);
            Ok((atoms::ok(), Binary::from_owned(bin, env)).encode(env))
        }
        Err(RunError::Timeout) => Ok((atoms::error(), atoms::timeout()).encode(env)),
        Err(RunError::FuelExhausted) => Ok((atoms::error(), atoms::fuel_exhausted()).encode(env)),
        Err(RunError::Oom) => Ok((atoms::error(), atoms::oom()).encode(env)),
        Err(RunError::JsError(msg)) => {
            Ok((atoms::error(), (atoms::js_error(), msg)).encode(env))
        }
        Err(RunError::Trap(msg)) => Ok((atoms::error(), (atoms::trap(), msg)).encode(env)),
    }
}

#[derive(Default)]
struct RunOpts {
    timeout_ms: Option<u64>,
    fuel: Option<u64>,
    max_memory: Option<u64>,
    env: Vec<(String, String)>,
}

impl RunOpts {
    fn decode(term: Term) -> NifResult<Self> {
        use rustler::MapIterator;

        let mut opts = RunOpts::default();
        if let Ok(iter) = MapIterator::new(term) {
            for (k, v) in iter {
                let key: Atom = k.decode()?;
                if key == atoms::timeout_ms() {
                    opts.timeout_ms = v.decode().ok();
                } else if key == atoms::fuel() {
                    opts.fuel = v.decode().ok();
                } else if key == atoms::max_memory() {
                    opts.max_memory = v.decode().ok();
                } else if key == atoms::env() {
                    if let Ok(list) = v.decode::<Vec<(String, String)>>() {
                        opts.env = list;
                    }
                }
            }
        }
        Ok(opts)
    }
}

#[derive(Debug)]
enum RunError {
    Timeout,
    FuelExhausted,
    Oom,
    JsError(String),
    Trap(String),
}

fn run_inner(
    runtime: &RuntimeResource,
    precompiled: &PrecompiledResource,
    input: &[u8],
    opts: RunOpts,
) -> Result<Vec<u8>, RunError> {
    use wasmtime_wasi::pipe::{MemoryInputPipe, MemoryOutputPipe};

    let stdin = MemoryInputPipe::new(input.to_vec());
    let stdout = MemoryOutputPipe::new(usize::MAX);

    let mut builder = WasiCtxBuilder::new();
    builder.stdin(stdin).stdout(stdout.clone());
    for (k, v) in &opts.env {
        builder.env(k, v);
    }
    let wasi = builder.build_p1();

    let mut store = Store::new(&runtime.engine, RunState { wasi });

    if let Some(fuel) = opts.fuel {
        let _ = store.set_fuel(fuel);
    } else {
        let _ = store.set_fuel(u64::MAX);
    }

    let mut linker: Linker<RunState> = Linker::new(&runtime.engine);
    preview1::add_to_linker_sync(&mut linker, |s: &mut RunState| &mut s.wasi)
        .map_err(|e| RunError::Trap(format!("linker init: {e:#}")))?;

    // Instantiate the plugin and register its exports so the user
    // module's dynamic imports resolve.
    let plugin_instance = linker
        .instantiate(&mut store, &runtime.plugin_module)
        .map_err(|e| RunError::Trap(format!("plugin instantiate: {e:#}")))?;

    for export in runtime.plugin_module.exports() {
        if let Some(ext) = plugin_instance.get_export(&mut store, export.name()) {
            linker
                .define(&mut store, &runtime.plugin_import_name, export.name(), ext)
                .map_err(|e| RunError::Trap(format!("plugin define: {e:#}")))?;
        }
    }

    // Timeout via epoch interruption.
    let epoch_thread = opts.timeout_ms.map(|ms| spawn_epoch_ticker(runtime.engine.clone(), ms));

    let user_instance = linker
        .instantiate(&mut store, &precompiled.module)
        .map_err(|e| classify_trap(e))?;

    let start = user_instance
        .get_typed_func::<(), ()>(&mut store, "_start")
        .map_err(|e| RunError::Trap(format!("missing _start: {e:#}")))?;

    let call_result = start.call(&mut store, ());

    if let Some(handle) = epoch_thread {
        handle.stop();
    }

    call_result.map_err(classify_trap)?;

    drop(store);

    let bytes = stdout
        .try_into_inner()
        .map(|b| b.to_vec())
        .unwrap_or_default();
    Ok(bytes)
}

fn classify_trap(err: anyhow::Error) -> RunError {
    let msg = format!("{err:#}");
    if msg.contains("all fuel consumed") {
        RunError::FuelExhausted
    } else if msg.contains("epoch deadline") || msg.contains("interrupt") {
        RunError::Timeout
    } else if msg.contains("out of memory") || msg.contains("memory limit") {
        RunError::Oom
    } else if msg.contains("JavaScript") || msg.contains("Uncaught") {
        RunError::JsError(msg)
    } else {
        RunError::Trap(msg)
    }
}

struct EpochHandle {
    stop: std::sync::Arc<Mutex<bool>>,
}

impl EpochHandle {
    fn stop(&self) {
        *self.stop.lock().unwrap() = true;
    }
}

fn spawn_epoch_ticker(engine: Engine, timeout_ms: u64) -> EpochHandle {
    let stop = std::sync::Arc::new(Mutex::new(false));
    let stop_clone = stop.clone();

    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(timeout_ms));
        if !*stop_clone.lock().unwrap() {
            engine.increment_epoch();
        }
    });

    EpochHandle { stop }
}

use rustler::Encoder;
