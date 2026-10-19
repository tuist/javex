;; Rebuild: wasm-tools parse test/fixtures/callback_probe.wat -o test/fixtures/callback_probe.wasm
;; Forge resumable provider states from stdin, bypassing all guest JS checks.
(module
  (import "wasi_snapshot_preview1" "fd_read"
    (func $read (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (func (export "javex-configure-v1") (param i32 i32 i32))
  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
    (i32.const 32768))
  (func (export "_start")
    (i32.store (i32.const 0) (i32.const 4096))
    (i32.store (i32.const 4) (i32.const 8192))
    (drop (call $read (i32.const 0) (i32.const 0) (i32.const 1) (i32.const 136)))
    (i32.store (i32.const 132) (i32.const 4096)))
  (func (export "javex-step-v1") (param i32 i32) (result i32)
    (i32.const 128)))
