#!/usr/bin/env bash
# attest.sh — anchor a zig-h3 release tarball to the Bitcoin chain via
# OpenTimestamps. No wallet, no gas, no account required.
#
# This closes BAKEOFF axis 8 (release engineering / supply chain) to its
# strongest possible state: the SHA-256 of every release tarball is
# cryptographically committed to a public, immutable Bitcoin Merkle
# tree within ~12 hours of `make attest`. Downstream consumers verify
# trustlessly:
#
#     ots verify zig-h3-vX.Y.Z.tar.gz.ots
#     # → Success! Bitcoin block 9XXXXX attests existence as of 2026-MM-DD
#
# Combined with GPG-signed tags + cosign blob signatures, the v1.4.x
# release line carries triple-provenance:
#   1. GPG: "stax signed this tag"             (cryptographic identity)
#   2. cosign: "stax signed this tarball"      (cryptographic identity)
#   3. OpenTimestamps: "this tarball existed by date X" (Bitcoin chain)
#
# Usage:
#     tools/onchain/attest.sh [path/to/release.tar.gz]
#
# Default target: latest GH release tarball downloaded via gh.

set -euo pipefail

# Find the OpenTimestamps client. Tries:
#   1. ots-cli on PATH (Arch / Debian)
#   2. /tmp/pyevm-venv/bin/ots (stax workstation pip install location)
#   3. python3 -m opentimestamps_client (if pip-installed in current env)
OTS_BIN=$(command -v ots 2>/dev/null || true)
if [[ -z "$OTS_BIN" && -x /tmp/pyevm-venv/bin/ots ]]; then
    OTS_BIN=/tmp/pyevm-venv/bin/ots
fi
if [[ -z "$OTS_BIN" ]]; then
    echo "ERROR: opentimestamps client not found." >&2
    echo "Install: pip install opentimestamps-client" >&2
    exit 1
fi

TARBALL="${1:-}"
if [[ -z "$TARBALL" ]]; then
    # Find the latest v*.tar.gz from /tmp (built by gh release)
    TARBALL=$(ls -1t /tmp/zig-h3-v*.tar.gz 2>/dev/null | head -1)
    if [[ -z "$TARBALL" ]]; then
        echo "ERROR: no tarball provided and no /tmp/zig-h3-v*.tar.gz found." >&2
        echo "Usage: $0 [path/to/release.tar.gz]" >&2
        exit 2
    fi
    echo "Using latest tarball: $TARBALL"
fi

if [[ ! -f "$TARBALL" ]]; then
    echo "ERROR: tarball not found: $TARBALL" >&2
    exit 3
fi

# Compute SHA-256 (this is what gets anchored)
HASH=$(sha256sum "$TARBALL" | cut -d' ' -f1)
echo "SHA-256: $HASH"
echo "Tarball: $TARBALL"
echo ""
echo "Submitting commitment to OpenTimestamps calendar servers..."
echo ""

# Make sure libstdc++ is reachable (workstation nix-vs-arch reconciliation)
LIBSTDCXX=$(find /nix/store -name libstdc++.so.6 -type f 2>/dev/null | head -1 || true)
if [[ -n "$LIBSTDCXX" ]]; then
    export LD_LIBRARY_PATH="/usr/lib:$(dirname "$LIBSTDCXX"):${LD_LIBRARY_PATH:-}"
fi

"$OTS_BIN" stamp "$TARBALL"

OTS_FILE="${TARBALL}.ots"
if [[ ! -f "$OTS_FILE" ]]; then
    echo "ERROR: .ots commitment file not produced at $OTS_FILE" >&2
    exit 4
fi

echo ""
echo "✓ Commitment created: $OTS_FILE"
echo ""
echo "Within ~12 hours this commitment will be anchored in a Bitcoin"
echo "block via a Merkle tree. To verify after anchoring:"
echo ""
echo "    ots upgrade $OTS_FILE       # refresh with the Bitcoin block"
echo "    ots verify $OTS_FILE        # cryptographic proof"
echo ""
echo "Attach this .ots file to the GitHub release alongside the tarball"
echo "and cosign bundle:"
echo ""
echo "    gh release upload <tag> $TARBALL $OTS_FILE"
echo ""
