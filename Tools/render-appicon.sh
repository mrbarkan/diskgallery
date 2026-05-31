#!/bin/bash
# Regenerate DiskGallery's AppIcon PNG set + Contents.json from the SwiftUI BrandMark.
# Run from the repo root after editing the mark:  ./Tools/render-appicon.sh
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="DiskGallery/Assets.xcassets/AppIcon.appiconset"

# swiftc needs the file with top-level code to be named main.swift, so stage both
# sources in a temp dir and build a throwaway executable.
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
cp Tools/RenderAppIcon.swift "$BUILD/main.swift"
cp DiskGallery/Views/Brand/BrandMark.swift "$BUILD/BrandMark.swift"

swiftc -O -o "$BUILD/render" "$BUILD/main.swift" "$BUILD/BrandMark.swift"
"$BUILD/render" "$OUT"

echo "Done. Regenerate the project if needed: xcodegen generate"
