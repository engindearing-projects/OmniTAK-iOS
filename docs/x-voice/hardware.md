# X Voice hardware (iOS)

Back to [X Voice overview](README.md). Android device pages, with more detail
on each device: [TAK-XVoice Supported Hardware](https://tx-tak.github.io/TAK-XVoice/hardware/).

## How Bluetooth hardware works on iOS

A Bluetooth speaker-mic has two separate parts:

1. **Audio:** the speaker and mic, over classic Bluetooth (HFP). You pair this
   in **iOS Settings → Bluetooth**, like a headset. X Voice uses it
   automatically whenever it's connected.
2. **Buttons:** PTT, secondary PTT and emergency, over Bluetooth LE. X Voice
   connects to these **directly**: you don't pair them in iOS Settings.
   X Voice scans for supported buttons and connects to the first one it
   finds, and to the saved one after that.

A standalone button (Pryme) has only the second part. Your voice then uses
whatever audio route is active (the iPhone's own mic and speaker, or a headset).

**Bluetooth buttons talk on PTT 1 only.** The AINA's secondary button is the
one exception: it keys PTT 2.

**One button device at a time.** X Voice connects to one Bluetooth button
device. With an AINA connected, a separate Pryme button won't also connect.
(Android has a separate External Button slot for this; iOS doesn't yet.)

## Supported devices

| Device | Audio | Buttons on iOS | Notes |
|---|---|---|---|
| **AINA APTT V2** | HFP (pair in iOS Settings) | PTT → PTT 1, secondary → PTT 2, emergency | Recommended |
| **AINA APTT V1** | HFP (pair in iOS Settings) | Same as V2, through its BLE button service | Its Classic SPP button channel needs Apple MFi, so iOS uses BLE |
| **Inrico BT02** | HFP (pair in iOS Settings) | PTT → PTT 1, emergency (2 s hold) | Budget / experimental. Top button unmapped. Mic gets +5 dB automatically |
| **Pryme BT-PTT-Z** | None (button only) | PTT → PTT 1 | Don't pair it in iOS Settings |

### AINA APTT (V1 / V2)

1. Pair the AINA in **iOS Settings → Bluetooth** (this is its audio).
2. Open OmniTAK. X Voice finds the AINA's buttons (`APTT…`) and connects.
3. On connect, X Voice sets two documented options in the AINA's
   configuration: *music controls off* and *phone controls off*, so its
   buttons don't also act as media or call buttons. Nothing else is changed.

Buttons: main PTT → PTT 1, secondary PTT → PTT 2, emergency: short press
raises the alert, 1 s hold cancels it.

### Inrico BT02

1. Pair `B02PTT-…` in **iOS Settings → Bluetooth** (audio).
2. Open OmniTAK. X Voice connects to the BT02's button service on its own.

Buttons: PTT → PTT 1; emergency fires after about a 2 s hold and can only be
cancelled from OmniTAK. The top and side buttons are not mapped. See the
[Android BT02 page](https://tx-tak.github.io/TAK-XVoice/hardware/inrico-bt02/).

### Pryme BT-PTT-Z

1. **Don't pair it in iOS Settings.** If it's listed there, tap ⓘ → *Forget
   This Device*.
2. Turn it on near the phone with OmniTAK open. X Voice connects to `PTT-Z` on
   its own.

PTT → PTT 1. See the
[Android Pryme page](https://tx-tak.github.io/TAK-XVoice/hardware/pryme-bt-ptt-z/).

**If it shows up as "DfuTarg":** the button is in firmware-update (bootloader)
mode and won't connect as itself. Turn it off (or remove the battery for 10 s)
and back on **without holding any button**. If it keeps coming back as
DfuTarg, the firmware may need reloading through Pryme.

## What doesn't work on iOS, and why

- **Buttons that pair as a keyboard or media remote** (selfie remotes, most
  "media" buttons). iOS keeps these to itself: apps can't read them over
  Bluetooth, and their presses only reach an app on screen as volume or
  play/pause, not in the background or locked. Not usable for PTT.
- **Headset play/pause as PTT.** Apple's PushToTalk can map a classic
  headset's media buttons to talk start and stop
  (`setAccessoryButtonEventsEnabled`, iOS 17), but Apple has disabled
  *starting* a transmission from a headset's Play command (car stereos send
  Play on connect). Only "stop" is reliable, so this isn't a PTT button.
  Apple's guidance for Bluetooth LE PTT buttons is to connect to them with
  CoreBluetooth, which is what X Voice does.
- **AINA V1's Classic SPP channel.** It needs Apple MFi certification. V1
  still works through BLE.
- **Samsung Active Key, Sonim XP10 keys.** Android hardware.

## Adding a new button

A Bluetooth LE PTT button can be supported if it reports presses over a GATT
characteristic (most dedicated PTT buttons do). To add one, X Voice needs the
button's advertised name or service, the characteristic that reports presses,
and the press/release values. The `[BLEPTT] scan:` log lines list every nearby
advertiser, and the code in
`OmniTAKMobile/Features/Voice/Bluetooth/BLEPTTManager.swift` shows how the
supported devices are decoded.
