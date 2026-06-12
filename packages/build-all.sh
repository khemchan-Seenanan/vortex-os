#!/bin/bash
# Build every Vortex OS .deb for arm64 + amd64 inside Docker.
# Standalone (`bash packages/build-all.sh`) or via `make packages`.
#
# Output: dist/debs/*.deb
#
# Signing key: production builds expect the public keyring at
# repo/keys/vortex-archive-keyring.gpg (created once by `repo/publish.sh init`).
# Without it, a DEV key is generated under repo/keys/dev/ (gitignored) so the
# whole pipeline runs zero-interaction. Dev artifacts must never be shipped.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=vortex-builder:bookworm

# ---- stage 1: host side — build the builder image, re-exec inside ----------
if [ ! -f /.dockerenv ] && [ -z "${VORTEX_IN_BUILDER:-}" ]; then
    echo "==> building builder image ($IMAGE)"
    docker build -t "$IMAGE" "$ROOT/packages/builder"
    echo "==> entering builder container"
    exec docker run --rm -e VORTEX_IN_BUILDER=1 \
        -v "$ROOT":/work -w /work "$IMAGE" bash packages/build-all.sh
fi

# ---- stage 2: container side ------------------------------------------------
# Bind mounts (especially Docker Desktop on Windows) are brutally slow for
# npm/dh walking thousands of files. Copy the source onto container-local
# disk, build there at native speed, and ship only the .debs back.
SRC=/work
BUILDROOT=/build
mkdir -p "$BUILDROOT"
tar -C "$SRC" \
    --exclude=./.git --exclude=./dist --exclude=./targets/pi/pi-gen \
    --exclude=./packages/vortex-openclaw/staging \
    --exclude=./repo/.aptly --exclude=./repo/public \
    -cf - . | tar -C "$BUILDROOT" -xf -
cd "$BUILDROOT"
VERSION=$(cat VERSION)
# Published apt repos are immutable per version: rebuilding identical version
# numbers with different bytes breaks publishing (and users' trust). Dev
# iterations get a +dev timestamp suffix that sorts ABOVE the base version;
# CI release builds set VORTEX_RELEASE=1 to use the bare VERSION.
if [ "${VORTEX_RELEASE:-0}" != 1 ]; then
    VERSION="$VERSION+dev$(date -u +%Y%m%d%H%M%S)"
    echo "==> dev build: packaging as version $VERSION"
fi
. branding/identity.env

DIST=/work/dist/debs
mkdir -p "$DIST"
rm -f "$DIST"/*.deb 2>/dev/null || true

# --- signing key (public part only is needed at package build time) ---------
KEYRING=/work/repo/keys/vortex-archive-keyring.gpg
if [ ! -f "$KEYRING" ]; then
    echo "WARNING: no production keyring found — generating a DEV signing key."
    echo "         Run 'repo/publish.sh init' to create the real one."
    mkdir -p /work/repo/keys/dev
    if [ ! -f /work/repo/keys/dev/vortex-archive-keyring.gpg ]; then
        export GNUPGHOME=$(mktemp -d)
        gpg --batch --quiet --passphrase '' --quick-generate-key \
            "Vortex OS DEV (untrusted) <dev@vortex.invalid>" ed25519 sign never
        gpg --batch --export > /work/repo/keys/dev/vortex-archive-keyring.gpg
        gpg --batch --export-secret-keys --armor > /work/repo/keys/dev/secret.asc
    fi
    KEYRING=/work/repo/keys/dev/vortex-archive-keyring.gpg
fi
export VORTEX_KEYRING_PUB=$KEYRING

# --- helpers -----------------------------------------------------------------
gen_changelog() { # $1 = source package dir, $2 = source name
    cat > "$1/debian/changelog" <<EOF
$2 ($VERSION) $VORTEX_BASE_SUITE; urgency=medium

  * Vortex OS release $VERSION.

 -- Vortex OS <khemchanseenanan@gmail.com>  $(date -R)
EOF
}

build_pkg() { # $1 = package dir name, $2... = arch list ("all" means one neutral build)
    local pkg=$1; shift
    local dir=$BUILDROOT/packages/$pkg
    echo "=============================================================="
    echo "==> $pkg ($*)"
    gen_changelog "$dir" "$pkg"
    # debian/copyright is shared boilerplate; sync it from the keyring package
    [ -f "$dir/debian/copyright" ] || cp "$BUILDROOT/packages/vortex-archive-keyring/debian/copyright" "$dir/debian/copyright"
    chmod +x "$dir/debian/rules"
    for arch in "$@"; do
        ( cd "$dir"
          # -d: toolchains (Go tarball, NodeSource node) come from the builder
          # image, not debs, so dpkg-checkbuilddeps can't see them.
          if [ "$arch" = all ] || [ "$arch" = "$(dpkg --print-architecture)" ]; then
              dpkg-buildpackage -us -uc -b -d
          else
              # pure Go / npm payloads: no C cross toolchain needed
              dpkg-buildpackage -us -uc -b -a "$arch" -d
          fi )
    done
    mv "$BUILDROOT"/packages/*.deb "$DIST"/ 2>/dev/null || true
    rm -f "$BUILDROOT"/packages/*.buildinfo "$BUILDROOT"/packages/*.changes
}

build_pkg vortex-archive-keyring all
build_pkg vortex-core            all   # also produces vortex-core-sdcard
build_pkg vortex-firstboot       all
build_pkg vortex-webui           amd64 arm64
build_pkg vortex-openclaw        amd64 arm64

echo "==> lintian"
lintian --suppress-tags-from-file "$BUILDROOT/packages/lintian-overrides.txt" \
    "$DIST"/*.deb || echo "WARNING: lintian findings above (non-fatal)"

echo "==> built packages:"
ls -la "$DIST"
