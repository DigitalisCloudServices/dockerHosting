#!/bin/bash
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#############################################
# Migrate /etc/fstab entries from kernel device names to UUID=
#
# Kernel names (/dev/sda1, /dev/nvme0n1p1, ...) are handed out in probe order
# and can change from one boot to the next. On 2026-10-12 a GCE host rebooted
# with its two SCSI disks swapped: fstab mounted the data disk as
# "/dev/sdb1 /opt", /dev/sdb1 was now the root disk, so /opt got the root
# filesystem a second time and the Docker stack under /opt disappeared. A UUID
# names the filesystem, not the slot, so it survives that.
#
# Only an entry whose source is a kernel name (sd, vd, xvd, hd, nvme) is
# rewritten. UUID=, PARTUUID=, LABEL=, PARTLABEL=, /dev/disk/by-*, /dev/mapper,
# LVM, tmpfs, proc, swap files, network filesystems and comments are left as
# they are. Options and field layout are kept, and nofail is not added.
#
# An entry is migrated only when the running system proves which filesystem
# its name means right now:
#   - filesystem: its mountpoint is mounted from that device, the mounted
#     filesystem's UUID is the one blkid reports for the device, and that
#     filesystem is mounted nowhere else. Mounted twice is what the swapped
#     boot above looked like (the root filesystem on / and on /opt); pinning
#     that UUID would make the wrong disk permanent.
#   - swap partition: it is active (/proc/swaps) from that device.
# An entry that is not mounted (or not active) is skipped with a warning. An
# entry mounted from the wrong device, with the wrong UUID or twice means the
# kernel names on this boot cannot be trusted, so nothing is migrated at all.
#
# The new file goes through `findmnt --verify` before it replaces fstab, and
# fstab is backed up first (/etc/fstab.bak-<UTC timestamp>). A second run finds
# nothing to do.
#
# Usage: migrate-fstab-to-uuid.sh [--dry-run]
#############################################

set -euo pipefail

FSTAB="${FSTAB:-/etc/fstab}"
PROC_SWAPS="${PROC_SWAPS:-/proc/swaps}"
DRY_RUN=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *)
            log_error "Unknown option: $arg (usage: $0 [--dry-run])"
            exit 1
            ;;
    esac
done

if [[ "$EUID" -ne 0 ]]; then
    log_error "This script must be run as root"
    exit 1
fi

# is_kernel_name SPEC: true for /dev/sdb1, /dev/vda, /dev/xvdf1, /dev/hda2,
# /dev/nvme0n1 and /dev/nvme0n1p3; false for everything else.
is_kernel_name() {
    [[ "$1" =~ ^/dev/((sd|vd|xvd|hd)[a-z]+[0-9]*|nvme[0-9]+n[0-9]+(p[0-9]+)?)$ ]]
}

# mount_problem DEV TARGET UUID: prints nothing when TARGET is mounted from DEV
# with the filesystem UUID, and that filesystem is mounted nowhere else.
# Otherwise prints why not, and returns 2 when that means the kernel names on
# this boot are wrong rather than the entry simply not being mounted.
mount_problem() {
    local dev="$1" target="$2" uuid="$3" source mounted_uuid majmin others
    source="$(findmnt -n -o SOURCE --mountpoint "$target" || true)"
    if [[ -z "$source" ]]; then
        echo "$target is not mounted"
        return 0
    fi
    if [[ "$source" != "$dev" ]]; then
        echo "$target is mounted from $source, not $dev"
        return 2
    fi
    mounted_uuid="$(findmnt -n -o UUID --mountpoint "$target" || true)"
    if [[ "$mounted_uuid" != "$uuid" ]]; then
        echo "the filesystem on $target has UUID '$mounted_uuid', but blkid gives $dev '$uuid'"
        return 2
    fi
    majmin="$(findmnt -n -o MAJ:MIN --mountpoint "$target")"
    # Whole-filesystem mounts (FSROOT /) of the same device; bind mounts of a
    # subdirectory do not count.
    others="$(findmnt -rn -o MAJ:MIN,FSROOT,TARGET |
        awk -v d="$majmin" '$1 == d && $2 == "/" { n++; t = t " " $3 } END { if (n > 1) print t }')"
    if [[ -n "$others" ]]; then
        echo "$dev is mounted on more than one place:$others"
        return 2
    fi
}

# swap_problem DEV: prints nothing when DEV is an active swap device.
swap_problem() {
    awk -v d="$1" 'NR > 1 && $1 == d { found = 1 } END { exit !found }' "$PROC_SWAPS" ||
        echo "swap on $1 is not active"
}

# migrate_line LINE: prints LINE with a kernel-name source replaced by UUID=
# when the running system proves it safe, and LINE untouched otherwise.
# Counts MIGRATED and SKIPPED, and sets UNTRUSTED for a mismatch.
migrate_line() {
    local line="$1" spec target fstype rest uuid problem rc=0 lead
    read -r spec target fstype rest <<< "$line"
    if ! is_kernel_name "$spec"; then
        printf '%s\n' "$line"
        return
    fi
    uuid="$(blkid -s UUID -o value "$spec" 2> /dev/null || true)"
    if [[ -z "$uuid" ]]; then
        problem="blkid finds no filesystem UUID on $spec"
    elif [[ "$fstype" == "swap" ]]; then
        problem="$(swap_problem "$spec")"
    else
        problem="$(mount_problem "$spec" "$target" "$uuid")" || rc=$?
    fi
    if [[ -n "$problem" ]]; then
        log_warn "SKIPPED $spec ($target): $problem" >&2
        SKIPPED=$((SKIPPED + 1))
        [[ "$rc" -ne 2 ]] || UNTRUSTED=true
        printf '%s\n' "$line"
        return
    fi
    lead="${line%%[![:space:]]*}"
    printf '%s\n' "${lead}UUID=${uuid}${line#"${lead}${spec}"}"
    log_info "$spec -> UUID=$uuid ($target)" >&2
    MIGRATED=$((MIGRATED + 1))
}

# install_candidate FILE: back up fstab, check FILE with findmnt --verify and
# move it into place. FSTAB is not touched when the check fails.
install_candidate() {
    local candidate="$1" backup
    backup="${FSTAB}.bak-$(date -u +%Y%m%dT%H%M%SZ)"
    cp -p "$FSTAB" "$backup"
    log_info "Backed up $FSTAB to $backup"
    if ! findmnt --verify --tab-file "$candidate"; then
        log_error "findmnt --verify rejects the migrated file: $FSTAB is unchanged (backup: $backup)"
        exit 1
    fi
    mv -f "$candidate" "$FSTAB"
    log_info "Wrote $FSTAB (entries migrated: $MIGRATED)"
    systemctl daemon-reload || log_warn "systemctl daemon-reload failed: run it before the next reboot"
}

[[ -f "$FSTAB" ]] || {
    log_error "$FSTAB not found"
    exit 1
}

log_info "Migrating kernel device names in $FSTAB to UUID=..."
MIGRATED=0
SKIPPED=0
UNTRUSTED=false
candidate=""
if [[ "$DRY_RUN" == false ]]; then
    # Same directory, so the final mv is an atomic rename; cp -p carries the
    # original's mode and owner over before the content is replaced.
    candidate="$(mktemp "${FSTAB}.new.XXXXXX")"
    trap 'rm -f "$candidate"' EXIT
    cp -p "$FSTAB" "$candidate"
    : > "$candidate"
fi

while IFS= read -r line || [[ -n "$line" ]]; do
    migrate_line "$line" >> "${candidate:-/dev/null}"
done < "$FSTAB"

if [[ "$UNTRUSTED" == true ]]; then
    log_warn "════════════════════════════════════════════════════════════════"
    log_warn "A kernel device name in $FSTAB does not match what is mounted."
    log_warn "The disks may have come up under different names this boot (as on"
    log_warn "2026-10-12). Nothing was migrated: pinning UUIDs now could make the"
    log_warn "wrong disk permanent. Check each mount with lsblk -f, fix them, re-run."
    log_warn "════════════════════════════════════════════════════════════════"
    exit 0
fi
[[ "$SKIPPED" -eq 0 ]] || log_warn "Entries left as kernel names: $SKIPPED (see above). Mount them and re-run."
if [[ "$MIGRATED" -eq 0 ]]; then
    log_info "Nothing to migrate: $FSTAB unchanged"
    exit 0
fi
if [[ "$DRY_RUN" == true ]]; then
    log_info "Dry run: would migrate $MIGRATED entries; $FSTAB unchanged"
    exit 0
fi
install_candidate "$candidate"
