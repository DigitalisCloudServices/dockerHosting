# Software Bill of Materials

This document identifies all software components installed and configured by dockerHosting on a target Debian Trixie server. It is intended to support supplier risk assessment, vulnerability management, and audit evidence obligations under frameworks including ISO 27001 A.8.8, CIS L1/L2, NIST SP 800-53 (SA-4, SA-8), and SOC 2 CC7.

All component versions are **resolved at install time** from the distribution package manager or official upstream source unless explicitly pinned. The pinned exceptions are noted in the Version column. To capture exact versions on a deployed host, see [Generating a Live SBOM](#generating-a-live-sbom) below.

---

## Component Inventory

### Operating System

| Component | Version | Source | License |
|---|---|---|---|
| Debian GNU/Linux | Trixie (13) | debian.org | DFSG-compatible mix |
| Linux kernel | Distribution default | Debian apt | GPL-2.0 |

---

### Container Runtime

| Component | Version | Source | License |
|---|---|---|---|
| docker-ce | Latest stable | download.docker.com | Apache-2.0 |
| docker-ce-cli | Latest stable | download.docker.com | Apache-2.0 |
| containerd.io | Latest stable | download.docker.com | Apache-2.0 |
| docker-buildx-plugin | Latest stable | download.docker.com | Apache-2.0 |
| docker-compose-plugin | Latest stable | download.docker.com | Apache-2.0 |

Docker is installed from Docker Inc.'s official APT repository, not the Debian package. The daemon is hardened post-install by `harden-docker.sh` (userns-remap, icc=false, no-new-privileges, log-driver json-file with size limits).

---

### Reverse Proxy / Ingress

| Component | Version | Source | License |
|---|---|---|---|
| Traefik | **v3.6** (pinned) | traefik Docker Hub image | MIT |

Traefik runs as a Docker container managed by `install-traefik.sh`. The version is pinned via the `TRAEFIK_VERSION` environment variable (default `v3.6`). Middleware applied globally: HSTS (1 year, includeSubdomains, preload), X-Frame-Options deny, X-Content-Type-Options nosniff, rate limiting (10 rps average, burst 20).

---

### Security Tools

| Component | Version | Source | License |
|---|---|---|---|
| ufw | Distribution | Debian apt | GPL-3.0 |
| fail2ban | Distribution | Debian apt | GPL-2.0 |
| aide | Distribution | Debian apt | GPL-2.0 |
| aide-common | Distribution | Debian apt | GPL-2.0 |
| auditd | Distribution | Debian apt | GPL-2.0 |
| audispd-plugins | Distribution | Debian apt | GPL-2.0 |
| apparmor | Distribution | Debian apt | GPL-2.0 |
| apparmor-utils | Distribution | Debian apt | GPL-2.0 |
| apparmor-profiles | Distribution | Debian apt | GPL-2.0 |
| apparmor-profiles-extra | Distribution | Debian apt | GPL-2.0 |
| libpam-pwquality | Distribution | Debian apt | GPL-2.0 / LGPL-2.1 |
| libpam-google-authenticator | Distribution | Debian apt | Apache-2.0 |
| trivy | Distribution | aquasec/trivy APT repo | Apache-2.0 |
| openssl | Distribution | Debian apt | Apache-2.0 |
| certbot | Distribution | Debian apt | Apache-2.0 |

Trivy is used by `scan-image.sh` to block deployment of container images with CRITICAL-severity CVEs. AIDE is initialised by `setup-aide.sh` and provides file integrity monitoring against a baseline snapshot taken at setup time. AppArmor enforces the `docker-default` profile on all containers. auditd is configured with 28+ rules covering privileged commands, file access, and authentication events.

---

### System Packages

| Component | Purpose | Source | License |
|---|---|---|---|
| curl | HTTP client / scripting | Debian apt | curl (MIT-like) |
| wget | HTTP retrieval | Debian apt | GPL-3.0 |
| git | Version control | Debian apt | GPL-2.0 |
| rsync | File synchronisation | Debian apt | GPL-3.0 |
| ca-certificates | TLS trust store | Debian apt | MPL-2.0 / various |
| gnupg | GPG keyring management | Debian apt | GPL-3.0 |
| lsb-release | OS identification | Debian apt | GPL-2.0 |
| apt-transport-https | HTTPS apt sources | Debian apt | GPL-2.0 |
| unattended-upgrades | Automatic security patches | Debian apt | GPL-2.0 |
| apt-listchanges | Changelog notifications | Debian apt | GPL-2.0 |
| chrony | NTP synchronisation | Debian apt | GPL-2.0 |
| logrotate | Log rotation | Debian apt | GPL-2.0 |
| jq | JSON processing | Debian apt | MIT |
| pwgen | Password generation | Debian apt | GPL-2.0 |
| htop | Process monitoring | Debian apt | GPL-2.0 |
| iotop | I/O monitoring | Debian apt | GPL-2.0 |
| lsof | Open file inspection | Debian apt | CDDL-1.0 |
| net-tools | Network utilities | Debian apt | GPL-2.0 |
| dnsutils | DNS query tools | Debian apt | ISC |
| tcpdump | Packet capture | Debian apt | BSD-3-Clause |
| traceroute | Network path tracing | Debian apt | GPL-2.0 |
| nano | Text editor | Debian apt | GPL-3.0 |
| screen | Terminal multiplexer | Debian apt | GPL-3.0 |
| unzip / zip / gzip / tar | Archive utilities | Debian apt | various (GPL) |
| default-mysql-client | MySQL CLI (debug use) | Debian apt | GPL-2.0 |
| python3 | Scripting runtime | Debian apt | PSF-2.0 |
| msmtp / msmtp-mta | SMTP relay | Debian apt | GPL-3.0 |
| mailutils / bsd-mailx | Mail sending | Debian apt | GPL-3.0 |

---

### Configuration & Deployment Scripts

The following are first-party shell scripts maintained in this repository. They carry no external runtime dependency beyond bash and the system tools above.

| Script | Purpose |
|---|---|
| `setup.sh` | Bootstrap entrypoint — orchestrates all below |
| `scripts/install-packages.sh` | Installs system packages from `config/packages.list` |
| `scripts/install-docker.sh` | Installs Docker CE from Docker Inc. APT repo |
| `scripts/install-traefik.sh` | Deploys Traefik v3.6 container; migrates nginx if present |
| `scripts/configure-firewall.sh` | Configures UFW default-deny inbound |
| `scripts/harden-kernel.sh` | Applies sysctl hardening (ASLR, SYN cookies, ptrace, BPF) |
| `scripts/setup-ntp.sh` | Configures chrony with ≥2 sources |
| `scripts/setup-audit.sh` | Deploys 28+ auditd rules; configures immutable ruleset |
| `scripts/setup-auto-updates.sh` | Enables unattended-upgrades for security-only patches |
| `scripts/harden-docker.sh` | Hardens Docker daemon (userns-remap, icc=false, etc.) |
| `scripts/setup-apparmor.sh` | Enables AppArmor; enforces docker-default on containers |
| `scripts/setup-pam-policy.sh` | PAM: 14-char min, complexity, history, pam_faillock lockout |
| `scripts/setup-aide.sh` | Initialises AIDE FIM baseline |
| `scripts/harden-shared-memory.sh` | Mounts /dev/shm noexec,nosuid,nodev |
| `scripts/setup-fail2ban-enhanced.sh` | Enhanced fail2ban jails (SSH, nginx, traefik) |
| `scripts/setup-email.sh` | Configures msmtp SMTP relay for system alerts |
| `scripts/harden-bootloader.sh` | Sets GRUB password (optional) |
| `scripts/harden-usb.sh` | Disables USB mass storage kernel module (optional) |
| `scripts/harden-ssh.sh` | SSH: key-only, no root, AEAD ciphers, no forwarding |
| `scripts/setup-ssh-mfa.sh` | Optional TOTP MFA via libpam-google-authenticator |
| `scripts/setup-logrotate.sh` | Log rotation for Docker container logs |
| `scripts/scan-image.sh` | Trivy vulnerability scan — blocks CRITICAL CVEs at deploy |
| `deploy-site.sh` | Interactive site deployment from Git repository |

---

## External Dependencies Not Managed by These Scripts

The following upstream services are runtime dependencies of a deployed server but are not installed or configured by this repository. They should have their own SBOM entries maintained by the owning team.

| Component | Role | Managed by |
|---|---|---|
| Cloudflare | DDoS protection, WAF, CDN edge | External / CDN team |
| Edge firewall | IP allowlisting upstream of origin | External / network team |
| ModSecurity WAF | L7 reverse proxy / OWASP ruleset | External / DMZ team |
| VPN / SSH bastion | Administrative access boundary | External / access team |
| NewRelic agent | Log shipping, observability | Application / ops team |
| Docker Hub | Container image registry for Traefik | Docker Inc. |
| Let's Encrypt / ACME CA | TLS certificate issuance | External CA |
| Application containers | Site workloads | kse-portal / dockerBuildfiles |

---

## Generating a Live SBOM

To capture exact package versions on a deployed server, run the following. `trivy` is already installed as part of the baseline.

**Host OS packages (SPDX format):**
```bash
trivy fs --format spdx-json --output sbom-host.spdx.json /
```

**Per-container SBOM:**
```bash
# List running containers
docker ps --format '{{.Image}}' | sort -u

# Generate SBOM for each image (example)
trivy image --format cyclonedx --output sbom-traefik.cdx.json traefik:v3.6
```

**Installed Debian packages only (plain text):**
```bash
dpkg-query -W -f='${Package}\t${Version}\t${Maintainer}\n' | sort > sbom-packages.tsv
```

These commands produce machine-readable output suitable for ingestion into a vulnerability management platform (Dependency-Track, Grype, etc.).

---

## Revision Policy

This document should be updated whenever:
- A new package or tool is added to `config/packages.list` or any install script
- A pinned version changes (e.g. `TRAEFIK_VERSION`)
- A script is added or removed from `setup.sh`
- An external dependency changes ownership or classification

---

*Last updated: 2026-05-03*
