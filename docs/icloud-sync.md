# iCloud Sync

Design and implementation plan for syncing caddie data across a user's Macs via
iCloud. Favorites and recents sync through **SwiftData + CloudKit**; overlay
settings sync through **iCloud Key-Value Storage (KVS)**; the OSM geometry cache
stays **local-only**.

## Table of Contents

- [iCloud Sync](#icloud-sync)
  - [Table of Contents](#table-of-contents)
  - [Overview](#overview)
  - [What Syncs and What Doesn't](#what-syncs-and-what-doesnt)
  - [Architecture](#architecture)
    - [Course data (CloudKit)](#course-data-cloudkit)
    - [Overlay settings (Key-Value Storage)](#overlay-settings-key-value-storage)
  - [Constraints and Gotchas](#constraints-and-gotchas)
  - [Implementation Plan](#implementation-plan)
    - [Phase 1 — Apple Developer setup](#phase-1--apple-developer-setup)
    - [Phase 2 — Entitlements and capabilities](#phase-2--entitlements-and-capabilities)
    - [Phase 3 — Model changes](#phase-3--model-changes)
    - [Phase 4 — Container split](#phase-4--container-split)
    - [Phase 5 — De-dupe safety net](#phase-5--de-dupe-safety-net)
    - [Phase 6 — Settings sync](#phase-6--settings-sync)
    - [Phase 7 — Verification](#phase-7--verification)
  - [Affected Files](#affected-files)
  - [Testing](#testing)
  - [Troubleshooting](#troubleshooting)
  - [Open Questions](#open-questions)

## Overview

The app persists three kinds of data today:

| Data | Model / store | Size | Re-derivable? |
| --- | --- | --- | --- |
| Favorited courses | `FavoriteCourse` (SwiftData) | Tiny | No |
| Recently viewed courses | `RecentCourse` (SwiftData) | Tiny | No |
| OSM course geometry cache | `OSMCourseData` (SwiftData) | Large (KB–MB blobs) | Yes — re-fetchable from Overpass |
| Overlay colors + visibility | `OverlaySettings` (`UserDefaults`) | Tiny | No |

The goal is for a user with more than one Mac to see the same favorites,
recents, and overlay styling everywhere, without paying iCloud quota for the
re-fetchable geometry cache.

## What Syncs and What Doesn't

- ✅ **`FavoriteCourse`** — synced via CloudKit private database.
- ✅ **`RecentCourse`** — synced via CloudKit private database.
- ✅ **`OverlaySettings`** (per-layer color + visibility) — synced via iCloud
  Key-Value Storage.
- ❌ **`OSMCourseData`** — stays local. It is large and fully re-fetchable, so
  syncing it would waste iCloud quota and bandwidth for zero user benefit.

## Architecture

### Course data (CloudKit)

`FavoriteCourse` and `RecentCourse` move into a CloudKit-backed
`ModelConfiguration`. `OSMCourseData` stays in a separate **local-only**
configuration within the same `ModelContainer`, so the cache never leaves the
device.

```text
ModelContainer
├── ModelConfiguration (cloudKitDatabase: .automatic)
│     ├── FavoriteCourse   → iCloud private DB
│     └── RecentCourse     → iCloud private DB
└── ModelConfiguration (cloudKitDatabase: .none)
      └── OSMCourseData     → local store only
```

SwiftData's CloudKit mirroring handles change tracking, push, and pull
automatically once the container is configured and the entitlements are in
place.

### Overlay settings (Key-Value Storage)

`OverlaySettings` is a handful of small string/bool keys — a perfect fit for
`NSUbiquitousKeyValueStore` rather than CloudKit records. The store keeps
writing to `UserDefaults` as a local cache, and additionally:

- Mirrors each `setColor` / `setVisible` / `resetToDefaults` write to the
  ubiquitous KVS.
- Observes `NSUbiquitousKeyValueStore.didChangeExternallyNotification` to merge
  changes pushed from another device, then notifies observers so the map
  re-renders.

```text
setColor/setVisible ──┬─▶ UserDefaults (local cache, instant read)
                      └─▶ NSUbiquitousKeyValueStore ──▶ iCloud KVS
                                                          │
   didChangeExternallyNotification ◀──────────────────────┘
                      └─▶ update in-memory overrides + redraw
```

## Constraints and Gotchas

These come from CloudKit's requirements on SwiftData models and **must** be
satisfied or the container will fail to load:

- **No `@Attribute(.unique)`.** CloudKit does not support unique constraints.
  All three models currently use it; it must be removed from the two synced
  models (`FavoriteCourse.identifier`, `RecentCourse.identifier`).
  `OSMCourseData` keeps its constraint because it stays in the local store.
- **Every stored property must be optional or have a default value.** The synced
  models' non-optional properties (name, address, coordinates, dates, …) each
  need a default.
- **No enforced uniqueness across devices.** Without `.unique`, two devices can
  independently create the same favorite/recent. We keep the existing
  fetch-by-identifier guards in `recordRecent` / `toggleFavorite` and add a
  launch-time de-dupe sweep as a backstop.
- **Schema deployment.** CloudKit auto-creates the schema in the Development
  environment. It must be **Deployed to Production** in the CloudKit Dashboard
  before notarized/distributed builds will sync.
- **Store migration.** Removing `.unique` triggers a lightweight SwiftData
  migration; verify existing local favorites/recents survive first launch.

## Implementation Plan

### Phase 1 — Apple Developer setup

1. Register the App ID `com.okjeffrey.caddie` with the **iCloud** capability.
2. Create a CloudKit container `iCloud.com.okjeffrey.caddie`.

### Phase 2 — Entitlements and capabilities

3. Add `caddie/caddie.entitlements` declaring:
   - `com.apple.developer.icloud-services` → `CloudKit`
   - `com.apple.developer.icloud-container-identifiers` →
     `iCloud.com.okjeffrey.caddie`
   - `com.apple.developer.ubiquity-kvstore-identifier` → `$(TeamIdentifierPrefix)com.okjeffrey.caddie`
   - `aps-environment` and background remote-notifications (for CloudKit push)
4. Wire `CODE_SIGN_ENTITLEMENTS` and the iCloud capability into
   `caddie.xcodeproj/project.pbxproj`.

### Phase 3 — Model changes

5. Remove `@Attribute(.unique)` from `RecentCourse.identifier` and
   `FavoriteCourse.identifier`. Leave `OSMCourseData` unchanged.
6. Give every stored property on `RecentCourse` and `FavoriteCourse` a default
   value (CloudKit requirement) — e.g. strings `= ""`, doubles `= 0`, dates
   `= .now`.

### Phase 4 — Container split

7. In `caddie/caddieApp.swift`, build the `ModelContainer` with two
   `ModelConfiguration`s: a CloudKit-backed config for `RecentCourse` +
   `FavoriteCourse`, and a `.none` local config for `OSMCourseData`.

### Phase 5 — De-dupe safety net

8. Add a launch-time de-dupe sweep: group `RecentCourse` and `FavoriteCourse`
   by `identifier`, keep the most recent per identifier, delete the rest. Run
   once from app init / a top-level `.task`.

### Phase 6 — Settings sync

9. Extend `OverlaySettings` to mirror writes to `NSUbiquitousKeyValueStore`
   alongside `UserDefaults`, observe
   `didChangeExternallyNotification`, merge remote values into the in-memory
   overrides, and trigger a redraw. Call `synchronize()` after batch writes.

### Phase 7 — Verification

10. Build with `./build.sh`, sign into the same iCloud account on two Macs, and
    confirm sync end to end (see [Testing](#testing)).

## Affected Files

| File | Change |
| --- | --- |
| `caddie/caddieApp.swift` | Split `ModelContainer` into synced + local configs |
| `caddie/ContentView.swift` | Remove `.unique`, add defaults on `RecentCourse`/`FavoriteCourse`; keep dedup guards; add launch de-dupe sweep |
| `caddie/OverlaySettings.swift` | Mirror to/from `NSUbiquitousKeyValueStore` |
| `caddie/caddie.entitlements` | **New** — iCloud + KVS entitlements |
| `caddie.xcodeproj/project.pbxproj` | `CODE_SIGN_ENTITLEMENTS` + iCloud capability |
| `docs/icloud-sync.md` | This document |

## Testing

1. **Build:** `./build.sh` succeeds and the app launches.
2. **Migration:** existing favorites/recents from before the change still appear
   on first launch.
3. **Favorites/recents sync:** favorite a course on Mac A → it appears on Mac B
   (and vice versa); same for recents.
4. **Settings sync:** change an overlay color/visibility on Mac A → it updates on
   Mac B.
5. **Cache stays local:** open a course on Mac A; confirm `OSMCourseData` does
   **not** appear in the CloudKit Dashboard and the cache is re-fetched (not
   synced) on Mac B.
6. **No duplicates:** favorite the same course on both Macs while offline, then
   reconnect; the de-dupe sweep collapses it to one entry.
7. **Schema:** confirm the expected record types in the CloudKit Dashboard
   (Development environment).

## Troubleshooting

- **Container fails to load / fatalError on launch:** almost always a leftover
  `@Attribute(.unique)` or a non-optional property without a default on a synced
  model.
- **Nothing syncs:** confirm both Macs are signed into the same iCloud account,
  iCloud Drive is enabled, and the entitlements/container identifier match the
  registered App ID.
- **Works in dev build but not in a distributed build:** the schema was never
  **Deployed to Production** in the CloudKit Dashboard.
- **Settings don't sync:** verify the `ubiquity-kvstore-identifier` entitlement
  and that `synchronize()` is called; KVS is best-effort and can lag.

## Open Questions

1. **CloudKit environment:** keep Development-only for now, or deploy the schema
   to Production immediately? Recommendation: Development-only until the feature
   is validated, documented above.
2. **Recents retention:** should synced recents be capped (e.g. last N) to avoid
   unbounded growth across devices? Recommendation: cap during the de-dupe sweep.
3. **Conflict policy for settings:** KVS is last-writer-wins per key, which is
   acceptable for overlay styling. Revisit if finer merging is ever needed.
