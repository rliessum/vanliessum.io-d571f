# VPS self-host (`vanliessum.io`)

Static Astro site in Docker. Host nginx terminates TLS and adds CSP/HSTS. The
container listens on loopback `:8798` and does **not** send those headers.
Build stage is `node:22-alpine` (`npm run build`, Astro static output). No webhook — the 45s timer polls `origin/main`.

| File | Role |
|---|---|
| `update.sh` | Root updater: flock, `ls-remote`, `runuser` git, compose build/up, health, rollback |
| `vanliessum-update.service` | oneshot (`TimeoutStartSec=15min`) |
| `vanliessum-update.timer` | `OnBootSec=60s`, then `OnUnitInactiveSec=45s` |
| `vanliessum-upstream.conf` | `vanliessum_app` → `127.0.0.1:8798` |
| `nginx-vanliessum.vhost.example` | Public vhost + Let's Encrypt paths |

Checkout: `/opt/vanliessum`. Image: `vanliessum:latest`. State:
`/var/lib/vanliessum-update/{deployed,previous}-sha`.

`/etc/nginx/snippets/vanliessum-headers.conf` does **not** exist yet. Create it
(copy `flashcards-headers.conf`, adjust CSP) before the cutover. Do not edit the flashcards snippet.

## What the updater does

1. Takes `/run/vanliessum-update.lock` (`flock -n`). A second start exits 0
   (`phase=skip reason=lock-held`).
2. `git ls-remote origin refs/heads/main` vs `git rev-parse HEAD` in
   `/opt/vanliessum`. Git runs as the checkout owner via `runuser -u`
   (`FLASHCARDS_GIT_USER` or `stat -c '%U' /opt/vanliessum`).
3. If the SHAs match: `phase=skip reason=unchanged`. No fetch, no build.
4. If they differ: `git fetch` + `git reset --hard` as that owner. Tag
   `vanliessum:latest` → `vanliessum:previous`. `GIT_SHA=<full sha>`
   `docker compose build` (300s) then `up -d` (120s).
5. Poll `http://127.0.0.1:8798/version.json` for up to 90s until `webSha`
   is the short SHA. On failure: reset git back, retag `:previous` →
   `:latest` (or rebuild that sha if `:previous` is missing), `up -d`,
   re-check.

Journal lines look like `vanliessum-update sha=abc1234 phase=skip reason=unchanged`.

## Install

Run as root from SSH. Clone with the **existing SSH alias** on the
checkout owner (deploy key + `known_hosts`). Do not use HTTPS.

```bash
hostname -f
GIT_USER=$(stat -c '%U' /opt/vanliessum 2>/dev/null || echo rliessum)
test -d /opt/vanliessum/.git || \
  runuser -u "$GIT_USER" -- git clone git@github-vanliessum:rliessum/vanliessum.io-d571f.git /opt/vanliessum

chmod 0755 /opt/vanliessum/deploy/update.sh

# First image. sudo -E drops GIT_SHA — pass it on the sudo command line.
S=$(runuser -u "$GIT_USER" -- git -C /opt/vanliessum rev-parse HEAD)
cd /opt/vanliessum
sudo GIT_SHA=$S docker compose build
sudo GIT_SHA=$S docker compose up -d
curl -fsS http://127.0.0.1:8798/version.json

install -d -m 0755 /var/lib/vanliessum-update
install -o root -g root -m 0644 /opt/vanliessum/deploy/vanliessum-update.service \
  /etc/systemd/system/vanliessum-update.service
install -o root -g root -m 0644 /opt/vanliessum/deploy/vanliessum-update.timer \
  /etc/systemd/system/vanliessum-update.timer

# Git as the checkout owner must work (deploy key + known_hosts)
runuser -u "$GIT_USER" -- git -C /opt/vanliessum ls-remote origin refs/heads/main

systemctl daemon-reload
# Do not enable the timer yet — wait until this PR is merged and main
# is checked out (see below).
```

## Enable the timer (after merge)

Only after this PR is on `origin/main` and `/opt/vanliessum` is that
commit:

```bash
GIT_USER=$(stat -c '%U' /opt/vanliessum)
runuser -u "$GIT_USER" -- git -C /opt/vanliessum fetch origin main
runuser -u "$GIT_USER" -- git -C /opt/vanliessum checkout main
runuser -u "$GIT_USER" -- git -C /opt/vanliessum reset --hard origin/main

systemctl enable --now vanliessum-update.timer
systemctl start vanliessum-update.service
journalctl -u vanliessum-update.service -n 40 --no-pager
```

Expect `phase=skip reason=unchanged` if `HEAD` already matches `origin/main`.

## Cutover

Host nginx keeps TLS and security headers. The container serves `/` and
HTML / SPA / `version.json` (`max-age=0, must-revalidate`), `/sw.js`
(`max-age=0`), `/manifest.json` and `/data/*` (`max-age=3600`),
`/icons/*` (`max-age=604800`), `/assets/*` (immutable), and gzip.

Leave `/etc/nginx/snippets/vanliessum-headers.conf` as-is.

```bash
install -o root -g root -m 0644 /opt/vanliessum/deploy/vanliessum-upstream.conf \
  /etc/nginx/vanliessum-upstream.conf
# Review, then:
# install -o root -g root -m 0644 /opt/vanliessum/deploy/nginx-vanliessum.vhost.example \
#   /etc/nginx/sites-available/vanliessum.io
nginx -t && systemctl reload nginx
curl -fsSI https://vanliessum.io/ | grep -Ei 'strict-transport|content-security|cache-control'
```

Leave the previous vhost in a backup until HTTPS and `/version.json` look right.

## Rollback

Automatic: a failed health check resets the checkout, retags
`vanliessum:previous` → `vanliessum:latest` (or rebuilds that sha if
`:previous` is missing), and `compose up -d`.

Manual (container only; vhost unchanged):

```bash
docker tag vanliessum:previous vanliessum:latest
cd /opt/vanliessum && docker compose up -d
curl -fsS http://127.0.0.1:8798/version.json
```

Manual (vhost cutover): restore the previous site file, `nginx -t`, reload.

Timer off:

```bash
systemctl disable --now vanliessum-update.timer
```
