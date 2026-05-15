# dockerHosting

Server setup and deployment automation for Debian Trixie servers hosting Docker-based applications.

**Boundary proxy:** [Traefik v3.6](https://traefik.io/traefik/) — self-signed SSL out of the box, hostname-based routing, zero-reload config via file provider.

> **Security posture:** See [docs/compliance.md](docs/compliance.md) for a full mapping of implemented controls against ISO 27001:2022, CIS Benchmarks (Linux + Docker), and NIST SP 800-53.

## Purpose

This repository provides scripts to:
1. **Setup a fresh Debian Trixie server** with Docker and essential packages
2. **Deploy new sites/environments** from Git repositories with automated configuration

## Quick Start

### 1. Initial Server Setup

Run this on a fresh Debian Trixie installation to install Docker, Docker Compose, and essential packages:

```bash
curl -fsSL https://raw.githubusercontent.com/DigitalisCloudServices/dockerHosting/main/setup.sh -o setup.sh && chmod +x ./setup.sh && sudo ./setup.sh
```

Or if you have the repository cloned:

```bash
sudo ./setup.sh
```

**What it does:**
- Installs Docker and Docker Compose
- Installs essential packages (git, curl, make, etc.)
- **Installs Traefik v3.6** as the boundary proxy (replaces nginx at the host level)
- Configures firewall (UFW) with default-deny inbound and egress allow-list
- Sets up security hardening (kernel params, NTP, AppArmor, SSH, fail2ban, audit logging, AIDE FIM)
- Sets up automated security updates
- Optionally configures SSH MFA (TOTP), GRUB bootloader password, and email notifications
- Sets up log rotation

**After setup:** Log out and log back in for group changes to take effect.

> **Re-running on a server with nginx:** `setup.sh` detects an existing nginx install and prompts to migrate automatically (migrates site configs + SSL certs, uninstalls nginx) or skip.

### 2. Deploy a New Site

All sites use a GCS artifact pipeline. The server never touches git or GitHub — it only
needs a GCS service account key and (optionally) artifact decryption keys.

**Interactive mode** (prompts for all information):

```bash
sudo ./deploy-site.sh
```

**Scripted mode:**

```bash
sudo ./deploy-site.sh \
  --site-name mysite \
  --gcs-key-file /path/to/gcs-sa.json \
  --artifact-aes-key-file /path/to/artifact_aes_key.txt \
  --artifact-signing-pub-key-file /path/to/artifact_signing_public_key.pem \
  --domain example.com \
  --kong-port 8443
```

**What `deploy-site.sh` does:**

1. Creates a dedicated system user (`nologin`) and deployment directory
2. Authenticates to GCS and downloads the `infra` artifact (bootstrap only — contains `docker-compose.yml`, nginx/Kong config, and any project-specific scripts)
3. Extracts the infra artifact, generates application secrets
4. Copies GCS and decryption keys into `infra/secrets/` (root-only, mode 600)
5. Writes a minimal `.env` (COMPOSE_PROJECT_NAME, GCS bucket, Kong port, registry, infra hash)
6. Calls `lib/update-site.sh <deploy-dir> --trigger bootstrap` — downloads all remaining artifacts, runs `bootstrap` lifecycle hooks, and starts the stack
7. Configures Traefik routing, log rotation, and a systemd timer for ongoing updates

`deploy-site.sh` has no knowledge of what artifact types a site uses beyond `infra`.
All site-specific artifact types (e.g. `frontend`, `wordpress`) are declared in the
site's own channel metadata and handled generically by `lib/update-site.sh`.

**Command-line options:**

| Option | Description |
|--------|-------------|
| `--site-name <name>` | Site name — alphanumeric + hyphens (required) |
| `--mode <production\|development>` | Default: `production` |
| `--gcs-key-file <path>` | GCS service account JSON key (required in production) |
| `--gcs-bucket <url>` | GCS bucket URL (default: from site's `.env`) |
| `--gcs-prefix <path>` | Optional subfolder prefix inside the bucket (for shared buckets) |
| `--artifact-aes-key-file <path>` | AES-256 key file for artifact decryption |
| `--artifact-signing-pub-key-file <path>` | RSA public key file for artifact verification |
| `--deploy-dir <path>` | Deployment directory (default: `/opt/apps/<site-name>`) |
| `--domain <hostname>` | Site hostname for Traefik routing |
| `--kong-port <port>` | Internal HTTPS port (default: auto-detect from 8443) |
| `--setup-timer <yes\|no>` | Install systemd updater timer (default: yes) |
| `--non-interactive` | Skip all prompts |

## Traefik Proxy

Traefik replaces system-level nginx as the boundary reverse proxy. It runs as a Docker container and hot-reloads routing config from files — no restart required.

### Managing sites

```bash
# Add a site (self-signed SSL auto-generated)
sudo /opt/dockerHosting/scripts/add-traefik-site.sh example.com 3001

# Add with explicit site name
sudo /opt/dockerHosting/scripts/add-traefik-site.sh example.com 3001 mysite

# Remove a site
sudo /opt/dockerHosting/scripts/remove-traefik-site.sh example.com

# Check status
docker ps --filter name=traefik
curl -s http://127.0.0.1:8080/api/http/routers
```

Config files are written to `/etc/traefik/dynamic/<site-name>.yml`.

### SSL certificates

| Mode | How |
|------|-----|
| **Self-signed** (default) | Traefik auto-generates — works immediately, browser will warn |
| **File cert** | Place `fullchain.pem` + `privkey.pem` in `/etc/traefik/certs/<site-name>/` then re-run `add-traefik-site.sh` |
| **Let's Encrypt** | Add `certificatesResolvers.letsencrypt` to `/etc/traefik/traefik.yml` and set `tls.certResolver: letsencrypt` in the site config |

SSL certs generated by `scripts/setup-ssl.sh` are automatically detected (they live in `/etc/ssl/dockerhosting/<site>/` which is symlinked into `/etc/traefik/certs/`).

### Dashboard

The Traefik dashboard is available at `http://127.0.0.1:8080` (localhost only — not exposed externally).

---

## Repository Structure

```
dockerHosting/
├── README.md                         # This file
├── setup.sh                          # Main server setup script
├── deploy-site.sh                    # Interactive site deployment script
├── Makefile                          # Developer targets: make lint, make test
├── .shellcheckrc                     # shellcheck configuration
├── lib/                              # Shared runtime libraries (deployed to server)
│   ├── decrypt.sh                    # Artifact verification + decryption (AES-256-GCM/CBC)
│   ├── gcs.sh                        # GCS OAuth2 helpers (_gcs_access_token, _gcs_https_url)
│   └── update-site.sh                # Generic artifact updater — runs on every timer cycle
├── docs/
│   └── compliance.md                 # Security posture: ISO 27001 / CIS / NIST mapping
├── scripts/                          # Modular setup scripts
│   ├── install-docker.sh             # Docker installation (GPG-verified repo)
│   ├── install-packages.sh           # Package installation
│   ├── install-traefik.sh            # Traefik boundary proxy installation
│   ├── add-traefik-site.sh           # Add a site to Traefik (DOMAIN PORT)
│   ├── remove-traefik-site.sh        # Remove a site from Traefik
│   ├── install-nginx.sh              # Nginx (kept for in-container use)
│   ├── configure-firewall.sh         # UFW: default-deny inbound + egress allow-list
│   ├── harden-kernel.sh              # sysctl: ASLR, SYN cookies, BPF, ptrace
│   ├── harden-docker.sh              # Docker daemon: icc=false, seccomp, userns-remap
│   ├── harden-shared-memory.sh       # /dev/shm: noexec, nodev, nosuid
│   ├── harden-ssh.sh                 # SSH: key-only, strong ciphers, no forwarding
│   ├── harden-bootloader.sh          # GRUB password (optional, CIS 1.4)
│   ├── harden-compose.sh             # Generate docker-compose.override.yml with cap_drop/no-new-privileges
│   ├── setup-ntp.sh                  # chrony NTP hardening (ISO A.8.17)
│   ├── setup-apparmor.sh             # AppArmor MAC + Docker default profile
│   ├── setup-pam-policy.sh           # PAM: password complexity + account lockout
│   ├── setup-audit.sh                # auditd: 28+ syscall/file audit rules
│   ├── setup-aide.sh                 # AIDE file integrity monitoring
│   ├── setup-fail2ban-enhanced.sh    # fail2ban: progressive SSH bans
│   ├── setup-ssh-mfa.sh              # SSH TOTP MFA via libpam-google-authenticator (optional)
│   ├── scan-image.sh                 # Trivy container image vulnerability scanner
│   ├── setup-auto-updates.sh         # unattended-upgrades (daily security patches)
│   ├── setup-users.sh                # User and permission management
│   ├── setup-logrotate.sh            # Log rotation configuration
│   ├── setup-email.sh                # Email notification setup (msmtp)
│   ├── setup-docker-network.sh       # Per-site Docker bridge networks
│   ├── setup-docker-permissions.sh   # Least-privilege sudoers rules per site
│   └── configure-site.sh             # Site-specific configuration
├── templates/                        # Configuration templates
│   ├── traefik/
│   │   ├── traefik.yml               # Traefik static config template
│   │   ├── middleware.yml            # Shared security headers + rate limiting
│   │   └── site.yml.template         # Per-site dynamic config (HTTP backend, no insecureSkipVerify)
│   ├── logrotate.conf.template       # Log rotation template
│   ├── systemd.service.template      # Systemd service template
│   └── env.template                  # Environment file template
├── tests/                            # Automated tests (BATS)
│   ├── helpers/
│   │   └── common.bash               # Shared test helpers and mock utilities
│   ├── traefik/
│   │   ├── test_add_site.bats        # Tests for add-traefik-site.sh
│   │   ├── test_remove_site.bats     # Tests for remove-traefik-site.sh
│   │   └── test_install_traefik.bats # Tests for install-traefik.sh
│   ├── test_syntax.bats              # bash -n syntax check for all 33 scripts
│   └── test_arg_validation.bats      # Argument validation for key scripts
└── config/                           # Configuration files
    └── packages.list                 # List of packages to install
```

## Usage Examples

### Example 1: Deploy a site (production)

```bash
sudo ./deploy-site.sh \
  --site-name mysite \
  --gcs-key-file /root/keys/gcs-sa.json \
  --artifact-aes-key-file /root/keys/artifact_aes_key.txt \
  --artifact-signing-pub-key-file /root/keys/artifact_signing_public_key.pem \
  --domain example.com \
  --kong-port 8443
```

The script bootstraps the infra artifact, then calls `lib/update-site.sh --trigger bootstrap`
which downloads all remaining artifacts, runs any bootstrap lifecycle hooks, and starts
the stack. The replay command is printed at the end for disaster recovery.

### Example 2: Deploy multiple sites on the same server

Each site gets its own user, deploy directory, Kong port, and Traefik route:

```bash
sudo ./deploy-site.sh --site-name site-a --gcs-key-file /root/keys/site-a-sa.json --kong-port 8443 --domain site-a.io
sudo ./deploy-site.sh --site-name site-b --gcs-key-file /root/keys/site-b-sa.json --kong-port 8444 --domain site-b.io
```

### Example 3: Force an immediate artifact update

```bash
sudo /opt/apps/mysite/bin/update-now
# or equivalently:
sudo /opt/dockerHosting/lib/update-site.sh /opt/apps/mysite

# Check what would update without applying:
sudo /opt/dockerHosting/lib/update-site.sh /opt/apps/mysite --dry-run

# Force-recreate all containers with current artifacts:
sudo /opt/dockerHosting/lib/update-site.sh /opt/apps/mysite --force
```

## Manual Script Usage

### Run individual hardening steps

Each hardening script is idempotent — safe to re-run, skips if already configured. Use `--force` to reconfigure.

```bash
sudo ./scripts/setup-ntp.sh             # NTP time synchronisation (chrony)
sudo ./scripts/setup-apparmor.sh        # AppArmor mandatory access control
sudo ./scripts/setup-ssh-mfa.sh         # SSH TOTP MFA (prompts; optional)
sudo ./scripts/harden-bootloader.sh     # GRUB bootloader password (prompts; optional)

# Scan a container image for known CVEs before deploying
sudo ./scripts/scan-image.sh nginx:latest
sudo ./scripts/scan-image.sh --compose /opt/apps/mysite/docker-compose.yml
sudo ./scripts/scan-image.sh --severity CRITICAL,HIGH --ignore-unfixed myimage:tag

# Force re-run a specific step without re-running setup in full
sudo ./setup.sh --force=ntp
sudo ./setup.sh --force=apparmor,firewall
```

### Audit report (`--report`)

Generate a passive, read-only posture audit of the host. Produces a Markdown
log and a JSON sidecar under `/var/log/dockerHosting/` and prints a coloured
summary to the terminal. No active probes (no nmap), no mutations.

```bash
sudo ./setup.sh --report
```

Outputs:

- `/var/log/dockerHosting/audit-report-<host>-<UTC-ISO-timestamp>.log` (Markdown)
- `/var/log/dockerHosting/audit-report-<host>-<UTC-ISO-timestamp>.log.json` (sidecar)
- Both files are mode `0640`, owner `root:adm`, and rotated weekly (12 kept).

Sections:

1. Host identity (hostnamectl, kernel, time sync, uptime)
2. Patch level (apt upgradable, unattended-upgrades, reboot-pending kernel)
3. Host CVEs (debsecan, grouped by severity)
4. Container image CVEs (Trivy via `scan-image.sh --json`)
5. UFW state (default policies, IPv6, logging)
6. Listening sockets vs UFW (passive target-identification, substitutes for nmap)
7. Running containers (image, restart policy, user, mounts, caps)
8. Traefik dynamic routes summary
9. Failed SSH auth in the last 24h + fail2ban status
10. Hardening posture (AppArmor, sshd_config, auditd)
11. Observability — New Relic detection (host agent + container presence)

Maps to NIST SP 800-115 §§3.1, 3.2, 3.3, 4.1, 4.4.

### Install Docker Only

```bash
sudo ./scripts/install-docker.sh
```

### Setup Email Notifications

Configure email notifications to receive system alerts:

```bash
sudo ./scripts/setup-email.sh
```

You'll be prompted for:
- Email address to receive notifications
- SMTP server (e.g., smtp.gmail.com)
- SMTP port (default: 587)
- SMTP credentials
- TLS settings

**Supported SMTP providers:**
- Gmail (smtp.gmail.com:587) - use App Password
- SendGrid (smtp.sendgrid.net:587)
- Mailgun (smtp.mailgun.org:587)
- Office 365 (smtp.office365.com:587)
- Any SMTP relay service

### Configure Log Rotation for Existing Site

```bash
sudo ./scripts/setup-logrotate.sh myapp /opt/apps/myapp
```

### Setup User for Existing Site

```bash
sudo ./scripts/setup-users.sh myapp /opt/apps/myapp
```

## Requirements

- **OS**: Debian Trixie (Debian 13)
- **Access**: Root or sudo privileges
- **Network**: Internet connection for package downloads

## Features

### Security

See [docs/compliance.md](docs/compliance.md) for full framework mapping (ISO 27001, CIS, NIST).

- **Firewall (UFW)** — default-deny inbound; egress allow-list (DNS, DNS-over-TLS, HTTP/S, NTP, SMTP)
- **Kernel hardening** — ASLR, SYN cookies, BPF/ptrace restrictions, IP spoofing protection
- **NTP** — chrony with ≥2 agreeing pool sources; replaces systemd-timesyncd
- **AppArmor** — mandatory access control; Docker containers confined by `docker-default` profile
- **SSH hardening** — key-only authentication, no root login, strong ciphers, no forwarding
- **SSH MFA** — optional TOTP second factor via `libpam-google-authenticator` (ISO A.8.5)
- **fail2ban** — progressive bans for SSH brute-force (1 h → 2 h → 4 h → 7 days max)
- **Audit logging** — auditd with 28+ syscall/file rules, immutable ruleset
- **File integrity monitoring** — AIDE with daily cron check and email alerts
- **Automated security updates** — unattended-upgrades (daily, no auto-reboot)
- **Docker daemon hardening** — `icc=false`, seccomp, optional userns-remap, log limits
- **Traefik container hardening** — `--cap-drop ALL`, `--cap-add NET_BIND_SERVICE`, `--security-opt no-new-privileges:true`
- **Container image scanning** — Trivy (`scripts/scan-image.sh`); blocks on CRITICAL CVEs
- **Per-site isolation** — dedicated user, bridge network, and sudoers file per site
- **Compose hardening** — deployed site containers should include `cap_drop: [ALL]` and `security_opt: [no-new-privileges:true]`; use `scripts/harden-compose.sh <deploy-dir>` to generate a `docker-compose.override.yml` automatically
- **GRUB bootloader password** — optional; prevents single-user-mode bypass (CIS 1.4)
- **Secure secret handling** — `.env` files mode 600; dashboard credentials root-only

### Logging & Monitoring
- Automatic log rotation
- Configurable retention periods
- Docker container log limits
- System log management
- Email notifications for system alerts (optional)
- **Observability agent (opt-in)** — pluggable host-level singleton; see
  [Observability (pluggable)](#observability-pluggable) below. Today supports
  New Relic (EU region); additional providers slot in by dropping templates
  into [`templates/observability/`](templates/observability/).

### Email Notifications
- Lightweight SMTP relay using msmtp
- System alerts and security notifications
- Cron job output delivery
- Configurable smarthost (Gmail, SendGrid, etc.)
- Secure credential storage

### Deployment
- GCS artifact pipeline — CI pushes, server pulls; no git access on the server
- Generic `lib/update-site.sh` — artifact types declared in channel metadata, services identified by Docker labels
- Lifecycle hooks — optional `bootstrap` and `update` hooks (`pre-start` / `post-start`) declared in the site's `infra/lifecycle-hooks.json`
- Atomic artifact swap — `cp` + `mv` prevents Docker bind-mount race condition
- Systemd timer — 15-minute poll with ±5 min jitter; manual trigger via `update-now` helper
- Traefik v3.6 boundary proxy — hostname routing, self-signed SSL, zero-reload config

## Artifact Pipeline

All sites managed by this tooling share a common GCS artifact pipeline.

### How it works

```
CI (GitHub Actions)
  │  builds artifacts (infra, frontend, wordpress, …)
  │  encrypts + uploads to GCS
  └► gs://<bucket>/[<prefix>/]artifacts/<type>-<hash>.tar.gz

  promotes channel metadata (including lifecycle_hooks from infra/lifecycle-hooks.json)
  └► gs://<bucket>/[<prefix>/]channels/prod-latest.json

Server (systemd timer → lib/update-site.sh <deploy-dir>)
  │  reads prod-latest.json
  │  compares channel hashes to .env hashes
  │  downloads + decrypts stale artifacts
  │  runs 'update' pre-start lifecycle hooks
  │  writes to artifact-cache/<name>.tar.gz  (stable bind-mount path)
  │  docker compose up -d --force-recreate <labeled services>
  └► runs 'update' post-start lifecycle hooks

First deploy (deploy-site.sh → lib/update-site.sh <deploy-dir> --trigger bootstrap)
  │  same as above, plus:
  │  runs 'bootstrap' pre-start hooks before docker compose up
  └► runs 'bootstrap' post-start hooks after stack is started
```

### Channel metadata — `prod-latest.json`

```json
{
  "infra": {
    "git_hash":   "abc123def456...",
    "signed":     true,
    "encrypted":  true,
    "type":       "gcs",
    "bucket":     "my-artifacts-bucket",
    "path":       "myproject/infra/abc123def456.tar.gz"
  },
  "artifacts": [
    {
      "name":      "frontend",
      "git_hash":  "def456abc789...",
      "signed":    true,
      "encrypted": true,
      "type":      "gcs",
      "bucket":    "my-artifacts-bucket",
      "path":      "myproject/frontend/def456abc789.tar.gz"
    },
    {
      "name":      "wordpress",
      "git_hash":  "789abc012def...",
      "signed":    false,
      "encrypted": false,
      "type":      "http",
      "url":       "https://cdn.example.com/wordpress-789abc012def.tar.gz",
      "target_dir": "wp-content/themes/custom"
    },
    {
      "name":      "plugins",
      "git_hash":  "external",
      "signed":    false,
      "encrypted": false,
      "type":      "local",
      "directory": "/mnt/nfs/wordpress-plugins"
    }
  ],
  "lifecycle_hooks": [
    { "script": "infra/bootstrap/setup-ssl.sh", "trigger": "bootstrap", "phase": "post-start" }
  ],
  "promoted_at":   "2026-05-06T14:00:00Z",
  "github_run_id": "12345678"
}
```

#### Storage types

Each artifact declares its storage backend explicitly:

- **`gcs`** — Google Cloud Storage
  - `bucket`: Bucket name (without `gs://` prefix)
  - `path`: Path to a tar.gz file within bucket (including any project prefix)
  - Requires GCS authentication via service account key

- **`http` / `https`** — Direct HTTP download
  - `url`: Full HTTPS URL to artifact
  - No authentication (public URL)

- **`local`** — Pre-existing local directory
  - `directory`: Absolute filesystem path (e.g., `/mnt/nfs/wordpress-plugins`)
  - No download — directory must already exist on server
  - Useful for NFS mounts or external dependencies managed outside the release process

#### Security flags

Each artifact can opt out of signing and/or encryption:

- `signed: true` — Artifact bundle includes RSA-SHA256 signature (requires public key)
- `encrypted: true` — Artifact content is AES-256-GCM encrypted (requires AES key)
- `signed: false, encrypted: false` — Plain tar.gz, no verification (useful for public CDN artifacts or `type: local`)

Default: both `true` if not specified. These flags do not apply to `type: local` artifacts (which are not downloaded or verified).

#### Extraction target directory

Artifacts can optionally specify a `target_dir` field to extract to a specific subdirectory within the deployment directory:

- **`target_dir`** (optional) — Relative path within the deployment directory
  - When specified, the artifact tar.gz is extracted to `${DEPLOY_DIR}/${target_dir}` instead of being written to a Docker volume
  - Path is always relative to the deployment directory root (leading/trailing slashes stripped automatically)
  - Useful for extracting theme files, configuration, or other filesystem-based artifacts
  - Example: `"target_dir": "wp-content/themes/custom"` extracts to `/opt/apps/mysite/wp-content/themes/custom`
  - When omitted, artifacts are written to Docker volumes as `/run/artifact.tar.gz` (default behavior for volume-mounted artifacts)

**Note:** `target_dir` does not apply to `type: local` artifacts, which are symlinked rather than extracted.

#### Adding artifacts

The `artifacts` array is the authoritative list of non-infra artifacts for a site. Adding
a new artifact type requires only: a new CI build job, a new entry in the array, and an
`artifact: <name>` label on the consuming Docker service. No changes to `lib/update-site.sh` or
`deploy-site.sh` are needed.

The `lifecycle_hooks` array is optional (defaults to `[]`). It is embedded by CI from the
site repo's `infra/lifecycle-hooks.json` file. See [Lifecycle Hooks](#lifecycle-hooks) below.

### Docker service labels

Each service that consumes an artifact declares it via a label in `docker-compose.yml`:

```yaml
services:
  nextjs:
    labels:
      artifact: frontend   # update.sh restarts this service when 'frontend' artifact changes
  wordpress:
    labels:
      artifact: wordpress
```

`lib/update-site.sh` uses `docker compose config --format json` to find all services with a
matching `artifact:` label and restarts exactly those services — nothing more.

### Artifact cache layout

```
artifact-cache/
├── frontend.tar.gz          ← stable path — Docker bind-mounts this
├── wordpress.tar.gz         ← stable path — Docker bind-mounts this
├── plugins -> /mnt/nfs/wordpress-plugins  ← symlink for local artifacts
├── frontend-<hash>.tar.gz   ← content-addressed cache (last 3 kept)
└── wordpress-<hash>.tar.gz
```

For `type: gcs` and `type: http` artifacts, stable paths are written atomically (`cp` + `mv`) so Docker never races with an in-progress download. For `type: local` artifacts, a symlink is created pointing to the pre-existing directory on the filesystem.
in-progress download and mistakenly creates a directory at that path.

### Shared-bucket prefix (`GCS_PREFIX`)

Multiple projects can share one GCS bucket by scoping each project's paths to a subfolder.
Pass `--gcs-prefix <path>` to `deploy-site.sh`:

```bash
sudo ./deploy-site.sh \
  --site-name mysite \
  --gcs-key-file /path/to/gcs-sa.json \
  --gcs-bucket gs://shared-artifacts \
  --gcs-prefix myproject
```

With `GCS_PREFIX=myproject` all paths become:

```
gs://shared-artifacts/myproject/channels/<channel>.json
gs://shared-artifacts/myproject/artifacts/<file>.tar.gz
```

The prefix is stored in `.env` as `GCS_PREFIX` and read automatically by `lib/update-site.sh`
on every update cycle. Omitting `--gcs-prefix` leaves the prefix blank and uses bucket-root
paths — fully backward compatible with existing single-project deployments.
Leading and trailing slashes are stripped automatically.

### `lib/update-site.sh` — generic artifact updater

Lives in dockerHosting at `lib/update-site.sh`. The systemd timer calls it every 15
minutes (±5 min jitter). It is entirely site-agnostic: the artifact list comes from the
channel metadata, the GCS bucket from `.env`, and the hook scripts from the site's own
`infra/lifecycle-hooks.json`.

```
Usage: lib/update-site.sh <deploy-dir> [options]

Options:
  --trigger <bootstrap|update>  Lifecycle hook trigger (default: update)
  --pull-only                   Download artifacts but do not restart containers
  --skip-artifact-download      Use cached artifacts; skip GCS (--force to restart)
  --force                       Force-recreate all containers even if up to date
  --dry-run                     Check staleness and report but make no changes
```

Trigger an immediate update:

```bash
sudo /opt/apps/<site>/bin/update-now
# or directly:
sudo /opt/dockerHosting/lib/update-site.sh /opt/apps/<site>

# Dry-run to see what would change:
sudo /opt/dockerHosting/lib/update-site.sh /opt/apps/<site> --dry-run

# Force-recreate all containers:
sudo /opt/dockerHosting/lib/update-site.sh /opt/apps/<site> --force
```

### Lifecycle hooks

Sites can declare optional scripts that run at specific points in the deployment
lifecycle. This is useful for project-specific setup that can't be baked into a container
image — generating self-signed certificates, seeding a database, or running a health
probe after restart.

Hooks are declared in the site repo at `infra/lifecycle-hooks.json` (which lives inside
the infra artifact and is therefore updated atomically with the rest of the infra):

```json
{
  "version": "1",
  "hooks": [
    {
      "script":      "infra/bootstrap/setup-ssl.sh",
      "trigger":     "bootstrap",
      "phase":       "post-start",
      "description": "Generate self-signed Kong SSL certificate on first deploy"
    },
    {
      "script":      "infra/bootstrap/drain.sh",
      "trigger":     "update",
      "phase":       "pre-start",
      "description": "Gracefully drain in-flight requests before restarting"
    }
  ]
}
```

| Field | Values | Meaning |
|-------|--------|---------|
| `script` | path relative to `DEPLOY_DIR` | must exist inside the extracted infra artifact |
| `trigger` | `bootstrap` \| `update` | `bootstrap` = first deploy only; `update` = every timer cycle |
| `phase` | `pre-start` \| `post-start` | before or after `docker compose up` |
| `description` | string (optional) | written to the update log |

**Execution order for `bootstrap` trigger** (first deploy via `deploy-site.sh`):

```
extract infra artifact
generate application secrets
bootstrap/pre-start hooks   ← run before stack starts
docker compose up
bootstrap/post-start hooks  ← run after stack is up
```

**Execution order for `update` trigger** (every systemd timer cycle):

```
download + decrypt stale artifacts
extract new infra artifact (if stale)
update/pre-start hooks      ← run before any restart
docker compose pull
docker compose up (stale services)
update/post-start hooks     ← run after restart
```

Hook scripts receive no arguments. If a hook exits non-zero the update aborts immediately.
Missing hook scripts are logged as a warning and skipped (not an error), so it is safe to
declare hooks that are added progressively.

The CI workflow embeds the `hooks` array verbatim into the channel metadata JSON at
promotion time, so `deploy-site.sh` can read bootstrap hooks from the metadata before the
infra artifact is even extracted. Subsequent timer runs read from the local
`infra/lifecycle-hooks.json` (which is kept up-to-date by infra artifact extraction).

**Adding a hook to a site repo:**

1. Create the script in `infra/bootstrap/` (e.g. `infra/bootstrap/setup-ssl.sh`)
2. Add the entry to `infra/lifecycle-hooks.json`
3. Push — CI embeds the hook in the channel metadata on next build

## Integration with Other Repositories

This repository works alongside:
- **dockerBuildfiles**: Builds shared container images published to Google Artifact Registry. Images are pulled by `update.sh` via `docker compose pull` on each update cycle.
- **site repos** (e.g. example-site): Each site repo contains its own `infra/` directory (packaged as the `infra` artifact), CI workflow that builds artifacts and promotes channel metadata to GCS, `docker-compose.yml` with `artifact:` labels on consuming services, and optionally `infra/lifecycle-hooks.json` declaring project-specific hook scripts.

## Security Verification

Quick commands to confirm the hardening posture after setup:

```bash
sudo ufw status verbose                      # Firewall rules
chronyc tracking                             # NTP sync status
sudo aa-status --summary                     # AppArmor profiles loaded
sudo ausearch -ts today | aureport --summary # Today's audit events
sudo aide-check                              # File integrity check (after AIDE init)
sudo fail2ban-client status sshd             # fail2ban SSH jail
sudo lynis audit system                      # Full CIS benchmark scan
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /etc:/etc:ro \
  docker/docker-bench-security               # CIS Docker benchmark
```

See [docs/compliance.md](docs/compliance.md) for the full control mapping and gap analysis.

## Troubleshooting

### Docker Permission Denied

After initial setup, you must log out and log back in for group changes:

```bash
logout
# Log back in
```

Or manually refresh groups:

```bash
newgrp docker
```

### Firewall Blocking Connections

Check firewall status:

```bash
sudo ufw status
```

Allow specific ports:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 22/tcp
```

### Log Rotation Not Working

Test log rotation manually:

```bash
sudo logrotate -f /etc/logrotate.d/{site-name}
```

Check log rotation status:

```bash
sudo cat /var/lib/logrotate/status
```

### Email Notifications Not Working

Check msmtp log file for errors:

```bash
sudo tail -f /var/log/msmtp.log
```

Test email sending manually:

```bash
echo "Test message" | mail -s "Test Subject" your@email.com
```

Verify msmtp configuration:

```bash
sudo cat /etc/msmtprc
```

Common issues:
- **Gmail**: Use an App Password, not your regular password
- **TLS errors**: Check if port 587 (TLS) or 465 (SSL) is correct for your provider
- **Authentication failed**: Verify username/password are correct
- **Blocked port**: Some ISPs block outbound port 25, use 587 instead

### Artifact Decryption Key Errors

If deployment fails with "Artifact requires encryption and signing but keys not found":

```bash
# Verify key files exist and are readable
ls -lh /root/aes.key /root/pub.pem

# Check the files contain valid key material (not empty)
wc -l /root/aes.key /root/pub.pem

# Ensure you're passing the correct paths
sudo ./deploy-site.sh \
  --artifact-aes-key-file /root/aes.key \
  --artifact-signing-pub-key-file /root/pub.pem \
  ... # other required flags
```

Common issues:
- **Wrong file paths**: Ensure paths are absolute and files exist
- **Empty key files**: Keys must contain valid base64 (AES) or PEM (RSA) formatted data
- **Permission errors**: Key files should be readable by root (the script runs as root)
- **Keys not provided**: If artifacts are encrypted/signed, both keys are required

The script copies these keys to `${DEPLOY_DIR}/infra/secrets/` during deployment. Subsequent updates read from that location.

### Artifact update fails / container not starting

```bash
# Check update logs
journalctl -fu <site>-updater.service

# Verify artifact cache has plain tar files (not directories)
ls -lh /opt/apps/<site>/artifact-cache/

# Check a specific artifact is a valid tar
tar tzf /opt/apps/<site>/artifact-cache/frontend.tar.gz | head

# Force re-download and restart
sudo /opt/dockerHosting/lib/update-site.sh /opt/apps/<site> --force
```

If `artifact-cache/frontend.tar.gz` is a **directory** (Docker created it before the
file existed), remove it and re-run the updater:

```bash
sudo rm -rf /opt/apps/<site>/artifact-cache/frontend.tar.gz
sudo /opt/dockerHosting/lib/update-site.sh /opt/apps/<site>
```

### Lifecycle hook fails

If a hook script exits non-zero the update aborts and logs the failure. Check the
journal for the hook name and error:

```bash
journalctl -fu <site>-updater.service | grep -A5 "Hook\|FATAL"
```

To skip hooks for an emergency restart (e.g. a broken hook blocking updates), run the
updater directly with the hook script temporarily renamed or made non-executable:

```bash
chmod -x /opt/apps/<site>/infra/bootstrap/<hook>.sh
sudo /opt/dockerHosting/lib/update-site.sh /opt/apps/<site> --force
chmod +x /opt/apps/<site>/infra/bootstrap/<hook>.sh
```

Note: hook scripts are overwritten on the next infra artifact extraction, so any manual
permission change is ephemeral — fix the hook script in the site repo instead.

### AIDE File Integrity Monitoring

Check AIDE initialization status:

```bash
aide-init-status
```

During setup, AIDE database initialization runs in the background and typically takes 5-10 minutes. Check the progress:

```bash
tail -f /var/log/aide/aide-init.log
```

Run manual file integrity check (only after initialization completes):

```bash
aide-check
```

Update AIDE database after making authorized changes:

```bash
sudo aide-update
```

Common issues:
- **Initialization still running**: Wait for initialization to complete (check with `aide-init-status`)
- **Database not found**: Initialization may have failed, check `/var/log/aide/aide-init.log`
- **False positives**: After making authorized changes, run `sudo aide-update` to update the baseline
- **Check failures**: AIDE detects changes - review the report carefully to determine if changes are authorized

## Observability (pluggable)

dockerHosting can install an optional host-level observability agent that
monitors the host kernel and every Docker container regardless of which
site/stack owns them. The agent is **opt-in** (default OFF), provider-pluggable,
and managed as a **singleton per host** by systemd — not by any site's compose
stack.

Supported providers today:

- **New Relic Infrastructure (EU region)** — single licence key, fixed FQDN
  allowlist.
- **OpenTelemetry Collector (contrib distribution)** — exports via OTLP/HTTPS
  to any compatible back-end (Grafana Cloud, Honeycomb, self-hosted
  Tempo/Mimir, …). Operator supplies the endpoint URL and an Authorization
  header value.

The mechanism is designed so additional providers (Datadog, Grafana Agent, …)
can be added by dropping templates into
[`templates/observability/`](templates/observability/) — see
[Adding another provider](#adding-another-provider) below.

### What the agent does

- Host metrics — CPU, memory, disk, network, process inventory, kernel info.
- Container metrics — per-container CPU/memory/network/IO via the Docker socket
  (mounted read-only) and label inventory.
- Inventory snapshots — installed packages, sysctl, users, services.
- All data egresses **only** to the configured provider's EU endpoints.

### Install (New Relic)

```bash
sudo ./setup.sh --observability=newrelic --observability-key=$NR_KEY
```

A back-compatible alias is accepted: `--newrelic --newrelic-key=$NR_KEY`.

The installer:
1. Validates the licence-key format (provider-specific validator).
2. Writes `/etc/observability/newrelic.env` (mode 600, root:root) with `NRIA_LICENSE_KEY=…`.
3. Writes `/opt/observability/newrelic/docker-compose.yml`.
4. Installs the generic systemd unit `observability-agent.service`.
5. Configures the egress allowlist (see below).
6. Enables and starts the unit; waits up to 60 s for the container to be running.

The script is idempotent: re-running with the same key is a no-op; re-running
with a different key updates the env file and restarts the service atomically.

### Verify

```bash
systemctl status observability-agent
docker ps --filter name=newrelic-infra
docker logs newrelic-infra
```

The host should appear in the New Relic UI under the **EU region** within ~2
minutes. Filter by custom attribute `managed_by = dockerHosting` to find it.

### Rotate the licence key

Re-run setup with the new key:

```bash
sudo ./setup.sh --observability=newrelic --observability-key=$NEW_KEY --force=observability
```

### Install (OpenTelemetry Collector)

```bash
sudo ./setup.sh \
  --observability=opentelemetry \
  --observability-key="Bearer $OTLP_TOKEN" \
  --observability-endpoint=https://otlp-gateway-prod-eu-west-2.grafana.net/otlp
```

The operator supplies two values:

- `--observability-key=` is the **value of the `Authorization` header** the
  collector will send on every OTLP/HTTPS request (e.g. `Bearer <token>` for
  Grafana Cloud, `Basic <base64>` for Honeycomb classic, `api-key <token>` for
  some self-hosted gateways). Stored in `/etc/observability/opentelemetry.env`
  as `OTLP_AUTH_HEADER` (mode 600).
- `--observability-endpoint=` is the **full HTTPS URL** of the OTLP back-end.
  Stored as `OTLP_ENDPOINT` in the same env file. `http://` is rejected — the
  egress allowlist is 443/tcp only.

The installer:

1. Validates both values (format only — runtime auth is verified by the
   back-end on first request).
2. Writes `/etc/observability/opentelemetry.env`.
3. Writes `/opt/observability/opentelemetry/docker-compose.yml` from the
   pinned `otel/opentelemetry-collector-contrib` image.
4. Writes `/opt/observability/opentelemetry/config.yaml` — the collector's
   pipeline definition. **This file is the customisation surface** for
   operators who want non-default receivers / processors / exporters;
   re-running setup without `--force=observability` will preserve operator
   edits.
5. Derives the FQDN from the endpoint URL, writes it to
   `/etc/observability/opentelemetry.egress`, and runs the egress allowlist
   refresh against that file.
6. Installs the generic systemd unit and starts the collector.

Default pipeline collects:

- Host metrics via the `hostmetrics` receiver (cpu, memory, disk, filesystem,
  network, load, paging, process inventory) — `/` is mounted at `/hostfs`
  inside the container.
- Per-container metrics via the `docker_stats` receiver (CPU, memory, network
  RX/TX, block I/O) — the Docker socket is mounted read-only.
- Resource attributes `service.instance.id = <hostname>` and
  `managed_by = dockerHosting` (mirrors the NR custom-attribute semantics so
  the same filter works across providers).

The collector's `health_check` extension is bound to `127.0.0.1:13133` only:

```bash
curl -fsS http://127.0.0.1:13133/
```

Rotate the token / change the endpoint by re-running with the new value(s):

```bash
sudo ./setup.sh --observability=opentelemetry \
  --observability-key="Bearer $NEW_TOKEN" \
  --observability-endpoint=https://otlp.new.example.com \
  --force=observability
```

### Egress allowlist (ipset + refresh timer)

ufw is the host's egress firewall; ufw has no native FQDN support. Approach:

- `scripts/configure-observability-egress.sh` creates ipset `obs_egress_ips`,
  resolves the provider's FQDN list (e.g. `templates/observability/newrelic.egress`)
  via the system resolver (no DNS-layer change — systemd-resolved is untouched),
  and adds the IPs to the set.
- A ufw `before.rules` line `-m set --match-set obs_egress_ips dst --dport 443
  -j ACCEPT` allows outbound HTTPS to those IPs only.
- A systemd timer `observability-egress-refresh.timer` re-resolves the FQDNs on
  boot and daily (+ jitter) to track provider IP rotations.

Provider FQDNs for New Relic EU1 (shipped statically in
`templates/observability/newrelic.egress`):

- `infra-api.eu.newrelic.com`
- `metric-api.eu.newrelic.com`
- `log-api.eu.newrelic.com`
- `identity-api.eu.newrelic.com`

US endpoints are **not** allowlisted — outbound traffic to `*.us.newrelic.com`
will be dropped by ufw default-deny-out.

#### Egress allowlist (OpenTelemetry)

Unlike New Relic, the OTLP back-end host varies per operator, so the FQDN
list cannot be shipped statically. At install time the installer parses the
host part out of `--observability-endpoint=<url>` and writes it to
`/etc/observability/opentelemetry.egress` (one FQDN, the OTLP gateway). Both
`configure-observability-egress.sh` and the daily refresh service prefer
`/etc/observability/<provider>.egress` over the shipped template, so the
dynamic FQDN flows through the same ipset + ufw + refresh-timer machinery as
the static lists. Changing endpoints (re-run with a new
`--observability-endpoint=` + `--force=observability`) rewrites the runtime
file and refreshes the ipset.

**Known limitation:** if a provider rotates IPs faster than the daily refresh
window, brief connectivity gaps are possible until the next refresh. Force a
refresh with `sudo systemctl start observability-egress-refresh.service`.

### Non-coexistence rule

**Sites MUST NOT run their own `newrelic-infra`, `otel-collector`, or
equivalent container.** Exactly one observability provider per host.

Two agents on one host:
- Double-count host CPU/memory/disk/network metrics.
- Produce duplicate per-container reports.
- Conflict on custom attributes (the second-registered agent overwrites the
  first in NR's host inventory).

See [VelaAir feature-469](https://github.com/DigitalisCloudServices/VelaAir/blob/main/docs/workstream/improvements/workInProgress/feature-469-newrelic-infra-agent-compose-pattern.md)
for the site-side companion documentation.

### Site label vocabulary

Sites should label their containers so operators can filter them in the
provider UI. VelaAir uses the following keys — other sites on this host are
encouraged to adopt the same scheme:

| Label key                  | Vocabulary                                       | Notes                          |
|----------------------------|--------------------------------------------------|--------------------------------|
| `com.velaair.environment`  | `prod`, `staging`, `dev`                         | Lifecycle stage                |
| `com.velaair.tier`         | `frontend`, `backend`, `infra`                   | Architectural tier             |
| `com.velaair.role`         | `web`, `api`, `worker`, `proxy`, `db`            | Functional role                |
| `com.velaair.team`         | `platform`, `web`, `data`, …                     | Ownership                      |
| `com.velaair.profile`      | `default`, `lean`, `debug`                       | Deployment profile             |
| `com.velaair.slot`         | `blue`, `green`                                  | Only on blue/green workloads   |
| `com.velaair.replica`      | `1`, `2`, …                                      | Only on multi-replica services |

In the New Relic UI, navigate to **Infrastructure → Third-party services →
Docker** and filter on any of the above. See VelaAir F469 §2.2 for the
authoritative vocabulary tables.

### Adding another provider

To add a new observability provider (e.g. Datadog, Grafana Agent):

1. Drop `templates/observability/<provider>.compose.template` — Compose file
   for the agent. Use `network_mode: host`, `pid: host`, `/:/host:ro` (or
   `/:/hostfs:ro,rslave` per provider convention) if you need host-kernel
   metrics; mount `/var/run/docker.sock:/var/run/docker.sock:ro` for
   container visibility. Pin the image tag (no `:latest`).
2. Drop `templates/observability/<provider>.egress` — one FQDN per line; these
   become the host's egress allowlist for that provider. If the back-end host
   is operator-supplied rather than fixed, leave this file as a comment-only
   placeholder and have the installer write the runtime list to
   `/etc/observability/<provider>.egress` (the egress script + refresh
   service prefer the runtime file over the shipped template). See the
   OpenTelemetry provider for an example of the dynamic pattern.
3. Drop `templates/observability/<provider>.validate.sh` — exits 0 if the
   supplied values are well-formed, non-zero otherwise. Called with
   `"$KEY" "$ENDPOINT"`; providers that only use the key ignore `$2`.
4. Add `<provider>` to `SUPPORTED_PROVIDERS` in
   [`scripts/install-observability.sh`](scripts/install-observability.sh) and
   add a `case` arm in `render_env_content` describing the env vars to write
   into `/etc/observability/<provider>.env`. Add the container name to the
   `verify_running` case statement.
5. If the provider needs additional config files (beyond the compose file),
   add a `case` arm in `write_provider_extras` and ship the template
   alongside the others; the installer preserves operator edits to the
   deployed copy unless `--force=observability` is set.

The generic systemd unit, env-file layout, ipset egress mechanism,
previous-provider teardown, and non-coexistence rule apply unchanged.

## Development

### Prerequisites

**Required:**
```bash
# macOS
brew install shellcheck bats-core yamllint

# Debian/Ubuntu
sudo apt-get install shellcheck bats yamllint
```

**Optional (for code quality checks):**
```bash
# macOS
brew install shfmt shellharden

# Universal (Python/Rust)
pip install bashate
cargo install shellharden  # if Rust installed

# Coverage (optional)
brew install kcov  # macOS
apt-get install kcov  # Debian
```

### Running tests

```bash
# Full test suite (lint + syntax + bats + quality checks)
make test

# Comprehensive suite including optional quality tools
make test-all

# Fast CI subset (no optional dependencies)
make ci

# Individual test categories
make lint              # shellcheck on all scripts
make test-syntax       # bash -n syntax check
make test-args         # argument validation
make test-traefik      # Traefik script tests
make test-lib          # lib/ script tests
**BATS Test Suites:**

| Test file | What it covers |
|-----------|---------------|
| `tests/test_syntax.bats` | `bash -n` parse check for all scripts |
| `tests/test_arg_validation.bats` | Scripts exit non-zero + print usage when required args missing |
| `tests/traefik/test_add_site.bats` | 28 tests: validation, config generation, site naming, SSL cert logic |
| `tests/traefik/test_remove_site.bats` | 13 tests: removal, site listing, domain-to-name conversion |
| `tests/traefik/test_install_traefik.bats` | 26 tests: nginx detection, migration, config writing |
| `tests/lib/test_decrypt.bats` | Artifact decryption and signature verification |
| `tests/lib/test_gcs.bats` | GCS OAuth2 and download helpers |
| `tests/test_lifecycle_hooks.bats` | Lifecycle hook parsing and execution |
| `tests/test_pam_policy.bats` | PAM password policy configuration |
| `tests/test_yaml.bats` | YAML syntax validation for templates |
| `tests/security/*.bats` | 11 security hardening script test suites |
| `tests/test_*.bats` | 16 additional infrastructure and deployment tests |

**Total:** ~1,200+ test cases across 39 scripts (95% coverage)

**Code Quality Checks:**

| Check | Tool | What it enforces |
|-------|------|------------------|
| Formatting | `shfmt` | Consistent indentation (4 spaces), case indentation, space redirects |
| Style | `bashate` | PEP8-style bash conventions, line length, naming |
| Security | `shellharden` | Proper quoting, safe variable expansion, common pitfalls |
| Complexity | Custom | Functions ≤30 lines, max nesting depth 3 |
| Dead code | Custom | Detects unused functions |
| Documentation | Custom | Functions >10 lines must have comments |
| Permissions | Custom | All `.sh` files must be executable
make test-security     # Security anti-patterns (shellharden)
make test-complexity   # Function length & nesting depth
make test-unused       # Detect unused functions
make test-docs         # Documentation coverage
make test-permissions  # Verify executable permissions

# Utilities
make format           # Auto-format all scripts
make coverage         # Generate coverage report
make check-deps       # Verify all tools installed
```

### Test coverage

| Test file | What it covers |
|--

### Pre-commit hooks

A git pre-commit hook automatically runs quality checks before each commit:
- shellcheck linting
- Syntax validation
- Format checking (if shfmt installed)
- Style checking (if bashate installed)

To bypass the hook temporarily:
```bash
git commit --no-verify
```

To install the hook on a fresh clone:
```bash
chmod +x .git/hooks/pre-commit
```---------|---------------|
| `tests/test_syntax.bats` | `bash -n` parse check for all 33 shell scripts |
| `tests/test_arg_validation.bats` | Scripts exit non-zero + print usage when required args are missing |
| `tests/traefik/test_add_site.bats` | 28 tests: validation, config generation, site naming, SSL cert logic, Traefik running check |
| `tests/traefik/test_remove_site.bats` | 13 tests: removal, site listing, domain-to-name conversion |
| `tests/traefik/test_install_traefik.bats` | 26 tests: nginx detection, migration helpers, config writing, docker invocations, prompt flags |

### Adding tests for new scripts

1. Create `tests/<category>/test_<script>.bats`
2. `load '../helpers/common'` at the top
3. Call `setup_mocks` and `setup_traefik_dirs` (if needed) in `setup()`
4. Use `create_mock` / `create_call_log_mock` to stub system commands
5. Use env vars (`TRAEFIK_DYNAMIC_DIR`, etc.) to redirect paths away from `/etc/`

### Linting

shellcheck runs on every PR via GitHub Actions. Configuration is in [.shellcheckrc](.shellcheckrc).

To suppress a specific warning inline:
```bash
# shellcheck disable=SC2086
some_command $unquoted_intentionally
```

## Contributing

When adding new features:
1. Update this README
2. Write tests in `tests/` for any new scripts
3. Run `make test` before pushing
4. Keep functions ≤30 lines; max nesting depth 3
5. Add env-var overrides for any paths that tests need to redirect (see existing Traefik scripts as a pattern)

## License

[Your License Here]
