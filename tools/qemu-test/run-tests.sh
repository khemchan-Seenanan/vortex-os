#!/bin/bash
# Vortex OS boot-test harness. Runs whatever is possible for the artifacts
# present in dist/ (see `make test`):
#
#   .iso    → unattended preseeded install into a blank qcow2, then boot and
#             assert the system contract over SSH
#   .qcow2  → boot directly with a NoCloud seed, assert cloud-init+firstboot
#   .img.xz → (Pi) chroot-level assertions — real boot needs hardware; see
#             the manual checklist in README.md
#
# Requirements: qemu-system-x86_64 (+OVMF for the UEFI pass), qemu-img,
# cloud-image-utils (cloud-localds), sshpass. On Windows, run inside WSL2.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
VERSION=$(cat "$ROOT/VERSION")
DIST=$ROOT/dist
SSH_PORT=2222
RAM_MB=4096

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
fail()  { red "FAIL: $*"; exit 1; }

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p $SSH_PORT"
vssh() { sshpass -p "${VORTEX_TEST_PASSWORD:-vortextest1}" ssh $SSH_OPTS vortex@127.0.0.1 "$@"; }

wait_ssh() {
    local tries=${1:-120}
    for _ in $(seq 1 "$tries"); do
        vssh true 2>/dev/null && return 0
        sleep 5
    done
    return 1
}

# ---- the system contract: identical asserts for every bootable target -------
assert_vortex() {
    echo "--- asserting the Vortex system contract over SSH"
    vssh "dpkg -l vortex-core vortex-webui vortex-openclaw vortex-firstboot | grep '^ii' | wc -l" | grep -q 4 \
        || fail "vortex packages not all installed"
    vssh "systemctl list-units --all vortex.slice | grep -q vortex.slice" \
        || fail "vortex.slice missing"
    vssh "swapon --show | grep -q zram0" \
        || fail "zram swap not active"
    vssh "systemctl is-enabled openclaw.service" | grep -qE 'enabled|disabled' \
        || fail "openclaw.service not installed"
    # pre-init: enabled-but-not-started is the contract (ships disabled until wizard)
    vssh "test -f /etc/vortex/.initialized || ! systemctl is-active --quiet openclaw.service" \
        || fail "openclaw running before initialization"
    vssh "curl -ks https://127.0.0.1/ | grep -qi vortex" \
        || fail "Caddy not answering on 443"
    vssh "ss -ltn | grep -q '127.0.0.1:9090'" \
        || fail "cockpit not bound to localhost"
    vssh "ss -ltn | grep -q '127.0.0.1:8090'" \
        || fail "stats daemon not bound to localhost"
    # idle RAM before OpenClaw starts: <= 200MB on amd64
    used=$(vssh "free -m | awk '/^Mem:/{print \$3}'")
    [ "$used" -le 200 ] || fail "idle RAM ${used}MB > 200MB budget"
    # vortex-tune adapts: profile must match this VM's RAM tier (4GB → 2-4GB tier)
    vssh "/usr/sbin/vortex-tune --json" | grep -q '"tier":"2-4GB"' \
        || fail "vortex-tune profile does not match 4GB tier"
    green "system contract OK (idle RAM ${used}MB)"
}

# ---- ISO: unattended install, then boot both firmwares ----------------------
# The shipped preseed deliberately keeps two questions interactive (password,
# disk-wipe confirmation). For CI we boot the ISO's kernel/initrd directly and
# answer those on the kernel cmdline — same preseed, plus the two answers.
test_iso() {
    local iso=$1 firmware=$2
    local disk; disk=$(mktemp -u /tmp/vortex-iso-test-XXXX.qcow2)
    qemu-img create -f qcow2 "$disk" 16G >/dev/null
    local fw_args=""
    if [ "$firmware" = uefi ]; then
        local ovmf
        ovmf=$(ls /usr/share/OVMF/OVMF_CODE*.fd 2>/dev/null | head -n1) || true
        [ -n "$ovmf" ] || { red "SKIP: OVMF not installed"; rm -f "$disk"; return 0; }
        fw_args="-bios $ovmf"
    fi
    echo "=== ISO install test ($firmware) — this takes a while"
    local mnt; mnt=$(mktemp -d)
    mount -o loop,ro "$iso" "$mnt"
    cp "$mnt/install/vmlinuz" "$mnt/install/initrd.gz" /tmp/vortex-iso-kernel/ 2>/dev/null || {
        mkdir -p /tmp/vortex-iso-kernel
        cp "$mnt"/install*/vmlinuz /tmp/vortex-iso-kernel/vmlinuz
        cp "$mnt"/install*/initrd.gz /tmp/vortex-iso-kernel/initrd.gz
    }
    umount "$mnt"; rmdir "$mnt"
    qemu-system-x86_64 -m $RAM_MB -smp 2 $fw_args \
        -kernel /tmp/vortex-iso-kernel/vmlinuz -initrd /tmp/vortex-iso-kernel/initrd.gz \
        -append "auto=true priority=critical file=/cdrom/install/vortex.cfg \
passwd/user-password=${VORTEX_TEST_PASSWORD:-vortextest1} \
passwd/user-password-again=${VORTEX_TEST_PASSWORD:-vortextest1} \
partman-partitioning/confirm_write_new_label=true partman/confirm=true \
partman/confirm_nooverwrite=true console=ttyS0" \
        -drive file="$disk",if=virtio \
        -cdrom "$iso" \
        -netdev user,id=n0,hostfwd=tcp::$SSH_PORT-:22 -device virtio-net,netdev=n0 \
        -display none -serial null -no-reboot
    echo "--- install pass done; booting installed disk"
    qemu-system-x86_64 -m $RAM_MB -smp 2 $fw_args \
        -drive file="$disk",if=virtio \
        -netdev user,id=n0,hostfwd=tcp::$SSH_PORT-:22 -device virtio-net,netdev=n0 \
        -display none -daemonize -pidfile "$disk.pid"
    wait_ssh || fail "installed system never came up on SSH"
    assert_vortex
    kill "$(cat "$disk.pid")" 2>/dev/null || true
    rm -f "$disk" "$disk.pid"
}

# ---- qcow2: NoCloud seed boot ------------------------------------------------
test_qcow2() {
    local qcow=$1
    echo "=== qcow2 NoCloud boot test"
    local work; work=$(mktemp -d)
    local disk=$work/disk.qcow2
    qemu-img create -f qcow2 -b "$qcow" -F qcow2 "$disk" 16G >/dev/null
    cat > "$work/user-data" <<EOF
#cloud-config
password: ${VORTEX_TEST_PASSWORD:-vortextest1}
chpasswd: { expire: false }
ssh_pwauth: true
EOF
    printf 'instance-id: vortex-test\nlocal-hostname: vortex\n' > "$work/meta-data"
    cloud-localds "$work/seed.iso" "$work/user-data" "$work/meta-data"
    qemu-system-x86_64 -m $RAM_MB -smp 2 \
        -drive file="$disk",if=virtio \
        -drive file="$work/seed.iso",if=virtio,media=cdrom \
        -netdev user,id=n0,hostfwd=tcp::$SSH_PORT-:22 -device virtio-net,netdev=n0 \
        -display none -daemonize -pidfile "$work/qemu.pid"
    wait_ssh || fail "qcow2 never came up on SSH (check cloud-init)"
    vssh "cloud-init status --wait" || fail "cloud-init did not finish"
    assert_vortex
    kill "$(cat "$work/qemu.pid")" 2>/dev/null || true
    rm -rf "$work"
}

# ---- Pi image: chroot-level assertions (no hardware in CI) -------------------
test_pi_img() {
    local img_xz=$1
    echo "=== Pi image chroot assertions (full boot needs hardware — see README)"
    local work; work=$(mktemp -d)
    xz -dk -c "$img_xz" > "$work/pi.img"
    local loop
    loop=$(losetup --show -fP "$work/pi.img")
    mkdir -p "$work/root"
    mount "${loop}p2" "$work/root"
    for f in \
        usr/sbin/vortex-tune usr/sbin/vortex-slim \
        etc/systemd/system/vortex.slice \
        etc/caddy/Caddyfile opt/openclaw/node_modules/.bin/openclaw \
        etc/default/zramswap etc/vortex/openclaw.env; do
        [ -e "$work/root/$f" ] || fail "pi image missing /$f"
    done
    ls "$work/root/etc/ssh/ssh_host_"* 2>/dev/null && fail "pi image ships SSH host keys"
    grep -q 'gpu_mem=16' "$work/root/../boot/config.txt" 2>/dev/null || {
        mkdir -p "$work/boot"; mount "${loop}p1" "$work/boot"
        grep -q 'gpu_mem=16' "$work/boot/config.txt" || fail "gpu_mem=16 not set"
        umount "$work/boot"; }
    umount "$work/root"; losetup -d "$loop"; rm -rf "$work"
    green "pi image assertions OK"
}

ran=0
if ls "$DIST"/vortex-${VERSION}-amd64.iso >/dev/null 2>&1; then
    test_iso "$DIST/vortex-${VERSION}-amd64.iso" bios
    test_iso "$DIST/vortex-${VERSION}-amd64.iso" uefi
    ran=1
fi
if ls "$DIST"/vortex-${VERSION}-amd64.qcow2 >/dev/null 2>&1; then
    test_qcow2 "$DIST/vortex-${VERSION}-amd64.qcow2"; ran=1
fi
if ls "$DIST"/vortex-pi-${VERSION}-arm64.img.xz >/dev/null 2>&1; then
    test_pi_img "$DIST/vortex-pi-${VERSION}-arm64.img.xz"; ran=1
fi
[ "$ran" = 1 ] || { red "nothing to test — build artifacts first (make all)"; exit 1; }
green "all available artifact tests passed"
