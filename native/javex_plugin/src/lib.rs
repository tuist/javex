//! Javy's standard synchronous environment plus a named JSON hostcall bridge.

use javy_plugin_api::{
    Config, import_namespace,
    javy::{Runtime, quickjs::prelude::Func},
};

import_namespace!("javex-plugin-v1");

#[link(wasm_import_module = "javex_host_v1")]
unsafe extern "C" {
    fn dispatch(ptr: *const u8, len: u32) -> u32;
    fn read_response(ptr: *mut u8, len: u32);
}

fn config() -> Config {
    let mut config = Config::default();
    config
        .text_encoding(true)
        .javy_stream_io(true)
        .simd_json_builtins(true);
    config
}

fn modify_runtime(runtime: Runtime) -> Runtime {
    runtime.context().with(|ctx| {
        ctx.globals()
            .set(
                "__javex_dispatch",
                Func::from(|request: String| {
                    // Request and reply remain in guest memory. The host bounds both
                    // lengths, and a host trap aborts Wasm rather than becoming catchable JS.
                    let length = unsafe { dispatch(request.as_ptr(), request.len() as u32) };
                    let mut response = vec![0; length as usize];
                    unsafe {
                        read_response(response.as_mut_ptr(), length);
                    }
                    String::from_utf8(response).unwrap()
                }),
            )
            .unwrap();
        ctx.eval::<(), _>(include_str!("host.js")).unwrap();
    });
    runtime
}

#[unsafe(export_name = "initialize-runtime")]
pub extern "C" fn initialize_runtime() {
    javy_plugin_api::initialize_runtime(config, modify_runtime).unwrap();
}
