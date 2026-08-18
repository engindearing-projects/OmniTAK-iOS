# OmniTAK iOS 2.40.0

Off-grid mesh takes a big step forward, plus situational-awareness and UI polish
driven by closed-test feedback. This train has been sitting built on `main` since
late June, this is the release that gets it to testers.

## Mesh & Meshtastic
- **Dropped markers now share over the mesh.** Points you drop on the map propagate
  to other OmniTAK devices over Meshtastic/MeshCore, not just self-position and
  chat. True off-grid marker sharing, no TAK server required. (#100)
- **In-app Meshtastic settings.** Manage the connected radio from OmniTAK: view,
  create, and share channels (QR), set broadcast interval, role, and rebroadcast
  scope, the stock Meshtastic app is no longer required to provision a radio. (#101)
- **Standard TAKPacket V2 interop.** Encodes CoT as standard TAKPacket for
  interoperability with ATAK's Meshtastic plugin.
- **Meshtastic connect no longer hangs.** Connecting to a radio times out cleanly
  and returns to a retryable state instead of sticking on "Connecting."

## Situational awareness
- **CoT point age + data source.** See how old a contact's position is, and whether
  it arrived via the TAK server or the mesh, so stale info doesn't get taken for
  current.

## UI
- **Landscape map chrome.** The toolbar no longer consumes most of the map in
  landscape (plate-carrier orientation).

## Fixes
- **Certificate enrollment parses `/Marti/api/tls/config` order-independently.**
  The config is now read with a real XML parser instead of an order-sensitive
  regex, so servers that emit `<nameEntry>` attributes in any order (e.g.
  `value="..." name="O"`) enroll with the correct subject DN. Thanks to @rick51231
  for the report. (#102)

---
*Build cut from `main`. Marketing version 2.40.0; build number stamped by
`scripts/release-ios.sh` at archive time.*
