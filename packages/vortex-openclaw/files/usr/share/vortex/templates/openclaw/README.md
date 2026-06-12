# OpenClaw config template (low-RAM defaults)

Rendered to `/home/vortex/.openclaw/openclaw.json` by the first-boot wizard.
Provider API keys are **not** stored here — the template references environment
variables (SecretRef `source: env`) that openclaw.service loads from
`/etc/vortex/openclaw-secrets.env` (root-owned, mode 0640, group vortex).

Low-RAM intent: single concurrent cron run, 24h session retention, info-level
logging. The Node heap cap itself comes from `NODE_OPTIONS` written by
vortex-tune, which is the real memory governor; the cgroup `vortex.slice`
MemoryMax is the hard backstop.

Keys here are limited to ones documented at https://docs.openclaw.ai —
re-verify against the docs when bumping the pinned OpenClaw version in
`packages/vortex-openclaw/app/package.json`.
