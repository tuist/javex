//! A bounded IPC supervisor and a disposable, OS-restricted execution child.
//! No untrusted Wasm or JavaScript is parsed in the supervisor or the BEAM.

#[cfg(target_os = "linux")]
mod callbacks;
#[cfg(target_os = "linux")]
pub mod compiler;
#[cfg(target_os = "linux")]
mod isolation;
#[cfg(target_os = "linux")]
mod output;
#[cfg(target_os = "linux")]
pub mod sandbox;

#[cfg(target_os = "linux")]
mod process {
    use std::io::{self, Read, Write};
    use std::os::unix::process::ExitStatusExt;
    use std::process::{Command, Stdio};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::{Duration, Instant};

    use crate::{callbacks, compiler, isolation, sandbox};
    use sandbox::{Budgets, CacheOptions, Control};

    const MAX_REQUEST: usize = 64 * 1024 * 1024;
    const MAX_HEADER: usize = 1024 * 1024;

    #[derive(serde::Deserialize)]
    struct Request {
        operation: String,
        limits: Budgets,
    }

    fn read_frame(input: &mut impl Read, remaining: &mut usize) -> anyhow::Result<Vec<u8>> {
        let mut size = [0; 4];
        input.read_exact(&mut size)?;
        let size = u32::from_be_bytes(size) as usize;
        anyhow::ensure!(size <= *remaining, "IPC request limit exceeded");
        *remaining -= size;
        let mut bytes = vec![0; size];
        input.read_exact(&mut bytes)?;
        Ok(bytes)
    }

    fn write_frame(output: &mut impl Write, bytes: &[u8]) -> anyhow::Result<()> {
        output.write_all(&u32::try_from(bytes.len())?.to_be_bytes())?;
        output.write_all(bytes)?;
        Ok(())
    }

    fn request(input: &mut impl Read) -> anyhow::Result<[Vec<u8>; 4]> {
        let mut remaining = MAX_HEADER;
        let header = read_frame(input, &mut remaining)?;
        let mut remaining = MAX_REQUEST - header.len();
        Ok([
            header,
            read_frame(input, &mut remaining)?,
            read_frame(input, &mut remaining)?,
            read_frame(input, &mut remaining)?,
        ])
    }

    fn response(result: Result<Vec<u8>, (&str, String)>, maximum: usize) -> anyhow::Result<()> {
        let (kind, bytes) = match result {
            Ok(bytes) => ("ok", bytes),
            Err((kind, message)) => (kind, message.into_bytes()),
        };
        let (kind, bytes) = if bytes.len() > maximum {
            ("output_limit", b"worker response limit exceeded".to_vec())
        } else {
            (kind, bytes)
        };
        let header = serde_json::to_vec(kind)?;
        let mut output = io::stdout().lock();
        write_frame(&mut output, &header)?;
        write_frame(&mut output, &bytes)?;
        output.flush()?;
        Ok(())
    }

    fn child(parent: u32, memory: u64, timeout: u64, maximum: usize) -> anyhow::Result<()> {
        isolation::prepare(parent, memory, timeout)?;
        // Only trusted engine setup precedes seccomp: the ticker must already exist
        // because creating threads/processes is forbidden once the policy is active.
        sandbox::initialize_engine(true)?;
        let (ready, started) = std::sync::mpsc::sync_channel(0);
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_all()
            .on_thread_start(move || {
                let _ = ready.send(());
            })
            .build()?;
        started.recv()?;
        // Synchronous WASI hostcalls adopt this runtime rather than lazily spawning
        // Wasmtime's global thread pool after clone/clone3 have been forbidden.
        let _guard = runtime.enter();
        isolation::restrict_syscalls()?;
        let [header, plugin, module, input] = request(&mut io::stdin())?;
        let request: Request = serde_json::from_slice(&header)?;
        let control = Control::new(timeout)?;
        let result = match request.operation.as_str() {
            "compile" => compiler::compile(
                &plugin,
                &module,
                request.limits.static_mode,
                &request.limits,
                control,
            )
            .map_err(|error| ("compile_error", format!("{error:#}"))),
            "run" => sandbox::build_runtime(
                &plugin,
                CacheOptions {
                    max_cache_bytes: 0,
                    max_cached_modules: 0,
                },
            )
            .map_err(|error| ("trap", format!("{error:#}")))
            .and_then(|runtime| {
                let maximum = request.limits.max_callback_output.saturating_add(1024);
                let dispatch: callbacks::Dispatch = Box::new(move |bytes| {
                    let mut output = io::stdout().lock();
                    write_frame(&mut output, br#""callback""#)?;
                    write_frame(&mut output, bytes)?;
                    output.flush()?;
                    drop(output);
                    read_frame(&mut io::stdin(), &mut maximum.clone())
                });
                sandbox::run_with_callbacks(
                    &runtime,
                    &module,
                    &input,
                    &request.limits,
                    control,
                    Some(dispatch),
                )
            }),
            _ => Err(("worker_error", "unknown worker operation".into())),
        };
        response(result, maximum)
    }

    fn supervise(memory: u64, timeout: u64, maximum: usize) -> anyhow::Result<i32> {
        let deadline = Instant::now() + Duration::from_millis(timeout);
        let mut input = io::stdin();
        let request = request(&mut input)?;
        let limits: Request = serde_json::from_slice(&request[0])?;
        let max_callback_input = limits.limits.max_callback_input.min(MAX_REQUEST);
        let max_callback_output = limits
            .limits
            .max_callback_output
            .min(MAX_REQUEST)
            .saturating_add(1024);
        let max_callback_calls = limits.limits.max_callback_calls;
        let mut child = Command::new(std::env::current_exe()?)
            .args([
                "--child".to_owned(),
                std::process::id().to_string(),
                memory.to_string(),
                timeout.to_string(),
                maximum.to_string(),
            ])
            .env_clear()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let cancelled = Arc::new(AtomicBool::new(false));
        let signal = cancelled.clone();
        let mut child_input = child.stdin.take().unwrap();
        std::thread::spawn(move || {
            let result = request
                .iter()
                .try_for_each(|bytes| write_frame(&mut child_input, bytes))
                .and_then(|_| child_input.flush().map_err(Into::into));
            if result.is_ok() {
                // Only explicit reply frames can reach the restricted child.
                // Cancellation, EOF, malformed/oversized replies all kill it.
                loop {
                    let mut command = [0];
                    if input.read_exact(&mut command).is_err() || command[0] != 2 {
                        break;
                    }
                    let Ok(bytes) = read_frame(&mut input, &mut max_callback_output.clone()) else {
                        break;
                    };
                    if write_frame(&mut child_input, &bytes).is_err()
                        || child_input.flush().is_err()
                    {
                        break;
                    }
                }
            }
            signal.store(true, Ordering::Release);
        });
        let overflow = Arc::new(AtomicBool::new(false));
        let signal = overflow.clone();
        let mut output = child.stdout.take().unwrap();
        let reader = std::thread::spawn(move || {
            // Validate and bound each frame before forwarding callback requests.
            // Final results are withheld until the child exits successfully.
            let result = (|| -> anyhow::Result<Vec<u8>> {
                let mut calls = 0;
                loop {
                    let header = read_frame(&mut output, &mut 4096)?;
                    let kind: String = serde_json::from_slice(&header)?;
                    let callback = kind == "callback";
                    let limit = if callback {
                        max_callback_input
                    } else {
                        maximum
                    };
                    let bytes = read_frame(&mut output, &mut limit.clone())?;
                    if callback {
                        calls += 1;
                        anyhow::ensure!(
                            calls <= max_callback_calls,
                            "callback call limit exceeded"
                        );
                        let mut host = io::stdout().lock();
                        write_frame(&mut host, &header)?;
                        write_frame(&mut host, &bytes)?;
                        host.flush()?;
                    } else {
                        let mut final_result = Vec::new();
                        write_frame(&mut final_result, &header)?;
                        write_frame(&mut final_result, &bytes)?;
                        // Bound even trailing garbage from a compromised child.
                        anyhow::ensure!(output.read(&mut [0])? == 0, "trailing worker output");
                        return Ok(final_result);
                    }
                }
            })();
            signal.store(result.is_err(), Ordering::Release);
            result
        });
        let status = loop {
            if let Some(status) = child.try_wait()? {
                break status.code().unwrap_or(128 + status.signal().unwrap_or(0));
            }
            let reason = if cancelled.load(Ordering::Acquire) {
                Some(125)
            } else if overflow.load(Ordering::Acquire) {
                Some(126)
            } else if Instant::now() >= deadline {
                Some(124)
            } else {
                None
            };
            if let Some(reason) = reason {
                let _ = child.kill();
                child.wait()?;
                break reason;
            }
            std::thread::sleep(Duration::from_millis(2));
        };
        if status == 0 {
            let bytes = reader
                .join()
                .map_err(|_| anyhow::anyhow!("IPC reader failed"))??;
            io::stdout().write_all(&bytes)?;
        }
        Ok(status)
    }

    pub fn main() -> anyhow::Result<i32> {
        let args: Vec<String> = std::env::args().collect();
        let child_mode = args.get(1).map(String::as_str) == Some("--child");
        let offset = if child_mode { 3 } else { 2 };
        let memory: u64 = args
            .get(offset)
            .ok_or_else(|| anyhow::anyhow!("memory required"))?
            .parse()?;
        let timeout: u64 = args
            .get(offset + 1)
            .ok_or_else(|| anyhow::anyhow!("timeout required"))?
            .parse()?;
        let maximum: usize = args
            .get(offset + 2)
            .ok_or_else(|| anyhow::anyhow!("response limit required"))?
            .parse()?;
        anyhow::ensure!(
            memory > 0 && memory <= i64::MAX as u64 && timeout > 0 && timeout <= i32::MAX as u64,
            "invalid process budget"
        );
        anyhow::ensure!(maximum <= MAX_REQUEST, "IPC response limit exceeded");
        if child_mode {
            child(args[2].parse()?, memory, timeout, maximum)?;
            Ok(0)
        } else {
            anyhow::ensure!(
                args.get(1).map(String::as_str) == Some("--supervise"),
                "invalid operation"
            );
            supervise(memory, timeout, maximum)
        }
    }
}

fn main() {
    #[cfg(target_os = "linux")]
    let status = process::main().unwrap_or(127);
    #[cfg(not(target_os = "linux"))]
    let status = 127;
    std::process::exit(status);
}
