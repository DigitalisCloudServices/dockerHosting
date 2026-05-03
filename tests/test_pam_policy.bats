#!/usr/bin/env bats
# Tests for scripts/setup-pam-policy.sh
# Focuses on pam_faillock insertion order — a previous bug had authsucc and authfail
# swapped, causing valid passwords to fail authentication.

load 'helpers/common'

SCRIPT="$REPO_ROOT/scripts/setup-pam-policy.sh"

# Minimal Debian Trixie common-auth (stock, before hardening)
STOCK_COMMON_AUTH='auth	[success=1 default=ignore]	pam_unix.so nullok
auth	requisite			pam_deny.so
auth	required			pam_permit.so
auth	optional			pam_cap.so'

setup() {
    TMPDIR="$BATS_TEST_TMPDIR"
    export PAM_AUTH="$TMPDIR/common-auth"
    printf '%s\n' "$STOCK_COMMON_AUTH" > "$PAM_AUTH"
}

# Simulate the three sed insertions from setup-pam-policy.sh using Python3
# (portable across GNU/Linux and BSD/macOS).
# Replicates the step-by-step behaviour of three separate `sed -i` runs:
#   1. /pam_unix.so/i preauth   — insert before
#   2. /pam_unix.so/a authsucc  — insert after  (first run)
#   3. /pam_unix.so/a authfail  — insert after  (second run, lands directly after pam_unix)
# Final order: preauth → pam_unix → authfail → authsucc
_apply_faillock_insertions() {
    python3 - "$PAM_AUTH" <<'PYEOF'
import sys
f = sys.argv[1]

PREAUTH  = "auth    required      pam_faillock.so preauth silent audit deny=5 unlock_time=900"
AUTHSUCC = "auth    sufficient    pam_faillock.so authsucc audit deny=5 unlock_time=900"
AUTHFAIL = "auth    [default=die] pam_faillock.so authfail audit deny=5 unlock_time=900"

def insert_before(lines, marker, new_line):
    out = []
    for l in lines:
        if marker in l:
            out.append(new_line + "\n")
        out.append(l)
    return out

def insert_after(lines, marker, new_line):
    out = []
    for l in lines:
        out.append(l)
        if marker in l:
            out.append(new_line + "\n")
    return out

lines = open(f).readlines()
lines = insert_before(lines, "pam_unix.so", PREAUTH)   # step 1: preauth before pam_unix
lines = insert_after(lines,  "pam_unix.so", AUTHSUCC)  # step 2: authsucc after pam_unix
lines = insert_after(lines,  "pam_unix.so", AUTHFAIL)  # step 3: authfail after pam_unix (lands before authsucc)
open(f, "w").writelines(lines)
PYEOF
}

# Return the 1-based line number of a pattern in the file, or empty string.
_lineno() {
    grep -n "$1" "$PAM_AUTH" | head -1 | cut -d: -f1
}

@test "pam_faillock: preauth appears before pam_unix" {
    _apply_faillock_insertions
    preauth=$(_lineno "preauth")
    unix=$(_lineno "pam_unix.so")
    [ -n "$preauth" ] && [ -n "$unix" ]
    [ "$preauth" -lt "$unix" ]
}

@test "pam_faillock: authfail appears immediately after pam_unix (success=1 skips it on success)" {
    _apply_faillock_insertions
    unix=$(_lineno "pam_unix.so")
    authfail=$(_lineno "authfail")
    [ -n "$unix" ] && [ -n "$authfail" ]
    [ "$authfail" -eq $(( unix + 1 )) ]
}

@test "pam_faillock: authsucc appears after authfail (reached only on success)" {
    _apply_faillock_insertions
    authfail=$(_lineno "authfail")
    authsucc=$(_lineno "authsucc")
    [ -n "$authfail" ] && [ -n "$authsucc" ]
    [ "$authsucc" -gt "$authfail" ]
}

@test "pam_faillock: all three faillock lines are present" {
    _apply_faillock_insertions
    grep -q "pam_faillock.so preauth"  "$PAM_AUTH"
    grep -q "pam_faillock.so authfail" "$PAM_AUTH"
    grep -q "pam_faillock.so authsucc" "$PAM_AUTH"
}

@test "pam_faillock: pam_unix line is preserved unchanged" {
    _apply_faillock_insertions
    grep -q "pam_unix.so nullok" "$PAM_AUTH"
}

@test "pam_faillock: pam_deny and pam_permit survive insertion" {
    _apply_faillock_insertions
    grep -q "pam_deny.so"   "$PAM_AUTH"
    grep -q "pam_permit.so" "$PAM_AUTH"
}
