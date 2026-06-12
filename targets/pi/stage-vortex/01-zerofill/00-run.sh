#!/bin/bash -e
# Zero free space so xz compresses the deploy image much harder.
on_chroot <<'CHROOT'
dd if=/dev/zero of=/zero.fill bs=1M 2>/dev/null || true
sync
rm -f /zero.fill
CHROOT
