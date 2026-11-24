# X Voice for OmniTAK (iOS)

X Voice is OmniTAK's push-to-talk voice plugin. It is the iOS port of
[TAK-XVoice](https://tx-tak.github.io/TAK-XVoice/), the ATAK voice plugin for
Android, and talks to the same Mumble voice server on your TAK server, so iOS
and Android operators share the same channels.

> **Non-mission-critical use only.** Like TAK-XVoice, X Voice comes with no
> warranty. Don't rely on it as your only means of communication for
> life-safety, public-safety or other mission-critical work.

## What it does

- **Hold-to-talk voice** over your TAK server's Mumble server, signed in with
  your device's TAK enrollment certificate. No separate voice account.
- **Two channels at once.** PTT 1 is your primary channel; PTT 2 is an
  optional second channel you listen to and can talk on.
- **Full duplex.** You keep hearing others while you talk. While you talk on
  one channel, the other channel is turned down (ducked to 25%).
- **Native iOS push-to-talk.** X Voice appears in the iPhone's system
  push-to-talk UI (lock screen, Dynamic Island), works in the background and
  with the phone locked, and uses iOS's own start/stop sounds and vibration.
- **Bluetooth speaker-mics and buttons.** AINA APTT, Inrico BT02 and the Pryme
  BT-PTT-Z button, found and connected automatically.
- **Emergency button.** A speaker-mic's emergency key raises a 911 alert in
  OmniTAK, the same alert as the in-app emergency button.

## Documentation

| Page | What's in it |
|---|---|
| [User guide](user-guide.md) | Turning it on, picking channels, talking, every setting, emergency |
| [Hardware](hardware.md) | Supported speaker-mics and buttons, what works on iOS and what doesn't |
| [Server & channels](server-and-channels.md) | What the server needs; links to the Android server guide |
| [How it works](how-it-works.md) | Architecture: Apple PushToTalk, audio session, Mumble, Bluetooth |
| [Troubleshooting](troubleshooting.md) | Symptoms, causes, and how to read the logs |
| [Device test checklist](../X_VOICE_TESTING.md) | Step-by-step hardware test runs for developers |

## iOS and Android

X Voice follows TAK-XVoice's design and protocol; the Android plugin stays the
source of truth. The Android documentation covers the shared ground in more
depth:

- [Quick Start](https://tx-tak.github.io/TAK-XVoice/quick-start/)
- [User Setup](https://tx-tak.github.io/TAK-XVoice/user-setup/)
- [Server & Channels](https://tx-tak.github.io/TAK-XVoice/server-setup/)
- [Supported Hardware](https://tx-tak.github.io/TAK-XVoice/hardware/)
- [Design Decisions](https://tx-tak.github.io/TAK-XVoice/design-decisions/)

What's different on iOS:

| | Android (TAK-XVoice) | iOS (X Voice) |
|---|---|---|
| Push-to-talk system | Plugin-managed | Apple's PushToTalk framework (system UI, background) |
| Start/stop cues | Talk Permit Tones (ASTRO 25, Nextel, DMR…) | iOS's own start/end sounds and vibration |
| Bluetooth buttons | PTT 1 and an External Button slot | **PTT 1 only** (the AINA's secondary button is the one exception: PTT 2) |
| Speaker-mic + separate button at once | Yes | No: one Bluetooth button device at a time |
| AINA V1 over Classic SPP | Yes | No (needs Apple MFi); V1 works through its BLE button service |
| Samsung Active Key, Sonim keys | Yes | Not applicable |
| Multicast mesh voice | Alpha | Not ported |
| Direct calling | Yes | Not yet |

## Editions

There are two builds of X Voice for iOS, on separate branches:

- **`voice-native-ptt`** (this one, recommended): built on Apple's
  PushToTalk framework. iOS owns the audio session and the start/stop cues.
  This is the edition for App Store distribution: it uses the
  `com.apple.developer.push-to-talk` entitlement and the `push-to-talk`
  background mode.
- **`voice-track-a`**: the original app-managed edition. X Voice manages its
  own audio session and plays its own talk-permit tone. It doesn't appear in
  the system push-to-talk UI.

Both share the Mumble client, the slot rules and the Bluetooth button code.
