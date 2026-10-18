//! Execution core shared by the NIF and the process-isolated worker.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use crate::output::Output;
use rustler::NifMap;
use sha2::{Digest, Sha256};
use wasmtime::{
    Config, Engine, Linker, Module, ResourceLimiter, Store, StoreLimits, StoreLimitsBuilder, Trap,
    UpdateDeadline,
};
use wasmtime_wasi::WasiCtxBuilder;
use wasmtime_wasi::p1::{self, WasiP1Ctx};
use wasmtime_wasi::p2::pipe::MemoryInputPipe;

pub struct Runtime {
    pub(crate) engine: Engine,
    pub(crate) plugin: Module,
    pub(crate) namespace: String,
    cache: Mutex<Cache>,
}

#[derive(Clone)]
pub struct Control {
    deadline: Instant,
    cancelled: Arc<AtomicBool>,
}

impl Control {
    pub fn new(timeout_ms: u64) -> anyhow::Result<Self> {
        let deadline = Instant::now()
            .checked_add(Duration::from_millis(timeout_ms))
            .filter(|_| timeout_ms > 0)
            .ok_or_else(|| anyhow::anyhow!("invalid timeout"))?;
        Ok(Self {
            deadline,
            cancelled: Arc::new(AtomicBool::new(false)),
        })
    }

    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }

    pub fn check(&self) -> anyhow::Result<()> {
        anyhow::ensure!(!self.cancelled.load(Ordering::Acquire), "cancelled");
        anyhow::ensure!(Instant::now() < self.deadline, "execution timed out");
        Ok(())
    }
}

// All stores use monotonic deadlines, not an engine-global "next tick" deadline.
// A single clock thread lives for the loaded NIF's lifetime, regardless of call count.
pub fn initialize_engine(isolated: bool) -> anyhow::Result<Engine> {
    static ENGINE: OnceLock<Result<Engine, String>> = OnceLock::new();
    ENGINE
        .get_or_init(|| {
            let mut config = Config::new();
            config.consume_fuel(true).epoch_interruption(true);
            config.wasm_memory64(false).wasm_multi_memory(false);
            if isolated {
                // Avoid Wasmtime's multi-GiB virtual reservations under RLIMIT_AS.
                config
                    .memory_reservation(0)
                    .memory_reservation_for_growth(0)
                    .memory_guard_size(64 * 1024)
                    // Anonymous memory only: no memfd-backed CoW allocations
                    // outside the process's virtual address-space accounting.
                    .memory_init_cow(false);
            }
            let engine = Engine::new(&config).map_err(|e| e.to_string())?;
            let clock = engine.clone();
            let (ready, started) = std::sync::mpsc::sync_channel(0);
            std::thread::Builder::new()
                .name("javex-epoch".into())
                .spawn(move || {
                    if ready.send(()).is_err() {
                        return;
                    }
                    loop {
                        std::thread::sleep(Duration::from_millis(1));
                        clock.increment_epoch();
                    }
                })
                .map_err(|e| e.to_string())?;
            // pthread/rseq initialization must finish before a worker installs TSYNC.
            started.recv().map_err(|e| e.to_string())?;
            Ok(engine)
        })
        .clone()
        .map_err(anyhow::Error::msg)
}

#[derive(NifMap)]
pub struct CacheOptions {
    pub max_cache_bytes: usize,
    pub max_cached_modules: usize,
}

struct Cache {
    entries: VecDeque<([u8; 32], Module, usize)>,
    bytes: usize,
    hits: u64,
    limits: CacheOptions,
}

impl Cache {
    fn get(&mut self, key: &[u8; 32]) -> Option<Module> {
        let index = self.entries.iter().position(|entry| &entry.0 == key)?;
        let entry = self.entries.remove(index).unwrap();
        let module = entry.1.clone();
        self.entries.push_back(entry);
        self.hits += 1;
        Some(module)
    }

    fn insert(&mut self, key: [u8; 32], module: Module) {
        let image = module.image_range();
        let size = image.end as usize - image.start as usize;
        if size > self.limits.max_cache_bytes || self.limits.max_cached_modules == 0 {
            return;
        }
        if self.entries.iter().any(|entry| entry.0 == key) {
            return;
        }
        while self.entries.len() >= self.limits.max_cached_modules
            || size > self.limits.max_cache_bytes - self.bytes
        {
            let (_, _, evicted_size) = self.entries.pop_front().unwrap();
            self.bytes -= evicted_size;
        }
        self.bytes += size;
        self.entries.push_back((key, module, size));
    }
}

#[derive(NifMap)]
pub struct CacheStats {
    cached_modules: usize,
    cache_bytes: usize,
    cache_hits: u64,
}

impl Runtime {
    pub fn stats(&self) -> CacheStats {
        let cache = self.cache.lock().unwrap();
        CacheStats {
            cached_modules: cache.entries.len(),
            cache_bytes: cache.bytes,
            cache_hits: cache.hits,
        }
    }
}

pub fn build_runtime(bytes: &[u8], limits: CacheOptions) -> anyhow::Result<Runtime> {
    anyhow::ensure!(bytes.len() <= 8 * 1024 * 1024, "provider exceeds 8 MiB");
    let engine = initialize_engine(false)?;
    let plugin = Module::from_binary(&engine, bytes)?;
    let namespace = wasmparser::Parser::new(0)
        .parse_all(bytes)
        .find_map(|section| match section {
            Ok(wasmparser::Payload::CustomSection(section))
                if section.name() == "import_namespace" =>
            {
                Some(std::str::from_utf8(section.data()).map(str::to_owned))
            }
            _ => None,
        })
        .ok_or_else(|| anyhow::anyhow!("plugin is missing import_namespace"))??;
    Ok(Runtime {
        engine,
        plugin,
        namespace,
        cache: Mutex::new(Cache {
            entries: VecDeque::new(),
            bytes: 0,
            hits: 0,
            limits,
        }),
    })
}

#[derive(NifMap, serde::Deserialize)]
pub struct Budgets {
    pub fuel: u64,
    pub max_memory: usize,
    pub max_input: usize,
    pub max_output: usize,
    pub max_stderr: usize,
    pub max_module: usize,
    pub env: Vec<(String, String)>,
    pub static_mode: bool,
}

struct Limiter {
    limits: StoreLimits,
    memory_bytes: usize,
    max_memory: usize,
    exceeded: bool,
}

impl ResourceLimiter for Limiter {
    fn memory_growing(
        &mut self,
        current: usize,
        desired: usize,
        maximum: Option<usize>,
    ) -> wasmtime::Result<bool> {
        let growth = desired.saturating_sub(current);
        if growth > self.max_memory - self.memory_bytes {
            self.exceeded = true;
            return Err(wasmtime::Error::msg("guest memory limit exceeded"));
        }
        let result = self.limits.memory_growing(current, desired, maximum);
        self.exceeded |= !matches!(result, Ok(true));
        if matches!(result, Ok(true)) {
            self.memory_bytes += growth;
        }
        result
    }
    fn table_growing(
        &mut self,
        current: usize,
        desired: usize,
        maximum: Option<usize>,
    ) -> wasmtime::Result<bool> {
        let result = self.limits.table_growing(current, desired, maximum);
        self.exceeded |= !matches!(result, Ok(true));
        result
    }
    fn instances(&self) -> usize {
        2
    }
    fn memories(&self) -> usize {
        2
    }
    fn tables(&self) -> usize {
        2
    }
}

pub(crate) struct StoreContext {
    wasi: WasiP1Ctx,
    limiter: Limiter,
}

pub(crate) struct Sandbox {
    pub(crate) store: Store<StoreContext>,
    stdout: Output,
    stderr: Output,
    control: Control,
}

impl Sandbox {
    pub(crate) fn new(
        engine: &Engine,
        input: &[u8],
        opts: &Budgets,
        control: Control,
    ) -> anyhow::Result<Self> {
        anyhow::ensure!(
            opts.max_memory > 0 && opts.max_input > 0 && opts.max_module > 0,
            "invalid budget"
        );
        control.check()?;
        let stdout = Output::new(opts.max_output);
        let stderr = Output::new(opts.max_stderr);
        let mut wasi = WasiCtxBuilder::new();
        wasi.stdin(MemoryInputPipe::new(input.to_vec()))
            .stdout(stdout.clone())
            .stderr(stderr.clone());
        for (key, value) in &opts.env {
            wasi.env(key, value);
        }
        let ctx = StoreContext {
            wasi: wasi.build_p1(),
            limiter: Limiter {
                limits: StoreLimitsBuilder::new()
                    .memory_size(opts.max_memory)
                    .table_elements(100_000)
                    .trap_on_grow_failure(true)
                    .build(),
                memory_bytes: 0,
                max_memory: opts.max_memory,
                exceeded: false,
            },
        };
        let mut store = Store::new(engine, ctx);
        store.limiter(|state| &mut state.limiter);
        store.set_fuel(opts.fuel)?;
        store.set_epoch_deadline(1);
        let deadline = control.clone();
        store.epoch_deadline_callback(move |_| {
            deadline.check().map_err(wasmtime::Error::from_anyhow)?;
            Ok(UpdateDeadline::Continue(1))
        });
        Ok(Self {
            store,
            stdout,
            stderr,
            control,
        })
    }

    pub(crate) fn linker(engine: &Engine) -> anyhow::Result<Linker<StoreContext>> {
        let mut linker = Linker::new(engine);
        p1::add_to_linker_sync(&mut linker, |state: &mut StoreContext| &mut state.wasi)?;
        Ok(linker)
    }

    pub(crate) fn finish<T>(&self, result: anyhow::Result<T>) -> Result<T, (&'static str, String)> {
        if self.control.cancelled.load(Ordering::Acquire) {
            return Err(("cancelled", "execution cancelled".into()));
        }
        if Instant::now() >= self.control.deadline {
            return Err(("timeout", "execution timed out".into()));
        }
        if self.store.data().limiter.exceeded {
            return Err(("oom", "guest memory or table limit exceeded".into()));
        }
        if self.stdout.exceeded() {
            return Err(("output_limit", "stdout limit exceeded".into()));
        }
        if self.stderr.exceeded() {
            return Err(("diagnostic_limit", "stderr limit exceeded".into()));
        }
        result.map_err(|error| {
            if matches!(error.downcast_ref::<Trap>(), Some(Trap::OutOfFuel)) {
                return ("fuel_exhausted", "fuel exhausted".into());
            }
            let diagnostics = String::from_utf8_lossy(&self.stderr.contents()).into_owned();
            if !diagnostics.is_empty()
                && matches!(
                    error.downcast_ref::<Trap>(),
                    Some(Trap::UnreachableCodeReached)
                )
            {
                ("js_error", diagnostics)
            } else {
                ("trap", format!("{error:#}"))
            }
        })
    }
}

pub fn run(
    runtime: &Runtime,
    wasm: &[u8],
    input: &[u8],
    opts: &Budgets,
    control: Control,
) -> Result<Vec<u8>, (&'static str, String)> {
    if input.len() > opts.max_input {
        return Err(("input_limit", "input limit exceeded".into()));
    }
    if wasm.len() > opts.max_module {
        return Err(("module_limit", "Wasm module limit exceeded".into()));
    }
    let mut sandbox = Sandbox::new(&runtime.engine, input, opts, control.clone())
        .map_err(|error| ("trap", error.to_string()))?;
    let result = (|| -> anyhow::Result<()> {
        control.check()?;
        let key: [u8; 32] = Sha256::digest(wasm).into();
        let cached = runtime.cache.lock().unwrap().get(&key);
        let module = match cached {
            Some(module) => module,
            None => {
                let module = Module::from_binary(&runtime.engine, wasm)?;
                // Cache compilation even if execution or JSON decoding subsequently fails.
                runtime.cache.lock().unwrap().insert(key, module.clone());
                module
            }
        };
        control.check()?;
        let mut linker = Sandbox::linker(&runtime.engine)?;
        if !opts.static_mode {
            let plugin = linker.instantiate(&mut sandbox.store, &runtime.plugin)?;
            linker.instance(&mut sandbox.store, &runtime.namespace, plugin)?;
        }
        let instance = linker.instantiate(&mut sandbox.store, &module)?;
        instance
            .get_typed_func::<(), ()>(&mut sandbox.store, "_start")?
            .call(&mut sandbox.store, ())?;
        Ok(())
    })();
    sandbox.finish(result)?;
    Ok(sandbox.stdout.contents())
}
