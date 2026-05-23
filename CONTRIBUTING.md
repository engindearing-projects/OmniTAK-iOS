# Contributing to OmniTAK-iOS

Thanks for your interest in contributing.

## Before you start

- For small fixes (typos, obvious bugs), open a PR directly.
- For new features or larger changes, open an issue first so we can align on scope.
- Security issues — see [SECURITY.md](SECURITY.md), do not file public issues.
- Translating OmniTAK into your language? No coding needed — see [TRANSLATING.md](TRANSLATING.md).

## Development setup

1. Install Xcode 15.4 or later
2. `git clone https://github.com/engindearing-projects/OmniTAK-iOS.git`
3. `open OmniTAKMobile.xcodeproj`
4. Set your Apple Developer Team and Bundle Identifier in **Signing & Capabilities**

## Code style

- Swift 5.9, SwiftUI-first for new views
- Follow existing module structure under `OmniTAKMobile/Features/<FeatureName>/`
- Public APIs get doc comments (`///`), internal helpers usually don't
- No force-unwraps in production code; use `guard` or optional chaining
- Prefer `async/await` over completion handlers in new code

## Tests

```bash
xcodebuild test \
  -project OmniTAKMobile.xcodeproj \
  -scheme OmniTAKMobile \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

Tests live in `OmniTAKMobileTests/` (unit) and `OmniTAKMobileUITests/` (UI / screenshots). New networking or CoT-parsing code needs a unit test.

## Commit style

- One logical change per commit
- Imperative subject line, ≤ 72 chars
- Body explains the *why*, not the *what*

Example:

```
Fix TLS 1.3 handshake hang on TAK Server 5.5

When the server presents a certificate chain longer than 4 entries,
NWConnection's challenge block was being invoked before our identity
was loaded. Loading the keychain identity synchronously on the
connection queue removes the race.
```

## Pull request checklist

- [ ] Builds clean (`xcodebuild build`)
- [ ] Tests pass
- [ ] No new warnings introduced
- [ ] No secrets or hardcoded URLs added
- [ ] If touching `Info.plist` or `PrivacyInfo.xcprivacy`, explain why in the PR
- [ ] If adding a dependency, note the license in the PR

## License

By submitting a contribution, you agree that your work is licensed under the Apache License 2.0 (see [LICENSE](LICENSE)).

## Code of conduct

Be respectful. Disagree on technical merits, not on people. Harassment, discrimination, or personal attacks will result in removal from the project.
