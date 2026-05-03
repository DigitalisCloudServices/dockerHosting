# GDPR / UK GDPR — Article 32 Technical Measures

## Overview

**EU GDPR (Regulation 2016/679)** and the **UK GDPR** (retained under the Data Protection Act 2018) both require, under Article 32, that data controllers and processors implement "appropriate technical and organisational measures" to ensure a level of security appropriate to the risk of processing personal data.

Article 32(1) specifically lists:
- Pseudonymisation and encryption of personal data
- Confidentiality, integrity, availability, and resilience of processing systems
- Ability to restore availability and access to personal data after an incident
- A process for regularly testing, assessing, and evaluating the effectiveness of security measures

**Scope caveat:** The GDPR applies to the organisation controlling or processing personal data, not directly to infrastructure scripts. If hosted applications process personal data of EU or UK data subjects, the controller and any processor have Article 32 obligations. The deploying organisation must determine whether and how these obligations apply. This document assesses the technical security measures relevant to Article 32 against the infrastructure layer only.

## Why It's Relevant

GDPR / UK GDPR Article 32 is effectively universally applicable:
- Any hosted application processing personal data of EU or UK individuals is in scope
- A hosting provider may be acting as a **data processor** on behalf of a controller (hosted customer), requiring a Data Processing Agreement (DPA) — Article 28
- The ICO (UK) and EU data protection authorities can issue enforcement notices for technical security failures that lead to personal data breaches
- Article 32 obligations apply regardless of organisation size, sector, or revenue

The technical measures described here are directly relevant to satisfying Article 32 and providing evidence of appropriate security in a DPA or audit context.

## Executive Summary

**Estimated Article 32 technical measures readiness: ~78% ~ ~85%**

The range reflects controls satisfied by external architecture pending deployment validation: MFA at VPN/bastion, Cloudflare + ModSecurity perimeter availability and confidentiality controls, block device encryption at the VM hypervisor, and NewRelic log retention configuration.

The infrastructure provides strong coverage of Article 32(1)(b) (confidentiality, integrity, availability, resilience): TLS 1.2/1.3 in transit, encryption at rest at the correct architectural layers, comprehensive access controls, IaC-based DR (~20 min recovery), and NewRelic infrastructure monitoring. The IaC cattle model directly supports Article 32(1)(c) (ability to restore availability). Regular testing (Article 32(1)(d)) is addressed by the available tooling (lynis, docker-bench-security, Trivy) but lacks a scheduled cadence.

The main limitations are: pseudonymisation is application-level (not addressable by infrastructure scripts), and organisational GDPR obligations (ROPA, DPIA, breach notification procedures, DPO where required) are outside the scope of infrastructure scripts.

---

## Scope

### In Scope (Article 32 Technical Measures)

| Measure | Description |
|---|---|
| Encryption in transit | TLS configuration, cipher policy |
| Encryption at rest | At the layers managed by or below this project |
| Access control and authentication | SSH, PAM, MFA, per-site isolation |
| Confidentiality of processing | Network isolation, log confidentiality |
| Integrity | Audit logging, FIM, immutable logs |
| Availability and resilience | DDoS protection, IaC DR, uptime monitoring |
| Testing and evaluation | Vulnerability scanning, BATS, lynis |
| Breach detection | Monitoring, alerting, anomaly detection |

### Out of Scope

| Area | Reason |
|---|---|
| Pseudonymisation | Application-level data design; not addressable by infrastructure scripts |
| Article 30 — Records of Processing Activities (ROPA) | Organisational documentation; lists what data is processed, by whom, for what purpose |
| Article 33/34 — Personal data breach notification | Procedural; 72-hour reporting timeline to supervisory authority and data subjects |
| Article 35 — Data Protection Impact Assessment (DPIA) | Required for high-risk processing; organisational assessment activity |
| Article 37 — Data Protection Officer (DPO) | Organisational/HR decision based on processing nature and scale |
| Article 28 — Data Processing Agreements | Contractual; required where hosting provider acts as a processor for a controller |
| Consent management | Application-level; lawful basis for processing |
| Data subject rights | Application-level tooling (subject access requests, right to erasure) |
| Data retention and deletion | Application-level policy and implementation |

---

## External Controls

| Control | Provider | Article 32 Measure |
|---|---|---|
| DDoS mitigation (L3/L4/L7) | Cloudflare | Availability; resilience of processing systems |
| WAF + OWASP ruleset | Cloudflare | Confidentiality; integrity; breach risk reduction |
| Application-layer WAF | ModSecurity (DMZ) | Confidentiality; integrity; perimeter breach prevention |
| MFA enforcement | VPN / SSH bastion | Access control; confidentiality (Art 32(1)(b)) |
| Remote log retention | NewRelic | Integrity; audit trail availability; breach detection |
| Infrastructure monitoring + alerting | NewRelic | Availability monitoring; incident detection |
| Block device encryption | VM hypervisor | Encryption at rest (Art 32(1)(a)) |
| Application-layer encryption | Applications | Encryption at rest (Art 32(1)(a)) — application layer |
| Application data backup + replication | Application team | Availability; ability to restore (Art 32(1)(c)) |
| IaC-based DR (~20 min recovery) | Architecture | Ability to restore availability (Art 32(1)(c)) |

---

## Article 32 Technical Measure Assessment

### Article 32(1)(a) — Pseudonymisation and Encryption

| Measure | Status | Detail |
|---|---|---|
| Encryption in transit | ✓ | TLS 1.2/1.3 AEAD ciphers at Cloudflare edge and Traefik; SSH with ChaCha20-Poly1305/AES-GCM — `harden-ssh.sh` |
| Encryption at rest — block device | ✓ (at correct layer) | VM hypervisor manages block device encryption; assumed in place — must be confirmed per deployment |
| Encryption at rest — application data | ✓ (at correct layer) | Each application implements encryption at rest for personal data; out of infrastructure scope |
| Pseudonymisation | Out of scope | Application-level data design decision; not addressable by infrastructure scripts |

### Article 32(1)(b) — Confidentiality, Integrity, Availability, and Resilience

**Confidentiality**

| Control | Status | Detail |
|---|---|---|
| Access control | ✓ | SSH key-only; per-site user isolation; per-command sudoers; no shared accounts |
| MFA for administrative access | ✓ (at access layer) | MFA enforced at VPN/bastion; host TOTP available as defence-in-depth (`setup-ssh-mfa.sh`) |
| Network isolation | ✓ | `icc=false`; per-site Docker networks; UFW default-deny; four-layer internet perimeter |
| Log confidentiality | ✓ | NewRelic access restricted to operators; auditd logs owner-readable only |
| Container egress | ~ | Docker bypasses UFW at host level; platform-level external controls assumed — **validate per deployment** — see [gaps.md](gaps.md) G1 |

**Integrity**

| Control | Status | Detail |
|---|---|---|
| Audit logging | ✓ | auditd 28+ rules capture all admin actions, file changes, network changes, Docker events |
| Immutable audit log | ✓ | Immutable auditd ruleset (`-e 2`); requires reboot to modify |
| Off-host log shipping | ✓ | auditd + Traefik access logs → NewRelic; cannot be deleted from the host |
| File integrity monitoring | ~ | AIDE daily batch; real-time FIM not implemented — see [gaps.md](gaps.md) G4 |
| Software integrity at deploy | ✓ | CI/CD signed artefacts validated at host before installation; Trivy blocks CRITICAL CVEs |

**Availability and Resilience**

| Control | Status | Detail |
|---|---|---|
| DDoS protection | ✓ | Cloudflare L3/L4/L7 DDoS protection at internet perimeter |
| Infrastructure availability monitoring | ✓ | NewRelic infrastructure agent; uptime alerting |
| Host OS resilience | ✓ | Automatic security patching (`unattended-upgrades`); `live-restore` on Docker daemon |
| System resilience | ✓ | IaC-based: `setup.sh` on a fresh Debian Trixie host restores full service in ~20 minutes |

### Article 32(1)(c) — Ability to Restore Availability and Access

| Area | Status | Detail |
|---|---|---|
| Infrastructure recovery | ✓ | Cattle model: full server recovery via `setup.sh` in ~20 min from any Debian Trixie host |
| Application data recovery | ✓ (at correct layer) | External application-layer backup and replication; data does not depend on host survival |
| Local volume data | ~ | Known transitional risk: Docker workloads using local volumes are not covered by the IaC recovery model — see [gaps.md](gaps.md) G7 |

### Article 32(1)(d) — Regular Testing, Assessing, and Evaluating

| Area | Status | Detail |
|---|---|---|
| Security assessment tooling | ✓ | lynis, docker-bench-security, Trivy available for on-demand assessment |
| Continuous vulnerability assessment | ✓ | Trivy scans at every deployment; `unattended-upgrades` daily OS patch |
| Scheduled assessment cadence | ~ | No scheduled quarterly scan (lynis/docker-bench) — see [gaps.md](gaps.md) G6 |
| BATS automated test suite | ✓ | 138+ tests validate hardening script correctness |

### Breach Detection Capability

| Mechanism | Coverage | Relevance to Art 32 |
|---|---|---|
| Cloudflare WAF | Web-layer attack detection; real-time | Reduces breach likelihood; detects exploitation attempts |
| ModSecurity WAF | Application-layer web attack detection; real-time | Detects data exfiltration attempts via web layer |
| NewRelic infrastructure monitoring | Host metrics, process monitoring, log alerting | Anomaly detection for infrastructure-layer incidents |
| fail2ban | SSH brute-force detection; reactive | Detects and responds to credential attack attempts |
| AIDE | Host file integrity changes | Daily batch; detects post-breach file modifications |
| auditd → NewRelic | Syscall-level audit trail | Off-host evidence for breach investigation |

**Assessment:** The breach detection posture provides credible capability to detect and investigate personal data breaches at the infrastructure layer. The 24-hour AIDE batch window is the main gap for file-level breach detection on the host OS; the cattle architecture limits blast radius. Application-layer breach detection is the application's responsibility.

---

## ICO Accountability Principle (Article 5(2))

Article 5(2) requires data controllers to be able to demonstrate compliance. Infrastructure evidence relevant to this obligation:

| Evidence Type | Source | Available |
|---|---|---|
| Technical security controls documentation | This repository | ✓ |
| Access control implementation | Scripts + auditd logs | ✓ |
| Encryption in transit configuration | Traefik + Cloudflare config | ✓ |
| Audit log availability | auditd + NewRelic | ✓ (conditional on NR retention ≥12 months — C1) |
| Vulnerability management evidence | Trivy scan outputs + unattended-upgrades logs | ✓ |
| Security testing evidence | BATS test results, lynis reports, docker-bench outputs | ✓ |

---

## Why Excluded Today

GDPR Article 32 is not a certification scheme — there is no pass/fail certificate. The obligation is continuous and proportionate to the risk of the processing involved. Infrastructure scripts cannot determine whether GDPR applies to a specific deployment, what personal data is processed, or what the appropriate level of security is for that data.

The organisational GDPR obligations (ROPA, DPIA, DPO, breach notification procedures, data subject rights, contractual obligations under Article 28) are outside the scope of infrastructure automation and must be addressed by the deploying organisation's legal and governance teams.

For hosted applications processing personal data, the key action for the deploying organisation is to:
1. Determine whether the hosting provider relationship constitutes a controller-processor relationship requiring an Article 28 DPA
2. Include the hosting infrastructure's technical controls as evidence in any DPIA
3. Confirm block device encryption is in place at the VM hypervisor layer (currently assumed)
4. Configure NewRelic log retention to ≥12 months (C1) to support breach investigation and audit obligations

Open technical gaps are tracked in [gaps.md](gaps.md).

---

*Last updated: 2026-05-03*
