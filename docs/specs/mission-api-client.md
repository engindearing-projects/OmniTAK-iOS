# Mission API Client — research + spec

**Issue:** [#14 SAR: Mission/data-sync creation flow from device](https://github.com/jfuginay/OmniTAK-iOS/issues/14)
**Source:** K9Blue SAR feedback (Discord, 5/10/26)
**Author:** Engie
**Status:** Draft — backing skeleton + failing-then-green test landed in
this session; UI + wire-format hardening to follow.

## TL;DR

OTS and TAK Server CIV both expose the same Marti Mission API
(`/Marti/api/missions/*`) gated behind 8089 mTLS — the auth posture we
already use for streaming CoT. Creating a mission is `PUT
/Marti/api/missions/{name}` with query-string metadata; attaching a
data-package is a two-step "upload then add by hash" dance:

1. `POST /Marti/sync/missionupload` (multipart) — returns the SHA-256
   `Hash` of the stored package.
2. `PUT /Marti/api/missions/{name}/contents` — JSON body referencing
   `{"hashes": ["..."]}` to attach to the mission.

Peer EUDs (Android/ATAK) discover the mission via the mission listener
push, then pull contents via `/Marti/sync/content?hash=...`.

## Background — what exists today

| Layer | File | State |
|---|---|---|
| KML export | `Features/Mission/MissionExporter.swift` | Done (ships in 2.18.0) |
| Data package zip | `Features/DataPackages/Managers/DataPackageManager.swift` → `exportPackage(...)` | Returns `PackageExportResult` with a `.zip` URL |
| HTTP scaffold | `Features/Networking/Services/TAKRestAPIClient.swift` | Has `getMissions`, `getMission`, `subscribeMission`, `uploadDataPackage`. **Orphaned** — not yet in xcodeproj sources |
| Sync framework | `Features/DataPackages/Services/MissionPackageSyncService.swift` | Generic queue/network state. Not wired to real endpoints |
| Settings UI | `Features/Settings/Views/SettingsView.swift` — `Section("MISSION")` | Exports KML only, no create flow |

The wire-format work has been started but never connected. This spec
fills the gap.

## OTS / TAK Server Marti Mission API

Both [OpenTAKServer](https://github.com/brian7704/OpenTAKServer) (Apache
2.0) and TAK Server CIV implement the Marti Mission Sync API. From the
OTS source under `opentakserver/blueprints/marti/` and the published
TAK Server CIV docs, the endpoints we need are:

### Create / update a mission

```
PUT  /Marti/api/missions/{missionName}
       ?creatorUid={UID}
       &description={text}
       &chatRoom={chatRoomUid}      (optional)
       &baseLayer={layerName}       (optional)
       &bbox={minLat,minLon,maxLat,maxLon}  (optional)
       &boundingPolygon={lat lon, lat lon ...}  (optional)
       &path={subpath}              (optional)
       &classification={text}       (optional)
       &tool={public|vbm|...}       (defaults to "public")
       &group={group}               (repeat for multi-group, defaults __ANON__)
       &defaultRole={MISSION_OWNER|MISSION_SUBSCRIBER|...}
       &inviteOnly={true|false}
       &allowDupe={true|false}
Headers:
       MissionAuthorization: {token}   (only if password-protected)
Body:  empty (TAK Server CIV) or empty JSON `{}`
Returns: 200/201 JSON envelope with the created mission record
         400 if name collides and allowDupe is false
```

OTS notes (from `opentakserver/blueprints/marti/missions.py`):
- mission names are case-insensitive; uppercased server side
- description and chatRoom go in query string, not body — historical
  Marti shape, not REST-tasteful but it's what every TAK client speaks

### Add contents (data packages, CoT) to a mission

Two flows. OmniTAK will use **(B)** because we already build a `.zip`.

**(A) Inline CoT add:**
```
PUT  /Marti/api/missions/{missionName}/contents
Body (JSON): {
  "uids": ["{cot-uid-1}", "{cot-uid-2}"],
  "hashes": []
}
```

**(B) File-by-hash add:**
```
PUT  /Marti/api/missions/{missionName}/contents
Body (JSON): {
  "hashes": ["{sha256-of-zip}"]
}
```

The hash must already exist in the sync DB — i.e. the package must be
uploaded first. Hence the two-step:

```
1. POST /Marti/sync/missionupload
        ?creatorUid={UID}
        &hash={sha256}              (optional pre-computed; server recomputes)
        &filename={name}.zip
   Content-Type: multipart/form-data
   Form field: assetfile = <zip bytes>
   Returns: 200 OK, body = plain-text URL ending in `?hash={sha}`
            (we parse the hash from this)

2. PUT  /Marti/api/missions/{missionName}/contents
   { "hashes": ["{sha}"] }
```

`TAKRestAPIClient.uploadDataPackage` already builds the multipart body
in (1); we add a thin `addContentsToMission` for (2).

### List / get missions

```
GET  /Marti/api/missions
GET  /Marti/api/missions/{name}
       Header: MissionPassword: {pw}  (if protected)
```

Both implemented in `TAKRestAPIClient.getMissions` / `getMission`.

### Subscribe (peer EUDs to a mission)

```
PUT    /Marti/api/missions/{name}/subscription?uid={eudUid}
DELETE /Marti/api/missions/{name}/subscription?uid={eudUid}
```

Already implemented.

## TAK Server CIV differences vs OTS

| Behaviour | OTS | TAK Server CIV |
|---|---|---|
| Auth (mTLS via 8089) | ✓ | ✓ |
| Path = `/Marti/api/missions/...` | ✓ | ✓ |
| `tool` query param | accepts `public` and a few custom values | strict whitelist (`public`, `vbm`, `mission`); rejects unknown with 400 |
| `boundingPolygon` query param | optional | optional but logged warn |
| Default group when omitted | `__ANON__` | `__ANON__` |
| Response envelope | `{ version, type, data: [...] }` | identical |
| Mission listener push (over CoT) | Uses `t-x-m-c` mission change CoT | Same `t-x-m-c` family |
| Empty body on PUT create | accepts | accepts |

So one client works for both. The only place we'd ever branch is if a
user picks a CIV-only tool value — which we wouldn't expose for a SAR
flow.

## Auth — already solved

OmniTAK already uses port-8089 streaming with client mTLS via
`TAKAPIURLSessionDelegate` in `TAKRestAPIClient.swift`. The cert posture
is documented in `[[project_omnitak_tak57_mtls]]` and the OTS interop
notes in `[[project_omnitak_ots_interop]]`.

For the REST endpoints we use port **8443** (HTTPS w/ optional client
cert). The same `CertificateManager` identity that authorises the CoT
stream authorises the mission API call, so a user who has connected to
the server is already authenticated for mission create. No new auth
flow needed.

If the server is configured for password-only missions (TAK Server CIV
"password-protected mission" mode), we send `MissionAuthorization:` /
`MissionPassword:` headers — modelled in `getMission`. For SAR, we
default to mTLS-only / no password.

## Data package format

`DataPackageManager.exportPackage` writes:

```
{name}_{version}.zip
├── manifest.json     ← our own format
├── overlays/         ← KML files from KMLOverlayManager
└── configs/
    └── app_settings.json
```

This is **not yet** a Marti MANIFEST. The TAK ecosystem expects a
`MANIFEST/manifest.xml` Marti envelope:

```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>
<MissionPackageManifest version="2">
  <Configuration>
    <Parameter name="uid"    value="{package-uid}"/>
    <Parameter name="name"   value="{display-name}"/>
    <Parameter name="onReceiveImport" value="true"/>
    <Parameter name="onReceiveDelete" value="false"/>
  </Configuration>
  <Contents>
    <Content zipEntry="overlays/search-area.kml" ignore="false">
      <Parameter name="contentType" value="KML"/>
    </Content>
    <Content zipEntry="sa.cot" ignore="false">
      <Parameter name="contentType" value="COT"/>
    </Content>
  </Contents>
</MissionPackageManifest>
```

ATAK / iTAK / TAKAware all reject packages that lack this manifest.
**Follow-up work:** extend `DataPackageManager.exportPackage` (or wrap
it) to emit a Marti manifest in addition to our internal manifest.json.
For this session the `MissionAPIClient` accepts an arbitrary `.zip`,
but the documented user flow assumes Marti-shaped packages.

## Proposed Swift surface

```swift
public protocol MissionAPIClient {
    func getMissions() async throws -> [TAKMissionInfo]

    /// PUT /Marti/api/missions/{name}
    @discardableResult
    func createMission(
        name: String,
        creatorUid: String,
        description: String?,
        tool: String,
        groups: [String],
        defaultRole: String?,
        bbox: MissionBoundingBox?
    ) async throws -> TAKMissionInfo

    /// POST /Marti/sync/missionupload  +
    /// PUT  /Marti/api/missions/{name}/contents
    @discardableResult
    func addContentsToMission(
        missionName: String,
        packageURL: URL,
        creatorUid: String
    ) async throws -> String   // returns sha-256 hash attached
}
```

A `URLProtocol`-based stub backs the unit test so we don't depend on a
live TAK server.

## Deferred to next session

- Marti MANIFEST emitter (`MissionPackageManifestBuilder`)
- Wire-up "Publish" button to real `createMission` + `addContentsToMission`
- `Publish` progress UI + retry on transient failure
- Member-picker (`uids[]` from contacts roster)
- Subscribe-other-EUDs flow (already have `subscribeMission`)
- TAK Server CIV `tool=vbm` whitelist exposure (advanced setting only)
- E2E integration test against the local TAK 5.7 docker box
  (`[[project_omnitak_tak57_mtls]]`)
- Android parity issue on OmniTAK-Android
