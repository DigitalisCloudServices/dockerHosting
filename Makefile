# dockerHosting — development targets
# Requires: shellcheck, bats (bats-core), yamllint
# Optional: shfmt, bashate, shellharden, kcov
#
# Install on macOS:  brew install shellcheck bats-core yamllint shfmt shellharden
# Install on Debian: apt-get install shellcheck bats yamllint shfmt
#                    pip install bashate

.PHONY: help lint test test-traefik test-lib test-syntax test-args test-yaml test-pam test-hooks \
        test-fail2ban test-harden-docker test-harden-kernel test-install-packages test-scan-image \
        test-firewall test-run-report test-install-observability test-configure-observability-egress \
        test-format test-style test-security test-complexity test-unused test-docs test-permissions \
        format coverage ci test-all check-deps

SHELL := /bin/bash

# All shell scripts to lint (excluding test helper stubs)
SCRIPTS := setup.sh deploy-site.sh \
  $(wildcard scripts/*.sh) \
  $(wildcard lib/*.sh)

# Prefer a project-local bats install, fall back to system
BATS := $(shell command -v bats 2>/dev/null || echo "")

# ── help ─────────────────────────────────────────────────────────────────────

help:
	@echo "Available targets:"
	@echo ""
	@echo "Core Tests:"
	@echo "  make lint              Run shellcheck on all scripts"
	@echo "  make test              Run required test suite (lint + bats + yaml)"
	@echo "  make test-all          Comprehensive suite with all quality checks"
	@echo "  make ci                Fast CI subset (lint + syntax + args + yaml)"
	@echo ""
	@echo "BATS Test Suites:"
	@echo "  make test-traefik      Run Traefik script tests only"
	@echo "  make test-lib          Run lib/ script tests"
	@echo "  make test-syntax       Run bash syntax checks for all scripts"
	@echo "  make test-args         Run argument-validation tests"
	@echo "  make test-pam          Run PAM policy tests"
	@echo "  make test-hooks        Run lifecycle hook tests"
	@echo "  make test-fail2ban     Run fail2ban tests"
	@echo "  make test-harden-docker Run Docker hardening tests"
	@echo "  make test-harden-kernel Run kernel hardening tests"
	@echo "  make test-install-packages Run install-packages tests"
	@echo "  make test-scan-image   Run image scanning tests"
	@echo "  make test-yaml         Run YAML validation checks"
	@echo ""
	@echo "Code Quality:"
	@echo "  make test-format       Check shell script formatting (shfmt)"
	@echo "  make test-style        Check bash style guide compliance (bashate)"
	@echo "  make test-security     Check for security anti-patterns (shellharden)"
	@echo "  make test-complexity   Check function length and nesting depth"
	@echo "  make test-unused       Detect unused functions"
	@echo "  make test-docs         Check function documentation coverage"
	@echo "  make test-permissions  Verify all .sh files are executable"
	@echo ""
	@echo "Utilities:"
	@echo "  make format            Auto-format all scripts with shfmt"
	@echo "  make coverage          Generate test coverage report (kcov)"
	@echo "  make check-deps        Check required tools are installed"

# ── dependency check ─────────────────────────────────────────────────────────

check-deps:
	@echo "Checking required dependencies..."
	@command -v shellcheck >/dev/null 2>&1 \
		|| { echo "ERROR: shellcheck not found."; \
		     echo "  macOS:  brew install shellcheck"; \
		     echo "  Debian: apt-get install shellcheck"; exit 1; }
	@echo "  ✓ shellcheck $(shell shellcheck --version | grep version: | awk '{print $$2}')"
	@command -v bats >/dev/null 2>&1 \
		|| { echo "ERROR: bats not found."; \
		     echo "  macOS:  brew install bats-core"; \
		     echo "  Debian: apt-get install bats"; exit 1; }
	@echo "  ✓ bats $(shell bats --version)"
	@command -v yamllint >/dev/null 2>&1 \
		|| { echo "ERROR: yamllint not found."; \
		     echo "  macOS:  brew install yamllint"; \
		     echo "  Debian: apt-get install yamllint"; exit 1; }
	@echo "  ✓ yamllint $(shell yamllint --version 2>&1 | awk '{print $$2}')"
	@echo "All required dependencies present."
	@echo ""
	@echo "Checking optional quality tools..."
	@command -v shfmt >/dev/null 2>&1 \
		&& echo "  ✓ shfmt $(shell shfmt --version)" \
		|| echo "  ⚠ shfmt not found (optional - for formatting checks)"
	@command -v bashate >/dev/null 2>&1 \
		&& echo "  ✓ bashate $(shell bashate --version 2>&1 | head -1)" \
		|| echo "  ⚠ bashate not found (optional - for style checks)"
	@command -v shellharden >/dev/null 2>&1 \
		&& echo "  ✓ shellharden $(shell shellharden --version 2>&1 | head -1)" \
		|| echo "  ⚠ shellharden not found (optional - for security checks)"
	@command -v kcov >/dev/null 2>&1 \
		&& echo "  ✓ kcov $(shell kcov --version 2>&1 | head -1)" \
		|| echo "  ⚠ kcov not found (optional - for coverage reports)"

# ── lint ─────────────────────────────────────────────────────────────────────

lint: check-deps
	@echo "Running shellcheck on $(words $(SCRIPTS)) scripts..."
	@shellcheck --severity=warning $(SCRIPTS)
	@echo "✓ Lint passed"

# ── tests ────────────────────────────────────────────────────────────────────

# Core test suite (required checks only)
test: lint test-syntax test-args test-traefik test-lib test-pam test-hooks test-fail2ban test-harden-docker test-harden-kernel test-install-packages test-scan-image test-firewall test-run-report test-install-observability test-configure-observability-egress test-yaml test-permissions
	@echo "✓ All required tests passed"

# Comprehensive test suite with optional quality checks
test-all: test test-format test-style test-security test-complexity test-docs test-unused
	@echo "✓ Full test suite completed"

# Fast CI subset (no optional tools required)
ci: lint test-syntax test-args test-yaml test-permissions
	@echo "✓ CI checks passed"

test-traefik: check-deps
	@echo "Running Traefik script tests..."
	@bats --recursive tests/traefik/

test-lib: check-deps
	@echo "Running lib/ script tests..."
	@bats --recursive tests/lib/

test-syntax: check-deps
	@echo "Running syntax checks..."
	@bats tests/test_syntax.bats

test-args: check-deps
	@echo "Running argument validation tests..."
	@bats tests/test_arg_validation.bats

test-pam: check-deps
	@echo "Running PAM policy tests..."
	@bats tests/test_pam_policy.bats

test-hooks: check-deps
	@echo "Running lifecycle hook tests..."
	@bats tests/test_lifecycle_hooks.bats

test-fail2ban: check-deps
	@echo "Running fail2ban tests..."
	@bats tests/security/test_fail2ban.bats

test-harden-docker: check-deps
	@echo "Running Docker hardening tests..."
	@bats tests/security/test_harden_docker.bats

test-harden-kernel: check-deps
	@echo "Running kernel hardening tests..."
	@bats tests/security/test_harden_kernel.bats

test-install-packages: check-deps
	@echo "Running install-packages tests..."
	@bats tests/test_install_packages.bats

test-scan-image: check-deps
	@echo "Running image scanning tests..."
	@bats tests/test_scan_image.bats

test-firewall: check-deps
	@echo "Running firewall tests..."
	@bats tests/security/test_firewall.bats

test-run-report: check-deps
	@echo "Running run-report tests..."
	@bats tests/test_run_report.bats

test-install-observability: check-deps
	@echo "Running install-observability tests..."
	@bats tests/test_install_observability.bats

test-configure-observability-egress: check-deps
	@echo "Running configure-observability-egress tests..."
	@bats tests/test_configure_observability_egress.bats

test-yaml: check-deps
	@echo "Running YAML validation..."
	@bats tests/test_yaml.bats

# ── code quality ─────────────────────────────────────────────────────────────

test-format:
	@echo "Checking shell script formatting..."
	@command -v shfmt >/dev/null 2>&1 \
		|| { echo "ERROR: shfmt not found. Install: brew install shfmt"; exit 1; }
	@shfmt -d -i 4 -ci -sr $(SCRIPTS) \
		|| { echo "✗ Formatting issues found. Run 'make format' to fix."; exit 1; }
	@echo "✓ Format check passed"

test-style:
	@echo "Running bashate style checks..."
	@command -v bashate >/dev/null 2>&1 \
		|| { echo "ERROR: bashate not found. Install: pip install bashate"; exit 1; }
	@bashate --verbose --ignore E006,E010,E011 $(SCRIPTS)
	@echo "✓ Style check passed"

test-security:
	@echo "Running security checks..."
	@command -v shellharden >/dev/null 2>&1 \
		|| { echo "ERROR: shellharden not found. Install: brew install shellharden"; exit 1; }
	@for script in $(SCRIPTS); do \
		shellharden --check "$$script" || exit 1; \
	done
	@echo "✓ Security check passed"

test-complexity:
	@echo "Checking code complexity..."
	@./scripts/check-complexity.sh

test-unused:
	@echo "Checking for unused functions..."
	@./scripts/check-unused-functions.sh

test-docs:
	@echo "Checking function documentation..."
	@./scripts/check-function-docs.sh

test-permissions:
	@echo "Checking file permissions..."
	@./scripts/check-permissions.sh

# ── formatters ───────────────────────────────────────────────────────────────

format:
	@echo "Formatting shell scripts..."
	@command -v shfmt >/dev/null 2>&1 \
		|| { echo "ERROR: shfmt not found. Install: brew install shfmt"; exit 1; }
	@shfmt -w -i 4 -ci -sr $(SCRIPTS)
	@echo "✓ Formatted $(words $(SCRIPTS)) scripts"

# ── coverage ─────────────────────────────────────────────────────────────────

coverage:
	@echo "Generating test coverage report..."
	@command -v kcov >/dev/null 2>&1 \
		|| { echo "ERROR: kcov not found. Install: brew install kcov"; exit 1; }
	@mkdir -p coverage
	@kcov --exclude-pattern=/usr coverage/ bats tests/
	@echo "✓ Coverage report generated in coverage/"
	@echo "  Open coverage/index.html to view"
