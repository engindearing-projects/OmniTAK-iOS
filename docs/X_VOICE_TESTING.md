# X Voice (PTT) — device test checklist

For developers testing X Voice on a real iPhone. User-facing docs are in
[docs/x-voice/](x-voice/README.md).

Branch: `voice-native-ptt` (Apple PushToTalk). Needs a provisioning profile with
the `com.apple.developer.push-to-talk` entitlement. Replace the placeholders:
`<DEVICE_ID>` (from `xcrun devicectl list devices`), `<TEAM_ID>`, `<BUNDLE_ID>`.

## Load to the phone

```bash
cd OmniTAK-iOS
xcodebuild -project OmniTAK.xcodeproj -scheme OmniTAKMobile -configuration Debug \
  -destination 'id=<DEVICE_ID>' -derivedDataPath .derived-device \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=<TEAM_ID> CODE_SIGN_STYLE=Automatic \
  PRODUCT_BUNDLE_IDENTIFIER=<BUNDLE_ID> build
xcrun devicectl device install app --device <DEVICE_ID> \
  .derived-device/Build/Products/Debug-iphoneos/OmniTAK.app
# launch with the console log (Ctrl-C to stop); the log stops if OmniTAK closes:
xcrun devicectl device process launch --device <DEVICE_ID> \
  --terminate-existing --console <BUNDLE_ID>
```

Log prefixes are explained in [How it works → Logging](x-voice/how-it-works.md#logging).
Every transmission ends with a `TX burst` and a `TX mic level` line: normal
speech is about −20 to −35 dBFS rms with some voiced %; around −80 dBFS and
voiced 0% means silence was sent.

## 0. System push-to-talk

| # | Do | Expect |
|---|----|--------|
| 0.1 | Enable X Voice, open OmniTAK | `[NativePTT] joined channel` → `channel manager ready`; X Voice channel on the lock screen / Dynamic Island |
| 0.2 | Lock the phone, press the system Talk button | iOS start cue, `transmit began`, `audio session ACTIVATED`, `TRANSMITTING on slot 1` |
| 0.3 | Leave the channel from the system UI | Voice stops |

## 1. iPhone's own mic

| # | Do | Expect |
|---|----|--------|
| 1.1 | Mic mode Standard: press on-screen PTT 1, stay silent 1 s, talk | `audio on — built-in mic (mic mode chosen Standard, active Standard), skipping the first 750 ms`; the listener doesn't hear the start buzz |
| 1.2 | X Voice → Audio levels → *Set mic mode to Voice Isolation…*, pick it | Row shows *Voice Isolation*, orange prompt gone |
| 1.3 | Press again | `audio on — transmitting immediately (… built-in mic, Voice Isolation)`; no start buzz |

## 2. Inrico BT02 speaker-mic

| # | Do | Expect |
|---|----|--------|
| 2.1 | Pair it in iOS Settings → Bluetooth, launch | `[BLEPTT] … auto-connecting` → `connected B02PTT-…` |
| 2.2 | Hold PTT, talk right after the vibration | `audio on — transmitting immediately (… Bluetooth)`; first word not lost |
| 2.3 | Have someone talk while idle | First words kept (buffered while the link wakes); back to standby ~8 s after they stop |
| 2.4 | Emergency key, ~2 s hold (warn the team first!) | `emergency released — FIRE` → `[VoiceHostBridge] emergency START`; one quiet cue in the speaker-mic; second press: `already active — no cue` |
| 2.5 | Top button | `speaker-mic button 0x03 (unmapped)`; nothing happens |

## 3. AINA APTT (V1 / V2)

| # | Do | Expect |
|---|----|--------|
| 3.1 | Pair the audio in iOS Settings, launch | Auto-connects `APTT…`; `AINA CONFIG read 0x.. — writing 0x..` (or `already set`) |
| 3.2 | PTT 1 ×10, short and long | Every `TX mic level` has voice. Mute flips are undone (`unmuted the system input`) |
| 3.3 | Secondary PTT (with a PTT 2 channel) | Transmits on slot 2 |
| 3.4 | Emergency short press / 1 s hold | Fires / cancels the alert |
| 3.5 | Turn the AINA off while holding PTT | TX stops, never stuck |

## 4. Pryme BT-PTT-Z

| # | Do | Expect |
|---|----|--------|
| 4.1 | Not paired in iOS Settings; turn it on; first time: Scan for PTT buttons → tap `PTT-Z` | `connected PTT-Z`; settings show *Talks on: PTT 1 only*. Relaunch: reconnects by itself |
| 4.1b | *Forget button*, then bring the app to the foreground a few times | Stays disconnected until picked from the scan list again |
| 4.2 | Press ×4 | Each transmits on slot 1 with voice |
| 4.3 | If the scan shows `DfuTarg` | Firmware-update mode: power-cycle without holding a button |

## 5. Channels, dual PTT and full duplex

- Channels → PTT 1 / PTT 2: search works; the other slot's channel shows *In use by PTT n* and can't be picked.
- PTT 2 appears on the map only after a second channel is picked; *Off* removes it.
- Hold PTT 1 and press PTT 2: only slot 1 transmits.
- While someone talks on channel 2, transmit on channel 1: you keep hearing them at 25%; they're at full level when you talk on channel 2.
- Talk over someone, release, press again at once, several times: every press gets audio (no `waiting for the system to activate audio` that never ends).

## 6. Robustness

| # | Do | Expect |
|---|----|--------|
| 6.1 | Hold PTT past the time limit (default 30 s) | Warning at 25 s, cutoff at 30 s; release and press again to talk |
| 6.2 | Phone call / Siri during voice use | PTT works again afterwards |
| 6.3 | Connect/disconnect a Bluetooth headset mid-session | Route follows; mic keeps working |
| 6.4 | Lock the phone for several minutes, have someone talk | Audio plays |
| 6.5 | Toggle Wi-Fi off/on | Slot 1 reconnects first, slot 2 follows; channel choices kept |

## Known gaps

- AINA V1's Classic SPP channel isn't used (needs MFi); V1 works over BLE.
