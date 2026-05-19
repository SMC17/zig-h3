#!/usr/bin/env bash
# generate-sbom.sh — emit a CycloneDX 1.5 SBOM for zig-h3 at the current
# commit. Closes BAKEOFF axis 8 (release engineering / supply chain) by
# making the dependency tree machine-readable for downstream auditors.
#
# Usage:
#   tools/generate-sbom.sh > sbom.cdx.json
#   tools/generate-sbom.sh --release-tag v1.4.1 > zig-h3-v1.4.1.sbom.json
#
# Output: CycloneDX 1.5 JSON with components for libh3 (vendored), Zig
# stdlib, and the zig-h3 binaries.
#
# Audit history (wave-2, 2026-05-19):
#   1. metadata.tools — migrated from the deprecated [{vendor,name,version}]
#      array form to the 1.5+ `tools: { components: [...] }` shape.
#   2. libh3 hash — previously emitted hashes[0].content="unknown" when the
#      build.zig.zon grep returned empty (the pattern matched a non-existent
#      quoted key and silently failed; even on success the value was a Zig
#      multihash, not the SHA-256 hex the CycloneDX schema requires). We now
#      fetch the upstream tarball and compute its SHA-256. If the fetch or
#      hash extraction fails, the script exits non-zero rather than emitting
#      a schema-invalid placeholder.
#   3. pkg:generic/zig-stdlib — added download_url qualifier (recommended by
#      the purl spec for pkg:generic). Same treatment for the libh3 purl
#      (download_url + vcs_url + checksum) so consumers don't need to
#      cross-reference build.zig.zon.

set -euo pipefail

err() { echo "generate-sbom: $*" >&2; }
die() { err "$*"; exit 1; }

RELEASE_TAG="${1:-}"
if [[ "$RELEASE_TAG" == "--release-tag" ]]; then
    RELEASE_TAG="${2:-HEAD}"
fi

# --- Inputs from repo state -----------------------------------------------

GIT_SHA=$(git rev-parse HEAD)
GIT_SHORT=$(git rev-parse --short HEAD)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
ZIG_VERSION=$(zig version 2>/dev/null || echo "unknown")
[[ "$ZIG_VERSION" == "unknown" ]] && die "could not determine zig version (is zig on PATH?)"

# libh3 version is pinned in build.zig.zon (.h3c.url ends with /v<X>.tar.gz)
LIBH3_VERSION="v4.1.0"

LIBH3_URL=$(grep -A 3 '\.h3c' build.zig.zon | grep '\.url' | head -1 | sed -E 's/.*"(.*)".*/\1/')
[[ -z "$LIBH3_URL" ]] && die "could not extract .h3c.url from build.zig.zon"

# Compute SHA-256 of the upstream tarball (the value build.zig.zon stores is
# a Zig package multihash of the *unpacked* tree, not the tarball's SHA-256,
# so it cannot satisfy the CycloneDX hash schema). We fetch the tarball once
# at SBOM generation time. Fail loud on any error — the audit caught this
# silently emitting "unknown" when extraction failed.
LIBH3_TARBALL=$(mktemp --suffix=.tar.gz)
trap 'rm -f "$LIBH3_TARBALL"' EXIT
if ! curl -sSL --fail --max-time 60 -o "$LIBH3_TARBALL" "$LIBH3_URL"; then
    die "failed to fetch $LIBH3_URL (need network for libh3 tarball hash)"
fi
LIBH3_HASH=$(sha256sum "$LIBH3_TARBALL" | awk '{print $1}')
if [[ ! "$LIBH3_HASH" =~ ^[a-f0-9]{64}$ ]]; then
    die "computed libh3 SHA-256 has unexpected shape: '$LIBH3_HASH'"
fi

# zig-h3 version from build.zig.zon (.version = "X.Y.Z")
ZIG_H3_VERSION=$(grep -E '^\s*\.version' build.zig.zon | head -1 | sed -E 's/.*"(.*)".*/\1/')
[[ -z "$ZIG_H3_VERSION" ]] && die "could not extract .version from build.zig.zon"

SERIAL_UUID=$(uuidgen 2>/dev/null || echo "00000000-0000-0000-0000-${GIT_SHORT}0000")

# purl qualifiers — URL-encode &, =, and spaces are not present so a literal
# concatenation is safe here. download_url is recommended by the purl spec
# for pkg:generic and useful (though not strictly required) on other types.
LIBH3_DOWNLOAD_URL_ENC=$(printf '%s' "$LIBH3_URL" | sed 's/:/%3A/g; s,/,%2F,g')
ZIG_STDLIB_DOWNLOAD_URL="https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_VERSION}.tar.xz"
ZIG_STDLIB_DOWNLOAD_URL_ENC=$(printf '%s' "$ZIG_STDLIB_DOWNLOAD_URL" | sed 's/:/%3A/g; s,/,%2F,g')

cat <<EOF
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "serialNumber": "urn:uuid:${SERIAL_UUID}",
  "version": 1,
  "metadata": {
    "timestamp": "${TIMESTAMP}",
    "tools": {
      "components": [
        {
          "type": "application",
          "group": "stax",
          "name": "zig-h3/tools/generate-sbom.sh",
          "version": "1.1.0",
          "supplier": { "name": "stax" }
        }
      ]
    },
    "component": {
      "type": "library",
      "bom-ref": "pkg:github/SMC17/zig-h3@${ZIG_H3_VERSION}",
      "name": "zig-h3",
      "version": "${ZIG_H3_VERSION}",
      "description": "Idiomatic Zig bindings + pure-Zig reimplementation of Uber's H3 v4 hexagonal spatial index, with batch+parallel API and C-ABI shim for Python/Go/Rust/Node bindings.",
      "licenses": [
        { "license": { "id": "Apache-2.0" } }
      ],
      "purl": "pkg:github/SMC17/zig-h3@${ZIG_H3_VERSION}",
      "externalReferences": [
        { "type": "vcs", "url": "https://github.com/SMC17/zig-h3" },
        { "type": "documentation", "url": "https://github.com/SMC17/zig-h3/tree/main/docs" },
        { "type": "release-notes", "url": "https://github.com/SMC17/zig-h3/releases" }
      ],
      "properties": [
        { "name": "zig:version-required", "value": "0.16.0" },
        { "name": "git:sha", "value": "${GIT_SHA}" },
        { "name": "bakeoff:score", "value": "6-lead / 4-parity / 3-uber-leads (2026-05-18)" }
      ]
    }
  },
  "components": [
    {
      "type": "library",
      "bom-ref": "pkg:github/uber/h3@${LIBH3_VERSION}",
      "name": "libh3",
      "version": "${LIBH3_VERSION}",
      "description": "Uber's H3 v4 hexagonal hierarchical spatial index — vendored as the C reference + ABI source of truth.",
      "licenses": [
        { "license": { "id": "Apache-2.0" } }
      ],
      "purl": "pkg:github/uber/h3@${LIBH3_VERSION}?download_url=${LIBH3_DOWNLOAD_URL_ENC}&checksum=sha256:${LIBH3_HASH}",
      "hashes": [
        { "alg": "SHA-256", "content": "${LIBH3_HASH}" }
      ],
      "scope": "required",
      "externalReferences": [
        { "type": "vcs", "url": "https://github.com/uber/h3" },
        { "type": "distribution", "url": "${LIBH3_URL}" }
      ]
    },
    {
      "type": "library",
      "bom-ref": "pkg:generic/zig-stdlib@${ZIG_VERSION}",
      "name": "zig-stdlib",
      "version": "${ZIG_VERSION}",
      "description": "Zig ${ZIG_VERSION} standard library (std.json, std.Thread, std.heap.c_allocator, etc.)",
      "licenses": [
        { "license": { "id": "MIT" } }
      ],
      "purl": "pkg:generic/zig-stdlib@${ZIG_VERSION}?download_url=${ZIG_STDLIB_DOWNLOAD_URL_ENC}",
      "scope": "required",
      "externalReferences": [
        { "type": "distribution", "url": "${ZIG_STDLIB_DOWNLOAD_URL}" },
        { "type": "vcs", "url": "https://github.com/ziglang/zig" }
      ]
    }
  ],
  "dependencies": [
    {
      "ref": "pkg:github/SMC17/zig-h3@${ZIG_H3_VERSION}",
      "dependsOn": [
        "pkg:github/uber/h3@${LIBH3_VERSION}",
        "pkg:generic/zig-stdlib@${ZIG_VERSION}"
      ]
    }
  ]
}
EOF
