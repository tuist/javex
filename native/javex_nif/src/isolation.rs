//! Linux process policy. Applied before parsing any supplied Wasm or JavaScript.

use std::io;

fn limit(resource: libc::__rlimit_resource_t, value: u64) -> anyhow::Result<()> {
    let limit = libc::rlimit {
        rlim_cur: value,
        rlim_max: value,
    };
    // SAFETY: limit points to a valid rlimit; no borrowed pointer is retained.
    anyhow::ensure!(
        unsafe { libc::setrlimit(resource, &limit) } == 0,
        "setrlimit: {}",
        io::Error::last_os_error()
    );
    Ok(())
}

pub fn prepare(parent: u32, memory: u64, timeout_ms: u64) -> anyhow::Result<()> {
    // The parent PID is supplied by the supervisor, not inferred after an orphaning race.
    // SAFETY: prctl's integer arguments do not reference Rust memory.
    unsafe {
        anyhow::ensure!(
            libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) == 0
                && libc::getppid() == parent as libc::pid_t,
            "supervisor is unavailable"
        );
        anyhow::ensure!(
            libc::prctl(libc::PR_SET_DUMPABLE, 0) == 0
                && libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == 0,
            "cannot drop process privileges"
        );
        anyhow::ensure!(
            libc::syscall(libc::SYS_close_range, 3u32, u32::MAX, 0u32) == 0,
            "close_range is required: {}",
            io::Error::last_os_error()
        );
    }
    limit(libc::RLIMIT_AS, memory)?;
    limit(libc::RLIMIT_CPU, timeout_ms.div_ceil(1000) + 1)?;
    limit(libc::RLIMIT_NOFILE, 64)?;
    limit(libc::RLIMIT_CORE, 0)?;
    limit(libc::RLIMIT_FSIZE, memory)?;
    Ok(())
}

fn instruction(code: u16, jt: u8, jf: u8, k: u32) -> libc::sock_filter {
    libc::sock_filter { code, jt, jf, k }
}

pub fn restrict_syscalls() -> anyhow::Result<()> {
    // Check the syscall ABI too: another ABI must not bypass the allowlist.
    #[cfg(target_arch = "x86_64")]
    const ARCH: u32 = 0xc000_003e;
    #[cfg(target_arch = "aarch64")]
    const ARCH: u32 = 0xc000_00b7;
    const LOAD: u16 = (libc::BPF_LD | libc::BPF_W | libc::BPF_ABS) as u16;
    const EQUAL: u16 = (libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K) as u16;
    const RETURN: u16 = (libc::BPF_RET | libc::BPF_K) as u16;
    const DENY: u32 = libc::SECCOMP_RET_ERRNO | libc::EPERM as u32;

    let mut filter = vec![
        instruction(LOAD, 0, 0, 4), // seccomp_data.arch
        instruction(EQUAL, 1, 0, ARCH),
        instruction(RETURN, 0, 0, libc::SECCOMP_RET_KILL_PROCESS),
        instruction(LOAD, 0, 0, 0), // seccomp_data.nr
    ];
    let allowed = [
        libc::SYS_read,
        libc::SYS_write,
        libc::SYS_readv,
        libc::SYS_writev,
        libc::SYS_close,
        libc::SYS_fstat,
        libc::SYS_lseek,
        libc::SYS_mmap,
        libc::SYS_mprotect,
        libc::SYS_munmap,
        libc::SYS_mremap,
        libc::SYS_brk,
        libc::SYS_madvise,
        libc::SYS_futex,
        libc::SYS_clock_gettime,
        libc::SYS_clock_nanosleep,
        libc::SYS_nanosleep,
        libc::SYS_getrandom,
        libc::SYS_sched_yield,
        libc::SYS_sched_getaffinity,
        libc::SYS_rt_sigaction,
        libc::SYS_rt_sigprocmask,
        libc::SYS_rt_sigreturn,
        libc::SYS_sigaltstack,
        libc::SYS_getpid,
        libc::SYS_gettid,
        libc::SYS_getrlimit,
        libc::SYS_exit,
        libc::SYS_exit_group,
        libc::SYS_membarrier,
        libc::SYS_epoll_create1,
        libc::SYS_epoll_ctl,
        libc::SYS_epoll_pwait,
        #[cfg(target_arch = "x86_64")]
        libc::SYS_epoll_wait,
        libc::SYS_eventfd2,
        libc::SYS_pipe2,
    ];
    for syscall in allowed {
        filter.push(instruction(EQUAL, 0, 1, syscall as u32));
        filter.push(instruction(RETURN, 0, 0, libc::SECCOMP_RET_ALLOW));
    }
    // libc abort re-raises fatal signals with tgkill. Permit only our own
    // thread group; the kernel checks TID membership.
    filter.extend([
        instruction(EQUAL, 0, 4, libc::SYS_tgkill as u32),
        instruction(LOAD, 0, 0, 16), // seccomp_data.args[0], low word
        instruction(EQUAL, 1, 0, std::process::id()),
        instruction(RETURN, 0, 0, DENY),
        instruction(RETURN, 0, 0, libc::SECCOMP_RET_ALLOW),
    ]);
    // F_SETOWN/F_SETSIG could signal another same-UID process. Only descriptor
    // and status operations are allowed; memfds and file-backed CoW are disabled.
    filter.push(instruction(EQUAL, 1, 0, libc::SYS_fcntl as u32));
    filter.push(instruction(RETURN, 0, 0, DENY));
    filter.push(instruction(LOAD, 0, 0, 24)); // seccomp_data.args[1], low word
    for command in [
        libc::F_GETFD,
        libc::F_SETFD,
        libc::F_GETFL,
        libc::F_SETFL,
        libc::F_DUPFD_CLOEXEC,
    ] {
        filter.push(instruction(EQUAL, 0, 1, command as u32));
        filter.push(instruction(RETURN, 0, 0, libc::SECCOMP_RET_ALLOW));
    }
    filter.push(instruction(RETURN, 0, 0, DENY));
    let program = libc::sock_fprog {
        len: filter.len().try_into()?,
        filter: filter.as_mut_ptr(),
    };
    // SAFETY: the kernel copies the valid BPF array during this syscall. TSYNC
    // applies the policy to the existing epoch-clock thread as well as this thread.
    let result = unsafe {
        libc::syscall(
            libc::SYS_seccomp,
            libc::SECCOMP_SET_MODE_FILTER,
            libc::SECCOMP_FILTER_FLAG_TSYNC,
            &program,
        )
    };
    anyhow::ensure!(result == 0, "seccomp TSYNC: {}", io::Error::last_os_error());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;
    use std::sync::{Arc, Barrier};

    #[test]
    fn enforces_os_boundary_in_every_thread() {
        const FLAG: &str = "JAVEX_TEST_OS_BOUNDARY";
        if std::env::var_os(FLAG).is_none() {
            let status = Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "isolation::tests::enforces_os_boundary_in_every_thread",
                ])
                .env_clear()
                .env(FLAG, "1")
                .status()
                .unwrap();
            assert!(status.success(), "isolated policy probe failed: {status}");
            return;
        }

        let barrier = Arc::new(Barrier::new(2));
        let probe = barrier.clone();
        let thread = std::thread::spawn(move || {
            probe.wait();
            probe.wait();
            // This existing thread must receive the filter through TSYNC too.
            // SAFETY: socket has no pointer arguments; a failed call creates no fd.
            assert_denied(unsafe { libc::socket(libc::AF_INET, libc::SOCK_STREAM, 0) } as i64);
        });
        barrier.wait();
        // SAFETY: getppid takes no arguments.
        prepare(unsafe { libc::getppid() } as u32, 512 * 1024 * 1024, 5000).unwrap();
        restrict_syscalls().unwrap();
        barrier.wait();
        thread.join().unwrap();

        // SAFETY: the strings are valid C strings. Invalid/empty arguments make
        // these probes harmless even if a regression accidentally allows a call.
        unsafe {
            assert_denied(libc::open(c"/etc/passwd".as_ptr(), libc::O_RDONLY) as i64);
            assert_denied(libc::socket(libc::AF_INET6, libc::SOCK_DGRAM, 0) as i64);
            assert_denied(libc::kill(libc::getppid(), 0) as i64);
            assert_denied(libc::syscall(
                libc::SYS_tgkill,
                libc::getppid(),
                libc::getppid(),
                0,
            ));
            assert_eq!(
                libc::syscall(
                    libc::SYS_tgkill,
                    libc::getpid(),
                    libc::syscall(libc::SYS_gettid),
                    0
                ),
                0
            );
            assert_denied(libc::fcntl(0, libc::F_SETOWN, 0) as i64);
            assert_denied(libc::syscall(libc::SYS_clone3, 0, 0));
            assert_denied(libc::syscall(libc::SYS_io_uring_setup, 0, 0));
            assert_denied(libc::syscall(libc::SYS_memfd_create, c"probe".as_ptr(), 0));
            assert_denied(libc::ftruncate(-1, 0) as i64);
            assert_denied(libc::syscall(libc::SYS_process_vm_readv, 0, 0, 0, 0, 0, 0));
            assert_denied(libc::syscall(libc::SYS_prlimit64, 0, libc::RLIMIT_AS, 0, 0));
            assert_denied(libc::syscall(
                libc::SYS_execve,
                c"/nonexistent".as_ptr(),
                0,
                0,
            ));
            let mut limits = libc::rlimit {
                rlim_cur: 0,
                rlim_max: 0,
            };
            // glibc's getrlimit wrapper uses prlimit64, which we deliberately deny.
            assert_eq!(
                libc::syscall(libc::SYS_getrlimit, libc::RLIMIT_AS, &mut limits),
                0
            );
            assert_eq!(limits.rlim_cur, 512 * 1024 * 1024);
            assert_eq!(limits.rlim_max, 512 * 1024 * 1024);
            let address = libc::mmap(
                std::ptr::null_mut(),
                1024 * 1024 * 1024,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_PRIVATE | libc::MAP_ANONYMOUS,
                -1,
                0,
            );
            assert_eq!(address, libc::MAP_FAILED);
            assert_eq!(
                io::Error::last_os_error().raw_os_error(),
                Some(libc::ENOMEM)
            );
            for fd in 3..64 {
                assert_eq!(libc::fcntl(fd, libc::F_GETFD), -1);
                assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::EBADF));
            }
        }
        // Avoid test-harness cleanup that may itself require forbidden syscalls.
        std::process::exit(0);
    }

    fn assert_denied(result: i64) {
        assert_eq!(result, -1);
        assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::EPERM));
    }
}
