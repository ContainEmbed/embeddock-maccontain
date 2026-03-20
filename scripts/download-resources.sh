#!/bin/bash
set -euo pipefail

# download-resources.sh
#
# Downloads EmbedDock VM binaries from GitHub Releases into Sources/EmbedDock/Resources/.
# Run this once after cloning the repo or when upgrading to a new release.
#
# Usage:
#   ./scripts/download-resources.sh [version]
#
# Examples:
#   ./scripts/download-resources.sh          # Downloads latest release
#   ./scripts/download-resources.sh 0.1.0    # Downloads specific version

REPO="ContainEmbed/embeddock-maccontain"
RESOURCES_DIR="Sources/EmbedDock/Resources"
REQUIRED_BINARIES=("vminitd" "vmexec" "vmlinux" "pre-init")

# Determine version
if [ $# -ge 1 ]; then
    VERSION="$1"
else
    echo "Fetching latest release version..."
    VERSION=$(gh release list --repo "$REPO" --limit 1 --json tagName --jq '.[0].tagName' 2>/dev/null || true)
    if [ -z "$VERSION" ]; then
        echo "Error: Could not determine latest version. Pass version explicitly:"
        echo "  $0 0.1.0"
        exit 1
    fi
fi

ASSET_NAME="EmbedDockResources.artifactbundle.zip"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET_NAME}"

echo "=== EmbedDock Resource Downloader ==="
echo "Version:  ${VERSION}"
echo "Target:   ${RESOURCES_DIR}/"
echo ""

# Check if resources already exist
ALL_PRESENT=true
for binary in "${REQUIRED_BINARIES[@]}"; do
    if [ ! -f "${RESOURCES_DIR}/${binary}" ]; then
        ALL_PRESENT=false
        break
    fi
done

if [ "$ALL_PRESENT" = true ]; then
    echo "All required binaries already present in ${RESOURCES_DIR}/."
    echo "To force re-download, delete them first:"
    echo "  rm ${RESOURCES_DIR}/{vminitd,vmexec,vmlinux,pre-init}"
    exit 0
fi

# Create temp directory for download
TMPDIR_PATH=$(mktemp -d)
trap 'rm -rf "$TMPDIR_PATH"' EXIT

echo "Downloading ${ASSET_NAME}..."

# Try gh CLI first (handles auth), fall back to curl
if command -v gh &>/dev/null; then
    gh release download "$VERSION" \
        --repo "$REPO" \
        --pattern "$ASSET_NAME" \
        --dir "$TMPDIR_PATH" 2>/dev/null || {
        echo "gh download failed, falling back to curl..."
        curl -fSL -o "${TMPDIR_PATH}/${ASSET_NAME}" "$DOWNLOAD_URL"
    }
else
    curl -fSL -o "${TMPDIR_PATH}/${ASSET_NAME}" "$DOWNLOAD_URL"
fi

echo "Extracting..."
unzip -q "${TMPDIR_PATH}/${ASSET_NAME}" -d "$TMPDIR_PATH"

# Find the extracted artifact bundle
BUNDLE_DIR="${TMPDIR_PATH}/EmbedDockResources.artifactbundle"
if [ ! -d "$BUNDLE_DIR" ]; then
    echo "Error: Expected EmbedDockResources.artifactbundle/ inside zip"
    exit 1
fi

# Copy binaries to Resources directory
mkdir -p "$RESOURCES_DIR"
for binary in "${REQUIRED_BINARIES[@]}"; do
    SRC="${BUNDLE_DIR}/bin/${binary}"
    if [ -f "$SRC" ]; then
        cp "$SRC" "${RESOURCES_DIR}/${binary}"
        chmod +x "${RESOURCES_DIR}/${binary}"
        echo "  Copied: ${binary} ($(du -h "$SRC" | cut -f1))"
    else
        echo "  Warning: ${binary} not found in artifact bundle"
    fi
done

echo ""
echo "Done! Resources installed to ${RESOURCES_DIR}/."
echo "You can now build with: swift build"
