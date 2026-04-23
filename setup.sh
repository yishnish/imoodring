#!/bin/bash
set -e

# Requires: brew install xcodegen
# Requires: sudo gem install cocoapods

# Download LiteRT Metal accelerator if not already present.
# The prebuilts zip had an arm64 packaging bug (fixed 2026-04-12).
# We verify architecture after download to catch any regressions.
METAL_DYLIB="Vendor/libLiteRtMetalAccelerator.dylib"
if [ ! -f "$METAL_DYLIB" ]; then
    echo "→ Downloading LiteRT prebuilts..."
    mkdir -p Vendor
    curl -# "https://storage.googleapis.com/litert/binaries/latest/litert_prebuilts.zip" \
        -o /tmp/litert_prebuilts.zip
    unzip -p /tmp/litert_prebuilts.zip "ios_arm64/libLiteRtMetalAccelerator.dylib" \
        > "$METAL_DYLIB"
    rm /tmp/litert_prebuilts.zip
    ARCH=$(file "$METAL_DYLIB")
    if echo "$ARCH" | grep -q "arm64"; then
        echo "✓ Metal accelerator: arm64 ok"
    else
        echo "⚠️  Metal accelerator is not arm64 — GPU will not work: $ARCH"
    fi
else
    echo "→ Metal accelerator already present, skipping download"
fi

echo "→ Generating Xcode project..."
xcodegen generate

echo "→ Installing CocoaPods..."
pod install

echo ""
echo "✓ Done. Open iMoodRing.xcworkspace in Xcode."
