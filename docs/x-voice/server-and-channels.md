# Server & channels

Back to [X Voice overview](README.md).

X Voice uses the same Mumble voice server as TAK-XVoice on Android, so the
server side is set up once for both. The full guide is the Android
**[Server & Channels](https://tx-tak.github.io/TAK-XVoice/server-setup/)**
page: host and port, TLS authentication, multiple TAK servers, and keeping
Mumble channels in sync with TAK Server groups.

## What X Voice on iOS expects

- **Host:** the same hostname as your standard TAK Server (Murmur does not have
  to run on the same machine, as long as it is reachable at that hostname).
- **Port:** 64738 (the standard Mumble port).
- **Sign-in:** mutual TLS using the same TAK Server enrollment certificate
  already on the device. There is no separate voice username or password.
- **Name on the server:** your callsign with spaces replaced by `_`, then
  `---`, a short device tag, and the slot: for example `ALPHA-1---1e374fVS1`
  and `ALPHA-1---1e374fVS2`. Other X Voice clients show only the callsign.
  This matches TAK-XVoice, so users can see which device and slot is talking.

## Channels

- Each slot (PTT 1, PTT 2) joins one channel. The root channel is shown as
  **Lobby**.
- The two slots never share a channel.
- A channel you can listen to but not speak in (suppressed) can't be
  transmitted on.
- Channel picks are saved and rejoined on the next connect.

For organising channels around TAK Server groups, see the Android guide's
[Channel Management section](https://tx-tak.github.io/TAK-XVoice/server-setup/#channel-management-tak-group-synchronization).
