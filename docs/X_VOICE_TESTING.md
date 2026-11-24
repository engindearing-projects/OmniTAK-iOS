# X Voice (PTT) — device test checklist

Branch: `voice-track-a`. Dev build bundle ID: `com.txtak.omnitak` (passed on the
`xcodebuild` command line; the project keeps `com.engindearing.omnitak.mobile`).

## Load to the phone

```bash
cd ~/repos/OmniTAK-iOS
xcodebuild -project OmniTAK.xcodeproj -scheme OmniTAKMobile -configuration Debug \
  -destination 'id=00008020-00146C403A84002E' -derivedDataPath ~/repos/.derived-device \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=99U48C86XG CODE_SIGN_STYLE=Automatic \
  PRODUCT_BUNDLE_IDENTIFIER=com.txtak.omnitak build
xcrun devicectl device install app --device 00008020-00146C403A84002E \
  ~/repos/.derived-device/Build/Products/Debug-iphoneos/OmniTAK.app
# launch with the console log (Ctrl-C to stop):
xcrun devicectl device process launch --device 00008020-00146C403A84002E \
  --terminate-existing --console com.txtak.omnitak
```

Useful log prefixes: `[Voice]` (PTT state machine), `[VoiceAudio]` (engine,
standby/wake, TX bursts), `[Mumble VS1|VS2]`, `[BLEPTT]`, `[VoiceHostBridge]`.

## Silent automated self-test (no audio sent, tones muted)

```bash
xcrun devicectl device process launch --device 00008020-00146C403A84002E \
  --terminate-existing --console com.txtak.omnitak -- -XVoiceSelfTest YES -XVoiceToneGain 0
```

Expect five scenarios A–E: full bursts transmit; a release during PRIMING or
the tone transmits nothing (`burst ended during …`); E starts from standby
(`engine standby before E: true` → `ACQUIRING` → `PRIMING` → `TPT start` →
`TPT played back` → `TRANSMITTING`). **Check that in E, `TPT played back`
comes ~330–400 ms after `TPT start`, not in the same millisecond** (that bug
was fixed overnight; this run confirms it). No line should say `TONE LEAK`.

## 1. Inrico BT02 speaker-mic

| # | Do | Expect |
|---|----|--------|
| 1.1 | Pair it in iOS Settings → Bluetooth, launch the app | Log: `[BLEPTT] looking for the PTT button of 'B02PTT-…'` → `auto-connecting` → `connected` |
| 1.2 | Leave it idle 10 s | `[VoiceAudio] standby … engine stopped, audio session released`. **The speaker-mic should stop hissing.** |
| 1.3 | Press and hold PTT | `ACQUIRING` → `PRIMING (Bluetooth, cold)` → ~0.7 s hold → permit tone in the speaker-mic → `TRANSMITTING`. Listener hears you. |
| 1.4 | Have someone talk while idle | First words not lost (buffered while the link wakes); plays in the speaker-mic; back to standby ~8 s after they stop |
| 1.5 | Emergency key (warn the team first!) | `[Voice] emergency released … FIRE` → `[VoiceHostBridge] emergency START` → 911 alert on the TAK server. Cancel from OmniTAK's emergency screen (BT02 sends a pulse, so it can't cancel by holding) |

## 2. AINA APTT V2 (BLE)

| # | Do | Expect |
|---|----|--------|
| 2.1 | Pair the audio in iOS Settings → Bluetooth, launch | BLE button auto-connects by name (`APTT…`). If not: X Voice → Bluetooth PTT button → Scan → pick it |
| 2.2 | PTT | Transmits on PTT 1 (same sequence as 1.3) |
| 2.3 | Pick a second channel (X Voice → Channels → PTT 2), press PTTS | Transmits on slot 2 |
| 2.4 | Emergency short press | Fires the 911 alert |
| 2.5 | Emergency hold ≥ 1 s | Cancels the alert at the 1 s mark (low double tone) |
| 2.6 | Turn the AINA off while holding PTT | TX stops (never stuck) |

## 2b. AINA Voice Responder V1 (APTT1) — VERIFIED working (2026-11-24)

The V1 also exposes AINA's BLE button service (`127FACE1-…`), so it uses the
same path as V2 — no SPP needed. Verified on an iPhone XS Max with
`APTT30CB1A`: auto-connect by name, PTT → slot 1, PTTS → slot 2, standby and
cold wake. Still to check on the V1: emergency press (fire) and hold (cancel).

## 3. Channels and dual PTT

- X Voice (bottom toolbar) → Channels → PTT 1 / PTT 2: search works; the other slot's channel is greyed out and can't be picked.
- PTT 2 appears on the map only after a second channel is picked; "Off" removes it.
- Hold PTT 1 and press PTT 2: only slot 1 transmits.
- While transmitting on one slot, the other slot's incoming audio is quieter (ducked); the slot you talk on stays full.

## 4. Robustness

| # | Do | Expect |
|---|----|--------|
| 4.1 | Hold PTT 30 s | Warning double-beep at 25 s, cutoff tone at 30 s, TX stops; must release and press again. (X Voice → Tones → Transmit time limit) |
| 4.2 | Phone call / Siri during voice use | After it ends: `[VoiceAudio] rebuilding engine: interruption ended`; PTT works again |
| 4.3 | Connect/disconnect a Bluetooth headset mid-session | `rebuilding engine: audio route changed`; mic keeps working (`mic format now …`) |
| 4.4 | Lock the phone, have someone talk | Audio plays (background). Note: in standby the app relies on its location/Bluetooth background modes to stay alive — **verify RX still arrives after several minutes locked** |
| 4.5 | Toggle Wi-Fi off/on | Slot 1 reconnects first, slot 2 follows; channel choices kept |
| 4.6a | Status tones: change channel; turn PTT 2 off; kill Wi-Fi | Ascending chirp on join, descending on PTT 2 off, double beep when voice drops (mid-burst: cutoff tone). Toggle: X Voice → Tones → Status tones |
| 4.6 | Full duplex on the phone speaker | People talking while you transmit are heard, and they don't hear themselves echoed |

## Known gaps

- Private calls / VX call signaling — not ported.
- AINA V1: works over BLE (section 2b); its SPP channel is not used.
