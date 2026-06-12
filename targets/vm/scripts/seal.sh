#!/bin/sh
# debos chroot script: final image seal — slim, dedupe identity, drop build repo.
set -e

/usr/sbin/vortex-slim

rm -f /etc/apt/sources.list.d/vortex-local.sources
rm -rf /opt/vortex-repo
apt-get clean

# Unique per-instance identity is created on first boot.
rm -f /etc/ssh/ssh_host_*
truncate -s0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
