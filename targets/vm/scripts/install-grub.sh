#!/bin/sh
# debos chroot script (after filesystem-deploy): bootloader + serial console
# for Proxmox/cloud debugging.
set -e

cat > /etc/default/grub.d/vortex.cfg <<'EOF'
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0"
GRUB_TIMEOUT=2
EOF

rootdev=$(findmnt -n -o SOURCE / | sed 's/p\?[0-9]*$//')
grub-install --target=i386-pc "$rootdev"
update-grub
