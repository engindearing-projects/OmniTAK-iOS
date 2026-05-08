# Build OmniTAK iOS from source

You can run OmniTAK on your own iPhone or iPad in about **5 minutes** without paying Apple. This guide is for developers, contributors, and anyone who wants to install a custom build (e.g. with their own plugins).

> **TL;DR:** clone → open in Xcode → change the **Bundle Identifier** to something unique → set your **Team** → run.

## Prerequisites

| | Requirement |
|---|---|
| **Mac** | macOS Sonoma 14 or later |
| **Xcode** | 15.4 or later (free from the App Store) |
| **Apple ID** | Any free Apple ID works for personal device builds |
| **Device** | iPhone or iPad on iOS 15 or later (or Apple Silicon Mac for Catalyst) |
| **iOS version** | Deployment target is iOS 15 |

## 5-minute setup

```bash
git clone https://github.com/engindearing-projects/OmniTAK-iOS.git
cd OmniTAK-iOS
open OmniTAKMobile.xcodeproj
```

In Xcode:

1. Select the **OmniTAKMobile** target in the project navigator
2. Go to **Signing & Capabilities**
3. **Change the Bundle Identifier** to something unique to you, e.g. `com.yourname.omnitak`. *This is the #1 thing people miss — see the troubleshooting section below.*
4. Set **Team** to your personal Apple ID (sign in via Xcode → Settings → Accounts if needed)
5. Connect your iPhone via USB, select it as the run destination, and hit **▶ Run**

The first run will prompt you on your phone to **trust the developer certificate**:

- iPhone → Settings → General → VPN & Device Management → tap your developer name → **Trust**

That's it. The app will launch and you'll see the new 8-page onboarding flow.

## The 7-day re-sign reality (free Apple ID)

With a **free** Apple ID, your build's signature expires every **7 days**. After that the app refuses to launch and you have to plug back into your Mac and rebuild from Xcode (takes ~30 seconds).

- **Want longer?** Pay $99/yr for an Apple Developer Program account → 1-year validity, no 7-day expiration
- **Want it permanent and free?** Use **TestFlight**: open `https://testflight.apple.com/join/SzxQGmMM` on your phone, no rebuilding ever
- **Want it permanent and self-built?** No — Apple does not allow that without a paid Developer Program

| Path | Cost | Re-sign cadence | Plugins | Notes |
|---|---|---|---|---|
| App Store | free | n/a | bundled only | search "OmniTAK" |
| TestFlight (public link) | free | n/a | bundled only | up to 10k testers |
| **Build from source (free Apple ID)** | free | **every 7 days** | ✅ custom | this guide |
| Build from source (paid Apple Developer) | $99/yr | yearly | ✅ custom | best for plugin developers |
| Mac Catalyst | free | n/a on the dev machine | ✅ custom | runs on your Mac, no signing pain |

## Mac Catalyst — easier than iPhone for plugin development

If you're iterating on a plugin and don't want to deal with the 7-day re-sign cycle, build for Mac Catalyst instead:

1. In Xcode, select the **OmniTAKMobile** target → **General** → check **Mac (Designed for iPad)** under "Supported Destinations"
2. Set the run destination to **My Mac (Designed for iPad)**
3. Hit **▶ Run** — OmniTAK launches as a Mac app, no provisioning required

Same UI as iPhone, full plugin SDK support, no 7-day timer.

## Adding your own plugin

OmniTAK ships with a plugin SDK. The ADS-B traffic feature is implemented as the reference plugin at `plugins/example-adsb-plugin/`. To add your own:

1. Read **[`docs/PLUGIN_AUTHORING.md`](docs/PLUGIN_AUTHORING.md)**
2. Copy the `example-adsb-plugin/` folder as a starting point
3. Add your package to OmniTAK's `Package.swift` dependencies
4. Register your plugin in `PluginRegistry.loadBundledPlugins()`
5. Build and run

Apple does not allow runtime code loading on iOS, so plugins must be **compiled into the binary**. The trade-off: every plugin user runs is a custom build.

## Building an IPA for sideload distribution

If you want to give your custom build to other people (without TestFlight), you can produce a signed `.ipa`:

```bash
xcodebuild archive \
  -project OmniTAKMobile.xcodeproj \
  -scheme OmniTAKMobile \
  -destination "generic/platform=iOS" \
  -archivePath build/OmniTAKMobile.xcarchive

xcodebuild -exportArchive \
  -archivePath build/OmniTAKMobile.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/
```

The recipient still needs to **re-sign with their own certificate** — Apple does not allow installing an `.ipa` signed by someone else's free Apple ID. Tools like [Sideloadly](https://sideloadly.io) or [esign](https://esign.yyyue.xyz) can do the re-sign on the user's side.

## Troubleshooting

### "Failed to register bundle identifier" or "An App ID with Identifier '...' is not available"

Apple requires bundle IDs to be **unique across all of Apple's developer accounts**. The default `soy.engindearing.omnitak.mobile` is registered to Engindearing — you cannot reuse it. Change it to something based on your own domain or name (e.g. `com.yourname.omnitak`).

### "The maximum number of apps for free development profiles has been reached"

Free Apple IDs are limited to **3 concurrent app installs**. Delete an old free-built app from your phone, or upgrade to a paid Developer account.

### "Could not launch OmniTAKMobile" / "Untrusted developer"

Go to iPhone Settings → General → VPN & Device Management → tap your developer name → **Trust**.

### Build fails on Localizable.strings

OmniTAK ships in EN / PL / DE / FR. If you've added new UI strings, run the included scripts to wire them into the project:

```bash
ruby scripts/add-localizations.rb
```

### Build succeeds but ADS-B doesn't show aircraft

ADS-B requires API keys for `adsbExchange` and `FlightRadar24`. The default providers (OpenSky and dump1090) work without keys but need either internet (OpenSky) or a local SDR setup (dump1090). Check **Settings → Plugins → ADS-B Traffic** for provider configuration.

## Where to ask for help

- **GitHub Issues:** https://github.com/engindearing-projects/OmniTAK-iOS/issues
- **TAK Discord:** the `#engindearing` channel in **Maker's Market**
- **Email:** support@engindearing.soy

If you build something cool with the plugin SDK, open a PR or DM us — we want to feature community plugins in the README.
