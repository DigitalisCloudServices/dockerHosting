# CIS Benchmark — Debian Linux (Level 1 & Level 2)

## Overview

The CIS Benchmarks are prescriptive hardening guidelines published by the Center for Internet Security. The Debian Linux benchmark provides two profiles:

- **Level 1**: Baseline security recommendations with minimal operational impact. Broadly applicable to any production system.
- **Level 2**: Stronger security posture for environments where security takes priority. Some controls may affect performance or restrict certain functionality.

The benchmark covers six sections: OS initial setup, Services, Network configuration, Logging and auditing, Access/authentication/authorisation, and System maintenance.

## Why It's Relevant

CIS Benchmarks are widely referenced across ISO 27001, PCI DSS, NIST, SOC 2, and vendor security questionnaires. `lynis` scoring and many automated assessment tools use the CIS Linux Benchmark as their primary reference. Demonstrable Level 1 alignment is a reasonable proxy for "well-hardened" in most commercial security assessments.

## Executive Summary

**Level 1: ~85% (known) ~ ~88% (assumed) | Level 2: ~63% (known) ~ ~65% (assumed)**

The narrow range reflects that most CIS Linux controls are host OS configuration verifiable by these scripts. The gap between known and assumed is primarily container egress (Section 3) — uncontrolled at host level but assumed mitigated by platform/network-level controls pending deployment validation.

The OS hardening scripts provide strong Level 1 coverage. The multi-layer perimeter (Cloudflare → Edge FW → ModSecurity → Host) substantially exceeds the benchmark's network security intent. Administrative access via VPN/bastion with MFA satisfies the benchmark's access control intent at the correct architectural layer.

Level 2 gaps are primarily USB/removable media blacklisting — low risk in VM deployments where physical media access is datacenter-controlled. Docker container egress is uncontrolled at the host level (G1); platform and network-level external controls are assumed to provide an outer layer pending deployment-specific validation.

---

## Scope

### In Scope

All CIS Debian controls addressable via OS-level scripts:
- sysctl parameters and kernel hardening
- SSH configuration
- PAM configuration (password policy, lockout, account controls)
- UFW firewall rules
- auditd rules and log management
- unattended-upgrades
- chrony NTP
- AppArmor profiles
- AIDE file integrity monitoring
- Shared memory hardening
- GRUB bootloader (optional)

### Out of Scope

| Area | Reason |
|---|---|
| Physical security controls | Datacenter responsibility |
| Wireless network controls | Not applicable — server deployment, no wireless interfaces |
| User awareness and training | Policy/organisational |
| Patch evidence collection | Operational process; tooling exists (`apt`, lynis) |
| CIS-CAT scoring | Requires CIS tooling subscription |

---

## External Controls

| Control | Provider | CIS Section |
|---|---|---|
| DDoS + web-layer attack mitigation | Cloudflare | Section 3 (Network) — supplements UFW |
| Application-layer WAF | ModSecurity (DMZ) | Section 3 (Network) — web application controls |
| Remote log storage | NewRelic | Section 4 (Logging) — off-host log retention |
| MFA at access boundary | VPN / SSH bastion | Section 5 (Access) — MFA before SSH is reachable |
| Block device encryption | VM hypervisor | Section 1 (OS setup) — encryption at rest |

---

## Control Assessment

### Level 1

#### Section 1 — OS Initial Setup

| Area | Coverage | Implementation |
|---|---|---|
| Filesystem configuration (shared memory, tmp) | ✓ | `/dev/shm` mounted `noexec,nodev,nosuid` — `harden-shared-memory.sh` |
| Software and patch management | ✓ | `unattended-upgrades` daily — `setup-auto-updates.sh` |
| Mandatory access control | ✓ | AppArmor enabled; docker-default profile on all containers — `setup-apparmor.sh` |
| File integrity monitoring | ✓ | AIDE initialised and daily cron check — `setup-aide.sh` |
| Cryptographic policy | ✓ | TLS 1.2/1.3 at Traefik; strong AEAD ciphers only in SSH |

**Estimated Section 1 coverage: ~90%**

#### Section 2 — Services

| Area | Coverage | Implementation |
|---|---|---|
| Unnecessary services | ✓ | Docker-only model; no Apache, MySQL, FTP on host |
| Time synchronisation | ✓ | chrony with ≥2 agreeing pool sources — `setup-ntp.sh` |
| X Window System absent | ✓ | Server-only deployment |

**Estimated Section 2 coverage: ~88%**

#### Section 3 — Network Configuration

| Area | Coverage | Implementation |
|---|---|---|
| Network parameters (kernel sysctl) | ✓ | ASLR, SYN cookies, IPv6 controls, ICMP, source routing — `harden-kernel.sh` |
| Host-level firewall | ✓ | UFW default-deny inbound + egress allow-list — `configure-firewall.sh` |
| Docker container egress | ~ | Docker bypasses UFW at host level; platform-level and network-level egress controls (Edge Firewall, VM network policy, data centre controls) are assumed to be in place — **validate per deployment**; host-level control tracked as [gaps.md](gaps.md) G1 |

**Estimated Section 3 coverage: ~92%** (strong; container egress uncontrolled at host level — assumed mitigated by platform/network controls, validate per deployment)

#### Section 4 — Logging and Auditing

| Area | Coverage | Implementation |
|---|---|---|
| auditd configuration | ✓ | 28+ rules covering auth, privilege escalation, filesystem, network, Docker — `setup-audit.sh` |
| Immutable audit rules | ✓ | `-e 2` flag; requires reboot to modify |
| Log rotation | ✓ | logrotate with defined retention — `setup-logrotate.sh` |
| Remote log shipping | ✓ | NewRelic infrastructure agent — off-host, tamper-evident from host perspective |
| Real-time file integrity monitoring | ~ | AIDE is daily batch; real-time FIM absent — see [gaps.md](gaps.md) |

**Estimated Section 4 coverage: ~92%**

#### Section 5 — Access, Authentication, and Authorisation

| Area | Coverage | Implementation |
|---|---|---|
| SSH configuration | ✓ | Key-only, no root, strong AEAD ciphers, no forwarding — `harden-ssh.sh` |
| PAM password policy | ✓ | 14-char minimum, complexity, 5-password history, lockout — `setup-pam-policy.sh` |
| Account lockout | ✓ | pam_faillock: 5 attempts → 15-min ban |
| SSH brute-force prevention | ✓ | fail2ban with progressive bans — `setup-fail2ban-enhanced.sh` |
| Least-privilege sudo | ✓ | No docker group; per-command sudoers allow-list — `setup-docker-permissions.sh` |
| MFA | ✓ (at access layer) | MFA enforced at VPN/bastion before SSH is reachable; host TOTP available as optional defence-in-depth |

**Estimated Section 5 coverage: ~90%**

#### Section 6 — System Maintenance

| Area | Coverage | Implementation |
|---|---|---|
| Security patches | ✓ | `unattended-upgrades` applies security patches daily |
| Container image patching | ✓ | Trivy blocks deployment on CRITICAL CVEs; blue/green CI/CD pipeline |

**Estimated Section 6 coverage: ~78%** (patching solid; automated rebuild and evidence collection are the gaps)

---

### Level 2 (Additional Controls)

| Control | Status | Implementation |
|---|---|---|
| AppArmor profiles | ✓ | `setup-apparmor.sh` — docker-default enforced on all containers |
| GRUB bootloader password | Optional | `harden-bootloader.sh` — see Optional Controls |
| USB / removable media blacklist | ✓ Optional | `harden-usb.sh` — prompted during `setup.sh`; see Optional Controls |
| Additional service disablement | ~ Partial | Docker-only model covers the majority; further review may identify additional candidates |

**Estimated Level 2 coverage: ~65%**

---

### Satisfied at Another Layer

| Control | Layer | What Provides It |
|---|---|---|
| Perimeter network filtering | Cloudflare + Edge FW + ModSecurity | Three layers before UFW; significantly exceeds the benchmark's network security intent |
| MFA for privileged access | VPN / SSH bastion | The benchmark's access control intent is met at the network boundary before SSH |
| Log aggregation and remote retention | NewRelic | Off-host log storage with infrastructure alerting |

### Architectural Exceptions

| Control | Position |
|---|---|
| Host anti-malware (AV) | Not applicable to a container-only host — see [iso27001.md](iso27001.md) for the full position. The CIS Benchmark's malware protection intent is met by: Trivy image scanning, AppArmor MAC, automatic OS updates, and perimeter WAF filtering. |
| Server-level backup | Servers are stateless cattle. No persistent application state at the OS layer. The CIS maintenance intent is met by IaC rebuild capability. |

### Optional Controls

| Control | Script | When May Be Skipped |
|---|---|---|
| GRUB bootloader password | `harden-bootloader.sh` | VM deployments where the hypervisor controls boot; managed hypervisors where console access is separately restricted |
| USB/removable media blacklist | `harden-usb.sh` | Prompted during `setup.sh`. Recommended on VMs. On bare-metal, confirm USB keyboards and mice are not the only input devices before applying; NB: only mass storage, FireWire, and Thunderbolt are blocked — USB HID devices (keyboards, mice) are unaffected by the blacklist. |
| SSH MFA at host level (TOTP) | `setup-ssh-mfa.sh` | When VPN/bastion already enforces MFA and host-level TOTP would create friction for automated access |

---

## Why Excluded Today

CIS Benchmarks are hardening references rather than certification frameworks. Level 1 coverage at ~88% represents a well-hardened operational baseline. The remaining Level 1 gaps are either:

- **Planned remediation**: Docker container egress at host level (G1, tracked in gaps.md); platform/network-level controls assumed in place but require deployment-specific validation
- **Operational process**: Evidence collection for patch compliance (tooling exists; scheduling and retaining outputs is an operational activity)

Level 2 is not a regulatory requirement for the current deployment context. USB blacklisting is a valid defence-in-depth control for Level 2 and is available via `harden-usb.sh`; on VM infrastructure where physical media access is datacenter-controlled, the practical risk is minimal. It is listed as optional rather than a gap.

Open technical gaps are tracked in [gaps.md](gaps.md).

---

*Last updated: 2026-05-03*
