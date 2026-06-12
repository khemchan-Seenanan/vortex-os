#!/bin/bash
# Build vortex-pi-<ver>-arm64.img.xz with pi-gen (Docker path — works on any
# x86 host/CI with binfmt+qemu-user-static, which Docker Desktop and
# ubuntu-latest runners provide).
#
# Prereqs: dist/debs/ populated (make packages) and repo/public/ published
# (make repo) — the signed repo tree is bundled so the chroot needs no network
# for Vortex packages.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HERE=$ROOT/targets/pi
VERSION=$(cat "$ROOT/VERSION")

# Pinned pi-gen (bookworm branch, 2025-11-24)
PIGEN_REPO=https://github.com/RPi-Distro/pi-gen.git
PIGEN_COMMIT=de9df5623109331cebf990578f342583d9138376

[ -d "$ROOT/repo/public/dists" ] || { echo "ERROR: repo/public missing — run 'make repo' first"; exit 1; }
ls "$ROOT"/dist/debs/vortex-archive-keyring_*.deb >/dev/null 2>&1 \
    || { echo "ERROR: keyring deb missing — run 'make packages' first"; exit 1; }

# --- pinned pi-gen checkout --------------------------------------------------
if [ ! -d "$HERE/pi-gen/.git" ]; then
    git clone "$PIGEN_REPO" "$HERE/pi-gen"
fi
git -C "$HERE/pi-gen" fetch --quiet origin
git -C "$HERE/pi-gen" checkout --quiet "$PIGEN_COMMIT"

# --- inject our stage + config ----------------------------------------------
rm -rf "$HERE/pi-gen/stage-vortex"
cp -a "$HERE/stage-vortex" "$HERE/pi-gen/stage-vortex"
chmod +x "$HERE"/pi-gen/stage-vortex/prerun.sh "$HERE"/pi-gen/stage-vortex/*/[0-9][0-9]-run.sh

# bundle the signed repo tree + keyring deb into the stage
FILES="$HERE/pi-gen/stage-vortex/00-vortex/files"
rm -rf "$FILES"; mkdir -p "$FILES"
cp -a "$ROOT/repo/public" "$FILES/vortex-repo"
cp "$ROOT"/dist/debs/vortex-archive-keyring_*.deb "$FILES/"

cp "$HERE/config" "$HERE/pi-gen/config"

# only the final stage exports an image
touch "$HERE"/pi-gen/stage0/SKIP_IMAGES "$HERE"/pi-gen/stage1/SKIP_IMAGES "$HERE"/pi-gen/stage2/SKIP_IMAGES
rm -f "$HERE"/pi-gen/stage2/EXPORT_IMAGE

# --- build (pi-gen's own Docker wrapper) --------------------------------------
cd "$HERE/pi-gen"
PRESERVE_CONTAINER=0 ./build-docker.sh -c config

# --- collect artifact ----------------------------------------------------------
mkdir -p "$ROOT/dist"
out=$(ls -t deploy/*.img.xz | head -n1)
cp "$out" "$ROOT/dist/vortex-pi-${VERSION}-arm64.img.xz"
( cd "$ROOT/dist" && sha256sum "vortex-pi-${VERSION}-arm64.img.xz" >> SHA256SUMS )
echo "==> dist/vortex-pi-${VERSION}-arm64.img.xz"
