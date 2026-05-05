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
  --site-name velaair \
  --gcs-key-file /path/to/gcs-sa.json \
  --artifact-aes-key-file /path/to/artifact_aes_key.txt \
  --artifact-signing-pub-key-file /path/to/artifact_signing_public_key.pem \
  --domain velaair.io \
  --kong-port 8443
```

**What `deploy-site.sh` does:**

1. Creates a dedicated system user (`nologin`) and deployment directory
2. Authenticates to GCS and downloads the `infra` artifact (bootstrap only — contains `docker-compose.yml`, nginx/Kong config, and any project-specific scripts)
3. Extracts the infra artifact, generates application secrets
4. Copies GCS and decryption keys into `infra/secrets/` (root-only, mode 600)
5. Writes a minimal `.env` (GCS bucket, Kong port, registry, infra hash)
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
  --site-name velaair \
  --gcs-key-file /root/keys/gcs-sa.json \
  --artifact-aes-key-file /root/keys/artifact_aes_key.txt \
  --artifact-signing-pub-key-file /root/keys/artifact_signing_public_key.pem \
  --domain velaair.io \
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
sudo /opt/apps/velaair/bin/update-now
# or equivalently:
sudo /opt/dockerHosting/lib/update-site.sh /opt/apps/velaair

# Check what would update without applying:
sudo /opt/dockerHosting/lib/update-site.sh /opt/apps/velaair --dry-run

# Force-recreate all containers with current artifacts:
sudo /opt/dockerHosting/lib/update-site.sh /opt/apps/velaair --force
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
  └► gs://<bucket>/artifacts/<type>-<hash>.tar.gz

  promotes channel metadata (including lifecycle_hooks from infra/lifecycle-hooks.json)
  └► gs://<bucket>/channels/prod-latest.json

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
  "infra_artifact": "infra-<hash>.tar.gz",
  "infra_hash":     "<sha>",
  "artifacts": [
    { "name": "frontend",  "artifact": "frontend-<hash>.tar.gz",  "git_hash": "<sha>" },
    { "name": "wordpress", "artifact": "wordpress-<hash>.tar.gz", "git_hash": "<sha>" }
  ],
  "lifecycle_hooks": [
    { "script": "infra/bootstrap/setup-ssl.sh", "trigger": "bootstrap", "phase": "post-start" }
  ],
  "promoted_at":   "2026-05-05T12:00:00Z",
  "github_run_id": "12345678"
}
```

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
├── frontend-<hash>.tar.gz   ← content-addressed cache (last 3 kept)
└── wordpress-<hash>.tar.gz
```

The stable paths are written atomically (`cp` + `mv`) so Docker never races with an
in-progress download and mistakenly creates a directory at that path.

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
- **site repos** (e.g. velaair-website): Each site repo contains its own `infra/` directory (packaged as the `infra` artifact), CI workflow that builds artifacts and promotes channel metadata to GCS, `docker-compose.yml` with `artifact:` labels on consuming services, and optionally `infra/lifecycle-hooks.json` declaring project-specific hook scripts.

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

## Development

### Prerequisites

```bash
# macOS
brew install shellcheck bats-core

# Debian/Ubuntu
sudo apt-get install shellcheck bats
```

### Running tests

```bash
# Full suite (lint + syntax + arg validation + Traefik tests)
make test

# Individual targets
make lint           # shellcheck on all 33 scripts
make test-syntax    # bash -n syntax check for every script
make test-args      # argument validation for key scripts
make test-traefik   # comprehensive tests for the Traefik scripts

# Check your tools are installed
make check-deps
```

### Test coverage

| Test file | What it covers |
|-----------|---------------|
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
