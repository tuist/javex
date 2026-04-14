// Javex NIF
//
// Bridges Elixir <-> Javy (JS -> Wasm) and wasmtime (Wasm execution).

use std::sync::{Arc, Mutex};
use std::time::Duration;

use rustler::{Atom, Binary, Encoder, Env, NifResult, OwnedBinary, ResourceArc, Term};
use sha2::{Digest, Sha256};
use wasmtime::{AsContextMut, Config, Engine, Linker, Module as WasmModule, OptLevel, Store};
use wasmtime_wasi::WasiCtxBuilder;
use wasmtime_wasi::p1::{self, WasiP1Ctx};
use wasmtime_wasi::p2::pipe::{MemoryInputPipe, MemoryOutputPipe};

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
    import_namespace: String,
}

pub struct PrecompiledResource {
    module: WasmModule,
}

#[rustler::resource_impl]
impl rustler::Resource for RuntimeResource {}

#[rustler::resource_impl]
impl rustler::Resource for PrecompiledResource {}

// ---- NIF init ----------------------------------------------------------

rustler::init!("Elixir.Javex.Native");

// ---- compile -----------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn compile<'a>(
    env: Env<'a>,
    plugin: Binary<'a>,
    source: Binary<'a>,
    mode: Atom,
) -> NifResult<Term<'a>> {
    let mode = decode_mode(mode)?;

    let source_bytes = source.as_slice().to_vec();
    let plugin_bytes = plugin.as_slice().to_vec();

    let result = match mode {
        Mode::Dynamic => compile_dynamic(plugin_bytes, source_bytes),
        Mode::Static => compile_static(source_bytes),
    };

    match result {
        Ok((wasm, hash)) => {
            let mut wasm_bin = OwnedBinary::new(wasm.len()).unwrap();
            wasm_bin.as_mut_slice().copy_from_slice(&wasm);

            let mut hash_bin = OwnedBinary::new(hash.len()).unwrap();
            hash_bin.as_mut_slice().copy_from_slice(&hash);

            let tuple = (
                Binary::from_owned(wasm_bin, env),
                Binary::from_owned(hash_bin, env),
            );
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

fn compile_dynamic(plugin_bytes: Vec<u8>, source: Vec<u8>) -> anyhow::Result<(Vec<u8>, Vec<u8>)> {
    use javy_codegen::{Generator, JS, LinkingKind, Plugin};

    let source_str = String::from_utf8(source)?;
    let js = JS::from_string(source_str);

    let plugin = Plugin::new(plugin_bytes.clone().into())?;
    let mut generator = Generator::new(plugin);
    generator.linking(LinkingKind::Dynamic);

    let wasm = block_on(generator.generate(&js))?;
    let hash = Sha256::digest(&plugin_bytes).to_vec();
    Ok((wasm, hash))
}

fn compile_static(source: Vec<u8>) -> anyhow::Result<(Vec<u8>, Vec<u8>)> {
    use javy_codegen::{Generator, JS, LinkingKind, Plugin};

    let source_str = String::from_utf8(source)?;
    let js = JS::from_string(source_str);

    let plugin = Plugin::default();
    let mut generator = Generator::new(plugin);
    generator.linking(LinkingKind::Static);

    let wasm = block_on(generator.generate(&js))?;
    Ok((wasm, Vec::new()))
}

fn block_on<F: std::future::Future>(fut: F) -> F::Output {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("tokio runtime");
    rt.block_on(fut)
}

// ---- runtime_new -------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn runtime_new<'a>(env: Env<'a>, plugin: Binary<'a>) -> NifResult<Term<'a>> {
    match build_runtime(plugin.as_slice().to_vec()) {
        Ok(runtime) => {
            let resource = ResourceArc::new(runtime);
            Ok((atoms::ok(), resource).encode(env))
        }
        Err(e) => Ok((atoms::error(), format!("{e:#}")).encode(env)),
    }
}

fn build_runtime(plugin_bytes: Vec<u8>) -> anyhow::Result<RuntimeResource> {
    let mut config = Config::new();
    config.cranelift_opt_level(OptLevel::SpeedAndSize);
    config.consume_fuel(true);
    config.epoch_interruption(true);

    let engine = Engine::new(&config)?;
    let plugin_module = WasmModule::from_binary(&engine, &plugin_bytes)?;
    let import_namespace = detect_import_namespace(&plugin_bytes)?;

    Ok(RuntimeResource {
        engine,
        plugin_module,
        import_namespace,
    })
}

fn detect_import_namespace(plugin_bytes: &[u8]) -> anyhow::Result<String> {
    use wasmparser::{Parser, Payload};

    for payload in Parser::new(0).parse_all(plugin_bytes) {
        if let Ok(Payload::CustomSection(c)) = payload
            && c.name() == "import_namespace"
        {
            return Ok(std::str::from_utf8(c.data())?.to_string());
        }
    }
    anyhow::bail!("plugin is missing `import_namespace` custom section")
}

// ---- module_precompile -------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn module_precompile<'a>(
    env: Env<'a>,
    runtime: ResourceArc<RuntimeResource>,
    wasm: Binary<'a>,
) -> NifResult<Term<'a>> {
    match WasmModule::from_binary(&runtime.engine, wasm.as_slice()) {
        Ok(module) => {
            let resource = ResourceArc::new(PrecompiledResource { module });
            Ok((atoms::ok(), resource).encode(env))
        }
        Err(e) => Ok((atoms::error(), format!("{e:#}")).encode(env)),
    }
}

// ---- run ---------------------------------------------------------------

struct StoreContext {
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
        Err(RunError::JsError(msg)) => Ok((atoms::error(), (atoms::js_error(), msg)).encode(env)),
        Err(RunError::Trap(msg)) => Ok((atoms::error(), (atoms::trap(), msg)).encode(env)),
    }
}

#[derive(Default)]
struct RunOpts {
    timeout_ms: Option<u64>,
    fuel: Option<u64>,
    _max_memory: Option<u64>,
    env: Vec<(String, String)>,
}

impl RunOpts {
    fn decode(term: Term) -> NifResult<Self> {
        let env = term.get_env();
        let mut opts = RunOpts::default();

        if let Ok(v) = term.map_get(atoms::timeout_ms().to_term(env)) {
            opts.timeout_ms = v.decode::<u64>().ok();
        }
        if let Ok(v) = term.map_get(atoms::fuel().to_term(env)) {
            opts.fuel = v.decode::<u64>().ok();
        }
        if let Ok(v) = term.map_get(atoms::max_memory().to_term(env)) {
            opts._max_memory = v.decode::<u64>().ok();
        }
        if let Ok(v) = term.map_get(atoms::env().to_term(env))
            && let Ok(list) = v.decode::<Vec<(String, String)>>()
        {
            opts.env = list;
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
    let stdin = MemoryInputPipe::new(input.to_vec());
    let stdout = MemoryOutputPipe::new(usize::MAX);

    let mut builder = WasiCtxBuilder::new();
    builder.stdin(stdin).stdout(stdout.clone());
    for (k, v) in &opts.env {
        builder.env(k, v);
    }
    let wasi = builder.build_p1();

    let ctx = StoreContext { wasi };
    let mut store: Store<StoreContext> = Store::new(&runtime.engine, ctx);

    if let Some(fuel) = opts.fuel {
        store
            .set_fuel(fuel)
            .map_err(|e| RunError::Trap(format!("set_fuel: {e:#}")))?;
    } else {
        store
            .set_fuel(u64::MAX)
            .map_err(|e| RunError::Trap(format!("set_fuel: {e:#}")))?;
    }

    if opts.timeout_ms.is_some() {
        store.set_epoch_deadline(1);
    }

    let mut linker: Linker<StoreContext> = Linker::new(&runtime.engine);
    p1::add_to_linker_sync(&mut linker, |c: &mut StoreContext| &mut c.wasi)
        .map_err(|e| RunError::Trap(format!("linker init: {e:#}")))?;

    // Instantiate the plugin against the linker, then register its
    // instance under the plugin's import namespace so the user module's
    // dynamic imports resolve.
    linker.allow_shadowing(true);
    let plugin_instance = linker
        .instantiate(store.as_context_mut(), &runtime.plugin_module)
        .map_err(|e| RunError::Trap(format!("plugin instantiate: {e:#}")))?;
    linker
        .instance(
            store.as_context_mut(),
            &runtime.import_namespace,
            plugin_instance,
        )
        .map_err(|e| RunError::Trap(format!("plugin register: {e:#}")))?;

    let epoch_handle = opts
        .timeout_ms
        .map(|ms| spawn_epoch_ticker(runtime.engine.clone(), ms));

    let instance = linker
        .instantiate(store.as_context_mut(), &precompiled.module)
        .map_err(classify_trap)?;

    let start = instance
        .get_typed_func::<(), ()>(store.as_context_mut(), "_start")
        .map_err(|e| RunError::Trap(format!("missing _start: {e:#}")))?;

    let call_result = start.call(store.as_context_mut(), ());

    if let Some(handle) = epoch_handle {
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

fn classify_trap<E: std::fmt::Display>(err: E) -> RunError {
    let msg = format!("{err}");
    if msg.contains("all fuel consumed") {
        RunError::FuelExhausted
    } else if msg.contains("epoch deadline") || msg.contains("interrupt") {
        RunError::Timeout
    } else if msg.contains("out of memory") || msg.contains("memory limit") {
        RunError::Oom
    } else if msg.contains("Uncaught") || msg.contains("JavaScript") {
        RunError::JsError(msg)
    } else {
        RunError::Trap(msg)
    }
}

struct EpochHandle {
    stop: Arc<Mutex<bool>>,
}

impl EpochHandle {
    fn stop(&self) {
        *self.stop.lock().unwrap() = true;
    }
}

fn spawn_epoch_ticker(engine: Engine, timeout_ms: u64) -> EpochHandle {
    let stop = Arc::new(Mutex::new(false));
    let stop_clone = stop.clone();

    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(timeout_ms));
        if !*stop_clone.lock().unwrap() {
            engine.increment_epoch();
        }
    });

    EpochHandle { stop }
}
