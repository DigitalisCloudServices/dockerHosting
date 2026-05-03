# Security Compliance Posture

Proactive posture tracking for dockerHosting against major compliance frameworks. Not a certification programme — intended as internal best-practice evidence and auditor-ready documentation.

All assessments cover **technical controls only**. Organisational policies, risk registers, personnel controls, incident reporting procedures, and audit evidence collection are outside the scope of infrastructure scripts and must be addressed by the deploying organisation.

---

## Architecture

Understanding the security architecture is prerequisite to any framework assessment. Several layers exist outside these scripts and materially affect every framework's posture.

### Inbound Web Traffic Stack

```
Internet
  ↓  Cloudflare — DDoS (L3/L4/L7), WAF, OWASP managed ruleset
  ↓  Edge Firewall — default-deny, operator-managed (external to these scripts)
  ↓  DMZ — ModSecurity WAF reverse proxy
  ↓  Host — UFW default-deny, Docker network isolation
  ↓  Container — AppArmor, seccomp, userns-remap, icc=false
```

The origin host IP is never directly internet-exposed for web traffic. The effective internet-facing boundary is the Cloudflare + Edge Firewall + ModSecurity stack, none of which is managed by these scripts.

### Administrative Access

SSH is not internet-exposed. All administrative access is behind site VPN or dedicated SSH bastion hosts, with MFA enforced at the access layer. Direct SSH from the internet is not possible by network topology.

CI/CD pipelines use a read-only service account. Deployable artefacts are signed and encrypted; the host validates the package signature before use.

### Host Model

These hosts are designed as cattle — the foundational layer of a fleet intended to migrate toward Kubernetes. The OS layer is stateless. Docker workloads may use local volumes (a known transitional risk tracked in [gaps.md](compliance/gaps.md)); no application data of record lives at the OS layer. Recovery is IaC re-deployment from `setup.sh` combined with application state from external replication.

### Encryption at Rest

| Layer | Responsibility | Status |
|---|---|---|
| Application layer | Each application | Out of scope — assumed in place |
| Block device / VM | Hypervisor / VM host | Out of scope — assumed in place |
| Host OS | Not applicable | Handled at the layers above and below |

---

## Scope of This Documentation

These scripts configure the host OS and Docker daemon on Debian Trixie. They do not manage:

- Application-level security (application code, databases, API security)
- CI/CD pipeline security (out of scope; assumed well-managed with signed artefacts)
- VPN / bastion host configuration (out of scope; assumed MFA-enforced)
- VM hypervisor or block device encryption (out of scope; assumed in place)
- Cloudflare, Edge Firewall, or ModSecurity configuration (external controls)
- NewRelic account settings (operational configuration, not infrastructure scripts)
- Organisational policies, risk registers, or governance

---

## Framework Coverage Summary

Coverage is expressed as a range: **known ~ assumed**.

- **Known** — controls directly implemented and verifiable on the host by running these scripts alone
- **Assumed** — full deployment with all external architecture validated in place (Cloudflare, Edge Firewall, ModSecurity WAF, VPN/bastion MFA, platform-level egress filtering, block device encryption)

These are estimates against **technical controls only** and do not represent certification readiness. See the [Reference Comparison](#reference-comparison) section below for context against a default Debian install and a typical manually-hardened server.

| Framework | Known ~ Assumed | Document |
|---|---|---|
| ISO 27001:2022 — Annex A.8 Technological | ~82% ~ ~88% | [iso27001.md](compliance/iso27001.md) |
| CIS Benchmark — Debian Linux Level 1 | ~85% ~ ~88% | [cis-linux.md](compliance/cis-linux.md) |
| CIS Benchmark — Debian Linux Level 2 | ~63% ~ ~65% | [cis-linux.md](compliance/cis-linux.md) |
| CIS Benchmark — Docker v1.6 | ~70% ~ ~73% | [cis-docker.md](compliance/cis-docker.md) |
| NIST SP 800-53 (selected families) | ~75% ~ ~80% | [nist-800-53.md](compliance/nist-800-53.md) |
| UK Cyber Essentials Plus | ~68% ~ ~82% | [cyber-essentials-plus.md](compliance/cyber-essentials-plus.md) |
| UK NIS / EU NIS2 (Article 21 technical measures) | ~72% ~ ~78% | [nis2.md](compliance/nis2.md) |
| PCI DSS v4.0 (conditional scope) | ~65% ~ ~72% | [pci-dss.md](compliance/pci-dss.md) |

---

## Reference Comparison

The percentages above are most useful as deltas. Three reference points are defined here to give them context.

> All percentages are **script-level technical controls only**. They exclude organisational policies, third-party testing, and audit evidence — all of which add further requirements on top for formal certification.

### The Three Reference Points

**Default Debian Trixie (clean install)**
A freshly installed server with no post-install hardening. UFW is inactive. SSH accepts password authentication and root login. No audit logging, no AIDE, no PAM complexity policy, no kernel hardening beyond kernel defaults. Docker, if installed, runs with no daemon hardening.

**Typical Hardened (industry baseline)**
What a security-conscious administrator commonly applies manually: UFW enabled with basic inbound rules, SSH key-only and no root login, basic PAM lockout, fail2ban, chrony NTP, Docker with a few common flags. This represents reasonable awareness but not systematic framework-driven coverage — no comprehensive auditd ruleset, no per-container isolation policy, no kernel sysctl hardening beyond common knowledge, no AppArmor on containers.

**dockerHosting Full Baseline**
All scripts in `setup.sh` run in full, including optional controls (AppArmor, USB hardening, GRUB). External controls (Cloudflare, ModSecurity, VPN/bastion) are **not** counted here — this column reflects only what the scripts configure on the host. Open infrastructure gaps (G1 Docker egress, G2 Traefik 8080) are reflected in the numbers.

### Coverage by Reference Point

| Framework | Default Debian | Typical Hardened | dockerHosting (known ~ assumed) |
|---|---|---|---|
| ISO 27001:2022 A.8 | ~15% | ~50% | ~82% ~ ~88% |
| CIS Linux Level 1 | ~20% | ~60% | ~85% ~ ~88% |
| CIS Linux Level 2 | ~5% | ~25% | ~63% ~ ~65% |
| CIS Docker | ~0% | ~40% | ~70% ~ ~73% |
| NIST SP 800-53 | ~15% | ~45% | ~75% ~ ~80% |
| UK Cyber Essentials Plus | ~10% | ~45% | ~68% ~ ~82% |
| UK NIS / EU NIS2 | ~10% | ~40% | ~72% ~ ~78% |
| PCI DSS v4.0 | ~5% | ~35% | ~65% ~ ~72% |

The gap between Default Debian and Typical Hardened is primarily SSH hardening, basic PAM, and UFW. The gap between Typical Hardened and dockerHosting is systematic coverage: comprehensive auditd rules (28+), per-site user isolation, Docker daemon hardening, kernel sysctl policy, AIDE FIM, AppArmor on all containers, automatic security updates, and USB/boot hardening. When external controls are added on top of dockerHosting, the effective posture increases further still.

### What a Technical Assessor Would Find

For a host running the full dockerHosting baseline, a configuration review or automated scan would expect the following outcomes. This is not certification — it is what the server looks like on the day.

| Assessment Tool / Check | Expected Outcome |
|---|---|
| `lynis audit system` — hardening index | 85–90 (vs ~65 typical hardened; ~40 default Debian) |
| `docker-bench-security` | Pass: sections 1–3; Partial: sections 4–5; Incomplete: section 6 |
| SSH configuration audit | Pass — key-only, no root, AEAD ciphers only, no forwarding |
| PAM policy audit | Pass — 14-char minimum, complexity, 5-password history, pam_faillock lockout |
| Firewall policy review | Pass for host-level rules; Docker container egress flagged as open (G1) |
| AppArmor status | Pass — docker-default profile enforced on all containers |
| Audit log review | Pass — 28+ rules, immutable ruleset, remote shipping via NewRelic |
| Kernel hardening (sysctl) | Pass — ASLR, SYN cookies, ptrace restriction, BPF, dmesg |
| MFA check | Pass — enforced at VPN/bastion access boundary; host TOTP available as optional additional layer |
| NTP synchronisation | Pass — chrony with ≥2 agreeing sources |
| Container image vulnerability scan | Pass — Trivy blocks CRITICAL CVEs at deploy |

---

## Known Gaps and Remediation

Open technical gaps, risk ratings, priorities, and deferral rationale are maintained separately to keep framework assessments clean.

→ [gaps.md](compliance/gaps.md)

---

*Last updated: 2026-05-03*
