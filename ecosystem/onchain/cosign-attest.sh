#!/usr/bin/env bash
# cosign-attest.sh — sign a release tarball with cosign blob signing.
#
# Cosign v3+ requires a signing-config; we ship one that elides the
# public Sigstore transparency log (rekor) for sovereign-substrate use.
# Verifiers must therefore pass --insecure-ignore-tlog=true (or
# equivalent) to verify without consulting rekor.
#
# Usage:
#   ./cosign-attest.sh <release-tarball>
#
# Produces:
#   <release-tarball>.cosign-bundle  (Sigstore bundle with sig + pub)
#
# The private key lives at ~/.local/share/cosign-keys/zig-h3.key
# (mode 0600). The public key is checked into the repo at cosign.pub.
#
# Verification (downstream):
#   cosign verify-blob \
#     --key cosign.pub \
#     --bundle <tarball>.cosign-bundle \
#     --insecure-ignore-tlog=true \
#     <tarball>
#
# The signing-config at /tmp/sovereign-signing-config.json is derived
# from Sigstore's public config with rekor/tsa removed — sovereign-only,
# no third-party log dependency.

set -euo pipefail

KEY="${COSIGN_KEY:-$HOME/.local/share/cosign-keys/zig-h3.key}"
SIGNING_CONFIG="${COSIGN_SIGNING_CONFIG:-$HOME/.local/share/cosign-keys/sovereign-signing-config.json}"
TARBALL="${1:-}"

if [[ -z "$TARBALL" || ! -f "$TARBALL" ]]; then
    echo "usage: $0 <release-tarball>" >&2
    exit 2
fi

if [[ ! -r "$KEY" ]]; then
    echo "cosign key not found at $KEY" >&2
    echo "generate via:" >&2
    echo "  cosign generate-key-pair --output-key-prefix \$HOME/.local/share/cosign-keys/zig-h3" >&2
    exit 2
fi

# Generate signing-config if it doesn't exist.
if [[ ! -r "$SIGNING_CONFIG" ]]; then
    echo "generating sovereign signing-config at $SIGNING_CONFIG ..." >&2
    mkdir -p "$(dirname "$SIGNING_CONFIG")"
    curl --silent \
        https://raw.githubusercontent.com/sigstore/root-signing/refs/heads/main/targets/signing_config.v0.2.json | \
        python3 -c "import sys,json; d=json.load(sys.stdin); d.pop('rekorTlogUrls',None); d.pop('tsaUrls',None); print(json.dumps(d))" \
        > "$SIGNING_CONFIG"
fi

BUNDLE="${TARBALL}.cosign-bundle"
COSIGN_PASSWORD="${COSIGN_PASSWORD:-}" cosign sign-blob \
    --key "$KEY" \
    --bundle "$BUNDLE" \
    --signing-config "$SIGNING_CONFIG" \
    --yes \
    "$TARBALL"

echo ""
echo "✓ signed: $BUNDLE"
echo ""
echo "Verify with:"
echo "  cosign verify-blob \\"
echo "    --key cosign.pub \\"
echo "    --bundle $BUNDLE \\"
echo "    --insecure-ignore-tlog=true \\"
echo "    $TARBALL"
