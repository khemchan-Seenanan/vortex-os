#!/bin/bash
# Build vortex-<ver>-amd64.iso with Debian live-build inside a privileged
# bookworm container (live-build needs loop devices + chroots).
# Boots UEFI and legacy BIOS (iso-hybrid). Fully offline install: the live
# squashfs ships all Vortex packages from the bundled signed repo.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HERE=$ROOT/targets/iso
VERSION=$(cat "$ROOT/VERSION")

[ -d "$ROOT/repo/public/dists" ] || { echo "ERROR: repo/public missing — run 'make repo' first"; exit 1; }
ls "$ROOT"/dist/debs/vortex-archive-keyring_*.deb >/dev/null 2>&1 \
    || { echo "ERROR: keyring deb missing — run 'make packages' first"; exit 1; }

if [ ! -f /.dockerenv ] && [ -z "${VORTEX_IN_ISO_BUILDER:-}" ]; then
    exec docker run --rm --privileged -e VORTEX_IN_ISO_BUILDER=1 \
        -v "$ROOT":/work -w /work debian:bookworm \
        bash -c "apt-get update -qq && apt-get install -y -qq live-build xorriso ca-certificates git >/dev/null && bash targets/iso/build.sh"
fi

BUILD=$HERE/.build
rm -rf "$BUILD"; mkdir -p "$BUILD"
cd "$BUILD"

mkdir -p auto
cp "$HERE/auto/config" auto/config && chmod +x auto/config
lb config

# --- wire in the Vortex repo, keyring, preseed and hooks ----------------------
# Local signed repo inside the chroot (offline package install at build time).
mkdir -p config/includes.chroot/opt
cp -a "$ROOT/repo/public" config/includes.chroot/opt/vortex-repo

mkdir -p config/includes.chroot/usr/share/keyrings config/includes.chroot/etc/apt/sources.list.d
# extract just the keyring from the keyring deb (the deb itself installs below)
dpkg-deb --fsys-tarfile "$ROOT"/dist/debs/vortex-archive-keyring_*.deb \
    | tar -xO ./usr/share/keyrings/vortex-archive-keyring.gpg \
    > config/includes.chroot/usr/share/keyrings/vortex-archive-keyring.gpg
cat > config/includes.chroot/etc/apt/sources.list.d/vortex-local.sources <<'EOF'
Types: deb
URIs: file:/opt/vortex-repo
Suites: bookworm
Components: main
Signed-By: /usr/share/keyrings/vortex-archive-keyring.gpg
EOF

# Vortex payload (vortex-archive-keyring installs the ONLINE source for updates)
mkdir -p config/package-lists
cat > config/package-lists/vortex.list.chroot <<'EOF'
vortex-archive-keyring
vortex-core
vortex-webui
vortex-openclaw
vortex-firstboot
sudo
EOF

mkdir -p config/hooks/live
cp "$HERE/hooks/0500-vortex-slim.hook.chroot" config/hooks/live/
chmod +x config/hooks/live/0500-vortex-slim.hook.chroot

# Preseed onto the medium where bootappend-install expects it.
mkdir -p config/includes.binary/install
cp "$HERE/preseed/vortex.cfg" config/includes.binary/install/vortex.cfg

# --- build ---------------------------------------------------------------------
lb build

mkdir -p "$ROOT/dist"
cp live-image-amd64.hybrid.iso "$ROOT/dist/vortex-${VERSION}-amd64.iso"
( cd "$ROOT/dist" && sha256sum "vortex-${VERSION}-amd64.iso" >> SHA256SUMS )
echo "==> dist/vortex-${VERSION}-amd64.iso"
