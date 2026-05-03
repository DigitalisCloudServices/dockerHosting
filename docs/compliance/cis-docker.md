# CIS Benchmark — Docker (v1.6)

## Overview

The CIS Docker Benchmark v1.6 provides prescriptive security guidance for Docker daemon hardening, container configuration, image hygiene, and container operations. It covers six sections:

1. Host configuration
2. Docker daemon configuration
3. Docker daemon configuration files
4. Container images and build files
5. Container runtime
6. Docker security operations

`docker-bench-security` automates assessment against this benchmark and is available for self-verification.

## Why It's Relevant

The CIS Docker Benchmark is the primary reference for container-specific security controls across ISO 27001, PCI DSS, NIST SP 800-190, and SOC 2 assessments for containerised workloads. Strong alignment to sections 1–3 (host and daemon) covers the highest-impact attack surface. Sections 5–6 (runtime and operations) require a more mature container operations programme.

## Executive Summary

**Estimated overall coverage: ~70% (known) ~ ~73% (assumed)**
**Section breakdown: Host ~92% | Daemon ~82% | Config files ~88% | Images ~55% | Runtime ~60% | Operations ~35%**

The range reflects container egress (Section 2) — uncontrolled at host level but assumed mitigated by platform/network-level controls pending deployment validation. All other sections are determined by host configuration verifiable by these scripts.

Host and daemon hardening are strong. The host benefits from the full four-layer perimeter (Cloudflare → Edge FW → ModSecurity → Host). `cap_drop: [ALL]` is implemented via `harden-compose.sh`, which generates a `docker-compose.override.yml` applied to all deployed services. Read-only root filesystems are available as an optional flag (`--read-only`) and applied where application compatibility permits. Section 6 (operations) requires a container operations programme (SBOM, Notary, image signing) that is beyond the scope of deployment automation scripts.

---

## Scope

### In Scope

Controls addressable by host OS and Docker daemon configuration:
- Docker daemon configuration (`daemon.json`, `harden-docker.sh`)
- Host OS hardening as it applies to Docker (kernel params, AppArmor, audit rules)
- Container image vulnerability scanning (Trivy)
- Docker network isolation per-site
- Seccomp and AppArmor profile enforcement
- User namespace remapping (optional)
- Compose template defaults

### Out of Scope

| Area | Reason |
|---|---|
| Container application security | Application-level controls; not infrastructure scripts |
| Docker registry hardening | External registry — out of project scope |
| CI/CD pipeline security | Managed separately; assumed to deliver signed artefacts |
| Docker Swarm / Kubernetes controls | Single-host Docker Compose deployment model |
| Image signing infrastructure | Requires a full signing programme (Cosign/DCT); see Architectural Exceptions |

---

## External Controls

| Control | Provider | CIS Section |
|---|---|---|
| Web-layer threat filtering | Cloudflare + ModSecurity | Section 1 (host) — network-layer attack surface |
| Infrastructure monitoring and alerting | NewRelic | Section 6 (operations) — monitoring capability |
| MFA at access boundary | VPN / SSH bastion | Section 1 (host) — admin access control |
| Signed artefact delivery | CI/CD pipeline | Section 4 (images) — supply chain integrity before host receives image |

---

## Control Assessment

### Section 1 — Host Configuration

| Control | Status | Implementation |
|---|---|---|
| Separate filesystem partition for Docker | ~ | Dependent on deployment — not enforced by scripts |
| Hardened OS and kernel parameters | ✓ | ASLR, SYN cookies, ptrace restriction, BPF, dmesg — `harden-kernel.sh` |
| Docker group does not contain unauthorised users | ✓ | No docker group membership; per-command sudoers — `setup-docker-permissions.sh` |
| AppArmor profile enabled | ✓ | docker-default profile on all containers — `setup-apparmor.sh` |
| SELinux / AppArmor on host | ✓ | AppArmor enabled system-wide |
| Audit rules for Docker files | ✓ | auditd rules cover Docker socket, daemon.json, container dirs — `setup-audit.sh` |
| Kernel version is current | ✓ | `unattended-upgrades` — `setup-auto-updates.sh` |

**Section 1: ~92%**

### Section 2 — Docker Daemon Configuration

| Control | Status | Implementation |
|---|---|---|
| Inter-container communication disabled | ✓ | `icc: false` in `daemon.json` — `harden-docker.sh` |
| Logging driver configured | ✓ | `json-file` with size limits in `daemon.json` |
| Live restore enabled | ✓ | `live-restore: true` in `daemon.json` |
| Userland proxy disabled | ✓ | `userland-proxy: false` in `daemon.json` |
| Default seccomp profile applied | ✓ | `seccomp-profile: default` in `daemon.json` |
| User namespace remapping | Optional | `userns-remap: default` — see Optional Controls |
| No insecure registries | ✓ | No `insecure-registries` in `daemon.json` |
| Container egress filtering | ✗ | Docker bypasses UFW; container outbound unrestricted — see [gaps.md](gaps.md) |

**Section 2: ~82%**

### Section 3 — Docker Daemon Configuration Files

| Control | Status | Implementation |
|---|---|---|
| `daemon.json` ownership (root:root) | ✓ | Set during `harden-docker.sh` installation |
| `daemon.json` permissions (0644) | ✓ | Set during `harden-docker.sh` installation |
| Docker socket not exposed over TCP | ✓ | Unix socket only; no TCP listener |
| Docker socket permissions | ✓ | `srw-rw---- root docker`; no world-accessible socket |

**Section 3: ~88%**

### Section 4 — Container Images and Build Files

| Control | Status | Implementation |
|---|---|---|
| Container images scanned for vulnerabilities | ✓ | Trivy blocks deployment on CRITICAL CVEs — `scan-image.sh` |
| Images pulled only from trusted registries | ✓ | Enforced via CI/CD signed artefact delivery |
| Images not run as root | ~ | Not enforced in compose template; application-dependent |
| Container image signing | ~ | CI/CD delivers signed artefacts; image-layer Cosign/DCT not enforced — see Architectural Exceptions |
| SBOM not generated | ✗ | No software bill of materials produced — see [gaps.md](gaps.md) |

**Section 4: ~55%**

### Section 5 — Container Runtime

| Control | Status | Implementation |
|---|---|---|
| AppArmor profile applied per container | ✓ | docker-default applied to all containers via daemon config |
| Seccomp profile applied per container | ✓ | Default seccomp profile via daemon config |
| `no-new-privileges` flag | ✓ | `NoNewPrivileges=true` in systemd service template |
| Container does not run as root | ~ | Application-dependent; not enforced in compose template |
| Sensitive host paths not mounted | ✓ | Not mounted in generated compose templates |
| Docker socket not mounted in containers | ✓ | Not present in generated compose templates |
| `cap_drop: [ALL]` in compose template | ✓ | Traefik: `--cap-drop ALL --cap-add NET_BIND_SERVICE`; deployed sites: required by convention, `harden-compose.sh` generates an override automatically |
| Read-only root filesystem | Optional | Not default; see Optional Controls |
| Memory and CPU limits | Optional | Application-dependent; see Optional Controls |

**Section 5: ~60%**

### Section 6 — Docker Security Operations

| Control | Status | Implementation |
|---|---|---|
| Image vulnerability scanning (regular) | ✓ | Trivy at deploy via CI/CD |
| Container health monitoring | ✓ | NewRelic infrastructure agent; Docker health checks |
| AIDE covers Docker config directories | ✓ | Docker config paths included in AIDE rules — `setup-aide.sh` |
| Centralised log management | ✓ | NewRelic remote log shipping |
| Image signing / provenance | ~ | Supply chain relies on CI/CD signed artefacts; image-layer signing not implemented |
| SBOM / content trust programme | ✗ | Not implemented — see Architectural Exceptions |
| Formal image update cadence | ~ | Blue/green CI/CD; no automated rebuild trigger on upstream base image patch |

**Section 6: ~35%**

---

### Satisfied at Another Layer

| Control | Layer | What Provides It |
|---|---|---|
| Web-layer attack filtering | Cloudflare + ModSecurity | CIS section 1 network security intent exceeded by four-layer perimeter |
| MFA for administrative access | VPN / SSH bastion | Admin access requires MFA before reaching the host |
| Supply chain integrity | CI/CD (signed + encrypted artefacts) | Images arrive via a validated, signed delivery pipeline |

### Architectural Exceptions

| Control | Position | Compensating Controls |
|---|---|---|
| Image signing (Cosign/DCT) at host | Image signing infrastructure requires a signing programme with key management, a signing station in the CI/CD pipeline, and verification at deploy. The CI/CD pipeline provides equivalent supply chain integrity via signed and encrypted artefact packages validated on the host. Full image-layer Cosign signing is a CI/CD pipeline concern, not a host configuration concern. | Signed CI/CD artefacts; Trivy CRITICAL gate; AppArmor; seccomp |
| SBOM programme | A full SBOM programme (generation, storage, tracking) is a CI/CD operations concern. Trivy provides the equivalent security value (vulnerability detection from the same sources that SBOM would track) at deploy time. | Trivy vulnerability scanning |
| Host anti-malware | See [iso27001.md](iso27001.md) for the full position. CIS Docker context: scanning container overlay filesystems with host-level AV produces high false-positive rates and does not reflect the actual container image content. Trivy scans the actual image layers pre-deployment. | Trivy; AppArmor; seccomp; ModSecurity; Cloudflare |

### Optional Controls

| Control | Script / Config | When May Be Skipped |
|---|---|---|
| `userns-remap` | `harden-docker.sh` | Applications using bind mounts with specific UID/GID mappings may have permission issues with userns-remap. Skip where application compatibility requires it; document the exception. |
| `read_only: true` on containers | Compose template | Applications that write to their container filesystem (logging, temp files). Use `tmpfs` for writable paths when read-only root is enabled. |
| CPU/memory resource limits | Compose template | Limits are application-specific. Operators should set appropriate limits per site after establishing baseline usage. |

---

## Why Excluded Today

CIS Docker Benchmark sections 5 and 6 assume a container operations programme: a private registry with signing infrastructure, formal SBOM tracking, and an image update process beyond what deployment automation can provide. These are CI/CD and platform engineering concerns that sit above the scope of host configuration scripts.

The primary security value of the Docker Benchmark (sections 1–3) is strongly covered. The compensating controls for section 5 gaps (AppArmor, seccomp, no-new-privileges) are in place and provide meaningful risk reduction.

Open technical gaps are tracked in [gaps.md](gaps.md).

---

*Last updated: 2026-05-03*
