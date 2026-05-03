# UK Cyber Essentials Plus

## Overview

UK Cyber Essentials Plus (CE+) is a UK government-backed certification scheme covering five technical control areas:

1. Firewalls
2. Secure Configuration
3. User Access Control
4. Malware Protection
5. Patch Management

CE+ differs from the basic Cyber Essentials self-assessment in that an **IASME-accredited Certification Body** performs independent technical verification — external vulnerability scanning and authenticated configuration review — before issuing the certificate. The 2023 refresh tightened the MFA requirement for privileged remote administrative accounts.

## Why It's Relevant

CE+ certification is:
- A mandatory requirement for UK government contracts and public sector supply chains
- Required by many UK enterprise vendor assessments and procurement frameworks
- A credible signal of baseline technical security hygiene for commercial due diligence

Even without formal certification, documented CE+ alignment demonstrates a clear, independently-verifiable baseline across the five most commonly exploited attack vector categories.

## Executive Summary

**Estimated CE+ readiness: ~68% (known) ~ ~82% (assumed)**

CE+ has the widest range of any tracked framework. The gap between known and assumed is driven primarily by MFA: CE+ 2023 requires MFA for all privileged remote access, and this requirement is satisfied at the VPN/bastion access layer — which must be validated per deployment. Without that validation, User Access Control drops to partial and becomes a certification blocker. The assumed figure also credits the full four-layer perimeter (Cloudflare, Edge Firewall, ModSecurity) for the Firewalls and Malware Protection control areas.

The security architecture significantly exceeds CE+ expectations in the firewall and network protection areas. The four-layer perimeter (Cloudflare → Edge FW → ModSecurity → Host) exceeds what CE+ assessors expect at the boundary. SSH is not internet-exposed — accessible only via VPN/bastion with MFA — which satisfies the User Access Control MFA requirement at the appropriate architectural layer.

Container egress is not controlled at the host level (tracked as G1); platform-level and network-level external controls (Edge Firewall, VM network policy, data centre egress filtering) are assumed to provide an outer layer — **these should be validated for each deployment**. No host-level anti-malware product — an architectural position rather than a gap. Traefik port 8080 is protected by mandatory BasicAuth with a strong random password generated at install time (`install-traefik.sh`); a network-level block is tracked as G2 but the access risk is already mitigated.

---

## Scope

### In Scope

The five CE+ control areas assessed against this server infrastructure:
- Firewalls: UFW, Docker network isolation, Cloudflare + Edge FW + ModSecurity perimeter
- Secure Configuration: OS hardening scripts, Docker daemon, SSH, kernel parameters
- User Access Control: PAM, SSH configuration, sudo model, per-site user isolation
- Malware Protection: AppArmor MAC, Trivy, automatic updates, CI/CD supply chain
- Patch Management: unattended-upgrades, Trivy, CI/CD blue/green deployment

### Out of Scope

| Area | Reason |
|---|---|
| End-user device controls | Scope is server infrastructure only |
| Organisational policies and procedures | Policy / governance work |
| Staff security awareness training | Personnel controls |
| CE+ certification engagement | Third-party assessor required; organisational decision |
| Cloudflare, Edge FW, ModSecurity configuration | External controls, assumed in place |
| VPN / bastion configuration | External controls, assumed MFA-enforced |

---

## External Controls

| Control | Provider | CE+ Area Addressed |
|---|---|---|
| DDoS mitigation (L3/L4/L7) | Cloudflare | Firewalls — perimeter DDoS protection |
| WAF + OWASP managed ruleset | Cloudflare | Firewalls — internet-facing boundary; Malware Protection — web-layer filtering |
| Edge Firewall (default-deny) | Operator-managed | Firewalls — network perimeter |
| Application-layer WAF | ModSecurity (DMZ) | Firewalls — web application boundary |
| MFA enforcement | VPN / SSH bastion | User Access Control — MFA before SSH is reachable |
| Block device encryption | VM hypervisor | Secure Configuration — encryption at rest |
| Application-layer encryption | Applications | Secure Configuration — data encryption |
| Signed artefact delivery | CI/CD | Malware Protection + Patch Management — trusted, verified software delivery |
| IaC-based DR | Architecture | Patch Management — recovery capability |

---

## Control Area Assessment

### 1. Firewalls

| Control | Status | Detail |
|---|---|---|
| Boundary firewall — default-deny inbound | ✓ | UFW default deny; explicit allow SSH/80/443 — `configure-firewall.sh` |
| Egress filtering (host processes) | ✓ | UFW outbound allow-list: DNS, DoT, HTTP/S, NTP, SMTP — `configure-firewall.sh` |
| DDoS protection | ✓ | Cloudflare L3/L4/L7 at internet perimeter |
| WAF at internet boundary | ✓ | Cloudflare WAF + OWASP managed ruleset; ModSecurity in DMZ |
| No unnecessary internet-exposed services | ✓ | Traefik on 80/443; SSH not internet-exposed (VPN/bastion only); no other ports |
| Docker container egress controlled | ~ | Docker bypasses UFW at host level; platform-level and network-level egress controls (Edge Firewall, VM network policy, data centre controls) are assumed to be in place — **validate per deployment**; host-level control tracked as [gaps.md](gaps.md) G1 |
| Traefik management port (8080) not network-blocked | ~ | Docker iptables bypass means 8080 may be network-reachable on origin IP; mitigated by mandatory BasicAuth with a cryptographically random password (`openssl rand -hex 20`; 20 bytes = 160 bits of entropy, between AES-128 and AES-256 in key strength) APR1-hashed, generated at install time by `install-traefik.sh` — unauthenticated access is not possible. Network-level block is tracked as [gaps.md](gaps.md) G2. |

**Firewalls: Good.** Perimeter is strong. Docker container egress is uncontrolled at the host level; assumed mitigated by platform/network-level controls pending deployment-specific validation (G1). Traefik 8080 is protected by strong BasicAuth pending the network-level block (G2).

### 2. Secure Configuration

| Control | Status | Detail |
|---|---|---|
| Default accounts removed / disabled | ✓ | Root login disabled; no default Docker accounts |
| Unnecessary software not present | ✓ | Docker-only model; no Apache, MySQL, FTP on host |
| Auto-lock on failed login attempts | ✓ | PAM pam_faillock: 5 attempts → 15-min lockout — `setup-pam-policy.sh` |
| Kernel hardening | ✓ | ASLR, SYN cookies, ptrace restriction, BPF restrictions, dmesg — `harden-kernel.sh` |
| Shared memory hardening | ✓ | `/dev/shm` mounted `noexec,nodev,nosuid` — `harden-shared-memory.sh` |
| SSH hardened | ✓ | Key-only auth, no root login, strong AEAD ciphers, no forwarding — `harden-ssh.sh` |
| Docker daemon hardened | ✓ | `icc=false`, seccomp default, logging, live-restore — `harden-docker.sh` |
| AppArmor MAC on all containers | ✓ | docker-default profile enforced — `setup-apparmor.sh` |
| Container capability restriction | ✓ | Traefik: `--cap-drop ALL --cap-add NET_BIND_SERVICE`; deployed sites: required by convention, `harden-compose.sh` generates an override automatically |
| Encryption at rest | ✓ (at correct layers) | Block device (VM hypervisor); application-layer (applications) |

**Secure Configuration: Good.** Host hardening is thorough. All container capability controls are in place.

### 3. User Access Control

| Control | Status | Detail |
|---|---|---|
| Unique accounts per administrator | ✓ | Per-site dedicated users; no shared accounts |
| Least privilege | ✓ | No docker group; per-site per-command sudoers allow-list |
| Account lockout | ✓ | PAM pam_faillock: 5 attempts → 15-min lockout |
| Root login disabled | ✓ | `PermitRootLogin no` in SSH configuration |
| Password authentication disabled | ✓ | `PasswordAuthentication no`; key-only SSH |
| MFA for privileged remote access | ✓ (at access layer) | MFA enforced at VPN/bastion before SSH is network-reachable; CE+ 2023 MFA requirement is satisfied at the architectural access boundary. Host-level TOTP (`setup-ssh-mfa.sh`) is available as defence-in-depth. |

**User Access Control: Good.** MFA satisfied at VPN/bastion access layer. Host-level TOTP is optional additional hardening.

### 4. Malware Protection

| Control | Status | Detail |
|---|---|---|
| Web-layer malware / threat filtering | ✓ | Cloudflare WAF + ModSecurity WAF at perimeter; malicious web traffic blocked before reaching host |
| Mandatory access control | ✓ | AppArmor docker-default profile confines all containers — `setup-apparmor.sh` |
| Automatic OS security updates | ✓ | `unattended-upgrades` applies security patches daily — `setup-auto-updates.sh` |
| Container image vulnerability scanning | ✓ | Trivy blocks deployment on CRITICAL CVEs — `scan-image.sh` |
| Signed and verified software delivery | ✓ | CI/CD delivers encrypted, signed artefacts; host validates signature before installation |
| File integrity monitoring | ✓ | AIDE daily check with email alert — `setup-aide.sh` |
| USB / removable media blacklisting | ✓ Optional | usb-storage, FireWire, and Thunderbolt modules blacklisted — `harden-usb.sh`; prompted during `setup.sh` |
| Host-level anti-malware (AV) | Architectural exception | See below |

**Malware Protection: Good with one architectural position to note (see below).**

#### Architectural Position: Host Anti-Malware

CE+ assessors typically expect a technical anti-malware product (e.g., ClamAV) on each in-scope system. For a container-only host operating as a pod equivalent, host-level AV is architecturally inappropriate:

- ClamAV cannot meaningfully scan container overlay filesystems; it scans the host OS filesystem, which contains only the base Debian installation and Docker tooling
- The meaningful scan target is the container *image*, not the running host — Trivy performs this scan pre-deployment
- AV on a container host introduces operational risk (false positives on container runtime files, high I/O during scans, potential interference with container operations)

The compensating control stack is:
- **Trivy**: scans container images for known vulnerabilities before deployment; blocks on CRITICAL
- **AppArmor docker-default + seccomp**: constrains container behaviour at runtime to a defined safe profile
- **CI/CD signed artefacts**: prevents deployment of untrusted or tampered software
- **Cloudflare WAF + ModSecurity**: filters web-layer malicious content at the perimeter
- **Automatic OS updates**: keeps the host OS free of known OS-level vulnerabilities

This position should be presented to a CE+ assessor with the compensating control evidence. Whether an individual assessor accepts this depends on their interpretation of the CE+ technical guidance. If a CE+ certificate is required and the assessor requires a host AV product regardless, ClamAV installation is a P2 remediation item tracked in [gaps.md](gaps.md).

### 5. Patch Management

| Control | Status | Detail |
|---|---|---|
| OS security patches applied within 14 days | ✓ | `unattended-upgrades` applies security patches daily — `setup-auto-updates.sh` |
| Application / container patches | ✓ | CI/CD blue/green deployment pipeline delivers updated container images |
| Container base image vulnerability gating | ✓ | Trivy blocks deployment on CRITICAL CVEs at deploy time |
| Cloudflare edge software patching | ✓ | Vendor-managed; Cloudflare's responsibility |
| Automated container image rebuild on upstream patch | ~ | No automated rebuild trigger; image update depends on CI/CD pipeline activity — see [gaps.md](gaps.md) |

**Patch Management: Good.** OS patching is solid; automated container image rebuild on upstream base image patch is a CI/CD pipeline concern.

---

## Why Excluded Today

CE+ certification requires engagement with an IASME-accredited Certification Body and represents an ongoing annual commitment. It is appropriate when a certificate is required for a specific contract or regulatory purpose.

The current posture (~82%) is strong. The primary technical difference between current state and CE+ certification readiness is:

1. **Docker container egress at host level** (G1): Planned remediation; platform/network-level controls assumed in place but require deployment-specific validation before relying on them as a compensating control
2. **Host anti-malware** (architectural position): If an assessor insists on a host AV product, ClamAV installation is tracked as a contingency P2 item

The security architecture actually exceeds CE+ expectations in several areas (four-layer perimeter, SSH not internet-exposed, signed CI/CD supply chain). An assessor would need to understand the architecture to appreciate this; providing an evidence pack and architecture diagram before assessment day is essential.

Open technical gaps are tracked in [gaps.md](gaps.md).

---

*Last updated: 2026-05-03*
