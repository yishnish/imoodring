#!/bin/bash
set -e

# Requires: brew install xcodegen
# Requires: sudo gem install cocoapods

echo "→ Generating Xcode project..."
xcodegen generate

echo "→ Installing CocoaPods..."
pod install

echo ""
echo "✓ Done. Open iMoodRing.xcworkspace in Xcode."
