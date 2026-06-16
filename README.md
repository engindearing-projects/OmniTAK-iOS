# OmniTAK-iOS

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Open-source TAK (Team Awareness Kit) client for iPhone and iPad, built in Swift + SwiftUI.

OmniTAK speaks Cursor-on-Target (CoT) over TLS to any TAK Server, supports data-package import, ADS-B traffic display, RTSP/SRT/HLS video feeds, Meshtastic radios, and more — designed for search-and-rescue, civil defense, and outdoor operations.

> **Bring your own TAK Server.** OmniTAK is a client. Stand up [TAK Server](https://tak.gov) (community CIV edition), [OpenTAKServer](https://github.com/brian7704/OpenTAKServer), or [taky](https://github.com/tkuester/taky) and point OmniTAK at it.

## Install

[![App Store](https://img.shields.io/badge/App_Store-OmniTAK-0D96F6?logo=apple&logoColor=white)](https://apps.apple.com/us/app/omnitakmobile/id6755246992)

**OmniTAK is live on the [App Store](https://apps.apple.com/us/app/omnitakmobile/id6755246992)** — current release **2.38.0**: KML placemarks as labeled yellow pins + a red-framed coordinate readout, UAS H.264 video with picture-in-picture, custom icon-pack import, expanded drawing tools (vertex / radius edit, drag-to-reposition, full 3D parity), lasso line/polygon selection, self-marker upgrades, and TAK/ATAK QR enrollment.

Free, no ads, Apache-2.0. Requires iOS 17+.

## Features

- **TAK Server connectivity** — TCP / TLS / mTLS with client-certificate enrollment
- **Cursor-on-Target** — full CoT XML send/receive, marker rendering, COT history
- **Data Packages (.zip)** — import TAK preference packs and certificate bundles via Files / AirDrop / iCloud Drive
- **CSR enrollment** — request client certs from a TAK Server enrollment endpoint (port 8446)
- **MapLibre** — vector basemaps, offline tiles, custom styles
- **ADS-B traffic** — OpenSky Network, adsbExchange, FlightRadar24, dump1090 (bring your own API key)
- **Video feeds** — HTTP / HLS via AVPlayer, RTSP / SRT via [MobileVLCKit](https://code.videolan.org/videolan/VLCKit) (LGPL v2.1+)
- **Meshtastic** — BLE + TCP connection to Meshtastic mesh radios
- **Photo attachments** — capture photos against CoT events with EXIF location
- **Plugin system** — Swift package extensions for custom CoT types and UI panels

## Requirements

- iOS 17.0 or later
- Xcode 15.4 or later
- Swift 5.9
- A TAK Server you can reach (BYO — see above)

## Getting started

```bash
git clone https://github.com/engindearing-projects/OmniTAK-iOS.git
cd OmniTAK-iOS
open OmniTAKMobile.xcodeproj
```

In Xcode:

1. Select the `OmniTAKMobile` target
2. Signing & Capabilities → set your **Team** and **Bundle Identifier**
3. Build & run on a device or simulator

The first launch shows an empty server list. Add your TAK Server via **Settings → TAK Servers → +** or import a `.zip` data package.

### Optional: ADS-B / FR24 API keys

OmniTAK supports four ADS-B providers. API keys (where required) are entered in **Settings → ADS-B** and stored in `UserDefaults` — never compiled into the binary.

| Provider | Key required | Where to get one |
|----------|-------------|------------------|
| OpenSky Network | No (anonymous) | https://opensky-network.org |
| dump1090 (local) | No | Local network |
| adsbExchange | Yes (RapidAPI) | https://rapidapi.com/adsbx |
| FlightRadar24 | Yes (paid) | https://fr24api.flightradar24.com |

## Architecture

```
OmniTAKMobile/
├── Core/             App entry, root SwiftUI views
├── Features/         Feature modules (Networking, Map, ADSB, Video, Chat, …)
├── Models/           Codable models, CoT types, server config
├── Services/         Background services (TAKService, CoT parser, Meshtastic, …)
├── UI/               Reusable views and styles
├── Utilities/        Helpers, extensions
└── Resources/        Info.plist, PrivacyInfo.xcprivacy, assets
```

The app links a precompiled native framework `OmniTAKMobile.xcframework` (Rust core for CoT parsing performance, certificate handling, and storage). The framework source is being prepared for separate open-source release as **OmniTAK-Core**.

## Security & privacy

- **No tracking, no analytics, no third-party SDKs**
- All TAK Server connections are TLS 1.2+ by default (legacy TLS 1.0/1.1 opt-in for old servers)
- Certificates are stored in iOS Keychain
- Privacy manifest declared in `OmniTAKMobile/Resources/PrivacyInfo.xcprivacy`

Found a vulnerability? See [SECURITY.md](SECURITY.md) for responsible disclosure.

## Contributing

Contributions welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). For larger changes, please open an issue first to discuss.

## License

Apache License 2.0. See [LICENSE](LICENSE).

**Free to use, modify, and share, with no separate permission needed.** Apache 2.0 covers personal, volunteer, commercial, and government use at no cost. It only asks that you keep the existing copyright and license notice in place, and note any changes you make to the source. Translations and other contributions are welcome.

OmniTAK-iOS bundles or links the following open-source components:

- [MapLibre Native iOS](https://github.com/maplibre/maplibre-gl-native-ios) — BSD 2-Clause
- [MobileVLCKit](https://code.videolan.org/videolan/VLCKit) — LGPL v2.1+
- [SwiftProtobuf](https://github.com/apple/swift-protobuf) — Apache 2.0

## Acknowledgments

Built by [Engindearing](https://engindearing.soy). Inspired by [ATAK](https://github.com/deptofdefense/AndroidTacticalAssaultKit-CIV), iTAK, [OpenTAKServer](https://github.com/brian7704/OpenTAKServer), and the broader TAK community.

OmniTAK is not affiliated with or endorsed by the U.S. Department of Defense, the TAK Product Center, or any other organization.
