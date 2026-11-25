# How X Voice works (iOS)

Back to [X Voice overview](README.md). For the design reasoning shared with
Android, see [TAK-XVoice Design Decisions](https://tx-tak.github.io/TAK-XVoice/design-decisions/).

This page describes the `voice-native-ptt` edition. Code lives in
`OmniTAKMobile/Features/Voice/`.

## Pieces

| Component | File | Job |
|---|---|---|
| Plugin | `Plugin/VoicePlugin.swift` | Registers the map overlay and settings row; settings screen |
| Controller | `VoiceController.swift` | Slot rules, PTT state machine, emergency, glue between everything |
| Apple push-to-talk bridge | `NativePTT/NativePTTManager.swift` | The system PTT channel, transmit requests, audio activation callbacks |
| Audio engine | `Audio/VoiceAudioEngine.swift` | Mic capture, Opus encode/decode, playback, ducking, idle release |
| Mumble client | `Mumble/MumbleClient.swift` | TLS + certificate auth, channels, voice over UDPTunnel. One per slot |
| Bluetooth buttons | `Bluetooth/BLEPTTManager.swift` | Scan, connect and decode AINA, Inrico and Pryme buttons |
| On-map buttons | `UI/VoicePTTOverlay.swift` | PTT 1 / PTT 2 buttons and the who's-talking labels |

The plugin's id is `com.atakmap.android.xv.plugin`, the same as the Android
plugin, so enable state and settings keys line up across platforms.

## Apple's PushToTalk framework

X Voice joins one system push-to-talk channel that represents both slots. iOS
owns three things:

1. **The UI.** Lock screen, Dynamic Island and the system Talk button (which
   keys PTT 1).
2. **The audio session.** X Voice never activates the session itself. It asks
   iOS to start a transmission (`requestBeginTransmitting`) or names an
   incoming talker (`setActiveRemoteParticipant`), and iOS activates audio
   (`didActivate`). X Voice builds its audio engine then, and tears it down on
   `didDeactivate`.
3. **The cues.** iOS plays the start/end sounds and vibration. X Voice plays
   no talk-permit tone.

The channel is set to **full duplex**, so incoming audio keeps playing while
you transmit.

## A transmission, step by step

1. **Press.** A Bluetooth button event, the on-map button, or the system Talk
   button.
2. **Acquiring.** X Voice asks iOS to begin transmitting; iOS confirms
   (`didBeginTransmitting`) and plays its start cue.
3. **Audio on.** iOS activates the audio session. A new audio engine starts.
   On a Bluetooth speaker-mic this takes about 0.3–0.5 s, the time for the
   Bluetooth voice link to come up.
4. **Transmitting.** Mic audio is encoded (Opus, 48 kHz, 20 ms frames) and
   sent to the slot's Mumble connection.
   - Bluetooth speaker-mic: sent from the first moment audio is available.
   - iPhone's own mic with **Voice Isolation** active: sent from the first
     moment too. Voice Isolation removes iOS's start cue completely (measured:
     the first 0.8 s stays at −90 to −185 dBFS).
   - iPhone's own mic in Standard or Wide Spectrum: the first 0.75 s after
     audio comes on is dropped. iOS plays its start cue (sound and vibration)
     as the audio activates, and the built-in mic picks it up: measured as a
     flat buzz of about −30 dBFS from roughly 0.1 s to 0.55–0.7 s after the
     mic starts. The mode iOS is *actually* using decides, since iOS sometimes
     runs Standard despite a Voice Isolation choice.
5. **Release.** The last 60 ms (3 frames) are dropped to cut the button click,
   a terminator packet ends the stream, and iOS plays its end cue.
6. **Idle.** After 5 s with no transmit and 8 s with nothing received, X Voice
   tells iOS it's done and iOS releases the audio.

## Receiving

- Received audio for a slot is decoded and played through that slot's mixer.
- If audio arrives while the engine is in standby, X Voice holds up to 4 s of
  it, names the talker to iOS, and plays the held audio once iOS activates the
  session. The first words aren't lost.
- X Voice names the talker on **any** received audio, also while you're
  transmitting. Otherwise iOS drops the session at release and a new request
  races the shutdown.
- If iOS hasn't activated audio 2 s after a request, X Voice resets the talker
  so the next press or packet starts clean.

## Voice processing and mic mode

On the iPhone's own mic and speaker, X Voice turns on Apple's voice processing
(`setVoiceProcessingEnabled`): echo cancellation, noise suppression and
automatic gain, the iOS equivalent of Android's AcousticEchoCanceler,
NoiseSuppressor and AGC. On a Bluetooth HFP speaker-mic it stays off: the
speaker-mic handles echo itself, skipping it saves engine start-up time, and
its AGC was pulling levels down.

With voice processing on, iOS applies the user's **mic mode** (Standard /
Voice Isolation / Wide Spectrum). There's no public API for an app to set the
mode, even in iOS 26; apps can read `AVCaptureDevice.activeMicrophoneMode` and
open the picker with `AVCaptureDevice.showSystemUserInterface(.microphoneModes)`.
X Voice recommends Voice Isolation and logs the active mode with each
built-in-mic transmission.

Standard voice processing can't remove iOS's push-to-talk start cue: the
start sound isn't something the app played, so it isn't in the echo
canceller's reference, and the vibration reaches the mic through the phone's
body. Voice Isolation does remove it, so X Voice drops the first 0.75 s after
audio-on only when Voice Isolation isn't active (see above).

## Ducking

While you transmit on one slot, the **other** slot's received audio is set to
25% (−12 dB). The slot you're talking on stays at full level.

## The system mic mute

iOS has a system-wide mic mute for call-style audio (iOS 17+). It flips
around push-to-talk transmissions and on some headset button presses (the
AINA's, for one). When it's on, the mic delivers digital silence. X Voice
un-mutes it at the start of every transmission and again if a mute lands
mid-transmission.

## Slots

- Slot 1 (VS1) always exists while the plugin is on and has priority.
- Slot 2 (VS2) is off until a second channel is picked, connects after slot 1
  has settled, and goes down with slot 1.
- The slots never share a channel. If the server puts them together anyway,
  PTT 2 falls back to slot 1 and duplicate audio is dropped.
- Slot 2 failures stay local: a short retry ladder (3 s, 8 s), then it stays
  down.
- Within a slot, PTT is an OR over sources (on-screen, Bluetooth, system).

## Bluetooth buttons

X Voice uses CoreBluetooth with the `bluetooth-central` background mode, so
button presses reach it in the background and with the phone locked, and iOS
lets it begin a transmission from them.

Three things keep that working with the phone locked:

- **The `audio` background mode**, alongside `push-to-talk`. Without it iOS
  begins the transmission but never turns the microphone on.
- **Background location.** OmniTAK's background location updates are what
  keep the app, and its connection to the voice server, running while it is
  not on screen. With location denied or off, iOS suspends the app and voice
  stops until OmniTAK is opened again.
- **Bluetooth state restoration.** If iOS ends the app in the background, a
  press on the saved device relaunches it and hands the connection back.
  That first press only wakes the app; voice reconnects a few seconds later.

Scanning in the background only finds devices that advertise a known service
(AINA V2, Inrico BT02, Pryme). An AINA V1 advertises none, so the first time
it is used OmniTAK has to be on screen. Reconnecting a saved device does not
need a scan.

| Device | Service / characteristic | Decoding |
|---|---|---|
| AINA APTT V1/V2 | `127FACE1-…` / button `127FBEEF-…`, config `127FDEAF-…` | Bitmask: `0x01` PTT 1, `0x04` PTT 2, `0x02` emergency |
| Inrico BT02 | `894C8042-…` | `0x01` down, `0x00` up, `0x08` emergency pulse; `0x02`–`0x04` other buttons (unmapped) |
| Pryme BT-PTT-Z | `FFE0` (or `00420000-…`) | Any non-zero byte = down, `0` = up |

On connect, X Voice ORs the AINA's two documented configuration bits into its
config byte: `0x20` (A2DP controls off) and `0x10` (phone controls off). The
AINA's other configuration bits are development-only and are never touched.

## Logging

Debug builds print to the console:

| Prefix | What |
|---|---|
| `[Voice]` | PTT state machine (ACQUIRING, TRANSMITTING), slots, emergency |
| `[VoiceAudio]` | Engine start/standby, TX burst stats, mic level, mute changes |
| `[NativePTT]` | Apple push-to-talk events: transmit began/ended, audio activated |
| `[Mumble VS1]` / `[Mumble VS2]` | Connection, channels, incoming streams |
| `[BLEPTT]` | Bluetooth scan, connect, button events, AINA config |
| `[VoiceHostBridge]` | Emergency alerts into OmniTAK |

Each transmission logs a summary like:

```text
[VoiceAudio] TX burst: 2.5s, frames 125, sent 122, ... 12484 bytes (40.4 kbps)
[VoiceAudio] TX mic level: during RX - | no RX 125 frames, voiced 19%, rms -28 dBFS, peak -14 dBFS
```

Normal speech is about −20 to −35 dBFS rms with some voiced %. A transmission
around −80 dBFS with 0% voiced sent silence. See
[Troubleshooting](troubleshooting.md).
