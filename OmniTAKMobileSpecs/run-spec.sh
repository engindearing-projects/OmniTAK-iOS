#!/usr/bin/env bash
# Run a single Spec by concatenating its `// swift-include:` references
# into a runnable Swift file, then `swift` it on macOS.
#
# Usage: ./run-spec.sh OmniTAKMobileSpecs/KMLOverlayRendererSpec.swift
set -euo pipefail

SPEC="${1:?spec file required}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

TMP="$(mktemp -d)"
TRG="$TMP/spec.swift"

# Prelude: alias NSColor as UIColor when building on macOS so production code
# that references UIColor still compiles. The spec only runs on macOS host.
cat > "$TRG" <<'PRELUDE'
#if canImport(AppKit) && !canImport(UIKit)
import AppKit
typealias UIColor = NSColor
#endif
PRELUDE

# Pull every `// swift-include: <relative path>` into the merged file,
# then append the spec body (with includes left as-is — Swift ignores comments).
grep -h '^// swift-include:' "$SPEC" | while read -r line; do
  rel="${line#// swift-include:}"
  rel="${rel## }"
  cat "$ROOT/$rel"
  echo
done >> "$TRG"

cat "$SPEC" >> "$TRG"

# Run on macOS host. MapKit + CoreLocation work fine on macOS.
swift -sdk "$(xcrun --sdk macosx --show-sdk-path)" "$TRG"
