#!/bin/bash
# qcow2 → .ova (vmdk + OVF descriptor, tarred). Import tested with VirtualBox:
# File → Import Appliance. Defaults: 2 vCPU, 4 GB RAM, virtio NIC/disk.
set -euo pipefail

QCOW=${1:?usage: make-ova.sh <image.qcow2> <out.ova>}
OVA=${2:?usage: make-ova.sh <image.qcow2> <out.ova>}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

NAME=$(basename "$OVA" .ova)

docker run --rm -v "$(dirname "$QCOW")":/in -v "$WORK":/out debian:bookworm-slim bash -c "
    apt-get update -qq && apt-get install -y -qq qemu-utils >/dev/null &&
    qemu-img convert -O vmdk -o subformat=streamOptimized /in/$(basename "$QCOW") /out/${NAME}-disk1.vmdk"

DISK_SIZE=$(stat -c %s "$WORK/${NAME}-disk1.vmdk" 2>/dev/null || stat -f %z "$WORK/${NAME}-disk1.vmdk")
sed -e "s|@NAME@|${NAME}|g" -e "s|@DISK_FILE@|${NAME}-disk1.vmdk|g" -e "s|@DISK_SIZE@|${DISK_SIZE}|g" \
    "$HERE/template.ovf" > "$WORK/${NAME}.ovf"

# OVA = tar with the .ovf FIRST.
tar -C "$WORK" -cf "$OVA" "${NAME}.ovf" "${NAME}-disk1.vmdk"
( cd "$(dirname "$OVA")" && sha256sum "$(basename "$OVA")" >> SHA256SUMS )
echo "==> $OVA"
