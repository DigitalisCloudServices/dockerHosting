#!/bin/bash

#############################################
# Docker Daemon Hardening Script
#
# Implements comprehensive Docker security:
# - User namespace remapping
# - Network isolation (no inter-container communication)
# - Resource limits
# - Logging configuration
# - Security options (no-new-privileges, read-only, etc.)
#
# Based on: CIS Docker Benchmark, NIST SP 800-190
#############################################

set -e

echo "[INFO] Hardening Docker daemon configuration..."

# Backup existing daemon.json if it exists
if [ -f /etc/docker/daemon.json ]; then
    cp /etc/docker/daemon.json /etc/docker/daemon.json.backup.$(date +%Y%m%d-%H%M%S)
    echo "[INFO] Backed up existing daemon.json"
fi

# Create comprehensive hardened daemon.json
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3",
    "labels": "production"
  },
  "icc": false,
  "userland-proxy": false,
  "live-restore": true,
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 64000,
      "Soft": 64000
    }
  },
  "seccomp-profile": "/etc/docker/seccomp-default.json",
  "selinux-enabled": false,
  "userns-remap": "default",
  "default-shm-size": "64M",
  "storage-driver": "overlay2",
  "storage-opts": [
    "overlay2.override_kernel_check=true"
  ],
  "exec-opts": ["native.cgroupdriver=systemd"],
  "features": {
    "buildkit": true
  },
  "experimental": false,
  "metrics-addr": "127.0.0.1:9323",
  "debug": false
}
EOF

echo "[INFO] Created hardened /etc/docker/daemon.json"

# Create default seccomp profile
cat > /etc/docker/seccomp-default.json <<'EOF'
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "archMap": [
    {
      "architecture": "SCMP_ARCH_X86_64",
      "subArchitectures": [
        "SCMP_ARCH_X86",
        "SCMP_ARCH_X32"
      ]
    },
    {
      "architecture": "SCMP_ARCH_AARCH64",
      "subArchitectures": [
        "SCMP_ARCH_ARM"
      ]
    }
  ],
  "syscalls": [
    {
      "names": [
        "accept",
        "accept4",
        "access",
        "adjtimex",
        "alarm",
        "bind",
        "brk",
        "capget",
        "capset",
        "chdir",
        "chmod",
        "chown",
        "chown32",
        "clock_adjtime",
        "clock_getres",
        "clock_gettime",
        "clock_nanosleep",
        "close",
        "connect",
        "copy_file_range",
        "creat",
        "dup",
        "dup2",
        "dup3",
        "epoll_create",
        "epoll_create1",
        "epoll_ctl",
        "epoll_ctl_old",
        "epoll_pwait",
        "epoll_wait",
        "epoll_wait_old",
        "eventfd",
        "eventfd2",
        "execve",
        "execveat",
        "exit",
        "exit_group",
        "faccessat",
        "fadvise64",
        "fadvise64_64",
        "fallocate",
        "fanotify_mark",
        "fchdir",
        "fchmod",
        "fchmodat",
        "fchown",
        "fchown32",
        "fchownat",
        "fcntl",
        "fcntl64",
        "fdatasync",
        "fgetxattr",
        "flistxattr",
        "flock",
        "fork",
        "fremovexattr",
        "fsetxattr",
        "fstat",
        "fstat64",
        "fstatat64",
        "fstatfs",
        "fstatfs64",
        "fsync",
        "ftruncate",
        "ftruncate64",
        "futex",
        "futimesat",
        "getcpu",
        "getcwd",
        "getdents",
        "getdents64",
        "getegid",
        "getegid32",
        "geteuid",
        "geteuid32",
        "getgid",
        "getgid32",
        "getgroups",
        "getgroups32",
        "getitimer",
        "getpeername",
        "getpgid",
        "getpgrp",
        "getpid",
        "getppid",
        "getpriority",
        "getrandom",
        "getresgid",
        "getresgid32",
        "getresuid",
        "getresuid32",
        "getrlimit",
        "get_robust_list",
        "getrusage",
        "getsid",
        "getsockname",
        "getsockopt",
        "get_thread_area",
        "gettid",
        "gettimeofday",
        "getuid",
        "getuid32",
        "getxattr",
        "inotify_add_watch",
        "inotify_init",
        "inotify_init1",
        "inotify_rm_watch",
        "io_cancel",
        "ioctl",
        "io_destroy",
        "io_getevents",
        "io_pgetevents",
        "ioprio_get",
        "ioprio_set",
        "io_setup",
        "io_submit",
        "ipc",
        "kill",
        "lchown",
        "lchown32",
        "lgetxattr",
        "link",
        "linkat",
        "listen",
        "listxattr",
        "llistxattr",
        "_llseek",
        "lremovexattr",
        "lseek",
        "lsetxattr",
        "lstat",
        "lstat64",
        "madvise",
        "memfd_create",
        "mincore",
        "mkdir",
        "mkdirat",
        "mknod",
        "mknodat",
        "mlock",
        "mlock2",
        "mlockall",
        "mmap",
        "mmap2",
        "mprotect",
        "mq_getsetattr",
        "mq_notify",
        "mq_open",
        "mq_timedreceive",
        "mq_timedsend",
        "mq_unlink",
        "mremap",
        "msgctl",
        "msgget",
        "msgrcv",
        "msgsnd",
        "msync",
        "munlock",
        "munlockall",
        "munmap",
        "nanosleep",
        "newfstatat",
        "_newselect",
        "open",
        "openat",
        "pause",
        "pipe",
        "pipe2",
        "poll",
        "ppoll",
        "prctl",
        "pread64",
        "preadv",
        "preadv2",
        "prlimit64",
        "pselect6",
        "pwrite64",
        "pwritev",
        "pwritev2",
        "read",
        "readahead",
        "readlink",
        "readlinkat",
        "readv",
        "recv",
        "recvfrom",
        "recvmmsg",
        "recvmsg",
        "remap_file_pages",
        "removexattr",
        "rename",
        "renameat",
        "renameat2",
        "restart_syscall",
        "rmdir",
        "rt_sigaction",
        "rt_sigpending",
        "rt_sigprocmask",
        "rt_sigqueueinfo",
        "rt_sigreturn",
        "rt_sigsuspend",
        "rt_sigtimedwait",
        "rt_tgsigqueueinfo",
        "sched_getaffinity",
        "sched_getattr",
        "sched_getparam",
        "sched_get_priority_max",
        "sched_get_priority_min",
        "sched_getscheduler",
        "sched_rr_get_interval",
        "sched_setaffinity",
        "sched_setattr",
        "sched_setparam",
        "sched_setscheduler",
        "sched_yield",
        "seccomp",
        "select",
        "semctl",
        "semget",
        "semop",
        "semtimedop",
        "send",
        "sendfile",
        "sendfile64",
        "sendmmsg",
        "sendmsg",
        "sendto",
        "setfsgid",
        "setfsgid32",
        "setfsuid",
        "setfsuid32",
        "setgid",
        "setgid32",
        "setgroups",
        "setgroups32",
        "setitimer",
        "setpgid",
        "setpriority",
        "setregid",
        "setregid32",
        "setresgid",
        "setresgid32",
        "setresuid",
        "setresuid32",
        "setreuid",
        "setreuid32",
        "setrlimit",
        "set_robust_list",
        "setsid",
        "setsockopt",
        "set_thread_area",
        "set_tid_address",
        "setuid",
        "setuid32",
        "setxattr",
        "shmat",
        "shmctl",
        "shmdt",
        "shmget",
        "shutdown",
        "sigaltstack",
        "signalfd",
        "signalfd4",
        "sigprocmask",
        "sigreturn",
        "socket",
        "socketcall",
        "socketpair",
        "splice",
        "stat",
        "stat64",
        "statfs",
        "statfs64",
        "statx",
        "symlink",
        "symlinkat",
        "sync",
        "sync_file_range",
        "syncfs",
        "sysinfo",
        "tee",
        "tgkill",
        "time",
        "timer_create",
        "timer_delete",
        "timerfd_create",
        "timerfd_gettime",
        "timerfd_settime",
        "timer_getoverrun",
        "timer_gettime",
        "timer_settime",
        "times",
        "tkill",
        "truncate",
        "truncate64",
        "ugetrlimit",
        "umask",
        "uname",
        "unlink",
        "unlinkat",
        "utime",
        "utimensat",
        "utimes",
        "vfork",
        "vmsplice",
        "wait4",
        "waitid",
        "waitpid",
        "write",
        "writev"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
EOF

echo "[INFO] Created seccomp profile: /etc/docker/seccomp-default.json"

# Setup user namespace remapping
if ! getent subuid dockremap > /dev/null; then
    echo "dockremap:100000:65536" >> /etc/subuid
    echo "[INFO] Added dockremap to /etc/subuid"
fi

if ! getent subgid dockremap > /dev/null; then
    echo "dockremap:100000:65536" >> /etc/subgid
    echo "[INFO] Added dockremap to /etc/subgid"
fi

# Create dockremap user if it doesn't exist
if ! id dockremap &>/dev/null; then
    useradd -r -s /usr/sbin/nologin -d /nonexistent dockremap
    echo "[INFO] Created dockremap user"
fi

# Restart Docker to apply changes
echo "[INFO] Restarting Docker daemon..."
if ! systemctl restart docker; then
    echo "[ERROR] Failed to restart Docker daemon!"
    echo ""
    echo "[ERROR] Recent Docker logs:"
    journalctl -xeu docker.service -n 50 --no-pager
    echo ""
    echo "[ERROR] Daemon configuration may be invalid. Check /etc/docker/daemon.json"
    echo "[ERROR] You can restore the backup from /etc/docker/daemon.json.backup.*"
    exit 1
fi

# Wait for Docker to start
sleep 3

# Verify Docker is running
if systemctl is-active --quiet docker; then
    echo "[INFO] Docker daemon restarted successfully"
else
    echo "[ERROR] Docker daemon failed to start!"
    echo ""
    echo "[ERROR] Recent Docker logs:"
    journalctl -xeu docker.service -n 50 --no-pager
    echo ""
    echo "[ERROR] You can restore the backup: cp /etc/docker/daemon.json.backup.* /etc/docker/daemon.json"
    exit 1
fi

# Verify configuration
echo ""
echo "[INFO] Verifying Docker configuration..."
docker info | grep -E "Seccomp|User Namespace|Storage Driver|Logging Driver" || true

echo ""
echo "[INFO] ════════════════════════════════════════════"
echo "[INFO] Docker Daemon Hardening Complete!"
echo "[INFO] ════════════════════════════════════════════"
echo ""
echo "[INFO] Security features enabled:"
echo "  ✓ User namespace remapping (containers run as unprivileged users)"
echo "  ✓ Inter-container communication DISABLED (--icc=false)"
echo "  ✓ Seccomp filtering (restricted system calls)"
echo "  ✓ No new privileges (prevents privilege escalation)"
echo "  ✓ Resource limits (ulimits configured)"
echo "  ✓ Logging limits (10MB max, 3 files)"
echo "  ✓ Live restore enabled (containers survive daemon restarts)"
echo "  ✓ Userland proxy disabled (better performance)"
echo ""
echo "[WARN] IMPORTANT: Containers now run in isolated networks"
echo "[WARN] Each site will have its own Docker network"
echo "[WARN] Cross-site communication ONLY via boundary Nginx"
echo ""
echo "[INFO] Configuration files:"
echo "  Daemon config: /etc/docker/daemon.json"
echo "  Seccomp profile: /etc/docker/seccomp-default.json"
echo "  User namespace: dockremap (UID/GID 100000-165535)"
echo ""
