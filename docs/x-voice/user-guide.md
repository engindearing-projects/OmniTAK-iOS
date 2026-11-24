# X Voice user guide (iOS)

Back to [X Voice overview](README.md). For the Android plugin, see the
[TAK-XVoice User Setup](https://tx-tak.github.io/TAK-XVoice/user-setup/).

## Before you start

- OmniTAK is enrolled with your TAK server (X Voice signs in to the voice
  server with the same client certificate).
- Your TAK server has a Mumble voice server on the same hostname, port 64738.
  See [Server & channels](server-and-channels.md).
- iOS 17 or later is recommended. X Voice needs iOS 16 for Apple's
  push-to-talk system; the fix that keeps a muted mic from silencing your
  transmissions needs iOS 17.

## Turning it on

1. Enable the **X Voice** plugin in OmniTAK's plugin settings.
2. Allow **Microphone** access when iOS asks. (Settings shows the current
   state under *Connection → Microphone*.)
3. X Voice connects on its own. The **X Voice** item in the bottom toolbar
   opens its settings over the map.
4. iOS adds an **X Voice** push-to-talk channel to the system: you'll see it
   on the lock screen and in the Dynamic Island while voice is active.

The on-map **PTT 1** button appears as soon as the plugin is on. **PTT 2**
appears once you pick a second channel.

## Channels: PTT 1 and PTT 2

X Voice keeps two voice connections, called slots:

| | PTT 1 (slot 1, VS1) | PTT 2 (slot 2, VS2) |
|---|---|---|
| Purpose | Your primary channel | An optional second channel |
| Always on? | Yes, while the plugin is on | Off until you pick a channel |
| Bluetooth buttons | Yes | Only the AINA's secondary button |
| iOS system Talk button | Yes | No |

Pick channels in **X Voice → Channels**. The list is searchable. "Lobby" is
the server's root channel.

Rules:

- **The two slots never share a channel.** A channel used by the other slot is
  shown as *In use by PTT n* and can't be picked.
- PTT 2 connects only after PTT 1 is connected and settled in its channel. If
  PTT 1 drops, PTT 2 drops with it and comes back with it.
- Choose **Off** in the PTT 2 list to turn the second channel off.
- Your channel picks are remembered.

## Talking

- **Hold to talk, release to stop.** Use the on-map PTT 1 / PTT 2 buttons, a
  Bluetooth speaker-mic or button, or the system **Talk** button on the lock
  screen or Dynamic Island (always PTT 1).
- **Wait for iOS's start cue** (the vibration and sound) to finish, then
  speak. On the iPhone's own mic, the first 0.75 s after audio comes on is
  dropped on purpose so the cue isn't sent. On a Bluetooth speaker-mic, audio
  is sent from the moment it's available.
- **One mic, one channel at a time.** If you press both, the first press wins.
- **Full duplex.** Others keep playing while you talk. The channel you're
  talking on stays at full volume; the *other* channel is ducked to 25% until
  you release.
- **Who's talking** shows in green above the PTT buttons and in the iOS
  push-to-talk UI.
- With nothing heard or sent for a few seconds, X Voice hands the audio back to
  iOS. Your speaker-mic stops hissing and music and other apps play normally.

### Bluetooth buttons talk on PTT 1 only

Every Bluetooth button and speaker-mic PTT key talks on **PTT 1** (voice
slot 1). They never key PTT 2: use the on-screen PTT 2 button for the second
channel. The one exception is the **AINA's secondary PTT button**, which keys
PTT 2. The Bluetooth button screen shows this under **Talks on**.

## Settings reference

Open **X Voice** from the bottom toolbar or OmniTAK's plugin settings.

### Connection

| Item | Meaning |
|---|---|
| Slot 1 (VS1) / Slot 2 (VS2) | Connection state of each voice slot |
| Microphone | Microphone permission |
| Connect / Reconnect / Disconnect | Start, restart or stop voice |

### Channels

PTT 1 and PTT 2 channel pickers (see above).

### Tones

| Setting | Default | Meaning |
|---|---|---|
| Status tones | Off | Extra cues for channel join/leave and voice loss. iOS's push-to-talk UI already shows these, so they're off by default. |
| Transmit time limit | 30 s | Warns 5 s before cutting off a held PTT. Off, 30 s, 60 s, 2 min or 3 min. |

iOS plays its own push-to-talk start and end sounds and vibration. X Voice
doesn't add a talk-permit tone (that's an Android feature).

### On-screen controls

**Side**: put the PTT buttons on the right (default) or left edge of the map.

### Bluetooth PTT button

| Item | Meaning |
|---|---|
| Button | The connected button or speaker-mic |
| Talks on | *PTT 1 only*, or *PTT 1 (secondary button: PTT 2)* for an AINA |
| Status | Scanning, connecting, connected… |
| Scan for PTT buttons | Lists supported buttons nearby; tap one to connect |
| Forget button | Stops auto-connecting to the saved button |

See [Hardware](hardware.md) for pairing each device.

### Audio levels

| Setting | Default | Meaning |
|---|---|---|
| Mic boost | +3 dB | Extra gain on your transmitted voice, with a soft limiter |
| Receive boost | +6 dB | Extra gain on what you hear |

An Inrico BT02 gets an automatic extra +5 dB on its mic. On the iPhone's own
mic and speaker, iOS echo cancellation, noise suppression and automatic gain
are on; on a Bluetooth speaker-mic they're off (the speaker-mic handles echo).
While voice is active, the phone's volume buttons set the speaker-mic / call
volume, which is separate from your media volume.

### Audio route

Shows where voice audio is going right now, for example
`APTT30CB1A (BluetoothHFP)` or `iPhone Microphone / Speaker`.

## Emergency

A speaker-mic's emergency key raises OmniTAK's 911 alert (the same alert as
OmniTAK's own emergency button), sent to your TAK server.

| Device | Raise the alert | Cancel it |
|---|---|---|
| AINA APTT | Short press | Hold 1 s |
| Inrico BT02 | Hold about 2 s | Only from OmniTAK's emergency screen (the BT02 can't cancel) |

- When the alert starts, a short, quiet cue plays in the speaker-mic. Pressing
  the key again while the alert is active doesn't replay it.
- The Inrico's top button does nothing (it's left unmapped on purpose).
- X Voice must be running: with OmniTAK closed, the emergency key does nothing.

**Warn your team before testing the emergency key.** It raises a real alert on
the server.

## Background and lock screen

- X Voice keeps working in the background and with the phone locked. Bluetooth
  buttons can start a transmission from the background.
- The lock screen and Dynamic Island show the X Voice channel, who's talking,
  and a **Talk** button (PTT 1).
- Leaving the X Voice channel from the system UI stops voice.
- iOS only lets X Voice join its system channel while OmniTAK is in the
  foreground, so open OmniTAK once after a restart.
