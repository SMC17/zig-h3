# Syndication architecture

> **Canonical origin: sunlitmoon.online** (homelab Forgejo).
> GitHub is a syndication mirror, not the source of truth.

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

The sovereign-stack posture: **own the origin, syndicate the rest.**

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
           │ stax-push-everywhere (multi-remote git push)
           ▼
┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐
│  github.com/SMC17   │  │  codeberg.org/SMC17 │  │  HuggingFace /SMC17  │
│  (read-mostly       │  │  (FOSS-friendly     │  │  (model/binary       │
│   syndication;      │  │   syndication;      │  │   distribution)      │
│   ★ farming, issue  │  │   secondary git     │  │                      │
│   funnel)           │  │   discovery)        │  │                      │
└─────────────────────┘  └─────────────────────┘  └─────────────────────┘
           │
           ▼
┌────────────────────────────────────────────────────────────────┐
│  DISCOVERY / TRAFFIC                                            │
│  - sunlitmoon.online       (own site — blog, case studies, lab) │
│  - LinkedIn (~5K connections)                                   │
│  - X / Twitter                                                  │
│  - GitHub stars + issues   (★ farming, not dependence)          │
│  - Email + RSS feed from sunlitmoon.online                      │
└────────────────────────────────────────────────────────────────┘
```

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

### Multi-remote push: `stax-push-everywhere`

The wrapper at `~/.local/bin/stax-push-everywhere` pushes the current
branch to every configured mirror in priority order:

```sh
$ stax-push-everywhere main
Pushing branch 'main' to: origin-sovereign origin-github

→ origin-sovereign  (http://stax:***@localhost:3000/stax/zig-h3.git)
   To http://localhost:3000/stax/zig-h3.git
      ab12c34..ef56789  main -> main

→ origin-github  (https://github.com/SMC17/zig-h3.git)
   To https://github.com/SMC17/zig-h3.git
      ab12c34..ef56789  main -> main

✓ pushed to all 2 mirrors
```

Remote naming convention across the portfolio:

| Remote name        | Role |
|--------------------|------|
| `origin-sovereign` | Local Forgejo (canonical) |
| `origin-github`    | github.com/SMC17/$repo (★-farming) |
| `origin-codeberg`  | codeberg.org/SMC17/$repo (FOSS discovery) |
| `origin-hf`        | huggingface.co/SMC17/$repo (binary dist) |

`origin` (no suffix) is treated as github for backwards compat but
should be renamed to `origin-github` over time.

### Why we still push to GitHub

Not because we depend on it. Because:

- **★-farming is real distribution.** A repo with 0 GitHub stars is
  invisible. The substrate work is good enough to earn stars; we
  collect them without ceding control.
- **Issue funnel.** GitHub's issue tracker is where most downstream
  consumers expect to file. We mirror issues back to the canonical
  origin (TODO: automation via Forgejo's issue-import API).
- **OSS discovery.** PyPI / crates.io / npm packages link back to a
  source-code URL. GitHub is the lowest-friction choice for that
  link today, even though the canonical origin remains
  sunlitmoon.online.

### Public link strategy

Every public-facing link should point to **sunlitmoon.online** by
default, with GitHub as the fallback. Once `git.sunlitmoon.online`
is live, the README banner becomes:

```markdown
**Canonical**: <https://git.sunlitmoon.online/stax/zig-h3>
**Syndicated**: [GitHub](https://github.com/SMC17/zig-h3) ·
[Codeberg](https://codeberg.org/SMC17/zig-h3) ·
[HuggingFace](https://huggingface.co/SMC17/zig-h3)
```

LinkedIn posts + X posts link to sunlitmoon.online. Blog posts on
sunlitmoon.online link to the project README at the canonical
origin. GitHub is where the ★ comes from; the work and the audience
flow through sunlitmoon.online.

## What this is not

- **Not abandoning GitHub.** The mirror stays. The ★-farming + issue
  funnel + PyPI/crates.io backlink need GitHub for now.
- **Not "screw MS."** It's risk diversification. Microsoft's
  GitHub policy can change overnight; sunlitmoon.online's policy
  is set by stax.
- **Not a self-hosted-purity stance.** The five paid surfaces from
  `MONETIZATION.md` (per-call API, enterprise support, GIS Pro,
  managed DB integrations, on-chain oracle) all flow through the
  canonical origin's release pipeline, but customer contact happens
  via whatever channel works (LinkedIn for enterprise, X for
  developer mindshare, sunlitmoon.online forms for direct).

## Migration sequence

The transition from "GitHub primary" to "sunlitmoon.online primary":

| Phase | What |
|-------|------|
| 0 (done 2026-05-19) | Local Forgejo running on localhost:3000; 5 OSS repos mirrored; `stax-push-everywhere` wrapper ships |
| 1 (operator-led) | Deploy Forgejo to edge VPS at `git.sunlitmoon.online`; Caddy reverse-proxy + Let's Encrypt |
| 2 (operator-led) | Codeberg mirrors created; `stax-push-everywhere` adds `origin-codeberg` |
| 3 (operator-led) | All README banners updated to canonical-first |
| 4 (operator-led) | LinkedIn / X cross-posts cite sunlitmoon.online URLs |

Phase 0 is engineering-complete on this workstation. Phases 1-4 are
operator-led infrastructure + content decisions.

## Where this lives in operator memory

- `reference_domain_sunlitmoon.md` — owned domain, canonical-origin role
- `project_sovereign_edge_cloudflare_decisions.md` — Phase 0 = VPS + Caddy + CF
- `feedback_no_cloud_rental_for_sovereign_deploy.md` — no AWS/GCP for substrate
- `project_sovereign_stack_launch.md` — 3 polished OSS repos + master index
- `feedback_engineering_bar_before_distribution.md` — substrate quality before amplification

This document is the engineering scaffold that lets the memory's
plan become live infrastructure with a single deploy.
