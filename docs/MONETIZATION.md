# Monetization strategy

How the zig-h3 substrate converts to revenue. Written ruthlessly,
following the operator's toll-model doctrine (per-unit / bps /
perf-fee, never hourly) and the "no parlor tricks" discipline.

The frame: **zig-h3 is the bottleneck-owner substrate** for spatial
indexing across every deployment surface (5 language bindings + 3 DB
extensions + wasm-on-chain + EVM oracle pattern). Every downstream
geo tool that routes through it pays a toll proportional to value
flow, not to clock time.

## What the substrate is worth (TAM context)

H3-the-protocol drives ~$X/year of dispatch decisions at Uber alone.
The downstream H3 ecosystem (Carto, Foursquare, Slack, DoorDash, Lyft,
every ride-hail, every mapping company that touched hexes since 2018)
is in the low-tens-of-billions-of-dollars range of geo-tool revenue.

zig-h3 doesn't have to win that whole pie. It has to win the
specific cases where the toll model applies and h3-py/h3-go can't
serve:

- **Per-call API** — workloads above ~1M H3 calls/day where calling
  h3-py from Python at ~100ns/call burns more CPU than the value of
  the answer. Our 8-thread parallel API at 558ns/op-amortized is
  3.6-6× faster per dollar of compute.
- **GIS-tool integrations** — desktop / DB / cloud integrations where
  the C-ABI shim halves the integration cost vs writing a per-tool
  binding.
- **On-chain oracles** — smart contracts that need H3 results pay
  gas (a real toll); our wasm + EVM oracle pattern is the only
  production-ready path.
- **Supply-chain provenance** — auditors who need Bitcoin-anchored
  release attestation pay for the verification infrastructure.

## Five concrete toll plays

### 1. Managed H3 API service ($per million cells)

Host the `libzig_h3.so` batch+parallel API behind a thin HTTP/gRPC
gateway. Customers send batch lat/lng arrays, get cell arrays back.
Pricing: $0.01 per 1M cell-encodings on the standard tier; $0.005
on enterprise volume.

Substrate cost: ~$0.002 per 1M on a $40/month VPS (measured via
BENCH.md numbers: 1M ops/sec parallel × 86400s × 30 days = 2.6
trillion ops/month per single 4-core node). Margin: ~80% at the
volume the toll model targets.

Competitive moat: h3-py + h3-go are free libraries but require the
customer to host their own compute. We're 3.6-6× faster per dollar
of compute on the parallel path; the customer pays us so they don't
have to think about hosting or scaling.

Engineering: ship the gateway in 1-2 weeks (the substrate is done).
Pricing model lives in code at `pricing/per_million.toml`. Stripe
handles the billing.

### 2. Enterprise support contract ($25K/yr base)

Companies that build on zig-h3 in production sign a support contract:
- 24-hour response SLA on correctness bugs
- Custom function development (per-quote toll, not hourly)
- Pre-1.0 → 1.0 migration assistance
- Access to private channels for design discussion

Base contract is $25K/year for the first 3 named consumers per
company. Per-named-user scaling matches the Datadog / New Relic
shape. Add-ons: custom binding for a non-shipped language ($15K
project fee), GIS plugin development ($30K), DB extension custom
SQL functions ($20K).

Why this works: the substrate's "Type-1 self-catch policy" plus
the BAKEOFF audit register is exactly what an enterprise procurement
team buys before they trust open source for production geo. They're
not paying for code; they're paying for the audit trail + the on-call.

### 3. Premium GIS desktop integrations

QGIS plugin Community edition: free, uses the standard
batch-not-parallel API. QGIS plugin Pro edition: paid ($199/seat/yr),
unlocks:
- The 8-thread parallel batch API.
- The BEYOND-libh3 functions (cellsKNearest, cellsInBbox).
- Direct DuckDB-via-extension integration for 100M+ row datasets.

Same shape for ArcGIS, kepler.gl, deck.gl. Each plugin is ~2-week
engineering.

### 4. Managed Postgres / Snowflake / BigQuery integrations

Free Postgres + SQLite + DuckDB extensions (already shipped).

Paid: a hosted Postgres-RDS / Snowflake / BigQuery integration where
we manage the deployment, upgrade path, and SBOM provenance.
Pricing: $1500/month per managed database, scales linearly to
$15K/month for enterprise scale (10+ DBs + custom UDFs).

Engineering: ship one cloud-managed integration first (probably
Postgres on AWS RDS via parameter groups). Each subsequent one is
template work.

### 5. On-chain oracle network

Operators run nodes that serve H3 queries to smart contracts. The
node operator stakes tokens (proof-of-stake gating); smart contracts
pay per-query gas in the chain's native token.

The "layer-zero" framing the operator named: a single oracle network
deployed via the [SMC17/zig-h3 wasm] artifact on:
- CosmWasm (Cosmos SDK chains)
- NEAR Protocol
- Polkadot parachains
- LayerZero protocol (cross-chain messaging) for ferrying results
  between chains

Revenue split: 60% to node operators, 20% to a treasury that funds
zig-h3 maintenance, 20% to stax as the substrate maintainer (toll on
value flow). All flows on-chain, auditable.

Engineering: 4-6 weeks. The wasm artifact exists; the node binary
+ staking contract + treasury contract are net-new. Validator
acquisition is the gating constraint, not code.

## Why this beats the alternatives

Uber's h3-* libraries are free. We can't sell what they give away.

What we sell is the **substrate position** — the C-ABI shim that's
the bottleneck for downstream tools. The merchant lens:

| Whose tool depends on zig-h3 | Toll path |
|------------------------------|-----------|
| Python data scientist | Per-call API (paid above 1M/day) |
| Postgres-shop SaaS | Managed DB integration ($1.5K-15K/month) |
| Cosmos DeFi protocol | On-chain oracle (~bps of value flow) |
| QGIS desktop user | Pro license ($199/seat/yr) |
| Supply-chain auditor | Provenance verification service |

Each toll is per-unit-of-value-flow, not per-hour. Engineering work
is the substrate; selling work is the toll-collection infrastructure.

## What this is not

- **Not a token launch.** No TGE, no airdrop, no presale. The on-chain
  oracle network uses an existing chain's native token (or a stable
  USDC-equivalent) for fees; we never issue our own token.
- **Not a SaaS lock-in.** Every paid surface has a free open-source
  counterpart (the AGPL substrate, the unmanaged DB extensions, the
  Community QGIS plugin). Customers pay for managed services, not
  to escape the OSS.
- **Not retainer billing.** Every commercial contract is per-unit or
  per-value-flow. Hourly rates are explicitly rejected — they cap
  the upside.
- **Not a moonshot.** Realistic Y1 revenue at 10% conversion of the
  identified TAM is ~$500K-$2M. Realistic Y3 with the oracle network
  + 3 cloud-managed integrations is ~$5-15M ARR.

## Operator decision points

This document is a **plan** — none of the paid surfaces are billing
yet. To execute:

1. **Per-call API** — needs a hosting decision (PG ext is in place; the
   HTTP gateway is 1-2 weeks). Operator decides which cloud
   substrate (DigitalOcean / Hetzner / OVH per sovereign-edge
   doctrine, not AWS/GCP).
2. **Enterprise support** — needs a sales motion. Operator decides
   whether to pursue this directly or via a Red Hat-style
   integrator partnership.
3. **GIS Pro editions** — needs the operator's call on Community/Pro
   feature split. Default proposed: parallel API + BEYOND-libh3
   convenience fns are Pro-only.
4. **Managed DB integrations** — needs a first reference customer.
   Probably best to pilot with one of the family-network door-opens
   (per operator memory) before commercial pricing.
5. **On-chain oracle network** — biggest commit (4-6 weeks
   engineering + validator acquisition). Operator-only decision.

## Filed substrate, ready to monetize

The engineering substrate (BAKEOFF 10/2/1, 9 downstream consumers,
quad-provenance releases) is done. Every paid surface above maps
1:1 to existing engineering artifacts. The unblocking work is
operator-led: hosting choice, sales motion, customer acquisition.
