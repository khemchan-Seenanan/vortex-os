#!/bin/bash
# Build vortex-<ver>-amd64.qcow2 (+ .ova) with debos in Docker.
# Uses KVM when /dev/kvm exists, else debos's qemu fallback (slower but works
# on plain CI runners).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HERE=$ROOT/targets/vm
VERSION=$(cat "$ROOT/VERSION")
DEBOS_IMAGE=godebos/debos:latest

[ -d "$ROOT/repo/public/dists" ] || { echo "ERROR: repo/public missing — run 'make repo' first"; exit 1; }
ls "$ROOT"/dist/debs/vortex-archive-keyring_*.deb >/dev/null 2>&1 \
    || { echo "ERROR: keyring deb missing — run 'make packages' first"; exit 1; }

# --- stage the signed repo + keyring into the recipe overlays ------------------
rm -rf "$HERE/overlays/vortex-repo" "$HERE/overlays/apt/usr" "$HERE/scratch"
mkdir -p "$HERE/scratch"
cp -a "$ROOT/repo/public/." "$HERE/overlays/vortex-repo/"
# keyring must pre-exist for the file: source Signed-By before the package installs
mkdir -p "$HERE/overlays/apt/keyrings-stage"
dpkg-deb --fsys-tarfile "$ROOT"/dist/debs/vortex-archive-keyring_*.deb 2>/dev/null \
    | tar -xO ./usr/share/keyrings/vortex-archive-keyring.gpg \
    > "$HERE/overlays/apt/keyrings-stage/vortex-archive-keyring.gpg" 2>/dev/null || {
    # host may lack dpkg — extract inside the debos container instead
    docker run --rm -v "$ROOT":/work debian:bookworm-slim bash -c \
      "dpkg-deb --fsys-tarfile /work/dist/debs/vortex-archive-keyring_*.deb | tar -xO ./usr/share/keyrings/vortex-archive-keyring.gpg" \
      > "$HERE/overlays/apt/keyrings-stage/vortex-archive-keyring.gpg"
    }

# debos overlay 'apt' lands on /etc/apt — keyrings live elsewhere; relocate via
# a tiny pre-script overlay trick: ship it under /etc/apt and move in chroot.
# (install-vortex.sh runs after overlays; first apt-get update needs the key.)
mkdir -p "$HERE/overlays/apt/trusted.gpg.d" # ensure dir exists
cp "$HERE/overlays/apt/keyrings-stage/vortex-archive-keyring.gpg" \
   "$HERE/overlays/vortex-repo/vortex-archive-keyring.gpg"
sed -i 's|Signed-By: /usr/share/keyrings/vortex-archive-keyring.gpg|Signed-By: /opt/vortex-repo/vortex-archive-keyring.gpg|' \
   "$HERE/overlays/apt/sources.list.d/vortex-local.sources" 2>/dev/null || true
rm -rf "$HERE/overlays/apt/keyrings-stage"

# --- run debos ------------------------------------------------------------------
KVM_ARGS=""
[ -e /dev/kvm ] && KVM_ARGS="--device /dev/kvm"
docker run --rm --privileged $KVM_ARGS \
    -v "$HERE":/recipe -w /recipe "$DEBOS_IMAGE" \
    debos -t image:scratch/vortex-vm.raw vortex-vm.yaml

# --- convert artifacts ------------------------------------------------------------
QCOW=$ROOT/dist/vortex-${VERSION}-amd64.qcow2
mkdir -p "$ROOT/dist"
docker run --rm -v "$ROOT":/work -v "$HERE":/recipe debian:bookworm-slim bash -c "
    apt-get update -qq && apt-get install -y -qq qemu-utils >/dev/null &&
    qemu-img convert -O qcow2 -c /recipe/scratch/vortex-vm.raw /work/dist/vortex-${VERSION}-amd64.qcow2"
( cd "$ROOT/dist" && sha256sum "vortex-${VERSION}-amd64.qcow2" >> SHA256SUMS )
echo "==> dist/vortex-${VERSION}-amd64.qcow2"

bash "$HERE/ova/make-ova.sh" "$QCOW" "$ROOT/dist/vortex-${VERSION}-amd64.ova"
