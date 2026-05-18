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

set -euo pipefail

RELEASE_TAG="${1:-}"
if [[ "$RELEASE_TAG" == "--release-tag" ]]; then
    RELEASE_TAG="${2:-HEAD}"
fi

GIT_SHA=$(git rev-parse HEAD)
GIT_SHORT=$(git rev-parse --short HEAD)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
ZIG_VERSION=$(zig version 2>/dev/null || echo "unknown")

# libh3 version is pinned in build.zig
LIBH3_VERSION="v4.1.0"
LIBH3_HASH_LINE=$(grep -A 2 '"h3c"' build.zig.zon | grep "hash" | head -1 || true)
LIBH3_HASH=$(echo "$LIBH3_HASH_LINE" | sed 's/.*"\(.*\)".*/\1/')

# zig-h3 version from build.zig.zon
ZIG_H3_VERSION=$(grep '.version' build.zig.zon | head -1 | sed 's/.*"\(.*\)".*/\1/')

cat <<EOF
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "serialNumber": "urn:uuid:$(uuidgen 2>/dev/null || echo "00000000-0000-0000-0000-${GIT_SHORT}0000")",
  "version": 1,
  "metadata": {
    "timestamp": "${TIMESTAMP}",
    "tools": [
      {
        "vendor": "stax",
        "name": "zig-h3/tools/generate-sbom.sh",
        "version": "1.0.0"
      }
    ],
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
      "purl": "pkg:github/uber/h3@${LIBH3_VERSION}",
      "hashes": [
        { "alg": "SHA-256", "content": "${LIBH3_HASH:-unknown}" }
      ],
      "scope": "required",
      "externalReferences": [
        { "type": "vcs", "url": "https://github.com/uber/h3" }
      ]
    },
    {
      "type": "library",
      "bom-ref": "pkg:generic/zig-stdlib@${ZIG_VERSION}",
      "name": "zig-stdlib",
      "version": "${ZIG_VERSION}",
      "description": "Zig 0.16 standard library (std.json, std.Thread, std.heap.c_allocator, etc.)",
      "licenses": [
        { "license": { "id": "MIT" } }
      ],
      "scope": "required"
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
