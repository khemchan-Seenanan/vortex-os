# Vortex OS

A minimal, console-only Linux distribution for hosting AI agents (OpenClaw),
with an aggressive self-tuning memory stack and a modern web management UI.
Built on Debian 12 (bookworm); the Vortex identity lives in **Debian packages**,
so `apt upgrade` updates everything, on every machine, forever.

| Target | Artifact | Install |
|---|---|---|
| Raspberry Pi 4/5 (arm64) | `vortex-pi-<ver>-arm64.img.xz` | Flash with Raspberry Pi Imager, boot |
| Any PC / laptop (amd64) | `vortex-<ver>-amd64.iso` | Boot from USB, automated console installer |
| VMs / cloud (amd64) | `vortex-<ver>-amd64.qcow2` / `.ova` | Import into Proxmox / VirtualBox / QEMU |

## Quickstart — Raspberry Pi

1. Flash `vortex-pi-<ver>-arm64.img.xz` with Raspberry Pi Imager (you may
   pre-set a password/SSH key in Imager; otherwise the default login is
   `vortex` / `vortex` until the wizard runs).
2. Boot. The console shows the setup URL and a one-time code.
3. Open `https://vortex.local/setup` (or `https://<ip>/setup`), enter the code,
   set your password, paste an SSH key and your AI provider API key.
4. Done — OpenClaw is running at `https://vortex.local/claw/`.

## Quickstart — PC (ISO)

1. Write `vortex-<ver>-amd64.iso` to a USB stick (Rufus, `dd`, Ventoy).
   Boots both UEFI and legacy BIOS.
2. Choose **Install**. The installer asks exactly two things: a password for
   the `vortex` user and the disk-wipe confirmation. Installation is fully
   offline — all packages are on the stick.
3. Reboot into the installed system; finish at `https://<ip>/setup` as above.
   Manual partitioning: press <kbd>Tab</kbd>/<kbd>e</kbd> on the install entry
   and remove `auto=true priority=critical` from the kernel line.

## Quickstart — VM

- **Proxmox/QEMU**: import `vortex-<ver>-amd64.qcow2`. Serial console is
  enabled (`ttyS0`). cloud-init is active (NoCloud, ConfigDrive, EC2, GCE) —
  if your platform supplies SSH keys/user-data, the wizard skips those steps.
- **VirtualBox**: File → Import Appliance → `vortex-<ver>-amd64.ova`
  (2 vCPU / 4 GB defaults).

## First boot, in detail

On first boot the machine generates SSH host keys, grows the root filesystem,
prints the setup URL + one-time code on the console, and serves the wizard at
`/setup`. The wizard (or `sudo vortex-setup` on the console) collects:
password, SSH public key, AI provider API keys, timezone, optional Tailscale
auth key. On submit it enables `openclaw.service` and the firewall, then
disables itself. SSH becomes **key-only** the moment a key is enrolled.

Everything web flows through Caddy on **443** (self-signed certificate —
your browser will warn once; the internal services only listen on localhost):

- `/` — landing page with live stats
- `/system/` — Cockpit (full admin console; log in as `vortex`)
- `/claw/` — OpenClaw gateway
- `/setup/` — first-boot wizard (auto-disabled after init)

## Updates

```sh
sudo apt update && sudo apt upgrade
```

That's the whole story: machines have exactly two apt sources (Debian +
Vortex). New OpenClaw versions ship as a new `vortex-openclaw` package.

## Building from source

Host needs **Docker only** (and qemu-system + OVMF for `make test`).

```sh
make packages   # all .debs (arm64+amd64) via the Docker builder
make repo       # publish into the signed apt tree (repo/public/)
make pi         # Raspberry Pi image (pi-gen, needs binfmt/qemu for arm64)
make iso        # PC installer ISO (live-build)
make vm         # qcow2 + ova (debos)
make all        # everything
make test       # qemu boot tests against dist/ artifacts (Linux/WSL2)
```

One-time before real releases: `bash repo/publish.sh init` (creates the GPG
signing key — see [repo/README.md](repo/README.md)). Without it, builds use a
throwaway dev key. Third-party debs (caddy, nodejs 22, tailscale, log2ram) are
vendored into the Vortex repo with `bash repo/publish.sh mirror`.

## Troubleshooting

- **OpenClaw got killed / restarted** — that's the memory cage working.
  `journalctl -u systemd-oomd` shows pressure kills; `systemctl status
  openclaw` shows the auto-restart. The slice limits come from
  `vortex-tune --show`.
- **OpenClaw logs** — `journalctl -u openclaw -f`.
- **Browser certificate warning** — expected (self-signed, `tls internal`).
  Trust it once, or put the box behind Tailscale and use its certs.
- **vortex.local doesn't resolve** — your client needs mDNS (Windows: enabled
  by default on 10+; Linux: `systemd-resolved` with `MulticastDNS=yes`).
  Use the IP shown on the console instead.
- **Wizard code lost** — it's reprinted on every boot until setup completes,
  or run `sudo vortex-setup` on the console.
- **Tailscale** — paste an auth key in the wizard, or later:
  `sudo apt install tailscale && sudo tailscale up`.

## Pi hardware checklist (manual, per release)

CI verifies the Pi image at chroot level only. Before a release, on real
hardware: boot Pi 4 and Pi 5 → wizard completes → `swapon --show` lists zram0
→ `systemctl status openclaw` active → `https://vortex.local` reachable →
idle RAM (pre-OpenClaw) ≤ 150 MB → `vortex-tune --show` matches the board's
RAM tier → reboot survives cleanly.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) — package-first design, the
vortex-tune sizing table, security model, and diagrams.
