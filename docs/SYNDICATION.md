# Syndication architecture (updated 2026-05-19 — sovereign-only posture)

> **Canonical origin: sunlitmoon.online** (homelab Forgejo, fed by
> `localhost:3000` for now).
>
> **As of 2026-05-19** — beta-period posture: **GitHub is
> abandoned, not used.** All 138 SMC17 repos are PRIVATE; the mirrors
> are frozen archives, not live targets. We don't need GitHub to
> distribute — Zig itself doesn't use it (ziglang.org self-hosts its
> own Gitea), and we have the same option.
>
> Distribution during beta = **deeply targeted power-user campaigns**
> via sunlitmoon.online + LinkedIn + X + direct outreach. Not a
> public ★ funnel. The people we want to find this will be invited;
> the people we don't want will not stumble across it.
>
> **Future option** (post-beta, once we have real users and are
> shipping an alpha that wants public eyes): push the alpha branch
> back out to a public GitHub mirror for top-of-funnel ★-farming.
> Until then, GitHub gets nothing.
>
> Why: GitHub (Microsoft) can ban an account at any time. A canonical
> origin you don't control is a single point of failure. The merchant
> lens: own the bottleneck. Microsoft owns GitHub; we own
> sunlitmoon.online. Also: random forkers who ignore the license are
> a tax on attention, not an asset.

This document captures the operator's 2026-05-19 directive: zig-h3
(and the sovereign-stack portfolio) treats GitHub as one of N
distribution surfaces, not the master. The same posture applies to
every public OSS repo in the stack.

## Why

GitHub is owned by Microsoft. Hosting code there means:

- Source-of-truth dependency on a vendor we don't control.
- Discovery + engagement metrics filtered through GitHub's algorithm.
- License posture under MS's contributor-agreement assumptions.
- Op overhead (action quotas, secret-leaks, account auth, etc.).

The sovereign-stack posture (2026-05-19 update): **own the origin,
freeze the mirrors, distribute through surfaces you control.**

The earlier version of this doc said "syndicate the rest." That
implied routine writes to GitHub. We've stopped. GitHub mirrors are
now read-only archives — fed once at flip time and left dormant.

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│  CANONICAL ORIGIN — sunlitmoon.online (homelab Forgejo)        │
│  - Forgejo 15 LTS on ~/.local/share/forgejo                    │
│  - SQLite-backed; full backup = one .db file                   │
│  - Owns: refs, releases, issues, PRs, discussions               │
│  - Audit logs stay local (no third-party telemetry)             │
└────────────────────────────────────────────────────────────────┘
           │
           │ stax-push-everywhere (sovereign-only by default)
           ▼
┌────────────────────────────────────────────────────────────────┐
│  github.com/SMC17/*  (PRIVATE, FROZEN, READ-ONLY)              │
│  - Snapshot taken 2026-05-19                                    │
│  - No routine pushes; no public READMEs; no public issues       │
│  - Reanimated only if/when a project leaves beta and wants ★    │
└────────────────────────────────────────────────────────────────┘
           │
           ▼ (targeted distribution, not broadcast)
┌────────────────────────────────────────────────────────────────┐
│  POWER-USER CAMPAIGNS                                           │
│  - sunlitmoon.online       (own site — blog, case studies, lab) │
│  - LinkedIn (~5K connections; long-form + DMs to power users)   │
│  - X / Twitter             (short-form mindshare, invite-style) │
│  - Email + RSS from sunlitmoon.online (owned audience list)     │
│  - Direct outreach via sean@sunlitmoon.online                   │
└────────────────────────────────────────────────────────────────┘
```

**Precedent**: Zig itself doesn't live on GitHub —
[ziglang.org](https://ziglang.org) self-hosts its own Gitea-class
forge for source, issues, and PRs. The language we build on already
chose this posture. We're doing the same thing.

## Operational details

### Local Forgejo install

The workstation runs Forgejo 15.0.2 LTS via nix:

```sh
# Already installed at ~/.local/bin/forgejo (symlink to nix-store path).
# Config in ~/.local/share/forgejo/custom/conf/app.ini.
# Data in ~/.local/share/forgejo/data/repositories/.

# Start daemon
nohup forgejo web -c ~/.local/share/forgejo/custom/conf/app.ini \
    > /tmp/forgejo.log 2>&1 &

# Verify
curl -s http://localhost:3000/api/v1/version
# {"version":"15.0.2"}
```

Production deploy plan (when the operator pulls the trigger):

1. Move the Forgejo install to the homelab Hetzner CX22/CX32 node
   declared in `~/.config/nix-config/hosts/edge.nix`.
2. Caddy reverse-proxy with auto-HTTPS for `git.sunlitmoon.online`.
3. Backup the SQLite db + `data/repositories/` to two off-site
   locations (tailnet peer + S3-compatible if needed for off-tailnet
   resilience).
4. SSH access via `ssh git@git.sunlitmoon.online:stax/repo.git`.

### Sovereign-only push: `stax-push-everywhere`

The wrapper at `~/.local/bin/stax-push-everywhere` defaults to
**sovereign-only** as of 2026-05-19. GitHub push is opt-in:

```sh
$ stax-push-everywhere main
Pushing branch 'main' to sovereign origin only.

→ origin-sovereign  (http://stax:***@localhost:3000/stax/zig-h3.git)
   To http://localhost:3000/stax/zig-h3.git
      ab12c34..ef56789  main -> main

✓ pushed to canonical origin
  (GitHub mirror is frozen; pass --include-github to also push there)
```

Opt-in GitHub push for the rare case:

```sh
$ stax-push-everywhere --include-github main
```

Remote naming convention across the portfolio:

| Remote name        | Role |
|--------------------|------|
| `origin-sovereign` | Local Forgejo (canonical, only routine target) |
| `origin-github`    | github.com/SMC17/$repo (frozen private archive) |
| `origin-codeberg`  | codeberg.org/SMC17/$repo (reserved; not in use) |
| `origin-hf`        | huggingface.co/SMC17/$repo (reserved; not in use) |

`origin` (no suffix) on legacy repos points to github for historical
reasons. New repo setup uses `origin-sovereign` as the only routine
remote.

### Why we no longer routinely push to GitHub (operator directive 2026-05-19)

The earlier draft of this doctrine kept GitHub as a "★-farming +
issue funnel + PyPI backlink" target. The operator overrode that:

> "i hate github and there are too many ops and too much unwanted
> eyes... allows shitty devs to think they are good bc they forked
> and dont listen to liscneses... all github would ever have to do
> is ban me and im fucked"

So:

- **All 138 GitHub repos are PRIVATE** as of 2026-05-19. ★-counts
  are frozen at whatever they were when the flip happened.
- **No routine push to GitHub.** `stax-push-everywhere` defaults to
  sovereign-only. GitHub push is an explicit opt-in (`--include
  github`) for the rare case where a backup-of-a-backup is wanted.
- **No public READMEs.** Every repo's `README.md` is a 10-line stub
  pointing at sunlitmoon.online. Full content lives at
  `.canonical-readme.md` (accessible to collaborators with repo
  access) + at the canonical Forgejo origin.
- **No public issue tracker.** Issues / discussions / PRs are
  collaborator-only via Forgejo. Filing channels move to
  `sean@sunlitmoon.online` and (eventually) Forgejo's own UI.

### Public distribution surfaces (the only ones that matter)

- **sunlitmoon.online** — primary surface. Blog, case studies, lab
  demos, journal, contact form, project READMEs (rendered from the
  canonical Forgejo origin).
- **LinkedIn** — ~5K connections. Long-form announcements link to
  sunlitmoon.online.
- **X / Twitter** — short-form developer mindshare. Same.
- **Email + RSS** — sunlitmoon.online subscriber list owns the
  audience relationship directly.

Each surface is one we own (sunlitmoon.online), one with strong
account-portability via export (LinkedIn export is authorized per
operator memory), and one that's volatile-but-broad (X). No single
takedown can sever the distribution; the canonical origin keeps
working regardless.

## What this is and isn't

- **We are abandoning GitHub during beta.** No routine writes. No
  public READMEs. No public issues. The mirror is a frozen archive,
  reanimated only when a project leaves beta and explicitly wants
  public ★-funnel exposure.
- **This is not anti-OSS.** The license is still AGPL/MIT/Apache on
  the repos that have one. Anyone with the canonical Forgejo URL can
  read, clone, build, contribute. We're choosing who finds the URL.
- **This is targeted distribution, not stealth.** Power users we
  want to reach get DMs, invites, demo links to
  `git.sunlitmoon.online/stax/<repo>`. Random forkers don't.
- **Future option.** Post-beta, a project that wants a star-funnel
  can push its alpha branch to a public GitHub mirror as a marketing
  surface. That's a decision per-project, not a default.

## Migration sequence

The transition from "GitHub primary" to "sunlitmoon.online primary":

| Phase | What |
|-------|------|
| 0 (done 2026-05-19) | Local Forgejo on localhost:3000; OSS repos mirrored; `stax-push-everywhere` ships; all 138 GitHub repos privatized; public READMEs replaced with canonical-pointer stubs |
| 1 (next) | Deploy Forgejo to edge VPS at `git.sunlitmoon.online`; Caddy + Let's Encrypt |
| 2 (next) | `stax-push-everywhere` default flipped to sovereign-only with `--include-github` opt-in |
| 3 (operator-led) | Targeted power-user campaigns: LinkedIn DMs, X invites, sunlitmoon.online demo posts citing `git.sunlitmoon.online` URLs |
| 4 (operator-led, post-beta) | Per-project decision: reanimate a public GitHub mirror for ★-funnel on the alpha branch only |

Phase 0 is engineering-complete on this workstation.

## Where this lives in operator memory

- `reference_domain_sunlitmoon.md` — owned domain, canonical-origin role
- `project_sovereign_edge_cloudflare_decisions.md` — Phase 0 = VPS + Caddy + CF
- `feedback_no_cloud_rental_for_sovereign_deploy.md` — no AWS/GCP for substrate
- `project_sovereign_stack_launch.md` — 3 polished OSS repos + master index
- `feedback_engineering_bar_before_distribution.md` — substrate quality before amplification

This document is the engineering scaffold that lets the memory's
plan become live infrastructure with a single deploy.
