#!/bin/bash
set -euo pipefail

# create-release.sh
#
# Creates a GitHub release for EmbedDock and uploads the artifact bundle.
#
# Prerequisites:
#   - gh CLI installed and authenticated
#   - EmbedDockResources.artifactbundle/ exists with all 4 binaries
#
# Usage:
#   ./scripts/create-release.sh <version>
#
# Example:
#   ./scripts/create-release.sh 0.2.0

REPO="ContainEmbed/embeddock-maccontain"
BUNDLE_DIR="EmbedDockResources.artifactbundle"
ZIP_NAME="EmbedDockResources.artifactbundle.zip"

# --- Validate arguments ---
if [ $# -ne 1 ]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 0.2.0"
    exit 1
fi

VERSION="$1"
TAG="${VERSION}"

# --- Validate artifact bundle exists ---
if [ ! -d "$BUNDLE_DIR" ]; then
    echo "Error: $BUNDLE_DIR not found."
    echo "Build the artifact bundle first."
    exit 1
fi

REQUIRED_BINARIES=("bin/vminitd" "bin/vmexec" "bin/vmlinux" "bin/pre-init")
for binary in "${REQUIRED_BINARIES[@]}"; do
    if [ ! -f "${BUNDLE_DIR}/${binary}" ]; then
        echo "Error: Missing ${BUNDLE_DIR}/${binary}"
        exit 1
    fi
done

if [ ! -f "${BUNDLE_DIR}/info.json" ]; then
    echo "Error: Missing ${BUNDLE_DIR}/info.json"
    exit 1
fi

# --- Create zip ---
echo "=== Creating ${ZIP_NAME} ==="
rm -f "$ZIP_NAME"
zip -r -X "$ZIP_NAME" "$BUNDLE_DIR"
echo "  Created: ${ZIP_NAME} ($(du -h "$ZIP_NAME" | cut -f1))"

# --- Compute checksum ---
CHECKSUM=$(shasum -a 256 "$ZIP_NAME" | awk '{print $1}')
echo ""
echo "  SHA256: ${CHECKSUM}"
echo ""

# --- Create GitHub release ---
echo "=== Creating GitHub release ${TAG} ==="

if gh release view "$TAG" --repo "$REPO" &>/dev/null; then
    echo "Release ${TAG} already exists. Uploading asset to existing release..."
    gh release upload "$TAG" "$ZIP_NAME" --repo "$REPO" --clobber
else
    gh release create "$TAG" "$ZIP_NAME" \
        --repo "$REPO" \
        --title "EmbedDock ${VERSION}" \
        --notes "## EmbedDock ${VERSION}

### Artifact Bundle
- \`${ZIP_NAME}\` contains VM binaries (vminitd, vmexec, vmlinux, pre-init) for arm64-apple-macosx.
- SHA256: \`${CHECKSUM}\`

### Installation
Add to your Package.swift:
\`\`\`swift
.binaryTarget(
    name: \"EmbedDockResources\",
    url: \"https://github.com/${REPO}/releases/download/${TAG}/${ZIP_NAME}\",
    checksum: \"${CHECKSUM}\"
)
\`\`\`"
fi

echo ""
echo "=== Done ==="
echo ""
echo "Update Package.swift with:"
echo ""
echo "  .binaryTarget("
echo "      name: \"EmbedDockResources\","
echo "      url: \"https://github.com/${REPO}/releases/download/${TAG}/${ZIP_NAME}\","
echo "      checksum: \"${CHECKSUM}\""
echo "  )"
echo ""
