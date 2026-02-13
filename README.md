# dockerHosting

Server setup and deployment automation for Debian Trixie servers hosting Docker-based applications.

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
- Configures firewall (UFW)
- Sets up security hardening (kernel params, SSH, fail2ban, audit logging)
- Sets up automated security updates
- Configures email notifications (optional - for alerts and system notifications)
- Sets up log rotation
- Adds current user to docker group

**After setup:** Log out and log back in for group changes to take effect.

### 2. Deploy a New Site

Once the server is set up, deploy a new site from a Git repository:

```bash
./deploy-site.sh
```

The script will interactively prompt for:
- Git repository URL
- Site name
- Deployment directory (default: `/opt/{site-name}`)
- Encryption keys/secrets
- User/group for the site
- Additional configuration options

**What it does:**
- Clones the Git repository
- Sets up users and permissions
- Configures log rotation for the site
- Creates systemd service (optional)
- Sets up environment files
- Initializes Docker environment

## Repository Structure

```
dockerHosting/
├── README.md                     # This file
├── setup.sh                      # Main server setup script
├── deploy-site.sh                # Interactive site deployment script
├── scripts/                      # Modular setup scripts
│   ├── install-docker.sh         # Docker installation
│   ├── install-packages.sh       # Package installation
│   ├── install-nginx.sh          # Boundary Nginx installation
│   ├── setup-users.sh            # User and permission management
│   ├── setup-logrotate.sh        # Log rotation configuration
│   ├── setup-email.sh            # Email notification setup
│   ├── configure-firewall.sh     # Firewall setup
│   ├── harden-*.sh               # Security hardening scripts
│   └── configure-site.sh         # Site-specific configuration
├── templates/                    # Configuration templates
│   ├── logrotate.conf.template   # Log rotation template
│   ├── systemd.service.template  # Systemd service template
│   └── env.template              # Environment file template
└── config/                       # Configuration files
    └── packages.list             # List of packages to install
```

## Usage Examples

### Example 1: Deploy KSE-Portal

```bash
./deploy-site.sh
# Enter when prompted:
# - Git repo: https://github.com/DigitalisCloudServices/KSE-Portal.git
# - Site name: kse-portal
# - Directory: /opt/kse-portal
# - User: kse-portal
# - Encryption keys: [paste keys]
```

### Example 2: Deploy Multiple Environments

Deploy production and staging on the same server:

```bash
# Production
./deploy-site.sh
# Site name: myapp-prod
# Directory: /opt/myapp-prod
# Branch: main

# Staging
./deploy-site.sh
# Site name: myapp-staging
# Directory: /opt/myapp-staging
# Branch: develop
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
sudo ./scripts/setup-logrotate.sh /opt/myapp myapp
```

### Setup User for Existing Site

```bash
sudo ./scripts/setup-users.sh myapp /opt/myapp
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
- Boundary Nginx for routing by hostname

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

## Contributing

When adding new features:
1. Update this README
2. Keep scripts modular and reusable
3. Follow existing patterns from serverSetup and KSE-Portal
4. Test on fresh Debian Trixie installation

## License

[Your License Here]
