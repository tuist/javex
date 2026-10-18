//! Compile QuickJS bytecode inside the same bounded sandbox as execution.
//! The wrapper follows Javy's documented provider ABI. Static modules embed the
//! already-initialized provider; no unbounded Wizer or native wasm-opt pass runs.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use crate::sandbox::{Budgets, CacheOptions, Control, Runtime, Sandbox, build_runtime};
use sha2::{Digest, Sha256};
use walrus::{DataKind, ExportItem, FunctionBuilder, ValType};

struct CompilerPermit;
static COMPILING: AtomicUsize = AtomicUsize::new(0);

impl Drop for CompilerPermit {
    fn drop(&mut self) {
        COMPILING.fetch_sub(1, Ordering::AcqRel);
    }
}

struct Provider {
    hash: [u8; 32],
    runtime: Arc<Runtime>,
}

fn provider(bytes: &[u8]) -> anyhow::Result<Arc<Runtime>> {
    // Keep at most one compiler provider; custom providers cannot grow a global cache.
    static PROVIDER: OnceLock<Mutex<Option<Provider>>> = OnceLock::new();
    let hash = Sha256::digest(bytes).into();
    let mut cached = PROVIDER.get_or_init(|| Mutex::new(None)).lock().unwrap();
    if let Some(provider) = cached.as_ref().filter(|provider| provider.hash == hash) {
        return Ok(provider.runtime.clone());
    }
    let runtime = Arc::new(build_runtime(
        bytes,
        CacheOptions {
            max_cache_bytes: 0,
            max_cached_modules: 0,
        },
    )?);
    *cached = Some(Provider {
        hash,
        runtime: runtime.clone(),
    });
    Ok(runtime)
}

pub fn compile(
    plugin: &[u8],
    source: &[u8],
    static_mode: bool,
    opts: &Budgets,
    control: Control,
) -> anyhow::Result<Vec<u8>> {
    anyhow::ensure!(
        source.len() <= opts.max_input && source.len() <= u32::MAX as usize,
        "source limit exceeded"
    );
    std::str::from_utf8(source)?;
    COMPILING
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
            (count < 16).then_some(count + 1)
        })
        .map_err(|_| anyhow::anyhow!("compiler busy"))?;
    let _permit = CompilerPermit;
    control.check()?;
    let runtime = provider(plugin)?;
    let mut sandbox = Sandbox::new(&runtime.engine, &[], opts, control.clone())?;
    let result = (|| -> anyhow::Result<Vec<u8>> {
        let linker = Sandbox::linker(&runtime.engine)?;
        let instance = linker.instantiate(&mut sandbox.store, &runtime.plugin)?;
        let memory = instance
            .get_memory(&mut sandbox.store, "memory")
            .ok_or_else(|| anyhow::anyhow!("provider has no exported memory"))?;
        let realloc = instance
            .get_typed_func::<(u32, u32, u32, u32), u32>(&mut sandbox.store, "cabi_realloc")?;
        let ptr = realloc.call(&mut sandbox.store, (0, 0, 1, source.len() as u32))?;
        memory.write(&mut sandbox.store, ptr as usize, source)?;
        let compile =
            instance.get_typed_func::<(u32, u32), u32>(&mut sandbox.store, "compile-src")?;
        let ptr = compile.call(&mut sandbox.store, (ptr, source.len() as u32))?;
        let mut record = [0u8; 12];
        memory.read(&sandbox.store, ptr as usize, &mut record)?;
        let tag = u32::from_le_bytes(record[0..4].try_into()?);
        let ptr = u32::from_le_bytes(record[4..8].try_into()?) as usize;
        let len = u32::from_le_bytes(record[8..12].try_into()?) as usize;
        let limit = if tag == 0 {
            opts.max_module
        } else {
            opts.max_stderr
        };
        anyhow::ensure!(len <= limit, "compiler result limit exceeded");
        let mut payload = vec![0; len];
        memory.read(&sandbox.store, ptr, &mut payload)?;
        anyhow::ensure!(tag == 0, "{}", String::from_utf8_lossy(&payload));
        Ok(payload)
    })();
    let bytecode = sandbox
        .finish(result)
        .map_err(|(_, message)| anyhow::anyhow!(message))?;
    control.check()?;
    let wasm = wrapper(plugin, &runtime.namespace, bytecode, static_mode)?;
    anyhow::ensure!(wasm.len() <= opts.max_module, "Wasm module limit exceeded");
    control.check()?;
    Ok(wasm)
}

fn wrapper(
    plugin: &[u8],
    namespace: &str,
    bytecode: Vec<u8>,
    static_mode: bool,
) -> anyhow::Result<Vec<u8>> {
    let config = walrus::ModuleConfig::new();
    let mut module = if static_mode {
        config.parse(plugin)?
    } else {
        walrus::Module::with_config(config)
    };
    let (realloc, invoke, memory) = if static_mode {
        let realloc = module.exports.get_func("cabi_realloc")?;
        let invoke = module.exports.get_func("invoke")?;
        let memory = match module
            .exports
            .iter()
            .find(|export| export.name == "memory")
            .map(|export| export.item)
        {
            Some(ExportItem::Memory(memory)) => memory,
            _ => anyhow::bail!("provider has no exported memory"),
        };
        let old_start = module
            .exports
            .iter()
            .find(|export| export.name == "_start")
            .map(|export| export.id());
        if let Some(start) = old_start {
            module.exports.delete(start);
        }
        (realloc, invoke, memory)
    } else {
        let realloc_type = module.types.add(&[ValType::I32; 4], &[ValType::I32]);
        let (realloc, _) = module.add_import_func(namespace, "cabi_realloc", realloc_type);
        let invoke_type = module.types.add(&[ValType::I32; 5], &[]);
        let (invoke, _) = module.add_import_func(namespace, "invoke", invoke_type);
        let (memory, _) =
            module.add_import_memory(namespace, "memory", false, false, 0, None, None);
        (realloc, invoke, memory)
    };
    let len = i32::try_from(bytecode.len())?;
    let data = module.data.add(DataKind::Passive, bytecode);
    let ptr = module.locals.add(ValType::I32);
    let mut start = FunctionBuilder::new(&mut module.types, &[], &[]);
    start
        .func_body()
        .i32_const(0)
        .i32_const(0)
        .i32_const(1)
        .i32_const(len)
        .call(realloc)
        .local_tee(ptr)
        .i32_const(0)
        .i32_const(len)
        .memory_init(memory, data)
        .local_get(ptr)
        .i32_const(len)
        .i32_const(0)
        .i32_const(0)
        .i32_const(0)
        .call(invoke);
    let start = start.finish(vec![], &mut module.funcs);
    module.exports.add("_start", start);
    Ok(module.emit_wasm())
}
