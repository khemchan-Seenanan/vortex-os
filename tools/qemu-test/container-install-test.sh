#!/bin/bash
# Fast dev-loop verification (the Phase-1 acceptance gate): in a pristine
# debian:bookworm container with ONLY Debian + the Vortex repo configured,
# `apt install vortex-*` must succeed and produce a branded, tuned system.
# Run via: docker run --rm -v <repo>:/work debian:bookworm bash /work/tools/qemu-test/container-install-test.sh
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
PASS=0
ok() { echo "  ok: $*"; PASS=$((PASS+1)); }

echo "=== configuring apt (Debian + Vortex only)"
KEY=/work/repo/keys/vortex-archive-keyring.gpg
[ -f "$KEY" ] || KEY=/work/repo/keys/dev/vortex-archive-keyring.gpg
install -D -m0644 "$KEY" /usr/share/keyrings/vortex-archive-keyring.gpg
cat > /etc/apt/sources.list.d/vortex.sources <<'EOF'
Types: deb
URIs: file:/work/repo/public
Suites: bookworm
Components: main
Signed-By: /usr/share/keyrings/vortex-archive-keyring.gpg
EOF
apt-get update -qq

echo "=== installing the full Vortex stack"
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    vortex-core vortex-webui vortex-openclaw vortex-firstboot 2>&1 | tail -n 60

echo "=== asserting"
grep -q '^ID=vortex' /etc/os-release            || fail "os-release ID"
grep -q 'Vortex OS 1.0 (Cyclone)' /etc/os-release || fail "os-release PRETTY_NAME"
grep -q '^VERSION_CODENAME=bookworm' /etc/os-release || fail "codename kept"
ok "branding (os-release rewritten, codename kept)"

[ -f /etc/vortex-release ] || fail "vortex-release missing"
ok "vortex-release present"

/usr/sbin/vortex-tune --show >/dev/null          || fail "vortex-tune --show"
[ -f /etc/default/zramswap ]                     || fail "zramswap config not generated"
grep -q 'ALGO=zstd' /etc/default/zramswap        || fail "zram algo"
[ -f /etc/sysctl.d/99-vortex-memory.conf ]       || fail "sysctl drop-in not generated"
[ -f /etc/systemd/system/vortex.slice.d/50-tuned.conf ] || fail "slice drop-in not generated"
grep -q 'max-old-space-size' /etc/vortex/openclaw.env   || fail "node heap env"
grep -q 'OPENCLAW_GATEWAY_PORT=18789' /etc/vortex/openclaw.env || fail "gateway port env"
ok "vortex-tune generated zram/sysctl/slice/env"

printf '# vortex-tune: manual\nALGO=lz4\n' > /etc/default/zramswap
/usr/sbin/vortex-tune >/dev/null
grep -q 'ALGO=lz4' /etc/default/zramswap         || fail "manual sentinel not honored"
ok "manual-edit sentinel honored"

# Files WITHOUT the sentinel must keep re-tuning (RAM can change in VMs); the
# generated header mentions the sentinel string and must not self-trigger.
VORTEX_TUNE_MEM_KB=$((1024*1024))  /usr/sbin/vortex-tune >/dev/null
grep -q 'vm.swappiness = 180' /etc/sysctl.d/99-vortex-memory.conf || fail "1GB retune did not apply"
VORTEX_TUNE_MEM_KB=$((16384*1024)) /usr/sbin/vortex-tune >/dev/null
grep -q 'vm.swappiness = 100' /etc/sysctl.d/99-vortex-memory.conf || fail "16GB retune did not apply (sentinel false-positive?)"
grep -q 'ALGO=lz4' /etc/default/zramswap || fail "sentinel file was clobbered by retune"
ok "re-tunes on RAM change; sentinel files still untouched"

[ -x /opt/openclaw/node_modules/.bin/openclaw ]  || fail "openclaw entrypoint"
v=$(node /opt/openclaw/node_modules/openclaw/openclaw.mjs --version 2>/dev/null || true)
echo "$v" | grep -q '2026.6.6' || fail "openclaw --version said: $v"
ok "openclaw runs under system node ($v)"
node --version | grep -qE '^v2[2-9]' || fail "node major"
ok "nodejs $(node --version) from vendored NodeSource deb"

command -v caddy >/dev/null || fail "caddy not installed"
caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 || fail "Caddyfile invalid"
ok "caddy installed ($(caddy version | cut -d' ' -f1)), Caddyfile validates"

[ -x /usr/bin/vortex-stats ] || fail "stats daemon missing"
ok "vortex-stats binary installed"

[ -L /etc/systemd/system/multi-user.target.wants/vortex-tune.service ] || fail "vortex-tune not enabled"
[ -L /etc/systemd/system/multi-user.target.wants/vortex-firstboot.service ] || fail "firstboot not enabled"
[ ! -e /etc/systemd/system/multi-user.target.wants/openclaw.service ] || fail "openclaw must ship disabled"
ok "units: tune+firstboot enabled, openclaw disabled until wizard"

getent passwd vortex >/dev/null || fail "vortex user"
[ -f /etc/ssh/sshd_config.d/40-vortex.conf ] || fail "ssh hardening"
[ -f /etc/fail2ban/jail.d/vortex.conf ] || fail "fail2ban jail"
ok "user + hardening files in place"

n=$(grep -rl '^Types: deb' /etc/apt/sources.list.d/ | wc -l)
src=$(ls /etc/apt/sources.list.d/)
echo "  sources present: $src"
[ -f /etc/apt/sources.list.d/vortex.sources ] || fail "online vortex.sources missing"
ok "online vortex source installed by keyring package"

echo
echo "ALL $PASS ASSERTIONS PASSED"
