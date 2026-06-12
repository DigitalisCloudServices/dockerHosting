# Container Compatibility Gaps

These are known issues when running dockerHosting setup scripts inside a container
(e.g. A devhost DinD environment).  Each item describes the behaviour,
the impact, and the preferred fix.

## GH-001 — setup.sh aborts on `systemctl start docker` in containers without systemd

**Script:** `scripts/install-docker.sh`
**Lines:** ~78–83 (the `systemctl daemon-reload / start docker / enable docker` block)

**Behaviour:**  
When systemd is not available as PID 1 (e.g. a plain DinD container), these calls
exit non-zero and `setup.sh` (which runs with `set -e`) aborts immediately. All
subsequent hardening steps are skipped.

**Current workaround:**  
Run systemd inside the container (`debian:trixie` + `/lib/systemd/systemd` as PID 1
+ cgroup mount) so the calls succeed for real.

**Preferred fix:**  
Guard the three `systemctl` calls with a container-detection check:
```bash
if _is_systemd_active; then
  systemctl daemon-reload
  systemctl enable docker
  systemctl start docker
else
  log_note "systemd not active — start Docker daemon manually"
fi
```
Where `_is_systemd_active` checks `[ -d /run/systemd/system ]`.

---

## GH-002 — configure-firewall.sh uses `systemd-run` for SSH session detach

**Script:** `scripts/configure-firewall.sh`

**Behaviour:**  
UFW activation is wrapped in `systemd-run` to detach from the SSH session and
avoid a self-disconnect.  Without systemd this fails silently or errors.

**Current workaround:**  
Running full systemd (GH-001 fix) also resolves this.

**Preferred fix:**  
Same container-detection guard: if `_is_systemd_active` is false, run the UFW
commands inline (no detach needed — there is no SSH session to protect in a
container).

---

## GH-003 — Kernel hardening sysctl calls silently fail in unprivileged containers

**Script:** `scripts/harden-kernel.sh`

**Behaviour:**  
`sysctl -w` calls may fail in containers that lack `CAP_SYS_ADMIN` or where the
host kernel has already locked those parameters.  With a `--privileged` container
these succeed; without `--privileged` they are silently ignored or error.

**Current workaround:**  
`--privileged` devhost container covers this.

**Preferred fix:**  
Wrap each `sysctl -w` with a `|| log_warn "sysctl $key not settable (container?)"` so
partial application does not fail the whole step.
