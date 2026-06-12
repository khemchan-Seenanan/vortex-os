#!/bin/bash
# Vortex OS apt repository management (aptly). Runs inside the builder image.
#
#   repo/publish.sh init            one-time: create the GPG signing key + repo
#   repo/publish.sh add <debs...>   add packages and re-publish the static tree
#   repo/publish.sh mirror          pull pinned third-party debs (caddy, nodejs,
#                                   tailscale, log2ram) into the Vortex repo
#
# Output: repo/public/ — a static tree servable by any web server.
# The GPG PRIVATE key lives only in repo/keys/*secret* (gitignored) or in CI
# secrets (VORTEX_GPG_SECRET, armored). It must never be committed or logged.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=vortex-builder:bookworm

if [ ! -f /.dockerenv ] && [ -z "${VORTEX_IN_BUILDER:-}" ]; then
    docker image inspect "$IMAGE" >/dev/null 2>&1 || docker build -t "$IMAGE" "$ROOT/packages/builder"
    exec docker run --rm -e VORTEX_IN_BUILDER=1 \
        ${VORTEX_GPG_SECRET:+-e VORTEX_GPG_SECRET} \
        -v "$ROOT":/work -w /work "$IMAGE" bash repo/publish.sh "$@"
fi

cd /work
. branding/identity.env
APTLY="aptly -config=repo/aptly.conf"
KEYDIR=/work/repo/keys
PUB=$KEYDIR/vortex-archive-keyring.gpg
SECRET=$KEYDIR/vortex-archive-secret.asc
export GNUPGHOME=${GNUPGHOME:-/work/repo/.aptly/gnupg}
mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"

load_secret() {
    if [ -n "${VORTEX_GPG_SECRET:-}" ]; then            # CI: armored key in env
        printf '%s' "$VORTEX_GPG_SECRET" | gpg --batch --quiet --import
    elif [ -f "$SECRET" ]; then                          # local production key
        gpg --batch --quiet --import "$SECRET"
    elif [ -f "$KEYDIR/dev/secret.asc" ]; then           # dev fallback
        echo "WARNING: signing with the DEV key — not for release."
        gpg --batch --quiet --import "$KEYDIR/dev/secret.asc"
    else
        echo "ERROR: no signing key. Run 'repo/publish.sh init' first."; exit 1
    fi
}

ensure_repo() {
    $APTLY repo show vortex >/dev/null 2>&1 || \
        $APTLY repo create -distribution="$VORTEX_BASE_SUITE" -component=main vortex
}

republish() {
    local keyid
    keyid=$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^sec/{print $5; exit}')
    [ -n "$keyid" ] || { echo "ERROR: no secret key in keyring"; exit 1; }
    if $APTLY publish list -raw 2>/dev/null | grep -q "filesystem:public:. $VORTEX_BASE_SUITE"; then
        $APTLY publish update -batch -gpg-key="$keyid" "$VORTEX_BASE_SUITE" filesystem:public:
    else
        $APTLY publish repo -batch -gpg-key="$keyid" vortex filesystem:public:
    fi
    echo "==> published: repo/public/ (serve this directory at $VORTEX_REPO_URL)"
}

case "${1:-}" in
init)
    mkdir -p "$KEYDIR"
    if [ -f "$PUB" ]; then echo "Keyring already exists: $PUB"; exit 0; fi
    echo "==> generating the Vortex archive signing key (ed25519, no expiry)"
    gpg --batch --passphrase '' --quick-generate-key \
        "$VORTEX_NAME archive signing key <$(echo "$VORTEX_HOME_URL" | sed 's|https://||;s|/|.|g')@vortex>" \
        ed25519 sign never
    gpg --batch --export > "$PUB"
    gpg --batch --export-secret-keys --armor > "$SECRET"
    chmod 600 "$SECRET"
    ensure_repo
    echo "==> public key : $PUB (commit this)"
    echo "==> SECRET key : $SECRET (gitignored — back it up, add to CI as VORTEX_GPG_SECRET, never commit)"
    ;;
add)
    shift
    [ $# -gt 0 ] || { echo "usage: publish.sh add <debs...>"; exit 1; }
    load_secret; ensure_repo
    $APTLY repo add -force-replace vortex "$@"
    republish
    ;;
mirror)
    load_secret; ensure_repo
    # Third-party debs vendored into OUR repo so installed machines need
    # exactly two apt sources: Debian + Vortex. Versions pinned by mirror
    # filter; bump deliberately.
    declare -A MIRRORS=(
        [caddy]="https://dl.cloudsmith.io/public/caddy/stable/deb/debian|any-version|main|caddy"
        [nodesource]="https://deb.nodesource.com/node_22.x|nodistro|main|nodejs"
        [tailscale]="https://pkgs.tailscale.com/stable/debian|$VORTEX_BASE_SUITE|main|tailscale"
        [log2ram]="https://packages.azlux.fr/debian|$VORTEX_BASE_SUITE|main|log2ram"
    )
    declare -A KEYS=(
        [caddy]="https://dl.cloudsmith.io/public/caddy/stable/gpg.key"
        [nodesource]="https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key"
        [tailscale]="https://pkgs.tailscale.com/stable/debian/$VORTEX_BASE_SUITE.noarmor.gpg"
        [log2ram]="https://azlux.fr/repo.gpg.key"
    )
    for m in "${!MIRRORS[@]}"; do
        IFS='|' read -r url dist comp pkg <<< "${MIRRORS[$m]}"
        echo "==> mirroring $pkg from $url ($dist)"
        curl -fsSL "${KEYS[$m]}" | gpg --batch --quiet --import || true
        $APTLY mirror show "$m" >/dev/null 2>&1 || \
            $APTLY mirror create -keyring="$GNUPGHOME/pubring.kbx" \
                -filter="$pkg" -filter-with-deps=false "$m" "$url" "$dist" "$comp"
        $APTLY mirror update -keyring="$GNUPGHOME/pubring.kbx" "$m"
        $APTLY repo import "$m" vortex "$pkg"
    done
    republish
    ;;
*)
    echo "usage: repo/publish.sh {init|add <debs...>|mirror}"; exit 1 ;;
esac
