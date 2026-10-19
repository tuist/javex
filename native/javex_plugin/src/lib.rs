//! Javy's provider ABI plus a resumable, versioned callback protocol.
//! No host capabilities are embedded in this snapshot.

use std::alloc::{Layout, alloc, dealloc};
use std::cell::RefCell;
use std::slice;

use javy::quickjs::{Function, Module, Persistent, Promise, Value};
use javy::{Config, Runtime, from_js_error};

thread_local! {
    static RUNTIME: Runtime = {
        let mut config = Config::default();
        config.text_encoding(true).javy_stream_io(true);
        Runtime::new(config).unwrap()
    };
    static ROOT: RefCell<Option<Persistent<Promise<'static>>>> = const { RefCell::new(None) };
    static BRIDGE: RefCell<Option<Persistent<Function<'static>>>> = const { RefCell::new(None) };
    static OUTPUT: RefCell<Vec<u8>> = const { RefCell::new(Vec::new()) };
    static RECORD: RefCell<[u32; 3]> = const { RefCell::new([0; 3]) };
}

// The namespace identifies bytecode/provider compatibility, not authorization.
#[unsafe(link_section = "import_namespace")]
#[used]
static NAMESPACE: [u8; 15] = *b"javex-plugin-v1";

fn checked<T>(result: anyhow::Result<T>) -> T {
    result.unwrap_or_else(|error| {
        eprintln!("{error:#}");
        std::process::abort()
    })
}

fn output(tag: u32, bytes: Vec<u8>) -> *const u32 {
    OUTPUT.with(|out| {
        *out.borrow_mut() = bytes;
        let out = out.borrow();
        RECORD.with(|record| {
            *record.borrow_mut() = [tag, out.as_ptr() as u32, out.len() as u32];
            record.as_ptr().cast()
        })
    })
}

#[unsafe(export_name = "initialize-runtime")]
pub extern "C" fn initialize() {
    RUNTIME.with(|_| {});
}

#[unsafe(export_name = "cabi_realloc")]
/// # Safety
/// `ptr` must be zero or an allocation of `old` bytes with the given alignment
/// returned by this function. The host must not use the old allocation again.
pub unsafe extern "C" fn realloc(ptr: *mut u8, old: usize, align: usize, size: usize) -> *mut u8 {
    if size == 0 {
        if old != 0 {
            unsafe { dealloc(ptr, Layout::from_size_align(old, align).unwrap()) };
        }
        return align as *mut u8;
    }
    let new = unsafe { alloc(Layout::from_size_align(size, align).unwrap()) };
    if new.is_null() {
        std::process::abort();
    }
    if old != 0 {
        unsafe {
            std::ptr::copy_nonoverlapping(ptr, new, old.min(size));
            dealloc(ptr, Layout::from_size_align(old, align).unwrap());
        }
    }
    new
}

#[unsafe(export_name = "compile-src")]
/// # Safety
/// `ptr..ptr+len` must refer to readable bytes in this instance's memory.
pub unsafe extern "C" fn compile(ptr: *const u8, len: usize) -> *const u32 {
    let source = unsafe { slice::from_raw_parts(ptr, len) };
    let result =
        RUNTIME.with(|rt| rt.compile_to_bytecode("function.mjs", std::str::from_utf8(source)?));
    match result {
        Ok(bytes) => output(0, bytes),
        Err(error) => output(1, error.to_string().into_bytes()),
    }
}

#[unsafe(export_name = "invoke")]
/// # Safety
/// `ptr..ptr+len` must contain bytecode produced by this provider. Invocation
/// requires a configured bridge and may only happen once per fresh instance.
pub unsafe extern "C" fn invoke(ptr: *const u8, len: usize, named: u32, _: u32, _: u32) {
    assert_eq!(named, 0, "Javex supports root module evaluation only");
    checked(RUNTIME.with(|rt| {
        rt.context()
            .with(|ctx| {
                let (_, root) =
                    unsafe { Module::load(ctx.clone(), slice::from_raw_parts(ptr, len))? }
                        .eval()?;
                ROOT.with(|slot| *slot.borrow_mut() = Some(Persistent::save(&ctx, root)));
                Ok(())
            })
            .map_err(|error| rt.context().with(|ctx| from_js_error(ctx, error)))
    }));
}

#[unsafe(export_name = "javex-configure-v1")]
pub extern "C" fn configure(calls: u32, concurrent: u32, input: u32) {
    checked(RUNTIME.with(|rt| {
        rt.context()
            .with(|ctx| {
                let factory: Function = ctx.eval(include_str!("bridge.js"))?;
                let bridge: Function = factory.call((calls, concurrent, input))?;
                BRIDGE.with(|slot| *slot.borrow_mut() = Some(Persistent::save(&ctx, bridge)));
                Ok(())
            })
            .map_err(|error| rt.context().with(|ctx| from_js_error(ctx, error)))
    }));
}

#[unsafe(export_name = "javex-step-v1")]
/// # Safety
/// `ptr..ptr+len` must contain readable UTF-8 completion JSON. Calls must be
/// serialized with all other calls using this instance's QuickJS context.
pub unsafe extern "C" fn step(ptr: *const u8, len: usize) -> *const u32 {
    let result = RUNTIME.with(|rt| -> anyhow::Result<Vec<u8>> {
        // Deliver completions before running their Promise reactions.
        let completions = std::str::from_utf8(unsafe { slice::from_raw_parts(ptr, len) })?;
        rt.context()
            .with(|ctx| {
                let bridge = BRIDGE.with(|slot| slot.borrow().as_ref().unwrap().clone());
                bridge.restore(&ctx)?.call::<_, ()>((completions, 0))
            })
            .map_err(|error| rt.context().with(|ctx| from_js_error(ctx, error)))?;
        rt.context()
            .with(|ctx| {
                let root = ROOT.with(|slot| slot.borrow().clone());
                let Some(root) = root else {
                    return Ok(String::from(
                        "{\"done\":true,\"fatal\":false,\"requests\":[]}",
                    ));
                };
                let root = root.restore(&ctx)?;
                let mut rejection = None;
                let done = loop {
                    match root.result::<Value>() {
                        Some(Ok(_)) => break true,
                        Some(Err(error)) => {
                            rejection = Some(error);
                            break true;
                        }
                        None if !ctx.execute_pending_job() => break false,
                        None => {}
                    }
                };
                let bridge = BRIDGE.with(|slot| slot.borrow().as_ref().unwrap().clone());
                let state = bridge
                    .restore(&ctx)?
                    .call::<_, String>(("[]", if done { 2 } else { 1 }))?;
                let fatal =
                    serde_json::from_str::<serde_json::Value>(&state).unwrap()["fatal"] == true;
                if !fatal && let Some(error) = rejection {
                    return Err(error);
                }
                Ok(state)
            })
            .map(String::into_bytes)
            .map_err(|error| rt.context().with(|ctx| from_js_error(ctx, error)))
    });
    match result {
        Ok(bytes) => output(0, bytes),
        Err(error) => output(1, error.to_string().into_bytes()),
    }
}
