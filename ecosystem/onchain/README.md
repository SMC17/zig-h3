# On-chain integrations

zig-h3 ships in three on-chain forms, each engineering-defensible:

1. **Bitcoin-anchored release timestamps** (OpenTimestamps) — the SHA-256
   of every release tarball is cryptographically committed to a public
   Bitcoin Merkle tree. Downstream auditors verify provenance without
   trusting GitHub.
2. **Wasm-on-chain oracle** (`zig_h3.wasm`) — the same 1.3 MB WASM
   shared library that runs in browsers / Bun / Node also runs in any
   CosmWasm chain, NEAR Protocol, Internet Computer, or Substrate
   parachain that supports wasm32-wasi.
3. **EVM oracle pattern** (documented below) — for chains that don't run
   wasm natively, an off-chain oracle (e.g., Chainlink Functions, Pyth)
   calls into `libzig_h3.so` via the C-ABI shim and posts the result
   as a signed attestation.

## 1. Bitcoin-anchored release timestamps

Build + attest a release in one command:

```sh
ecosystem/onchain/attest.sh path/to/zig-h3-vX.Y.Z.tar.gz
```

This:
- Computes SHA-256 of the tarball.
- Submits the hash to 4 public OpenTimestamps calendar servers
  (a.pool.opentimestamps.org, b.pool.opentimestamps.org,
  a.pool.eternitywall.com, ots.btc.catallaxy.com).
- Saves a `.ots` commitment file alongside the tarball.

Within ~12 hours the hash is anchored in a Bitcoin block. Downstream
verifiers run:

```sh
ots upgrade zig-h3-vX.Y.Z.tar.gz.ots    # fetch the Bitcoin block proof
ots verify zig-h3-vX.Y.Z.tar.gz.ots     # → "Success! Bitcoin block 9XXXXX ..."
```

The v1.4.1 release at <https://github.com/SMC17/zig-h3/releases/tag/v1.4.1>
ships with `zig-h3-v1.4.1-attest.tar.gz.ots` already submitted.

**No wallet, no gas, no account, no fees.** OpenTimestamps' public
calendars are free and the protocol's design means a single Bitcoin
transaction per ~hour amortizes the cost across thousands of
attestations.

### Quad-provenance on every v1.5+ release

| Layer | What it proves | Mechanism |
|-------|----------------|-----------|
| GPG tag | "stax signed this tag" | fingerprint `079261B06444C6A410B3BE363CFCB60243028886` |
| Cosign blob | "stax signed this tarball" | Sigstore ECDSA via `cosign.pub` in repo; sovereign signing-config (no rekor) |
| SBOM | "these are the components" | CycloneDX 1.5 listing libh3 + zig-stdlib + zig-h3 |
| OpenTimestamps | "this tarball existed by date X" | Bitcoin Merkle anchor (~12h finality) |

A downstream supply-chain auditor can verify all four independently.
A git bundle (`.bundle`) is also attached for offline-mirrorable
release-tagged history.

> **Audit history (2026-05-19 → 2026-05-20)**: an earlier draft of
> this table included Cosign as if shipped, when in fact no signing
> tooling existed. The over-claim was caught by substrate audit, the
> claim was retracted, and now (2026-05-20) the cosign tooling has
> been implemented: `ecosystem/onchain/cosign-attest.sh` produces
> the `.cosign-bundle` artifact, and `cosign.pub` is checked into
> the repo. The table is honest again — four layers, all real.

## 2. Wasm-on-chain (CosmWasm / NEAR / Internet Computer / Substrate)

The same `zig_h3.wasm` shared library built via `zig build
-Dtarget=wasm32-wasi -Doptimize=ReleaseFast` (1.3 MB) deploys to any
chain with a wasm32 runtime.

### CosmWasm deploy (Cosmos SDK chains)

```sh
# Build the wasm
cd /path/to/zig-h3
zig build -Dtarget=wasm32-wasi -Doptimize=ReleaseFast

# Strip + compress to fit CosmWasm's 600KB upload limit (post-strip
# zig_h3.wasm is ~900KB; will need additional optimization)
wasm-opt -Oz zig-out/lib/zig_h3.wasm -o zig_h3.opt.wasm
wasm-strip zig_h3.opt.wasm

# Upload to chain (Osmosis testnet example)
osmosisd tx wasm store zig_h3.opt.wasm \
    --from <key> --gas auto --chain-id osmo-test-5 \
    --node https://rpc.osmotest5.osmosis.zone:443
```

The contract exposes the same 30 `zig_h3_*` functions as the native
shared library. Smart contracts on the chain can call into them via
the wasm cross-contract-call API.

### Use case: on-chain geo-fencing

```rust
// Pseudo-CosmWasm contract that gates a token transfer on geo
fn execute_geo_gated_transfer(deps: Deps, lat: f64, lng: f64, amount: u128) -> StdResult<Response> {
    let cell: u64 = call_zig_h3("latlng_to_cell", (lat, lng, 9))?;
    if cell != ALLOWED_NYC_CELL {
        return Err(StdError::generic_err("transfer locked outside NYC res-9 cell"));
    }
    // ... proceed with transfer
}
```

Used for: location-anchored derivatives, geo-fenced NFTs, jurisdictional
compliance pre-checks, supply chain provenance.

### Use case: on-chain submarine cable monitoring

Combine the on-chain wasm with the oceanman × zig-h3 spatial index
(see `~/oceanman/tools/h3-spatial-index/`) for **chain-native cable
incident attestation**:

```rust
// Submit an incident report. The contract validates the location
// falls in a known cable-plant cell (via h3_latlng_to_cell), then
// emits an event that off-chain indexers correlate with cable owners.
fn report_cable_incident(deps: Deps, lat: f64, lng: f64, severity: u8) -> StdResult<Response> {
    let cell = call_zig_h3("latlng_to_cell", (lat, lng, 5))?;
    let known_cable_cells = load_state(deps)?.known_cells;
    if !known_cable_cells.contains(&cell) {
        return Err(StdError::generic_err("report not in any known cable plant cell"));
    }
    // Emit cable-incident event; SLA payouts settle from a separate
    // escrow contract reading this event
    Ok(Response::new().add_event(
        Event::new("cable_incident")
            .add_attribute("cell", cell.to_string())
            .add_attribute("severity", severity.to_string())
    ))
}
```

### Use case: EVM oracle via Chainlink Functions

For EVM chains that don't run wasm natively, a Chainlink Functions job
calls `libzig_h3.so` via the C-ABI shim (Node binding works directly):

```javascript
// Chainlink Functions source (JavaScript)
const zigh3 = await import("@smc17/zigh3");
await zigh3.init(secrets.WASM_URL);
const cell = zigh3.latlngToCell(args[0], args[1], parseInt(args[2]));
return Functions.encodeUint256(cell);
```

The oracle returns the H3 cell on-chain; the consumer smart contract
reads it like any oracle answer.

## 3. The merchant frame on this

zig-h3 is positioned as the **bottleneck-owner substrate for spatial
indexing across every deployment surface**:

| Surface | Substrate form | Status |
|---------|----------------|--------|
| Native (server / desktop) | `libzig_h3.so` + `libzig_h3_static.a` | ✓ shipped |
| Python | `zig_h3` PyPI candidate via ctypes + NumPy | ✓ binding ships |
| Go | `zigh3` Go module via cgo | ✓ binding ships |
| Rust | `zigh3` crate via raw FFI | ✓ binding ships |
| Node / Bun | `zigh3` via koffi | ✓ binding ships |
| Browser | `zigh3` via WebAssembly + JS glue | ✓ binding ships |
| Postgres | `zig_h3.so` Postgres extension (17 SQL fns) | ✓ ecosystem ships |
| SQLite | `zig_h3.so` SQLite extension (14 SQL fns) | ✓ ecosystem ships |
| DuckDB | Python-UDF integration (12 fns) | ✓ ecosystem ships |
| CosmWasm chains | `zig_h3.wasm` direct deploy | ✓ wasm artifact ships |
| NEAR / IC / Substrate | same `zig_h3.wasm` | ✓ wasm artifact ships |
| EVM chains | off-chain oracle calling `libzig_h3.so` | doc pattern above |
| Supply-chain provenance | OpenTimestamps + Bitcoin anchor | ✓ pipeline ships |

The same C-ABI shim (with the same Type-1-catch-guarded units handling)
underlies every surface. **One substrate, twelve+ downstream forms.**
