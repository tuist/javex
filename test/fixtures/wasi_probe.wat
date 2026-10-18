;; Rebuild: wasm-tools parse test/fixtures/wasi_probe.wat -o test/fixtures/wasi_probe.wasm
;; Return [preopen errno, socket errno, environment count] through stdout.
;; WASI preview1 errno BADF is 8. Descriptor 3 must not be preopened.
(module
  (import "wasi_snapshot_preview1" "fd_prestat_get"
    (func $prestat (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "sock_accept"
    (func $accept (param i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "environ_sizes_get"
    (func $environment (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_write"
    (func $write (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 16)
  (data (i32.const 32) "[0,0,0]")
  (func (export "_start")
    (i32.store8 (i32.const 33)
      (i32.add (call $prestat (i32.const 3) (i32.const 8)) (i32.const 48)))
    (i32.store8 (i32.const 35)
      (i32.add (call $accept (i32.const 3) (i32.const 0) (i32.const 16)) (i32.const 48)))
    (drop (call $environment (i32.const 0) (i32.const 4)))
    (i32.store8 (i32.const 37) (i32.add (i32.load (i32.const 0)) (i32.const 48)))
    (i32.store (i32.const 64) (i32.const 32))
    (i32.store (i32.const 68) (i32.const 7))
    (drop (call $write (i32.const 1) (i32.const 64) (i32.const 1) (i32.const 72)))))
