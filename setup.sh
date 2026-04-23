#!/bin/bash
set -e

# Requires: brew install xcodegen

echo "→ Generating Xcode project..."
xcodegen generate

echo ""
echo "✓ Done. Open iMoodRing.xcodeproj in Xcode."
echo "  Xcode will resolve the llama.swift SPM package on first open."
