# Troubleshooting X Voice (iOS)

Back to [X Voice overview](README.md). Log prefixes and the per-transmission
summary are explained in [How it works → Logging](how-it-works.md#logging).

## Getting logs

In a debug build, launch OmniTAK from a Mac with the console attached:

```bash
xcrun devicectl device process launch --device <device-id> \
  --terminate-existing --console <bundle-id>
```

The log stops when OmniTAK is closed. The
[device test checklist](../X_VOICE_TESTING.md) has the full build-and-install
steps.

## Symptoms

### Nobody hears me, or only sometimes

Check the `TX mic level` line for the transmission:

- **Around −80 dBFS, voiced 0%:** the mic sent digital silence. The usual
  cause is iOS's system mic mute. You should see `system input mute changed →
  MUTED` and then `unmuted the system input`. If there's no un-mute line, the
  phone is older than iOS 17 or the fix isn't in the build.
- **Normal level, but the listener hears nothing:** check that you and the
  listener are in the same channel, and which slot you pressed. PTT 1 and
  PTT 2 go to different channels.
- **`burst ended during acquiring — nothing transmitted`:** you released
  before iOS started the audio. Hold until the start cue.

### Every press hangs and nothing is sent

`waiting for the system to activate audio` with no `audio session ACTIVATED`
after it. iOS never started the audio. Current builds recover after 2 s
(`system never activated audio … resetting the remote participant`), and the
next press works. If it doesn't recover, disconnect and reconnect X Voice.

### First word cut off

- Bluetooth speaker-mic: the link takes about 0.3–0.5 s to come up after the
  vibration. Start talking just after the cue.
- iPhone's own mic in Standard or Wide Spectrum mode: the first 0.75 s after
  audio comes on is dropped on purpose, so iOS's start cue (sound and
  vibration) isn't sent. Start talking once the cue has finished, or switch
  the mic mode to Voice Isolation (no drop needed). The log line
  `audio on — built-in mic (mic mode chosen …, active …)` shows which mode was
  in effect.

### I hear the other channel quietly while talking

That's ducking: while you talk on one channel, the other channel is turned
down to 25%. The channel you're talking on isn't ducked.

### Speaker-mic not connecting

- **Audio:** the speaker-mic must be paired and connected in iOS Settings →
  Bluetooth. *Audio route* in X Voice settings shows where audio is going.
- **Buttons:** look for `[BLEPTT] auto-connecting …` and `connected …`. A
  speaker-mic's buttons connect by themselves once iOS is using it for audio
  (make a first press on screen if they haven't yet); a standalone button
  needs one tap in *Scan for PTT buttons* the first time. X Voice connects to
  one button device at a time. *Forget button* stops it reconnecting until you
  pick it from the scan list again.
- AINA: `[BLEPTT] AINA CONFIG read 0x.. — writing 0x..` then `write OK` on
  connect is normal.

### Pryme button won't pair or reconnect

- Don't pair it in iOS Settings; forget it there if it's listed.
- If the scan shows **`DfuTarg`** with service `00001530-…` instead of
  `PTT-Z`, the button is stuck in firmware-update mode. Power-cycle it without
  holding any button.

### Bluetooth button presses go to the wrong channel

Bluetooth buttons talk on PTT 1 only. Use the on-screen PTT 2 button for the
second channel, or the AINA's secondary button.

### Emergency key does nothing

OmniTAK must be running. Look for `[Voice] emergency released — FIRE` and
`[VoiceHostBridge] emergency START`. An alert that's already active doesn't
replay its cue.

### The volume keeps changing

iOS keeps separate volumes for media and for calls. While voice is active, the
volume buttons set the call / speaker-mic volume, so the level jumps when
audio switches between the two. That's iOS, not X Voice.

### Audio stuck on the speaker-mic, or it hisses

X Voice releases the audio 5 s after you stop transmitting and 8 s after the
last incoming audio (`idle … releasing the session`). If it doesn't, check for
a stuck press: a `pttDown` with no matching `pttUp`.
