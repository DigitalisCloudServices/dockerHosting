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
sudo apt-get update && sudo apt-get install curl -y
curl -fsSL https://raw.githubusercontent.com/DigitalisCloudServices/dockerHosting/main/setup.sh -o setup.sh
chmod +x setup.sh
sudo ./setup.sh
```

Or if you have the repository cloned:

```bash
sudo ./setup.sh
```

**What it does:**
- Installs Docker and Docker Compose
- Installs essential packages (git, curl, make, etc.)
- Configures firewall (UFW)
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
│   ├── setup-users.sh            # User and permission management
│   ├── setup-logrotate.sh        # Log rotation configuration
│   ├── configure-firewall.sh     # Firewall setup
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
- Firewall configuration (UFW)
- User isolation per site
- Proper file permissions
- Secure secret handling

### Logging
- Automatic log rotation
- Configurable retention periods
- Docker container log limits
- System log management

### Deployment
- Blue-green deployment support
- Environment-based configuration
- Git-based deployments
- Artifact support

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

## Contributing

When adding new features:
1. Update this README
2. Keep scripts modular and reusable
3. Follow existing patterns from serverSetup and KSE-Portal
4. Test on fresh Debian Trixie installation

## License

[Your License Here]
