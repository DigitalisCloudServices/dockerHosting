# PCI DSS v4.0 — Conditional Scope

## Overview

PCI DSS v4.0 is the Payment Card Industry Data Security Standard. It applies to all entities that store, process, or transmit cardholder data (CHD), and to all systems within the Cardholder Data Environment (CDE) or directly connected to it.

**Scope caveat:** We are not a PCI business. However, some applications hosted on this infrastructure may process or transmit payment card data. The deploying organisation must perform a scoping exercise to determine whether any hosted application brings these servers into CDE or connected-system scope. All assessments below assume CDE scope applies; if no CHD flows through these servers the framework does not apply.

## Why It's Relevant

Any application that accepts, processes, or transmits payment card data — even via a redirect to a third-party payment processor — may require these servers to meet PCI DSS requirements as part of the connected system scope or shared hosting assessment. Understanding the technical posture ahead of any scoping exercise or QSA engagement avoids surprises.

PCI DSS v4.0 raised the bar on several controls (MFA, TLS requirements, WAF for public-facing apps) compared to v3.2.1. The architecture already satisfies several of those elevated requirements.

## Executive Summary

**Estimated technical readiness (if CDE in scope): ~65% (known) ~ ~72% (assumed)**

The range reflects controls satisfied by external architecture pending deployment validation: MFA at VPN/bastion (Req 8.4.2), Cloudflare WAF (Req 6.4.2 — already marked closed), platform-level container egress filtering (Req 1.3.2), and NewRelic log retention configuration (Req 10.5.1). The lower figure reflects scripts and directly verifiable host controls alone.

The Cloudflare WAF satisfies Req 6.4.2 (WAF for public-facing applications). NewRelic remote log shipping satisfies Req 10.3.3 (remote log server). The four-layer perimeter exceeds Req 1's network security expectations for web traffic. MFA is satisfied at the VPN/bastion access layer.

The main blockers for PCI attestation are: Docker container egress at host level (Req 1.3.2 — platform/network-level controls assumed but require deployment-specific validation), host anti-malware (Req 5 — addressed as an architectural position), NewRelic log retention configuration (Req 10.5.1 — a configuration action), and third-party testing (Req 11 — requires external vendor engagement regardless of technical posture).

---

## Scope

### In Scope (Technical Requirements Assessed)

| Requirement | Description |
|---|---|
| Req 1 | Network security controls |
| Req 2 | Secure configurations for all system components |
| Req 4 | Protect cardholder data with strong cryptography during transmission |
| Req 5 | Protect all systems and networks from malicious software |
| Req 6 | Develop and maintain secure systems and software |
| Req 7 | Restrict access to system components and cardholder data |
| Req 8 | Identify users and authenticate access to system components |
| Req 10 | Log and monitor all access to system components and cardholder data |
| Req 11 | Test security of systems and networks regularly |

### Out of Scope (Technical Project Boundary)

| Requirement | Reason |
|---|---|
| Req 3 — Protect stored account data | Application-level; no CHD stored on host OS by design |
| Req 9 — Physical security | Datacenter responsibility |
| Req 12 — Policies, processes, and programmes | Organisational governance |
| QSA engagement and Report on Compliance | Organisational commitment; requires external qualified assessor |
| Network diagram documentation | Operational deliverable |
| CDE scoping documentation | Organisational deliverable; depends on application architecture |

---

## External Controls

| Control | Provider | PCI Requirement |
|---|---|---|
| DDoS mitigation (L3/L4/L7) | Cloudflare | Req 1 — Availability and boundary protection |
| WAF + OWASP managed ruleset | Cloudflare | Req 6.4.2 — WAF for public-facing apps — **closed** |
| Edge Firewall (default-deny) | Operator-managed | Req 1.2.1 — Inbound deny-default |
| Application-layer WAF | ModSecurity (DMZ) | Req 1.4.1 — Controls between trusted/untrusted networks |
| TLS at Cloudflare edge | Cloudflare | Req 4.2.1 — Strong cryptography in transit |
| MFA enforcement | VPN / SSH bastion | Req 8.4.2 — MFA for all non-console admin access to CDE |
| Remote log storage + off-host retention | NewRelic | Req 10.3.3 — Remote/off-host log server — **closed** |
| Infrastructure monitoring + alerting | NewRelic | Req 10.4.1 — Daily log review tooling |
| Block device encryption | VM hypervisor | Req 3.5 — Encryption at rest (infrastructure layer) |
| Application-layer encryption | Applications | Req 3.5 — Encryption at rest (data layer) |
| Signed artefact delivery | CI/CD | Req 6.3 — Vulnerability management via secure delivery |

---

## Requirement Assessment

### Requirement 1 — Network Security Controls

| Control | Status | Detail |
|---|---|---|
| 1.1.2 — Network diagram | ~ | Architecture documented; formal network diagram is an operational deliverable |
| 1.2.1 — Inbound deny-default | ✓ | UFW default deny; Cloudflare + Edge FW at internet boundary |
| 1.2.2 — Outbound filtered | ✓ | UFW egress allow-list for host processes |
| 1.3.1 — Restrict inbound to CDE | ✓ | Cloudflare proxies 80/443; SSH via VPN/bastion only; no other inbound |
| 1.3.2 — Restrict outbound from CDE | ~ | Docker bypasses UFW at host level; platform-level and network-level egress controls (Edge Firewall, VM network policy) are assumed to restrict container outbound — **validate per deployment**; host-level control tracked as [gaps.md](gaps.md) G1 |
| 1.4.1 — Controls between trusted/untrusted networks | ✓ | Cloudflare → Edge FW → ModSecurity → UFW — layered boundary |
| 1.5.1 — Security controls for untrusted network connections | ✓ | Cloudflare as internet DMZ; SSH hardened; no direct host exposure for web |

**Req 1: Partial.** Strong web-traffic boundary. Docker container egress is uncontrolled at the host level; platform/network-level controls are assumed in place but require deployment-specific validation (G1).

### Requirement 2 — Secure Configurations

| Control | Status | Detail |
|---|---|---|
| 2.2.1 — Hardening standards per component type | ✓ | Extensive hardening scripts for kernel, SSH, Docker, PAM, AppArmor |
| 2.2.4 — Only necessary services / functions enabled | ✓ | Docker-only model; `NoNewPrivileges=true`, `PrivateTmp=true` in systemd |
| 2.2.7 — All non-console admin access encrypted | ✓ | SSH only (key-based); Traefik dashboard on port 8080 protected by BasicAuth with a cryptographically random password (`openssl rand -hex 20`; 160 bits of entropy — between AES-128 and AES-256 in key strength) APR1-hashed, generated at install — `install-traefik.sh`; network-level block pending (G2) |
| 2.3.1 — Wireless environments | N/A | No wireless; server deployment |

**Req 2: Good.**

### Requirement 4 — Protect Cardholder Data in Transit

| Control | Status | Detail |
|---|---|---|
| 4.2.1 — Only trusted TLS | ✓ | TLS 1.2/1.3 at Cloudflare edge and Traefik; no TLS 1.0/1.1 |
| 4.2.1.1 — Inventory of trusted keys/certs | ~ | Let's Encrypt / Cloudflare-managed at edge; no formal certificate inventory |
| 4.2.2 — No insecure protocols | ✓ | SSH only (strong ciphers); no FTP, Telnet, HTTP without redirect |

**Req 4: Good.**

### Requirement 5 — Protect Against Malicious Software

| Control | Status | Detail |
|---|---|---|
| 5.2.1 — Anti-malware deployed on all applicable components | Architectural exception | See below |
| 5.2.2 — Anti-malware detects, prevents, and alerts | Architectural exception | See below |
| 5.3.1 — Anti-malware solution kept current | Architectural exception | See below |
| 5.4.1 — Phishing attacks addressed | N/A | Server infrastructure; email/end-user control |

**Req 5: Architectural position — see below.**

#### Architectural Position: PCI DSS Req 5 and Host Anti-Malware

PCI DSS v4.0 Req 5.2.1 requires anti-malware on all system components. The standard also provides a mechanism for documenting that some components are not at risk from malware, supported by a periodic review.

For this architecture, the compensating control position is:

- **Trivy**: Scans container images for known vulnerabilities (including those enabling malware delivery) before deployment; blocks on CRITICAL CVEs. This is the appropriate scan point — images, not the running host filesystem.
- **AppArmor docker-default + seccomp default**: Constrains container behaviour to a defined safe profile at runtime; prevents execution of processes outside the allowed profile.
- **CI/CD signed artefacts**: Prevents deployment of untrusted or tampered software; all software arrives via a validated, cryptographically-signed pipeline.
- **Automatic OS security updates**: Keeps the host OS free of known OS-level exploitable vulnerabilities daily.
- **Cloudflare WAF + ModSecurity**: Blocks malicious web content at the perimeter before it reaches the host.
- **AppArmor on host OS**: MAC policy constrains processes on the host OS itself.

A PCI QSA may accept this compensating control argument under PCI DSS v4.0's customised approach provisions (section 3.3), or may require a formal Compensating Control Worksheet (CCW). If a QSA insists on a host AV product regardless, ClamAV installation is tracked as a contingency item in [gaps.md](gaps.md).

### Requirement 6 — Develop and Maintain Secure Systems

| Control | Status | Detail |
|---|---|---|
| 6.3.1 — Vulnerability management process | ✓ | `unattended-upgrades` daily + Trivy at deploy |
| 6.3.3 — All components protected from known vulnerabilities | ✓ | OS: daily patches; containers: Trivy CRITICAL gate; Cloudflare: vendor-managed |
| 6.4.1 — Public-facing web apps address common vulnerabilities | ✓ | Cloudflare WAF + ModSecurity + Traefik security headers |
| 6.4.2 — WAF or DAST for public-facing web applications | ✓ | **Closed** — Cloudflare WAF (OWASP managed ruleset) + ModSecurity WAF |

**Req 6: Good.** Cloudflare + ModSecurity close Req 6.4.2.

### Requirements 7 and 8 — Access Control and Authentication

| Control | Status | Detail |
|---|---|---|
| 7.2.1 — Access based on least privilege | ✓ | Per-site sudoers; no docker group; role-based command allow-list |
| 7.2.2 — Access assigned based on job function | ✓ | Per-site user isolation; site users cannot access other sites |
| 8.2.1 — Unique IDs for all users | ✓ | Dedicated per-site users; no shared accounts |
| 8.3.4 — Invalid auth attempts locked | ✓ | PAM pam_faillock: 5 attempts → 15-min lockout; fail2ban progressive bans |
| 8.3.6 — Minimum password complexity | ✓ | PAM: 14 chars, uppercase/lowercase/digit/special, 5-password history |
| 8.4.2 — MFA for all non-console admin access into CDE | ✓ (at access layer) | MFA enforced at VPN/bastion before SSH is network-reachable; Req 8.4.2 satisfied at the architectural access boundary |

**Req 7/8: Good.** MFA satisfied at VPN/bastion.

### Requirement 10 — Log and Monitor All Access

| Control | Status | Detail |
|---|---|---|
| 10.2.1 — Audit logs for specified events | ✓ | auditd 28+ rules: auth, privilege escalation, file changes, network, Docker |
| 10.2.2 — Audit logs with required fields | ✓ | auditd captures timestamp, event type, subject, action, outcome |
| 10.3.2 — Audit logs protected from destruction | ✓ | Immutable auditd ruleset (`-e 2`); requires reboot to modify |
| 10.3.3 — Audit logs backed up to remote log server | ✓ | **Closed** — NewRelic infrastructure agent ships logs off-host |
| 10.4.1 — Log review at least daily | ~ | NewRelic dashboards and alerting available; automated daily review requires NR alert policy configuration (operational) |
| 10.5.1 — Retain logs for 12 months, 3 months accessible | ⚠ | **Configuration action required** — NewRelic must be configured for ≥12-month retention; not enabled by default on all plans — see [gaps.md](gaps.md) |
| 10.6.1 — Time synchronisation | ✓ | chrony with ≥2 agreeing pool sources |
| 10.7.1 — Failures of security controls detected and reported | ✓ | AIDE email + fail2ban email + NewRelic infrastructure alerts |

**Req 10: Good (conditional on NewRelic retention configuration).**

### Requirement 11 — Test Security of Systems and Networks

| Control | Status | Detail |
|---|---|---|
| 11.2.1 — Internal vulnerability scans quarterly | ~ | lynis and docker-bench-security available; not yet scheduled quarterly — see [gaps.md](gaps.md) |
| 11.2.2 — External vulnerability scans quarterly by PCI ASV | ✗ | Requires third-party PCI SSC Approved Scanning Vendor engagement |
| 11.3.1 — External penetration test annually | ✗ | Requires CREST-accredited provider engagement |
| 11.3.2 — Internal penetration test annually | ✗ | Requires qualified internal or external resource |
| 11.4.1 — Intrusion detection | ~ | Cloudflare WAF + ModSecurity at perimeter; NewRelic infrastructure monitoring on host; no kernel-level IDS |
| 11.5.1 — Change detection (FIM) | ✓ | AIDE daily check + email alerts |

**Req 11: Incomplete** — pen testing and ASV scans require third-party engagement regardless of technical posture. This cannot be met by infrastructure scripts.

#### Note on External Testing and the Perimeter Architecture

PCI ASV scans and pen tests must account for two distinct attack surfaces:

| Surface | What It Tests |
|---|---|
| **Cloudflare-fronted domains** (internet-facing) | Cloudflare's edge security posture; WAF bypass attempts; business logic at the application layer |
| **Origin server IP** (SSH on port 22; VPN/bastion-accessible) | SSH hardening; host OS; Docker daemon; container runtime; kernel |

Cloudflare is itself PCI DSS Level 1 certified. ASV scanning of Cloudflare-proxied domains tests Cloudflare's surface. The origin server IP must be separately declared to the ASV for SSH and any other directly exposed services.

---

## Why Excluded Today

PCI DSS does not currently apply — we are not a PCI business. If a hosted application brings these servers into CDE or connected-system scope, a QSA engagement and formal scoping exercise would be required. This documentation provides the technical starting point for that conversation.

Full PCI attestation requires:
- A QSA to review and attest (Req 12 / ROC)
- Quarterly ASV external scans (Req 11.2.2) — vendor engagement
- Annual penetration testing (Req 11.3) — vendor engagement

These are ongoing operational and vendor commitments that cannot be met by infrastructure scripts. The technical posture at ~72% means that if CDE scope is determined to apply, the primary infrastructure work is: adding host-level container egress control (G1; platform/network-level compensating controls assumed in place — validate first), confirming NewRelic log retention (configuration action), and either accepting the Req 5 architectural position with a CCW or installing ClamAV as a contingency.

Open technical gaps are tracked in [gaps.md](gaps.md).

---

*Last updated: 2026-05-03*
