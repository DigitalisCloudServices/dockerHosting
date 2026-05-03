# Known Gaps and Remediation

This document consolidates all open technical gaps across the compliance frameworks tracked in this project. Framework assessment documents are kept clean of gap details; everything actionable lives here.

Gaps are classified as **infrastructure gaps** (require script changes), **configuration actions** (require account/service configuration, no script changes), and **conditional gaps** (only applicable if a specific condition applies — e.g., PCI CDE scope). Items that are organisational or policy in nature are noted separately for completeness but are not tracked here as infrastructure work.

---

## Infrastructure Gaps

Gaps that require new or modified scripts in this repository.

| ID | Gap | Priority | Frameworks | Risk | Compensating Controls | Further Controls | Why Deferred |
|---|---|---|---|---|---|---|---|
| G1 | Docker container egress bypasses UFW — container outbound traffic is unrestricted | P1 | PCI 1.3.2, CE+ Firewalls, NIS2, CIS L1 §3 | Medium-High — compromised container can exfiltrate data or establish C2 without host-level egress detection | AppArmor docker-default limits container behaviour; `icc=false` prevents lateral movement between containers; Cloudflare + ModSecurity reduce initial compromise likelihood at the perimeter. Additionally, host-level, network-level, and wider platform-level external egress controls are assumed to be in place within the deployment environment (Edge Firewall, VM network policy, data centre controls) — **these should be validated** against the actual deployment to confirm egress is restricted at an outer layer | `scripts/harden-docker-egress.sh` — egress allow-list rules in the `DOCKER-USER` iptables chain (the only chain Docker leaves for operator use) | Requires careful design to avoid breaking container DNS and outbound application traffic; wrong rules will silently break deployed sites |
| G2 | Traefik management port 8080 potentially reachable via Docker iptables bypass | P2 | CE+ Firewalls, PCI 1.3 | Medium — management port network-reachable on origin IP; unauthenticated access would expose Traefik dashboard and API | Mandatory BasicAuth with `openssl rand -hex 20` password (160 bits of entropy — between AES-128 and AES-256 in key strength) APR1-hashed, generated at install by `install-traefik.sh`; residual risk is password exposure, not brute-force | Drop 8080 in `DOCKER-USER` chain as part of `harden-docker-egress.sh` | Dependent on G1 |
| G4 | AIDE file integrity monitoring is daily batch only | P3 | ISO A.8.16, NIST SI-7, CIS L1 §4 | Medium — up to 24h window between a file integrity event and detection | Servers are stateless cattle (limited blast radius; rebuild is the response); auditd ships syscall events to NewRelic in real time; NewRelic infrastructure monitoring provides process-level anomaly detection | Supplement AIDE with inotifywait-based alerting for high-value paths, or introduce Wazuh agent for real-time FIM | Wazuh is high-effort with significant ongoing operational overhead; the cattle architecture limits blast radius of the detection gap |
| G5 | NewRelic log retention not verified at ≥12 months | Config action | PCI 10.5.1, NIS2 | Medium (compliance) — if NR defaults to 30-day retention, audit log retention requirements are unmet | Local logrotate retains logs on-host (14 days app / 4 weeks containers); auditd immutable rules protect on-host logs from tampering | Configure in NewRelic account: Logs → Data Management → set retention to ≥12 months | Not a script change — requires access to the NewRelic account |
| G6 | No quarterly internal vulnerability scan schedule | P3 | PCI 11.2.1, NIS2 (effectiveness) | Low — tooling exists; drift may go undetected between ad-hoc reviews | AIDE daily FIM; NewRelic continuous infrastructure monitoring; unattended-upgrades daily; Trivy gates at every deployment | Add quarterly cron for lynis + docker-bench-security with output shipped to NewRelic log | Low-effort once approach is agreed; deferred pending operational process decisions |
| G7 | Local volume data not covered by IaC recovery model | Known risk | NIST CP-9, ISO A.8.13 | Medium (transitional) — Docker workloads using local volumes have data that depends on host survival; cattle rebuild model does not cover this data | Per-site user isolation limits cross-container access; application-layer backups cover application data where configured; risk is documented and accepted as transitional | Migrate to external volume mounts (NFS, cloud block storage) as part of the K8s migration path | Architectural dependency on K8s migration; cannot be fully resolved at the host configuration layer |

---

## Configuration Actions

Items that require account or service configuration rather than script changes. No code to write — but must be actioned to close the compliance item.

| ID | Action | Frameworks | Detail |
|---|---|---|---|
| C1 | Configure NewRelic log retention to ≥12 months | PCI 10.5.1, NIS2, ISO A.8.15 | Logs → Data Management in the NewRelic account. Verify auditd, Traefik access logs, and Docker container logs are all being forwarded by the NR infrastructure agent. Standard NR plans default to 30 days. |
| C2 | Confirm Cloudflare proxy mode (orange cloud) is active on all in-scope DNS records | CE+ Firewalls, PCI 1.3, 6.4.2 | A DNS-only record (grey cloud) exposes the origin IP directly, bypassing the WAF and DDoS protection. Check each DNS record used by hosted sites. |
| C3 | Configure Cloudflare to restrict origin IP access to Cloudflare's published IP ranges on ports 80/443 | CE+ Firewalls, PCI 1.3 | Prevents bypass of Cloudflare by direct connection to the origin IP. Can be implemented as UFW rules allowing only Cloudflare's IP ranges on 80/443, or at the Edge Firewall layer. |
| C4 | Configure Traefik to trust Cloudflare IP ranges and log `CF-Connecting-IP` as the real client IP | PCI 10.2.1 (audit accuracy) | Without this, audit logs show Cloudflare egress IPs as the source, not real client IPs. Traefik `forwardedHeaders.trustedIPs` should include Cloudflare's IP ranges. |

---

## Conditional Gaps (PCI DSS — Only Applicable if CDE in Scope)

The following gaps only become relevant if a hosted application brings these servers into PCI CDE or connected-system scope. We are not a PCI business; these are tracked proactively.

| ID | Gap | PCI Requirement | Detail |
|---|---|---|---|
| P1 | No PCI ASV external vulnerability scan | Req 11.2.2 | Quarterly external scan by a PCI SSC Approved Scanning Vendor required. Cannot be self-performed. Estimated cost: £500–£2,000/quarter depending on IP scope. |
| P2 | No external penetration test | Req 11.3.1 | Annual external penetration test by a CREST-accredited provider required. Must test both Cloudflare-fronted domains and origin server IP (dual-track). |
| P3 | No internal penetration test | Req 11.3.2 | Annual internal penetration test required. Can be self-performed by qualified staff. |
| P4 | No formal TLS certificate inventory | Req 4.2.1.1 | Inventory of all trusted keys and certificates in the CDE. Cloudflare-managed at edge; Let's Encrypt at Traefik. Operational documentation deliverable. |
| P5 | Host anti-malware (Req 5.2) — architectural position | Req 5.2–5.3 | If a QSA does not accept the compensating control position, ClamAV installation is the fallback. See `pci-dss.md` for the full architectural position. ClamAV integration tracked as contingency item: `scripts/setup-clamav.sh`. |

---

## Out of Scope — Acknowledged

The following items have been raised in the context of compliance assessments and are acknowledged here. They are not infrastructure script work; they belong with the deploying organisation's governance programme.

| Item | Frameworks | Note |
|---|---|---|
| Formal ISMS documentation (SOA, risk register, management review) | ISO 27001 | Organisational governance; cannot be addressed by infrastructure scripts |
| Incident response runbooks and escalation procedures | NIST IR, NIS2, SOC 2 CC7 | Detection tooling is in place; documented response procedures are the organisation's responsibility |
| Staff security awareness training | CE+, NIS2, NIST AT | Personnel controls |
| NIS2 registration with competent authority | NIS2 | Regulatory; depends on organisation's sector and size determination |
| NIS2 incident reporting procedures (24h/72h timelines) | NIS2 Art 23 | Procedural; cannot be met by infrastructure scripts |
| PCI QSA engagement and Report on Compliance | PCI DSS Req 12 | Required for PCI attestation; organisational commitment |
| PCI CDE scoping documentation | PCI DSS | Must be determined by the organisation based on application architecture |
| Supplier contracts and third-party risk registers (Cloudflare, NewRelic) | NIS2, ISO A.5, SOC 2 CC9 | Policy/procurement work |
| Formal change management process | ISO A.8.9, NIST CM-3, SOC 2 CC8 | Git history provides audit trail; a formal CAB is an organisational process decision |
| Block device encryption confirmation | ISO A.8.24, NIST SC-28, PCI Req 3, GDPR Art 32 | VM hypervisor responsibility; assumed in place; confirmation requires access to hypervisor management |
| SOC 2 audit engagement (Type I / Type II) | SOC 2 | Requires AICPA-licensed CPA firm; Type II needs ≥6-month observation window; organisational decision |
| SOC 2 CC1–CC5 control documentation (policies, risk assessment) | SOC 2 | Control environment, risk management, and security policy documentation; organisational deliverable |
| GDPR ROPA (Article 30), DPIA (Article 35), DPO (Article 37) | GDPR | Legal/governance obligations; determined by the deploying organisation's DPO or legal team |
| GDPR Article 28 Data Processing Agreements | GDPR | Contractual; required where this hosting infrastructure acts as processor for a controller |
| GDPR breach notification procedures (Article 33/34) | GDPR | 72-hour reporting obligation to supervisory authority; procedural, not infrastructure |
| GDPR pseudonymisation of personal data | GDPR Art 32(1)(a) | Application-level data design; infrastructure scripts cannot determine what personal data is processed |
| NCSC Cloud Security Principles governance framework (Principle 4) | NCSC CSP | Formal ISMS documentation; organisational deliverable |
| NCSC Cloud Security Principles personnel security (Principle 6) | NCSC CSP | Background screening, joiners/movers/leavers process; HR and organisational |
| G-Cloud supplier registration | NCSC CSP | Crown Commercial Service supplier submission; organisational decision |

---

*Last updated: 2026-05-04*
