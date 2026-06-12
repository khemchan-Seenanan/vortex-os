# Vortex apt repository

One signed apt repo feeds all three install targets and every already-installed
machine. `apt upgrade` on a Vortex box updates OpenClaw and all Vortex behavior.

## One-time setup

```sh
bash repo/publish.sh init
```

Creates the ed25519 signing key:

- `repo/keys/vortex-archive-keyring.gpg` — **public**, commit it; it is baked
  into the `vortex-archive-keyring` package.
- `repo/keys/vortex-archive-secret.asc` — **private**, gitignored. Back it up
  (password manager / offline). Add its contents to GitHub Actions as the
  `VORTEX_GPG_SECRET` secret. It must never appear in the repo or CI logs.

Until `init` is run, `packages/build-all.sh` generates a throwaway DEV key in
`repo/keys/dev/` so local builds work — never ship dev-signed artifacts.

## Publishing

```sh
bash repo/publish.sh add dist/debs/*.deb   # add/replace packages, re-sign, re-publish
bash repo/publish.sh mirror                # vendor caddy, nodejs 22, tailscale, log2ram
```

Output is the static tree `repo/public/`. Vortex machines consume it via
`/etc/apt/sources.list.d/vortex.sources` (deb822, pinned to the keyring),
installed by `vortex-archive-keyring`.

## Hosting

Any static web server works — it's just files:

- **Existing Caddy/nginx box**: copy `repo/public/` to e.g.
  `/srv/vortex-repo` and serve it at `VORTEX_REPO_URL` (see
  `branding/identity.env`). nginx: `location / { root /srv/vortex-repo; }`.
- **GitHub Pages**: push `repo/public/` to a `vortex-repo` repository with
  Pages enabled. Mind the limits: soft 1 GB repository size, 100 MB max file.
  The vendored `nodejs` deb (~30 MB) and `vortex-openclaw` fit today; if the
  pool outgrows Pages, move to any object store or VPS.

After changing `VORTEX_REPO_URL`, rebuild `vortex-archive-keyring` so the
sources file matches.

## Key rotation

Generate a new key with `init` (move the old files away first), publish with
both signatures during a transition window if needed, ship an updated
`vortex-archive-keyring`, then retire the old key.
