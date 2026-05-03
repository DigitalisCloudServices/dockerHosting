# UK NCSC Cloud Security Principles

## Overview

The UK National Cyber Security Centre (NCSC) Cloud Security Principles define 14 security properties that cloud and hosting services should satisfy to protect the data and workloads they host. Originally developed to underpin the UK government's G-Cloud and Digital Marketplace frameworks, they are widely used as a reference for cloud security due diligence and procurement assessments across the public and private sectors.

The 14 principles are:

1. Data in transit protection
2. Asset protection and resilience
3. Separation between users
4. Governance framework
5. Operational security
6. Personnel security
7. Secure development
8. Supply chain security
9. Secure user management
10. Identity and authentication
11. External interface protection
12. Secure service administration
13. Audit information and alerting for customers
14. Secure use of the service

## Why It's Relevant

The NCSC Cloud Security Principles are a practical, UK-government-backed reference framework for cloud hosting services. They are:
- Required or referenced by UK public sector procurement frameworks (G-Cloud, Crown Commercial Service)
- Commonly used by UK enterprise procurement teams assessing cloud hosting vendors
- Aligned with the NCSC Cyber Assurance Framework and the CE+ scheme
- A credible, vendor-neutral baseline for documenting the security posture of a hosting service

Even for organisations outside G-Cloud scope, alignment with the 14 principles provides a structured and UK-recognised way to articulate the security properties of hosted infrastructure.

## Executive Summary

**Estimated NCSC Cloud Principles technical readiness: ~75% ~ ~82%**

The range reflects controls satisfied by external architecture pending deployment validation: MFA at VPN/bastion (Principle 10), the full Cloudflare + Edge Firewall + ModSecurity perimeter (Principles 1, 3, 11), platform-level container egress filtering, and NewRelic log retention configuration.

The architecture maps strongly onto Principles 1 (data in transit), 2 (asset protection), 3 (separation), 5 (operational security), 7 (secure development), 8 (supply chain), 9 (user management), 10 (identity), 11 (external interfaces), and 12 (service administration). The main partial-coverage areas are Principle 4 (governance framework — organisational documentation), Principle 6 (personnel security — HR processes), Principle 13 (customer-facing audit information — no customer portal), and Principle 14 (customer guidance for secure use).

---

## Scope

### In Scope (Technical Principles)

| Principle | Description |
|---|---|
| 1 — Data in transit protection | TLS configuration, cipher management |
| 2 — Asset protection and resilience | Hardening, FIM, IaC DR |
| 3 — Separation between users | Per-site isolation, Docker network policy |
| 5 — Operational security | Monitoring, patching, vulnerability management |
| 7 — Secure development | IaC, testing, code validation |
| 8 — Supply chain security | Container scanning, signed artefacts |
| 9 — Secure user management | SSH, PAM, sudoers, access model |
| 10 — Identity and authentication | MFA, key-only SSH, PAM lockout |
| 11 — External interface protection | Perimeter architecture, UFW, Cloudflare |
| 12 — Secure service administration | Admin access controls, audit logging |

### Out of Scope

| Principle | Reason |
|---|---|
| 4 — Governance framework | Requires formal ISMS documentation and management commitment; organisational deliverable |
| 6 — Personnel security | Background screening, HR security, joiners/movers/leavers processes; organisational |
| 13 — Audit information and alerting for customers (full) | Customer-facing audit portal not implemented; NewRelic is operator-facing only |
| 14 — Secure use of the service (guidance aspect) | Customer security guidance documentation is an organisational deliverable |
| G-Cloud supplier submission | Requires formal supplier registration with Crown Commercial Service |

---

## External Controls

| Control | Provider | NCSC Principle |
|---|---|---|
| DDoS mitigation (L3/L4/L7) | Cloudflare | P1 (transit), P2 (resilience), P11 (external interface) |
| WAF + OWASP managed ruleset | Cloudflare | P11 — External interface protection; P5 — Malicious traffic filtering |
| Application-layer WAF | ModSecurity (DMZ) | P11 — DMZ boundary; P5 — Web attack detection |
| MFA enforcement | VPN / SSH bastion | P10 — MFA for all administrative access |
| Remote log retention and alerting | NewRelic | P5 (operational monitoring), P13 (operator audit information) |
| Block device encryption | VM hypervisor | P2 — Asset protection (encryption at rest) |
| Application-layer encryption | Applications | P1 / P2 — Data protection at rest within applications |
| Signed artefact delivery | CI/CD | P8 — Supply chain integrity |
| Application data backup + external replication | Application team | P2 — Data resilience and recovery |
| IaC-based DR (~20 min recovery) | Architecture | P2 — Infrastructure resilience |

---

## Principle Assessment

### Principle 1 — Data in Transit Protection (✓)

| Area | Status | Detail |
|---|---|---|
| TLS for all web traffic | ✓ | TLS 1.2/1.3 at Cloudflare edge and Traefik; AEAD ciphers only; no TLS 1.0/1.1 |
| No plaintext protocols | ✓ | No FTP, Telnet, unencrypted HTTP without redirect; SSH only for admin |
| SSH cipher strength | ✓ | ChaCha20-Poly1305, AES-GCM only; ED25519 / RSA-4096 keys — `harden-ssh.sh` |
| Certificate management | ~ | Let's Encrypt / Cloudflare-managed at edge; no formal certificate inventory |

### Principle 2 — Asset Protection and Resilience (✓)

| Area | Status | Detail |
|---|---|---|
| Physical security | Out of scope | Datacenter responsibility |
| Host OS hardening | ✓ | Comprehensive hardening: kernel sysctl, SSH, PAM, AppArmor, shared memory |
| Container image security | ✓ | Trivy blocks CRITICAL CVEs before deployment |
| File integrity monitoring | ~ | AIDE daily batch; real-time FIM not implemented — see [gaps.md](gaps.md) G4 |
| Resilience and recovery | ✓ | IaC rebuild in ~20 min; Cloudflare DDoS for availability; external application data replication |
| Data resilience | ✓ (at appropriate layers) | Block device encryption at VM hypervisor; application-layer encryption and backup |

### Principle 3 — Separation Between Users (✓)

| Area | Status | Detail |
|---|---|---|
| Per-site user isolation | ✓ | Dedicated OS user per site; site users cannot access other sites' files or containers |
| Container network isolation | ✓ | `icc=false` prevents inter-container communication across bridges; per-site networks |
| Privilege separation | ✓ | No docker group; per-command sudoers allow-list; no shared admin accounts |
| Docker userns-remap | Optional | Available as additional kernel-level isolation; prompted during `setup.sh` |

### Principle 4 — Governance Framework (~)

| Area | Status | Detail |
|---|---|---|
| Technical controls documented | ✓ | Full compliance documentation; controls mapped to multiple frameworks |
| Formal security management framework | ~ | No formal ISMS; technical controls are in place but policies and management commitment are organisational |
| Risk management process | Out of scope | Organisational deliverable |

### Principle 5 — Operational Security (✓)

| Area | Status | Detail |
|---|---|---|
| Vulnerability management | ✓ | `unattended-upgrades` daily OS patches; Trivy CRITICAL gate at deploy |
| Security monitoring | ✓ | NewRelic infrastructure agent; auditd 28+ rules → NewRelic; fail2ban SSH alerting |
| Protective monitoring | ✓ | Cloudflare WAF + ModSecurity real-time web attack detection; AIDE daily FIM |
| Configuration management | ✓ | Full IaC; all configuration is version-controlled code; immutable auditd rules |
| Incident response capability | ~ | Detection tooling in place; no formal incident response runbooks (organisational) |

### Principle 6 — Personnel Security (~)

| Area | Status | Detail |
|---|---|---|
| Background screening | Out of scope | HR process; organisational |
| Security awareness training | Out of scope | Personnel controls |
| Access removal on role change | ~ | Per-site accounts managed; no automated joiner/mover/leaver workflow |

### Principle 7 — Secure Development (✓)

| Area | Status | Detail |
|---|---|---|
| Infrastructure as Code | ✓ | All configuration is version-controlled code; no manual server changes |
| Automated testing | ✓ | BATS test suite (138+ tests); syntax validation in scripts (`sshd -t`, `visudo -c`) |
| CI/CD validation | ✓ | shellcheck in CI; deploy-time signature validation of artefacts |
| Secure defaults | ✓ | All scripts default to restrictive configuration; optional controls prompted interactively |

### Principle 8 — Supply Chain Security (✓)

| Area | Status | Detail |
|---|---|---|
| Container image vulnerability scanning | ✓ | Trivy blocks deployment on CRITICAL CVEs — `scan-image.sh` |
| Signed software delivery | ✓ | CI/CD delivers encrypted, signed artefacts; host validates signature before use |
| OS package integrity | ✓ | APT with signed repositories; `unattended-upgrades` applies only trusted packages |
| Image signing at container layer | ~ | CI/CD provides supply chain integrity; Cosign/DCT image signing not implemented — see [cis-docker.md](cis-docker.md) |

### Principle 9 — Secure User Management (✓)

| Area | Status | Detail |
|---|---|---|
| Authentication controls | ✓ | SSH key-only; no password authentication; `PasswordAuthentication no` |
| Access model | ✓ | Per-site users; per-command sudoers; no docker group |
| Account lockout | ✓ | PAM pam_faillock: 5 attempts → 15-min lockout; fail2ban progressive bans |
| Unique identities | ✓ | Dedicated per-site users; no shared accounts |
| Root login disabled | ✓ | `PermitRootLogin no`; root access requires sudo from named account |

### Principle 10 — Identity and Authentication (✓)

| Area | Status | Detail |
|---|---|---|
| MFA for administrative access | ✓ (at access layer) | MFA enforced at VPN/bastion before SSH is network-reachable; host-level TOTP (`setup-ssh-mfa.sh`) available as defence-in-depth |
| Key-based authentication | ✓ | SSH ED25519 or RSA-4096 keys only; no password authentication over SSH |
| PAM password policy | ✓ | 14 chars minimum; uppercase/lowercase/digit/special; 5-password history; `setup-pam-policy.sh` |

### Principle 11 — External Interface Protection (✓)

| Area | Status | Detail |
|---|---|---|
| Internet-facing boundary | ✓ | Cloudflare → Edge Firewall → ModSecurity → UFW — four-layer default-deny perimeter |
| No unnecessary internet exposure | ✓ | Traefik on 80/443 only; SSH not internet-exposed; no other ports open to internet |
| Container egress | ~ | Docker bypasses UFW at host level; platform-level and network-level external controls assumed in place — **validate per deployment** — see [gaps.md](gaps.md) G1 |
| Traefik management port 8080 | ~ | BasicAuth with `openssl rand -hex 20` password (160-bit entropy, APR1-hashed) required; network-level block tracked as G2 — see [gaps.md](gaps.md) |

### Principle 12 — Secure Service Administration (✓)

| Area | Status | Detail |
|---|---|---|
| Administrative access hardened | ✓ | SSH with key-only auth; strong AEAD ciphers; no forwarding; no root login |
| Admin access network-restricted | ✓ | SSH not internet-exposed; admin access requires traversal of VPN/bastion with MFA |
| Administrative actions audited | ✓ | auditd captures all privilege escalation, admin commands, file changes; shipped to NewRelic |
| Separate admin and user channels | ✓ | SSH for admin; web traffic through Traefik on 80/443; fully separated |

### Principle 13 — Audit Information for Customers (~)

| Area | Status | Detail |
|---|---|---|
| Audit logging (operator) | ✓ | auditd + NewRelic provides comprehensive audit trail for operators |
| Customer-accessible audit logs | ~ | No customer-facing audit portal; NewRelic is operator-facing; application access logs available per-site if configured |
| Log integrity | ✓ | Immutable auditd ruleset (`-e 2`); remote shipping to NewRelic prevents on-host tampering |
| Log retention | ~ | NewRelic must be configured for ≥12-month retention — see [gaps.md](gaps.md) G5 |

### Principle 14 — Secure Use of the Service (~)

| Area | Status | Detail |
|---|---|---|
| Technical documentation | ✓ | Scripts are well-documented with inline comments and BATS test coverage |
| Security guidance for operators | ✓ | Compliance documentation suite provides operational security guidance |
| Customer security guidance | ~ | No customer-facing documentation for secure application deployment practices |

---

## Why Excluded Today

The NCSC Cloud Security Principles are a reference framework, not a mandatory certification. G-Cloud supplier status (which formally requires alignment with the principles) requires registration with the Crown Commercial Service and is an organisational decision, not an infrastructure script deliverable.

For the principles that are partial (4, 6, 13, 14), the gaps are primarily organisational documentation and customer-facing tooling, not infrastructure. The technical posture is already strong across the principles that infrastructure scripts can address.

If G-Cloud supplier registration or a formal NCSC Cloud Security Principles assessment is required, the primary preparation work is: documenting a governance framework (Principle 4), customer-facing security guidance documentation (Principle 14), and considering whether a customer audit portal is in scope (Principle 13).

Open technical gaps are tracked in [gaps.md](gaps.md).

---

*Last updated: 2026-05-03*
