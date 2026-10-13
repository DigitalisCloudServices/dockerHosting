#!/usr/bin/env bats
# Tests for scripts/migrate-fstab-to-uuid.sh
#
# findmnt, blkid and systemctl are mocks. The mounted state comes from $MOUNTS
# (one "target source uuid maj:min fsroot" line per mount), blkid answers from
# $BLKID ("device uuid" lines) and active swap from $PROC_SWAPS. The script is
# patched to skip its root check, except in the test of that check.

load 'helpers/common'

SCRIPT="$SCRIPTS_DIR/migrate-fstab-to-uuid.sh"

ROOT_UUID="11111111-aaaa-4bbb-8ccc-000000000001"
DATA_UUID="22222222-aaaa-4bbb-8ccc-000000000002"
SWAP_UUID="33333333-aaaa-4bbb-8ccc-000000000003"

setup() {
    setup_mocks
    export FSTAB="$BATS_TEST_TMPDIR/etc/fstab"
    export PROC_SWAPS="$BATS_TEST_TMPDIR/proc_swaps"
    export MOUNTS="$BATS_TEST_TMPDIR/mounts"
    export BLKID="$BATS_TEST_TMPDIR/blkid"
    export FINDMNT_LOG="$BATS_TEST_TMPDIR/findmnt.log"
    export BLKID_LOG="$BATS_TEST_TMPDIR/blkid.log"
    export SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
    mkdir -p "$(dirname "$FSTAB")"
    printf 'Filename\t\t\t\tType\t\tSize\t\tUsed\t\tPriority\n' > "$PROC_SWAPS"

    # A healthy GCE host: root disk sda, data disk sdb on /opt.
    cat > "$FSTAB" <<EOF
UUID=$ROOT_UUID / ext4 rw,discard,errors=remount-ro,x-systemd.growfs 0 1
/dev/sdb1 /opt ext4 defaults 0 0
EOF
    cat > "$MOUNTS" <<EOF
/ /dev/sda1 $ROOT_UUID 8:1 /
/opt /dev/sdb1 $DATA_UUID 8:17 /
EOF
    cat > "$BLKID" <<EOF
/dev/sda1 $ROOT_UUID
/dev/sdb1 $DATA_UUID
EOF

    cat > "$MOCK_BIN/findmnt" <<'MOCK'
#!/bin/bash
echo "$*" >> "$FINDMNT_LOG"
if [[ "$1" == "--verify" ]]; then
    [[ -z "${MOCK_VERIFY_FAILS:-}" ]] && exit 0
    echo "[E] mock verify failure in $3"
    exit 1
fi
if [[ "$1" == "-rn" ]]; then
    awk '{ print $4, $5, $1 }' "$MOUNTS"
    exit 0
fi
# findmnt -n -o COLUMN --mountpoint TARGET; exits 1 when nothing is mounted there.
case "$3" in SOURCE) f=2 ;; UUID) f=3 ;; MAJ:MIN) f=4 ;; esac
awk -v t="$5" -v f="$f" '$1 == t { print $f; found = 1 } END { exit !found }' "$MOUNTS"
MOCK
    chmod +x "$MOCK_BIN/findmnt"

    # blkid -s UUID -o value DEV; exits 2 when DEV has no UUID, like blkid.
    cat > "$MOCK_BIN/blkid" <<'MOCK'
#!/bin/bash
echo "$*" >> "$BLKID_LOG"
awk -v d="$5" '$1 == d { print $2; found = 1 } END { exit found ? 0 : 2 }' "$BLKID"
MOCK
    chmod +x "$MOCK_BIN/blkid"

    create_call_log_mock systemctl "$SYSTEMCTL_LOG"

    PATCHED_SCRIPT="$BATS_TEST_TMPDIR/migrate-fstab-to-uuid.sh"
    sed 's|if \[\[ "\$EUID" -ne 0 \]\]|if false|' "$SCRIPT" > "$PATCHED_SCRIPT"
    ORIGINAL="$BATS_TEST_TMPDIR/fstab.original"
}

teardown() {
    teardown_mocks
}

# Snapshot fstab as it is now, so a test can check it is unchanged.
_snapshot() {
    cp "$FSTAB" "$ORIGINAL"
}

_backups() {
    find "$(dirname "$FSTAB")" -name 'fstab.bak-*' | wc -l | tr -d ' '
}

_leftovers() {
    find "$(dirname "$FSTAB")" -name 'fstab.new.*' | wc -l | tr -d ' '
}

run_migrate() {
    run bash "$PATCHED_SCRIPT" "$@"
}

# ── migration ───────────────────────────────────────────────────────────────

@test "migrate-fstab: a mounted kernel-name entry becomes UUID=" {
    run_migrate
    [ "$status" -eq 0 ]
    grep -qx "UUID=$DATA_UUID /opt ext4 defaults 0 0" "$FSTAB"
    refute_file_contains "$FSTAB" '/dev/sdb1'
    grep -qF -- "/dev/sdb1 -> UUID=$DATA_UUID (/opt)" <<< "$output"
    [ "$(_leftovers)" -eq 0 ]
}

@test "migrate-fstab: reloads systemd after writing" {
    run_migrate
    [ "$status" -eq 0 ]
    grep -qx 'daemon-reload' "$SYSTEMCTL_LOG"
}

@test "migrate-fstab: the new file is checked with findmnt --verify before it replaces fstab" {
    run_migrate
    [ "$status" -eq 0 ]
    grep -q -- "--verify --tab-file $FSTAB.new." "$FINDMNT_LOG"
}

@test "migrate-fstab: backs fstab up with a timestamp before writing" {
    _snapshot
    run_migrate
    [ "$status" -eq 0 ]
    [ "$(_backups)" -eq 1 ]
    backup=$(find "$(dirname "$FSTAB")" -name 'fstab.bak-*')
    grep -Eq 'fstab\.bak-[0-9]{8}T[0-9]{6}Z$' <<< "$backup"
    cmp "$ORIGINAL" "$backup"
}

@test "migrate-fstab: keeps the file's mode" {
    chmod 640 "$FSTAB"
    run_migrate
    [ "$status" -eq 0 ]
    [ "$(file_mode "$FSTAB")" = "640" ]
}

@test "migrate-fstab: comments, other entries, options and layout are kept byte for byte" {
    printf '%s\n' \
        '# /etc/fstab: static file system information.' \
        '#' \
        '# <file system> <mount point>   <type>  <options>       <dump>  <pass>' \
        "UUID=$ROOT_UUID /               ext4    errors=remount-ro 0       1" \
        'PARTUUID=5e1d2c3b-01  /boot  ext4  defaults  0 2' \
        'LABEL=scratch /scratch xfs defaults,nofail 0 2' \
        'PARTLABEL=logs /var/log/extra ext4 defaults 0 2' \
        '/dev/disk/by-id/google-data-part1 /data ext4 defaults 0 2' \
        '/dev/mapper/vg0-lv0 /srv ext4 defaults 0 2' \
        '/dev/vg0/backup /backup ext4 defaults 0 2' \
        'tmpfs /dev/shm tmpfs defaults,noexec,nodev,nosuid,size=2G 0 0' \
        'proc /proc proc defaults,hidepid=2 0 0' \
        '/swapfile none swap sw 0 0' \
        'nfs.example.internal:/export /mnt/nfs nfs4 defaults,_netdev 0 0' \
        '#/dev/sdc1 /old ext4 defaults 0 0' \
        '' > "$FSTAB"
    printf '\t/dev/sdb1\t/opt\text4\tdefaults,noatime\t0\t2  \n' >> "$FSTAB"
    _snapshot

    run_migrate
    [ "$status" -eq 0 ]

    expected="$BATS_TEST_TMPDIR/expected"
    head -n 16 "$ORIGINAL" > "$expected"
    printf '\tUUID=%s\t/opt\text4\tdefaults,noatime\t0\t2  \n' "$DATA_UUID" >> "$expected"
    diff "$expected" "$FSTAB"
    # Only the kernel-name entry was looked up.
    [ "$(cat "$BLKID_LOG")" = "-s UUID -o value /dev/sdb1" ]
}

@test "migrate-fstab: recognises every kernel-name family and nothing else" {
    printf '%s\n' \
        '/dev/nvme0n1p1 /mnt/a ext4 defaults 0 2' \
        '/dev/nvme1n1 /mnt/b ext4 defaults 0 2' \
        '/dev/vdb /mnt/c ext4 defaults 0 2' \
        '/dev/xvdf1 /mnt/d ext4 defaults 0 2' \
        '/dev/hda2 /mnt/e ext4 defaults 0 2' \
        '/dev/sdaa1 /mnt/f ext4 defaults 0 2' \
        '/dev/md0 /mnt/raid ext4 defaults 0 2' \
        '/dev/sr0 /media/cdrom udf,iso9660 user,noauto 0 0' \
        '/dev/loop0 /mnt/loop ext4 defaults 0 2' \
        '/dev/dm-0 /mnt/dm ext4 defaults 0 2' > "$FSTAB"
    : > "$MOUNTS"
    : > "$BLKID"
    n=0
    for dev in nvme0n1p1:a nvme1n1:b vdb:c xvdf1:d hda2:e sdaa1:f; do
        n=$((n + 1))
        echo "/mnt/${dev#*:} /dev/${dev%:*} uuid-$n 259:$n /" >> "$MOUNTS"
        echo "/dev/${dev%:*} uuid-$n" >> "$BLKID"
    done

    run_migrate
    [ "$status" -eq 0 ]
    for i in 1 2 3 4 5 6; do
        grep -q "^UUID=uuid-$i " "$FSTAB"
    done
    grep -qx '/dev/md0 /mnt/raid ext4 defaults 0 2' "$FSTAB"
    grep -qx '/dev/sr0 /media/cdrom udf,iso9660 user,noauto 0 0' "$FSTAB"
    grep -qx '/dev/loop0 /mnt/loop ext4 defaults 0 2' "$FSTAB"
    grep -qx '/dev/dm-0 /mnt/dm ext4 defaults 0 2' "$FSTAB"
    [ -z "$(grep -E 'md0|sr0|loop0|dm-0' "$BLKID_LOG")" ]
}

@test "migrate-fstab: a bind mount of a subdirectory elsewhere does not block it" {
    echo "/srv/cache /dev/sdb1 $DATA_UUID 8:17 /cache" >> "$MOUNTS"
    run_migrate
    [ "$status" -eq 0 ]
    grep -qx "UUID=$DATA_UUID /opt ext4 defaults 0 0" "$FSTAB"
}

# ── swap ────────────────────────────────────────────────────────────────────

@test "migrate-fstab: an active swap partition becomes UUID=" {
    echo '/dev/sdb2 none swap sw 0 0' >> "$FSTAB"
    echo "/dev/sdb2 $SWAP_UUID" >> "$BLKID"
    printf '/dev/sdb2                               partition\t2097148\t\t0\t\t-2\n' >> "$PROC_SWAPS"
    run_migrate
    [ "$status" -eq 0 ]
    grep -qx "UUID=$SWAP_UUID none swap sw 0 0" "$FSTAB"
}

@test "migrate-fstab: an inactive swap partition is skipped with a warning, the rest still migrates" {
    echo '/dev/sdb2 none swap sw 0 0' >> "$FSTAB"
    echo "/dev/sdb2 $SWAP_UUID" >> "$BLKID"
    run_migrate
    [ "$status" -eq 0 ]
    grep -qx '/dev/sdb2 none swap sw 0 0' "$FSTAB"
    grep -qF -- "SKIPPED /dev/sdb2 (none): swap on /dev/sdb2 is not active" <<< "$output"
    grep -qx "UUID=$DATA_UUID /opt ext4 defaults 0 0" "$FSTAB"
}

# ── entries that are skipped ────────────────────────────────────────────────

@test "migrate-fstab: an unmounted entry is skipped with a warning, the rest still migrates" {
    echo '/dev/sdc1 /backup ext4 defaults,noauto 0 2' >> "$FSTAB"
    echo "/dev/sdc1 44444444-aaaa-4bbb-8ccc-000000000004" >> "$BLKID"
    run_migrate
    [ "$status" -eq 0 ]
    grep -qx '/dev/sdc1 /backup ext4 defaults,noauto 0 2' "$FSTAB"
    grep -qF -- "SKIPPED /dev/sdc1 (/backup): /backup is not mounted" <<< "$output"
    grep -qF -- "Entries left as kernel names: 1" <<< "$output"
    grep -qx "UUID=$DATA_UUID /opt ext4 defaults 0 0" "$FSTAB"
}

@test "migrate-fstab: a device with no filesystem UUID is skipped with a warning" {
    sed -i.orig "/sdb1/d" "$BLKID"
    _snapshot
    run_migrate
    [ "$status" -eq 0 ]
    cmp "$ORIGINAL" "$FSTAB"
    grep -qF -- "SKIPPED /dev/sdb1 (/opt): blkid finds no filesystem UUID on /dev/sdb1" <<< "$output"
    [ "$(_backups)" -eq 0 ]
}

# ── a boot whose kernel names cannot be trusted ─────────────────────────────

# The 2026-10-12 state: the disks came up swapped, /dev/sdb1 is now the root
# disk, and systemd mounted it on /opt as well as /. Device and UUID agree with
# fstab, so only the second mount of the same filesystem gives it away.
@test "migrate-fstab: the swapped-disk boot (root filesystem also on /opt) migrates nothing" {
    cat > "$MOUNTS" <<EOF
/ /dev/sdb1 $ROOT_UUID 8:17 /
/opt /dev/sdb1 $ROOT_UUID 8:17 /
EOF
    cat > "$BLKID" <<EOF
/dev/sda1 $DATA_UUID
/dev/sdb1 $ROOT_UUID
EOF
    _snapshot
    run_migrate
    [ "$status" -eq 0 ]
    cmp "$ORIGINAL" "$FSTAB"
    grep -qF -- "SKIPPED /dev/sdb1 (/opt): /dev/sdb1 is mounted on more than one place: / /opt" <<< "$output"
    grep -qF -- "Nothing was migrated" <<< "$output"
    [ "$(_backups)" -eq 0 ]
    [ "$(_leftovers)" -eq 0 ]
    [ ! -s "$SYSTEMCTL_LOG" ]
}

@test "migrate-fstab: a mountpoint mounted from another device migrates nothing, not even good entries" {
    echo '/dev/sdc1 /backup ext4 defaults 0 2' >> "$FSTAB"
    echo "/backup /dev/sdc1 44444444-aaaa-4bbb-8ccc-000000000004 8:33 /" >> "$MOUNTS"
    echo "/dev/sdc1 44444444-aaaa-4bbb-8ccc-000000000004" >> "$BLKID"
    sed -i.orig "s|^/opt /dev/sdb1 |/opt /dev/sda1 |" "$MOUNTS"
    _snapshot
    run_migrate
    [ "$status" -eq 0 ]
    cmp "$ORIGINAL" "$FSTAB"
    grep -qF -- "SKIPPED /dev/sdb1 (/opt): /opt is mounted from /dev/sda1, not /dev/sdb1" <<< "$output"
    grep -qF -- "Nothing was migrated" <<< "$output"
    [ "$(_backups)" -eq 0 ]
}

@test "migrate-fstab: a mounted UUID that differs from blkid's migrates nothing" {
    sed -i.orig "s|^/opt /dev/sdb1 $DATA_UUID|/opt /dev/sdb1 $ROOT_UUID|" "$MOUNTS"
    _snapshot
    run_migrate
    [ "$status" -eq 0 ]
    cmp "$ORIGINAL" "$FSTAB"
    grep -qF -- "the filesystem on /opt has UUID '$ROOT_UUID', but blkid gives /dev/sdb1 '$DATA_UUID'" <<< "$output"
    grep -qF -- "Nothing was migrated" <<< "$output"
}

# ── idempotency, dry run, failures ──────────────────────────────────────────

@test "migrate-fstab: a second run changes nothing and says so" {
    run_migrate
    [ "$status" -eq 0 ]
    cp "$FSTAB" "$ORIGINAL"
    : > "$SYSTEMCTL_LOG"
    run_migrate
    [ "$status" -eq 0 ]
    grep -qF -- "Nothing to migrate: $FSTAB unchanged" <<< "$output"
    cmp "$ORIGINAL" "$FSTAB"
    [ "$(_backups)" -eq 1 ]
    [ "$(_leftovers)" -eq 0 ]
    [ ! -s "$SYSTEMCTL_LOG" ]
}

@test "migrate-fstab: an fstab already on UUIDs is left alone" {
    sed -i.orig "s|^/dev/sdb1 |UUID=$DATA_UUID |" "$FSTAB"
    _snapshot
    run_migrate
    [ "$status" -eq 0 ]
    cmp "$ORIGINAL" "$FSTAB"
    grep -qF -- "Nothing to migrate" <<< "$output"
    [ ! -s "$BLKID_LOG" ]
}

@test "migrate-fstab: --dry-run reports the change and writes nothing" {
    _snapshot
    run_migrate --dry-run
    [ "$status" -eq 0 ]
    grep -qF -- "/dev/sdb1 -> UUID=$DATA_UUID (/opt)" <<< "$output"
    grep -qF -- "Dry run: would migrate 1 entries" <<< "$output"
    cmp "$ORIGINAL" "$FSTAB"
    [ "$(_backups)" -eq 0 ]
    [ "$(_leftovers)" -eq 0 ]
    refute_file_contains "$FINDMNT_LOG" '--verify'
    [ ! -s "$SYSTEMCTL_LOG" ]
}

@test "migrate-fstab: a file findmnt --verify rejects is not kept" {
    _snapshot
    MOCK_VERIFY_FAILS=1 run_migrate
    [ "$status" -ne 0 ]
    grep -qF -- "findmnt --verify rejects the migrated file" <<< "$output"
    cmp "$ORIGINAL" "$FSTAB"
    [ "$(_backups)" -eq 1 ]
    [ "$(_leftovers)" -eq 0 ]
    [ ! -s "$SYSTEMCTL_LOG" ]
}

@test "migrate-fstab: a missing fstab is an error" {
    rm -f "$FSTAB"
    run_migrate
    [ "$status" -eq 1 ]
    grep -qF -- "not found" <<< "$output"
}

@test "migrate-fstab: an unknown option is an error" {
    _snapshot
    run_migrate --force
    [ "$status" -eq 1 ]
    grep -qF -- "Unknown option: --force" <<< "$output"
    cmp "$ORIGINAL" "$FSTAB"
}

@test "migrate-fstab: refuses to run as non-root" {
    [ "$EUID" -ne 0 ] || skip "the root check cannot fail when the tests run as root"
    _snapshot
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    grep -qF -- "must be run as root" <<< "$output"
    cmp "$ORIGINAL" "$FSTAB"
}
