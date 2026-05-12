# OmniTAKMobileSpecs

Standalone XCTest harnesses that DO NOT depend on a PBXNativeTarget.

## Why this exists

The Xcode project still has no `OmniTAKMobileTests` PBXNativeTarget (see
release notes 2.18.0). Until one is added, `OmniTAKMobileTests/*.swift`
sit as orphan source — meaningful as documentation/spec but not actually
executed by `xcodebuild test`.

`OmniTAKMobileSpecs/` is the workaround. Each spec is a tiny self-contained
Swift file that:
- Includes the production-code symbols it needs directly (via include-files
  list, not `@testable import`), OR
- Reimplements only the surface area under test against the real type
  definitions copied as references.

Run with `swift` directly — no Xcode project required.

## Running a spec

```bash
swift OmniTAKMobileSpecs/KMLOverlayRendererSpec.swift
```

Exit 0 means the spec passes. Non-zero exit means failure (the spec prints
which assertion blew up).

## Adding a spec

1. Copy the structure of `KMLOverlayRendererSpec.swift`.
2. Source the production types you depend on with absolute file paths via
   a `// swift-include:` marker — they get string-concatenated at build
   time by `run-spec.sh`.
3. Use `precondition(...)` for inline assertions; the script catches the
   failure and reports the line number.

This is intentionally lightweight. The real story is wiring a PBX test
target — these specs are just the gap-filler.
