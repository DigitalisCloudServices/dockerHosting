# UK NIS Regulations / EU NIS2 Directive

## Overview

**UK NIS Regulations 2018** apply to Operators of Essential Services (OES) and Digital Service Providers (DSPs), including cloud computing services, online marketplaces, and online search engines. The UK Cyber Security and Resilience (CS&R) Bill is progressing through Parliament and will expand scope and tighten requirements.

**EU NIS2 Directive (2022/2555)** applies to entities in EU member states across significantly expanded sectors (essential entities and important entities). Member state transposition deadline was October 2024. NIS2 materially broadens the original NIS scope and strengthens requirements around incident reporting, supply chain security, MFA, and board accountability.

Where requirements differ materially, both are noted.

## Why It's Relevant

NIS2 expanded scope means many organisations that were outside NIS1 scope are now caught. Categories potentially in scope include: managed service providers, cloud service providers, digital infrastructure operators, and organisations in sectors including energy, transport, health, water, digital infrastructure, ICT service management, public administration, and space.

The deploying organisation must determine their own NIS2 scope based on sector and size. This document provides the technical posture against NIS2's Article 21 technical measures, regardless of whether formal NIS2 obligations apply.

## Executive Summary

**Estimated NIS2 technical readiness: ~72% (known) ~ ~78% (assumed)**

The range reflects controls satisfied by external architecture pending deployment validation: MFA at VPN/bastion (Art 21(2)(j)), platform-level container egress filtering, Cloudflare and ModSecurity perimeter availability and monitoring contributions, and NewRelic log retention configuration (operational action required).

The combination of the four-layer perimeter (Cloudflare → Edge FW → ModSecurity → Host), NewRelic infrastructure monitoring, and the IaC-based DR model provides strong coverage of NIS2's availability, monitoring, and business continuity requirements. The CI/CD signed artefact pipeline addresses the supply chain security measures.

MFA is satisfied at the VPN/bastion access layer. The main partial-coverage areas are real-time incident detection (AIDE is daily batch, NewRelic infrastructure monitoring is not a SIEM) and formal risk analysis documentation (organisational, not infrastructure).

---

## Scope

### In Scope (Article 21 Technical Measures)

NIS2 Article 21 requires "appropriate and proportionate technical and organisational measures" including:

- Risk analysis and information system security policies
- Incident handling (detection and response)
- Business continuity and DR
- Supply chain security
- Security in acquisition, development, and maintenance
- Effectiveness assessment policies
- Cryptography
- Human resources security and access control
- MFA and continuous authentication

Technical measures from this list are assessed below. Organisational measures (policies, procedures, governance) are outside the scope of infrastructure scripts.

### Out of Scope

| Area | Reason |
|---|---|
| NIS2 registration with competent authority | Organisational / regulatory |
| Incident reporting timelines (24h early warning, 72h notification) | Procedural; cannot be met by infrastructure scripts |
| Supplier contracts and third-party risk registers | Policy / procurement |
| Staff security awareness training | Personnel controls |
| Formal risk register and ISMS governance | Organisational |
| NIS2 self-assessment submissions | Organisational |
| Board accountability and liability provisions | Governance |

---

## External Controls

| Control | Provider | NIS2 Measure |
|---|---|---|
| DDoS mitigation (L3/L4/L7) | Cloudflare | Availability; business continuity |
| WAF + OWASP ruleset | Cloudflare | Incident handling (web-layer detection); network security |
| Application-layer WAF | ModSecurity (DMZ) | Network security; incident detection |
| MFA enforcement | VPN / SSH bastion | MFA for administrative access (Art 21(2)(j)) |
| Remote log retention | NewRelic | Monitoring; incident detection; log evidence |
| Infrastructure monitoring + alerting | NewRelic | Incident handling; effectiveness assessment |
| Application data backup | Application team | Business continuity |
| External data replication | Application team | Business continuity; availability |
| IaC-based DR (~20 min recovery) | Architecture | Business continuity; DR |
| Signed artefact delivery | CI/CD | Supply chain security |

---

## Article 21 Technical Measures Assessment

### Risk Analysis and Information Security Policies

| Area | Status | Detail |
|---|---|---|
| Technical security controls documented | ✓ | Full compliance documentation; controls mapped to frameworks |
| Formal risk analysis / risk register | Out of scope | Organisational deliverable; technical controls are in place |

### Incident Handling

| Area | Status | Detail |
|---|---|---|
| Web-layer attack detection | ✓ | Cloudflare WAF + ModSecurity in real time |
| Infrastructure anomaly detection | ✓ | NewRelic infrastructure agent; metrics, process monitoring, alerting |
| SSH brute-force detection | ✓ | fail2ban with progressive bans and email alerts |
| Audit event shipping (off-host) | ✓ | auditd → NewRelic; Traefik access logs → NewRelic |
| File integrity detection | ~ | AIDE daily batch; real-time FIM not implemented — see [gaps.md](gaps.md) |
| Real-time host IDS | ~ | NewRelic infrastructure monitoring provides anomaly alerting; syscall/kernel-level IDS not implemented |
| Formal incident response runbooks | Out of scope | Organisational deliverable |

### Business Continuity and DR

| Area | Status | Detail |
|---|---|---|
| DR plan | ✓ (architectural) | IaC-based: `setup.sh` on fresh Debian Trixie host restores full service in ~20 minutes |
| Application data recovery | ✓ | External application-layer backup + replication; data does not depend on host survival |
| Availability assurance | ✓ | Cloudflare provides DDoS protection and CDN availability; blue/green deployment minimises downtime |

### Supply Chain Security

| Area | Status | Detail |
|---|---|---|
| Container image vulnerability management | ✓ | Trivy blocks deployment on CRITICAL CVEs at deploy time |
| Signed software delivery | ✓ | CI/CD delivers encrypted, signed artefacts validated at host before deployment |
| Image signing at container layer | ~ | CI/CD supply chain provides integrity; image-layer Cosign/DCT not implemented — see [cis-docker.md](cis-docker.md) |

### Security in Acquisition, Development, and Maintenance

| Area | Status | Detail |
|---|---|---|
| Secure development practices | ✓ | BATS test suite; shellcheck CI; `sshd -t` and `visudo -c` validation in scripts |
| Full IaC | ✓ | All configuration is version-controlled code |

### Effectiveness Assessment

| Area | Status | Detail |
|---|---|---|
| Assessment tooling available | ✓ | lynis, docker-bench-security available for on-demand assessment |
| NewRelic dashboards | ✓ | Continuous infrastructure monitoring |
| Scheduled assessment cadence | ~ | No scheduled quarterly lynis/docker-bench runs — see [gaps.md](gaps.md) |

### Cryptography

| Area | Status | Detail |
|---|---|---|
| TLS in transit | ✓ | TLS 1.2/1.3 with AEAD ciphers only at Cloudflare edge and Traefik; no TLS 1.0/1.1 |
| SSH cryptography | ✓ | ChaCha20-Poly1305, AES-GCM ciphers only; ED25519 / RSA-4096 keys — `harden-ssh.sh` |
| GRUB / boot cryptography | Optional | PBKDF2-SHA512 for GRUB password — `harden-bootloader.sh` |
| Encryption at rest | ✓ (at correct layers) | Block device (VM hypervisor); application-layer encryption by applications |

### Human Resources Security and Access Control

| Area | Status | Detail |
|---|---|---|
| Access control policy | ✓ | Key-only SSH; PAM password policy + lockout; per-command sudoers; per-site isolation |
| Least privilege | ✓ | No docker group; site users cannot access other sites |
| Admin account management | ✓ | No shared admin accounts; dedicated per-site users |

### MFA and Continuous Authentication

| Area | Status | Detail |
|---|---|---|
| MFA for all admin access | ✓ (at access layer) | MFA enforced at VPN/bastion; SSH not reachable without traversing MFA-enforced access control. NIS2 Art 21(2)(j) MFA requirement is satisfied at the network access boundary. |
| Host-level TOTP | Optional | `setup-ssh-mfa.sh` available as additional defence-in-depth |

---

## Incident Detection Infrastructure

NIS2 requires incident detection capability to support the 24-hour early warning obligation. Current detection posture:

| Mechanism | Coverage | Notes |
|---|---|---|
| Cloudflare WAF | Web-layer attack detection; L7 DDoS; bot detection | Perimeter only; real-time |
| ModSecurity WAF | Application-layer web attack detection | DMZ layer; real-time |
| NewRelic infrastructure | Host metrics, process monitoring, log shipping, alerts | Real-time infrastructure anomaly detection |
| fail2ban | SSH brute-force | Reactive; alerts on threshold breach |
| AIDE | File integrity changes on host | Daily batch; not real-time |
| auditd → NewRelic | Syscall/file audit trail | Off-host; correlation requires NR alert policies (operational) |

**Assessment:** The Cloudflare + ModSecurity + NewRelic combination provides credible incident detection capability for NIS2 purposes. Real-time infrastructure anomaly detection is available. The absence of a kernel-level HIDS means some classes of attack would only be detected on the next AIDE run (24h). NewRelic alert policy configuration (defining specific alert rules) is an operational decision, not an infrastructure gap.

---

## Why Excluded Today

NIS2 applicability depends on the deploying organisation's sector and size — this cannot be determined from infrastructure scripts. The technical posture documented here is available as evidence regardless of whether NIS2 formally applies.

The formal organisational obligations of NIS2 (registration with competent authority, incident reporting timelines, board accountability, supplier contracts) are not addressable by infrastructure automation.

Real-time host IDS (e.g., Wazuh HIDS) would improve the incident detection posture but represents a significant operational investment — alert tuning, false positive management, ongoing maintenance. The NewRelic + AIDE combination provides a proportionate detection capability for the current scale and risk profile. Wazuh remains a P3 future consideration as the fleet grows.

Open technical gaps are tracked in [gaps.md](gaps.md).

---

*Last updated: 2026-05-03*
