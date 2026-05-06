# dockerHosting — development targets
# Requires: shellcheck, bats (bats-core), yamllint
#
# Install on macOS:  brew install shellcheck bats-core yamllint
# Install on Debian: apt-get install shellcheck bats yamllint

.PHONY: help lint test test-traefik test-lib test-syntax test-args test-yaml test-pam test-hooks check-deps

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
	@echo "  make lint          Run shellcheck on all scripts"
	@echo "  make test          Run full test suite (lint + bats + yaml)"
	@echo "  make test-traefik  Run Traefik script tests only"
	@echo "  make test-lib      Run lib/ script tests"
	@echo "  make test-syntax   Run bash syntax checks for all scripts"
	@echo "  make test-args     Run argument-validation tests"
	@echo "  make test-pam      Run PAM policy tests"
	@echo "  make test-hooks    Run lifecycle hook tests"
	@echo "  make test-yaml     Run YAML validation checks"
	@echo "  make check-deps    Check required tools are installed"

# ── dependency check ─────────────────────────────────────────────────────────

check-deps:
	@echo "Checking dependencies..."
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
	@echo "All dependencies present."

# ── lint ─────────────────────────────────────────────────────────────────────

lint: check-deps
	@echo "Running shellcheck on $(words $(SCRIPTS)) scripts..."
	@shellcheck --severity=warning $(SCRIPTS)
	@echo "✓ Lint passed"

# ── tests ────────────────────────────────────────────────────────────────────

test: lint test-syntax test-args test-traefik test-lib test-pam test-hooks test-yaml
	@echo "✓ All tests passed"

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

test-yaml: check-deps
	@echo "Running YAML validation..."
	@bats tests/test_yaml.bats
