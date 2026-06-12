#!/bin/sh
# debos chroot script: kernel + cloud-init + Vortex packages from the bundled
# signed repo (no network needed beyond the Debian mirror for the base).
set -e

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    linux-image-amd64 grub-pc systemd-sysv \
    cloud-init cloud-guest-utils \
    vortex-archive-keyring vortex-core vortex-webui vortex-openclaw vortex-firstboot \
    sudo

# cloud-init: broad datasource net; firstboot detects cloud-init and defers
# the overlapping steps (fs growth, ssh keys from user-data).
cat > /etc/cloud/cloud.cfg.d/90-vortex.cfg <<'EOF'
datasource_list: [ NoCloud, ConfigDrive, Ec2, GCE, None ]
system_info:
  default_user:
    name: vortex
    lock_passwd: false
    groups: [ sudo ]
    shell: /bin/bash
preserve_hostname: false
EOF
