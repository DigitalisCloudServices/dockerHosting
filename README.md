# dockerHosting

Server setup and deployment automation for Debian Trixie servers hosting Docker-based applications.

**Boundary proxy:** [Traefik v3.6](https://traefik.io/traefik/) — self-signed SSL out of the box, hostname-based routing, zero-reload config via file provider.

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
- Configures firewall (UFW)
- Sets up security hardening (kernel params, SSH, fail2ban, audit logging)
- Sets up automated security updates
- Configures email notifications (optional - for alerts and system notifications)
- Sets up log rotation

**After setup:** Log out and log back in for group changes to take effect.

> **Re-running on a server with nginx:** `setup.sh` detects an existing nginx install and prompts to migrate automatically (migrates site configs + SSL certs, uninstalls nginx) or skip.

### 2. Deploy a New Site

Once the server is set up, deploy a new site from a Git repository.

**Interactive mode** (prompts for all information):

```bash
./deploy-site.sh
```

**Scripted mode** (pass all parameters):

```bash
./deploy-site.sh \
  --git-url "git@github.com:org/repo.git" \
  --site-name "mysite" \
  --deploy-dir "/opt/apps/mysite" \
  --git-branch "main" \
  --create-user yes \
  --setup-logrotate yes \
  --setup-systemd no \
  --ssh-key-file "/path/to/ssh/key" \
  --encryption-key "your-key"
```

In interactive mode, the script will prompt for:
- Git repository URL
- Site name
- Deployment directory (default: `/opt/apps/{site-name}`)
- Encryption keys/secrets
- Git SSH private key (optional - for private repositories)
- User/group for the site
- Additional configuration options

**What it does:**
- Clones the Git repository
- Sets up users and permissions
- Configures Git SSH authentication (if private key provided)
- Configures log rotation for the site
- Creates systemd service (optional)
- Sets up environment files
- Initializes Docker environment

**After deployment**, add a Traefik route using the `SITE_HOSTNAME` and `SITE_PORT` from the site's `.env`:

```bash
sudo /opt/dockerHosting/scripts/add-traefik-site.sh <domain> <port>
```

**Command-line Options:**
- `--git-url <url>` - Git repository URL (required)
- `--site-name <name>` - Site name (required)
- `--deploy-dir <path>` - Deployment directory (default: /opt/apps/<site-name>)
- `--git-branch <branch>` - Git branch to clone (optional)
- `--create-user <yes|no>` - Create dedicated user (default: yes)
- `--setup-logrotate <yes|no>` - Setup log rotation (default: yes)
- `--setup-systemd <yes|no>` - Setup systemd service (default: no)
- `--encryption-key <key>` - Encryption key (optional)
- `--ssh-key-file <path>` - Path to SSH private key file (optional)
- `--additional-vars <vars>` - Additional environment variables (optional)
- `--non-interactive` - Run without prompts (auto-enabled when git-url and site-name provided)

**Git SSH Keys:**
When deploying from a private repository, you can provide an SSH private key. The script will:
- Save the key securely for the site user (~/.ssh/)
- Configure SSH to use the key for the Git host
- Enable the site user to pull/push updates without password prompts

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
├── scripts/                          # Modular setup scripts
│   ├── install-docker.sh             # Docker installation
│   ├── install-packages.sh           # Package installation
│   ├── install-traefik.sh            # Traefik boundary proxy installation
│   ├── add-traefik-site.sh           # Add a site to Traefik (DOMAIN PORT)
│   ├── remove-traefik-site.sh        # Remove a site from Traefik
│   ├── install-nginx.sh              # Nginx (kept for in-container use)
│   ├── setup-users.sh                # User and permission management
│   ├── setup-logrotate.sh            # Log rotation configuration
│   ├── setup-email.sh                # Email notification setup
│   ├── configure-firewall.sh         # Firewall setup
│   ├── harden-*.sh                   # Security hardening scripts
│   └── configure-site.sh             # Site-specific configuration
├── templates/                        # Configuration templates
│   ├── traefik/
│   │   ├── traefik.yml               # Traefik static config template
│   │   ├── middleware.yml            # Shared security headers + rate limiting
│   │   └── site.yml.template         # Per-site dynamic config template
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
│   ├── test_syntax.bats              # bash -n syntax check for all 28 scripts
│   └── test_arg_validation.bats      # Argument validation for key scripts
└── config/                           # Configuration files
    └── packages.list                 # List of packages to install
```

## Usage Examples

### Example 1: Deploy KSE-Portal

```bash
./deploy-site.sh
# Enter when prompted:
# - Git repo: https://github.com/DigitalisCloudServices/KSE-Portal.git
# - Site name: kse-portal
# - Directory: /opt/apps/kse-portal
# - User: kse-portal
# - Encryption keys: [paste keys]
```

### Example 2: Deploy Multiple Environments

Deploy production and staging on the same server:

```bash
# Production
./deploy-site.sh
# Site name: myapp-prod
# Directory: /opt/apps/myapp-prod
# Branch: main

# Staging
./deploy-site.sh
# Site name: myapp-staging
# Directory: /opt/apps/myapp-staging
# Branch: develop
```

### Example 3: Deploy from Private Repository

Deploy a site from a private Git repository using SSH key authentication:

```bash
./deploy-site.sh
# Enter when prompted:
# - Git repo: git@github.com:YourOrg/private-repo.git
# - Site name: myapp
# - Directory: /opt/apps/myapp
# - Provide SSH private key for Git? y
# - [Paste your SSH private key, then press Ctrl+D]
# - Create dedicated user? yes
```

The SSH key will be saved securely and configured for the site user, allowing them to pull updates:
```bash
# As the site user, pull updates without password prompts
sudo -u myapp git -C /opt/apps/myapp pull
```

After deployment, the script displays the exact command to replicate the deployment:
```bash
[INFO] To replicate this deployment, use:

sudo ./deploy-site.sh \
  --git-url "git@github.com:YourOrg/private-repo.git" \
  --site-name "myapp" \
  --deploy-dir "/opt/apps/myapp" \
  --create-user yes \
  --setup-logrotate yes \
  --setup-systemd no \
  --ssh-key-file "/path/to/ssh/key"
```

## Manual Script Usage

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
- Firewall configuration (UFW) with default-deny policy
- Kernel hardening (ASLR, SYN cookies, IP spoofing protection)
- SSH hardening (key-only authentication, rate limiting)
- fail2ban protection for brute-force prevention
- Audit logging (auditd) for security events
- Automated security updates (unattended-upgrades)
- File integrity monitoring (AIDE with background initialization)
- Docker daemon hardening
- User isolation per site
- Proper file permissions
- Secure secret handling

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
- Blue-green deployment support
- Environment-based configuration
- Git-based deployments
- Artifact support
- Traefik v3.6 boundary proxy — hostname routing, self-signed SSL, zero-reload config

## Integration with Other Repositories

This repository works alongside:
- **dockerBuildfiles**: Provides shared Docker container definitions
- **KSE-Portal**: Customer sites that use these deployment scripts
- **serverSetup**: Provides baseline setup scripts

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

### Git SSH Authentication Issues

If the site user cannot pull/push from Git:

Check SSH key permissions:

```bash
# SSH key should be 600, .ssh directory should be 700
sudo ls -la /home/site-user/.ssh/
```

Test SSH connection to Git host:

```bash
sudo -u site-user ssh -T git@github.com
# Should show: "Hi username! You've successfully authenticated..."
```

Verify SSH config:

```bash
sudo cat /home/site-user/.ssh/config
```

Common issues:
- **Permission denied (publickey)**: SSH key not added to Git provider (GitHub/GitLab/Bitbucket)
- **Host key verification failed**: Remove offending key: `sudo -u site-user ssh-keygen -R github.com`
- **Wrong key format**: Ensure you provided the private key, not the public key
- **Key permissions**: Fix with `sudo chmod 600 /home/site-user/.ssh/id_*` and `sudo chown site-user:site-user /home/site-user/.ssh/id_*`

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
make lint           # shellcheck on all 28 scripts
make test-syntax    # bash -n syntax check for every script
make test-args      # argument validation for key scripts
make test-traefik   # comprehensive tests for the Traefik scripts

# Check your tools are installed
make check-deps
```

### Test coverage

| Test file | What it covers |
|-----------|---------------|
| `tests/test_syntax.bats` | `bash -n` parse check for all shell scripts |
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
