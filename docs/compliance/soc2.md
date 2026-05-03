# SOC 2 — Trust Service Criteria

## Overview

SOC 2 (System and Organisation Controls 2) is an AICPA audit framework based on the Trust Service Criteria (TSC). It is not a certification standard — it is an independently attested audit report (Type I for design; Type II for operating effectiveness over a period). SOC 2 reports are widely used in commercial B2B vendor assessments, especially in the US market and with enterprise procurement.

The TSC are organised into five categories: **Security** (Common Criteria — the only mandatory category), **Availability**, **Processing Integrity**, **Confidentiality**, and **Privacy**. Infrastructure relevant categories are Security, Availability, and Confidentiality. Processing Integrity is application-level; Privacy is data protection governance.

The Common Criteria (CC1–CC9) are structured around the COSO framework. CC1–CC5 (Control Environment, Communication, Risk Assessment, Monitoring Activities, Control Activities) are primarily organisational. CC6 (Logical and Physical Access), CC7 (System Operations), and CC8 (Change Management) are directly addressable by technical controls.

## Why It's Relevant

SOC 2 is the most commonly demanded third-party assurance report in B2B vendor security assessments, particularly:
- US enterprise customers and procurement teams
- SaaS customers with data processor requirements
- Organisations conducting vendor risk management programmes

Even without a formal audit, documented SOC 2 alignment provides structured evidence for vendor questionnaires. A Type I report can typically be completed within 3–6 months once the technical posture is strong. Type II requires 6–12 months of operational evidence.

## Executive Summary

**Estimated SOC 2 technical readiness (CC6, CC7, CC8 + Availability): ~72% ~ ~80%**

The range reflects controls satisfied by external architecture pending deployment validation: MFA at VPN/bastion (CC6.1), Cloudflare availability controls (A1), platform-level network controls (CC6.6), and block device encryption at the VM hypervisor (CC6.1).

Technical control coverage is strong in CC6 (access control) and the Availability criteria, driven by the four-layer perimeter, SSH hardening, PAM policy, per-site user isolation, and IaC-based DR. CC7 (system operations) is well-served by NewRelic infrastructure monitoring, auditd, AIDE, and fail2ban. CC8 (change management) is addressed through full IaC and BATS testing, though without a formal change approval workflow.

CC1–CC5 (control environment, risk assessment, policies and procedures) are organisational in nature and cannot be addressed by infrastructure scripts. These criteria represent a significant proportion of the overall TSC and will require documented policies and management processes before a SOC 2 audit can be completed.

---

## Scope

### In Scope (Technical TSC Controls)

| Criterion | Description |
|---|---|
| CC6 — Logical and Physical Access | SSH hardening, PAM, MFA, per-site isolation, sudo model |
| CC7 — System Operations | Monitoring, anomaly detection, incident detection tooling |
| CC8 — Change Management | IaC, BATS testing, deployment pipeline controls |
| CC9 — Risk Mitigation (partial) | Vendor security posture (Cloudflare, NewRelic) noted; formal vendor management is organisational |
| A1 — Availability | IaC DR, DDoS protection, infrastructure monitoring |
| C1 — Confidentiality | TLS in transit, access controls, log confidentiality |

### Out of Scope

| Criterion | Reason |
|---|---|
| CC1 — Control Environment | Organisational governance; board-level commitments, HR security |
| CC2 — Communication and Information | Security policies, risk communication frameworks |
| CC3 — Risk Assessment | Formal risk register, threat modelling process |
| CC4 — Monitoring Activities (organisational) | Management review and reporting cycles |
| CC5 — Control Activities (policies) | Documented policies and procedures for all CC criteria |
| Processing Integrity (PI) | Application-level accuracy and completeness of processing |
| Privacy (P) | Data protection governance; maps to GDPR/UK GDPR Article 32 |
| SOC 2 audit engagement | Requires AICPA-licensed CPA firm; organisational decision |
| Type II operating effectiveness evidence | Requires minimum 6-month observation period |

---

## External Controls

| Control | Provider | TSC Criterion |
|---|---|---|
| DDoS mitigation (L3/L4/L7) | Cloudflare | A1.1 — Availability and protection against environmental threats |
| WAF + OWASP managed ruleset | Cloudflare | CC6.6 — Access restrictions for ingress; CC7.2 — Threat detection |
| Application-layer WAF | ModSecurity (DMZ) | CC6.6 — Restrict access to authorised boundaries |
| MFA enforcement | VPN / SSH bastion | CC6.1 — Multi-factor authentication for admin access |
| Remote log retention | NewRelic | CC7.2 — Monitor system components for anomalous behaviour |
| Infrastructure monitoring and alerting | NewRelic | CC7.1 / CC7.2 — Operations monitoring and anomaly detection |
| Block device encryption | VM hypervisor | CC6.1 / C1.1 — Confidentiality protection of data at rest |
| Application-layer encryption | Applications | C1.1 — Encryption of confidential information |
| Signed artefact delivery | CI/CD | CC8.1 — Authorised and tested change deployment |
| IaC-based DR (~20 min recovery) | Architecture | A1.3 — Recovery point and time objectives |
| Application data backup + replication | Application team | A1.2 / A1.3 — Backup and recovery |

---

## TSC Control Assessment

### CC6 — Logical and Physical Access (~85% ~ ~90%)

| Control | Status | Implementation |
|---|---|---|
| CC6.1 — Restrict logical access using authorised credentials | ✓ | SSH key-only; PAM 14-char complexity + history; no password login |
| CC6.1 — Multi-factor authentication | ✓ (at access layer) | MFA at VPN/bastion before SSH is network-reachable; host TOTP available as defence-in-depth |
| CC6.1 — Encryption for data at rest | ✓ (at correct layers) | VM hypervisor block device encryption; application-layer encryption |
| CC6.2 — Control access to authorised users | ✓ | Per-site dedicated users; no shared accounts; per-command sudoers |
| CC6.3 — Remove access when no longer required | ~ | Per-site accounts managed by `setup-docker-permissions.sh`; no automated de-provisioning workflow |
| CC6.6 — Implement security controls to prevent exploitation of vulnerabilities | ✓ | Four-layer perimeter; kernel hardening; AppArmor; seccomp; Trivy at deploy |
| CC6.7 — Restrict transmission of confidential information | ✓ | TLS 1.2/1.3 AEAD only; no plaintext protocols in transit |
| CC6.8 — Implement controls to prevent or detect malicious software | ✓ (at appropriate layers) | Trivy image scanning + AppArmor + seccomp + CI/CD signed artefacts + Cloudflare/ModSecurity WAF |

### CC7 — System Operations (~72% ~ ~80%)

| Control | Status | Implementation |
|---|---|---|
| CC7.1 — Detect and monitor components for changes | ✓ | AIDE daily FIM; auditd 28+ rules; NewRelic infrastructure agent |
| CC7.2 — Monitor system components for anomalous behaviour | ✓ | NewRelic infrastructure monitoring; fail2ban; auditd → NewRelic |
| CC7.3 — Evaluate security events to determine if incidents | ~ | Detection tooling in place; no formal incident classification procedure |
| CC7.4 — Respond to identified security incidents | ~ | fail2ban automated response; no documented incident response runbook |
| CC7.5 — Identify and remediate software vulnerabilities | ✓ | `unattended-upgrades` daily; Trivy at deploy; AIDE detects post-deploy changes |

### CC8 — Change Management (~65% ~ ~70%)

| Control | Status | Implementation |
|---|---|---|
| CC8.1 — Authorise changes using IaC and defined processes | ✓ | Full IaC; all changes are version-controlled code; BATS test suite validates changes |
| CC8.1 — Test changes before deployment | ✓ | BATS automated tests; `sshd -t` and `visudo -c` syntax validation in scripts |
| CC8.1 — Formal change approval workflow | ~ | Git history provides audit trail; no formal change advisory board or approval gate |

### A1 — Availability (~75% ~ ~85%)

| Control | Status | Implementation |
|---|---|---|
| A1.1 — Protect against threats that could impact availability | ✓ | Cloudflare L3/L4/L7 DDoS; fail2ban SSH brute-force; SYN cookies |
| A1.2 — Monitor systems to detect threats to availability | ✓ | NewRelic infrastructure monitoring and uptime alerting |
| A1.3 — Recover from events that affect availability | ✓ | IaC rebuild in ~20 minutes; external application data replication |

### C1 — Confidentiality (~80% ~ ~88%)

| Control | Status | Implementation |
|---|---|---|
| C1.1 — Identify and maintain confidentiality protections | ✓ | TLS 1.2/1.3 in transit; block device and application-layer encryption at rest |
| C1.2 — Dispose of confidential information in a defined manner | ~ | Servers are cattle; OS rebuild is the disposal mechanism; application data disposal is application responsibility |

---

## Why Excluded Today

SOC 2 is not a regulatory obligation — it is a voluntary commercial assurance standard. A SOC 2 audit requires engagement with an AICPA-licensed CPA firm and represents a significant organisational commitment:

- **Type I** (design effectiveness at a point in time): 3–6 months preparation; audit readiness requires documented policies for all in-scope CC criteria
- **Type II** (operating effectiveness over a period): minimum 6–12 months observation window; ongoing operational processes must be demonstrably consistent

The technical controls are in a strong position for CC6, CC7, CC8, and Availability. The primary pre-audit work is organisational: documenting security policies for CC1–CC5, establishing formal incident response procedures (CC7.3–CC7.5), and implementing a change approval workflow (CC8.1). These are not infrastructure script deliverables.

If a SOC 2 report is required for a specific customer or commercial purpose, a readiness assessment by a SOC 2-experienced CPA firm is the first step. The technical posture described here should allow a readiness assessment to proceed efficiently.

Open technical gaps are tracked in [gaps.md](gaps.md).

---

*Last updated: 2026-05-03*
