#!/bin/bash -e
# stage-vortex: the entire Pi pipeline payload. Tiny by design — all Vortex
# behavior lives in the packages; this stage only installs them from the
# signed repo tree bundled at build time (no network needed in the chroot).

# 1. Bring in the bundled signed repo + keyring package
install -d "${ROOTFS_DIR}/tmp/vortex"
cp -a files/vortex-repo "${ROOTFS_DIR}/tmp/vortex/repo"
cp files/vortex-archive-keyring_*.deb "${ROOTFS_DIR}/tmp/vortex/"

on_chroot <<'CHROOT'
set -e
# Keyring first: installs /usr/share/keyrings/... and the ONLINE vortex.sources
# (used for apt upgrade after install).
dpkg -i /tmp/vortex/vortex-archive-keyring_*.deb

# Build-time source: the bundled tree, same signature, zero network.
cat > /etc/apt/sources.list.d/vortex-local.sources <<EOF
Types: deb
URIs: file:///tmp/vortex/repo
Suites: bookworm
Components: main
Signed-By: /usr/share/keyrings/vortex-archive-keyring.gpg
EOF

apt-get update -o Dir::Etc::SourceParts=/etc/apt/sources.list.d
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    vortex-core vortex-core-sdcard vortex-webui vortex-openclaw vortex-firstboot

# Shrink the image
/usr/sbin/vortex-slim

# Drop the build-time source; the online one from the keyring package stays.
rm -f /etc/apt/sources.list.d/vortex-local.sources
rm -rf /tmp/vortex
apt-get clean
CHROOT

# 2. Images must never ship SSH host keys (regenerated on first boot)
rm -f "${ROOTFS_DIR}/etc/ssh/ssh_host_"*

# 3. Pi firmware tweaks: no GPU RAM for a headless box, no bluetooth
CONFIG_TXT="${ROOTFS_DIR}/boot/firmware/config.txt"
if [ -f "$CONFIG_TXT" ]; then
	grep -q '^gpu_mem=' "$CONFIG_TXT" || cat >> "$CONFIG_TXT" <<'EOF'

# Vortex OS: headless console box — minimal GPU split, bluetooth off.
# WiFi stays enabled; to disable add: dtoverlay=disable-wifi
gpu_mem=16
dtoverlay=disable-bt
EOF
fi
