# OSM Boundary / Feature Rendering Performance

Goal: paint the course boundary as fast as possible (it's the first thing drawn),
and lay the groundwork to progressively draw the rest of the OSM objects
(greens, fairways, bunkers, tees, paths…) afterward.

## Phase 1 — Kill the main-thread decode cost (cached-course win)

- [x] Split persisted geometry from the heavy `raw` payload so drawing doesn't
      decode the full Overpass dump.
- [x] Move the SwiftData fetch + JSON decode off the main thread; return only the
      drawable geometry to the main actor for assignment.
      (Superseded: dropping `raw` shrank the blob to a few KB, so the main-thread
      decode is now negligible — a background context was unnecessary complexity.)
- [x] Remove the redundant double `updateCourseOutline` on cache hits; have the
      fetch path return the geometry it just built and assign once.

## Phase 2 — Split first paint from the network (uncached-course win)

- [x] Two-stage Overpass query: Query A (boundary only, fast) + Query B (all features).
- [x] Use `out geom;` instead of `>; out skel qt;` to inline geometry.
- [x] Progressive model + map layering: independent overlay collections per kind.

## Phase 3 — Network latency & throttle (shared infra)

- [x] Tame the throttle backoff so one 429/503 doesn't penalize later selections.
- [x] Endpoint mirror failover / racing.
- [x] Hover prefetch on sidebar rows, coalesced with click.

## Phase 4 — Perceived performance polish

- [x] In-memory decoded-geometry cache keyed by course id.
- [x] Lightweight loading affordance while Query A is outstanding.

## Review

### Phase 1 (done)

- Removed `raw: OverpassResponse` from `OSMCourse` (its only use was a debug
  element count). The persisted `encodedCourse` blob and every decode of it
  dropped from the full Overpass element dump to a few KB of boundary/feature
  coordinates. JSONDecoder ignores the leftover `raw` key in old cached rows, so
  the change is backward compatible — no store wipe required.
- `ensureOSMData` now returns `OSMCourse?`: the freshly built course on a real
  fetch, `nil` on cache hit / not-found / error / in-flight. The selection
  handler draws the cached boundary immediately via `cachedCourse(for:)`, then
  only re-assigns when a network fetch actually returns new data — eliminating
  the second redundant decode.
- Because the blob is now tiny, the planned background-thread decode was dropped
  as unnecessary complexity (Simplicity First).

### Phase 2 (done)

- `OSMFetcher.fetch` now returns an `AsyncThrowingStream<OSMFetchStage, Error>`
  driven by an actor-isolated `runStagedFetch`. Stage A runs a cheap
  boundary-only query and emits `.boundary` so the outline paints immediately;
  Stage B runs the full feature query and emits `.complete`. Dedup + throttle
  happen once, before Stage A; the two stages share a single gap.
- Both queries switched from `out body; >; out skel qt;` to `out geom;`, which
  inlines vertex coordinates on ways and relation members. The builder now
  prefers inline `geometry` (with node-table resolution kept as a fallback), and
  `OverpassWay.nodes` became optional with a new `geometry` field.
- `ContentView` gained a `courseFeatures: [OSMFeature]` layer rendered via a
  `@MapContentBuilder featureOverlay` — filled `MapPolygon` for closed areas
  (green/bunker/water…), stroked `MapPolyline` for open paths — colored by kind.
  The selection handler draws cached boundary + features instantly, then the
  stream refreshes boundary (Stage A) and features (Stage B) in order. All
  applies are guarded against stale results for a deselected course.

### Tradeoff note

- Two-stage means two Overpass calls per uncached course (one extra cheap call)
  against the public, rate-limited endpoint. The `out geom` switch makes each
  call lighter, so net server time is comparable while the boundary paints
  sooner. If rate-limiting becomes an issue, Stage A can be collapsed into B
  (boundary-first benefit lost) — revisit alongside Phase 3 mirror failover.
- Only stale/missing-cache courses exercise the new path. Use the Debug ▸ Clear
  OSM Cache menu (⇧⌘K) to force a fresh staged fetch and see features stream in.

### Phase 3 (done)

- Mirror failover: `OSMFetcher` now holds three public Overpass mirrors
  (overpass-api.de, kumi.systems, private.coffee). `postWithFailover` tries each
  in rotation starting from the last working one, advancing on rate-limit or
  transport failure and remembering the mirror that succeeds. The error only
  surfaces once every mirror is exhausted. `postOverpass` takes the endpoint as
  a parameter.
- Time-based backoff decay: a 429/503 still doubles `minGap` (capped at 30s),
  but `decayBackoff()` (called from `waitForGap`) now linearly relaxes it back to
  the 1s baseline over 60s since the last rate limit, so a selection made minutes
  later isn't stalled by a stale backoff. `lastRateLimitedAt` tracks the decay
  origin and clears once back at baseline.
- Hover prefetch: sidebar rows gained `.onHover` → `prefetchOnHover`, a 300ms
  debounced `Task` that calls `ensureOSMData` to warm the cache. Hover-out
  cancels the pending task. The actor's `inFlight` set coalesces a hover prefetch
  with the click that follows (the click's stream dedups to a no-op and the
  hover task applies results once `displayedCourse` catches up). Tasks are
  tracked per-id in `hoverPrefetchTasks`.

### Tradeoff note (Phase 3)

- Failover is sequential, not raced — it adds latency only when a mirror is
  actually failing, and avoids hammering all mirrors in parallel (which would be
  rude to free public infra). Racing was considered and rejected for that reason.
- Hover prefetch can issue requests the user never clicks. The 300ms debounce +
  cache short-circuit + per-host gap keep this modest, but on a flaky network it
  trades some background bandwidth for click latency. Acceptable for a desktop
  app; revisit if it proves chatty.

### Phase 4 (done)

- In-memory geometry cache: `ContentView` holds `osmCache: [String: OSMCourse]`.
  `cachedCourse(for:)` checks it before touching SwiftData, and warms it on a
  disk hit and on every completed fetch. Re-selecting a course in the same
  session now skips the SwiftData fetch + JSON decode entirely. A plain
  dictionary is fine here (bounded by courses-per-session, lightweight coordinate
  structs now that `raw` is gone) — unlike an image cache it doesn't need
  `NSCache` eviction.
- Loading affordance: a subtle `loadingBanner` (ProgressView + "Loading course…"
  in a `.regularMaterial` capsule) sits in the Map's top overlay. It's rendered
  unconditionally and driven by `.opacity` + `.animation` (never inserted/removed
  near the Map view, per the AppKit relayout-crash lessons) and is
  `allowsHitTesting(false)`.
- Loading is tracked with a reference COUNT (`loadingCounts: [String: Int]`), not
  a flag. When a hover prefetch and the click that follows both call
  `ensureOSMData` for the same id, the actor dedups the second to an empty
  stream; a flag would let that second call's `defer` clear the spinner while the
  first fetch is still running. The count keeps it visible until the real fetch
  finishes. The banner only shows for the currently displayed course, so hover
  prefetches of other rows don't flash it.

### Note

- `featureColor` was edited externally to use `.yellowGreen` / `.darkGreen`;
  added a `Color` extension defining them so the build stays green.

## All phases complete.
## Multi-course facility support (selectable sub-courses)

- [x] Fetch child course  `featuresQuery` folds the matched relation'spolygons 
      member ways into the area set (`way(r.named)` + union `map_to_area`) so a
      multipolygon facility's inner-ring sub-course and its holes are returned.
- [x]  `OSMSubCourse` + `OSMCourse.subCourses`; resilient `init(from:)`Model 
      (`decodeIfPresent(subCourses) ?? []`) so legacy cache rows still decode.
- [x]  `makeSubCourses` unions relation membership (primary signal)Detection 
      with spatial containment; primary = largest boundary, relation wins ties.
- [x]  re-added `GolfGeometry` (`isInside`, `ringArea`, `centroid`).Geometry 
- [x] State/ `activeSubCourseID` + `displayedSubCourses`; outline/holes/render 
      features filtered to the active sub-course; holes/features attributed to the
      SMALLEST containing sub-course; `.onChange(of: activeSubCourseID)` re-renders.
- [x]  `subCourseRows(for:)` indented child buttons under the displayedSidebar 
      facility (List selection stays on the facility).
- [x] On- floating segmented `subCoursePicker`, shown when > 1 sub-course.map 
- [x]  `docs/ui-glossary.2.4 Sub-Course 3.2 Sub-Course Picker.Rows, md` Docs 

### Review
- Verified end-to-end against LIVE Overpass: Balboa returns relation 3573430 +
  member ways Championship (`outer`) + Executive (`inner`); a Python mirror of
  `makeCourse` yields sub-courses [Championship, Executive] with holes attributed
  30 / 9 (the 39 total is genuine OSM duplicate hole mappings, pre-existing).
- KEY CORRECTION (see tasks/lessons.md): spatial containment alone was wrong 
  Balboa's outer/inner members are geographically disjoint; membership is the
  real signal. `map_to_area` of the multipolygon is a donut, so member ways must
  be mapped to areas too or the inner sub-course's holes never come back.
- Debug build (OSM_DEBUG) `** BUILD SUCCEEDED **`. Coronado preserved: driving
  range still excluded by `isCourseBoundary`, so single courses show no picker.
- Not yet exercised in the running  needs interactive click-through.GUI 
- All changes uncommitted on `fix/layer-draw-order` per the leave-uncommitted pref.

## Generalize sub-course detection (Augusta tag-tier + hulls)
- [x] Phase  name-matched primary (`OSMFetcher` threads search name; builder prefers name match, area tie-break, largest fallback)0 
- [x] Phase  `OSMSubCourse` reshaped: `id: String`, `holeIDs`/`featureIDs` precomputed at build time1 
 convex hull boundary; Tier 2 polygons; `GolfGeometry.convexHull` + `buffered`
- [x] Phase  render is pure membership filtering (`visibleHoles`/`visibleFeatures` by IDs; deleted render-time `smallestSubCourse`); `activeSubCourseID: String?`3 
- [x] Phase  picker/sidebar bind to `id: String`4 
- [x] Phase  verified live + Debug build SUCCEEDED5 

### Review
- Verified against LIVE Overpass via Python mirror of the new builder:
  - ** primary correctly resolves to "Augusta National Golf Club"Augusta** 
    (name-matched; beat the swept-in "Augusta Country Club" on the area tie-break).
    Tier 1 splits into "Augusta National" (18 holes / 116 features, hull 7.7e-5) and
    "Par 3 Course" (9 holes / 23 features, hull 6.5e- distinct hulls, features6) 
    split by smallest containing hull.
 Championship (30) + Executive (9).
  - ** Tier 3 single course (driving range excluded, no  no picker.tag) Coronado** 
- Attribution moved to BUILD time (`holeIDs`/`featureIDs`); render is now a pure
  Set-membership filter. Deleted the render-time geometry helper `smallestSubCourse`.
- Phase 0 fixes a latent bug: the primary was "largest boundary in the response",
  so a larger neighbouring club could have hijacked the displayed course.
- Debug build `** BUILD SUCCEEDED **`. Not yet exercised in the running GUI.
- All changes uncommitted on `fix/layer-draw-order` per the leave-uncommitted pref.

## Multi-ring course boundaries (TPC Sawgrass holes outside boundary)
- [x] Multi-ring `GolfGeometry` helpers (`isInside(_,rings:)` even-odd, `polygonArea`, `centroid(ofRings:)`)
- [x] `assembleRings` close-on-return assembler (4 disjoint rings, drops nothing)
[])
- [x] Builder call-sites updated (candidates/centroid/containment/area all multi-ring); `stitchRing` retained for feature stitching
- [x] Render: `courseOutlines: [[CLLocationCoordinate2D]]`, `ForEach` one polyline per ring, `applyOutline` flattens
- [x] Debug build `** BUILD SUCCEEDED **`; verified live

### Review
- Root cause: `stitchRing` built ONE ring and dropped TPC Sawgrass's 3 other
 9/36 holes outside the drawn boundary.
- Verified against LIVE Overpass via Python mirror of the new builder:

    single course, no picker.
  - **Bethpage**: 1 ring, Tier-1 (Black/Red/Green/Blue/Yellow), 0/90 outside.
  - **Augusta**: 1 ring, Tier-1 (Augusta National 18 + Par 3 9), 0/27 outside.
  - **Coronado**: single course, 0/18 outside.
  - **Balboa**: relation 3573430, 1 ring; 9/39 "outside" = the Executive 9, a
    separate Tier-2 sub-course polygon. Expected, not a regression ("All" uses the
    main/championship boundary per prior decision).
- Tolerant decoder keeps legacy `[Coordinate]` cache rows decoding (wrapped as one
`[]` to avoid stranding the map.
- Debug build `** BUILD SUCCEEDED **`. Not yet exercised in the running GUI.
- All changes uncommitted on `fix/layer-draw-order` per the leave-uncommitted pref.

## Split TPC Sawgrass into its two courses (Tier 1b hole-name prefix)
- [x] Diagnosed: Sawgrass holes are untagged (`golf:course:name` absent) and have NO
      per-course polygons; the course encodes in the hole `name` ("Stadium N"/"Valley N")
- [x] Added `holeNameSubCourses` (Tier 1b) + `courseNamePrefix(of:)` to `OSMCourse.swift`
 single (real polygons beat hulls)
- [x] Guard: skip Tier 1b when any hole carries `golf:course:name`
- [x] Debug build `** BUILD SUCCEEDED **`; verified live via app `map_to_area` query

### Review
- TPC Sawgrass now splits into **Stadium (18)** + **Valley (18)** in the sub-course
  picker; "All" still shows the whole 4-ring facility boundary + every hole/feature.
 no split (Balboa
  still Tier 2 polygons); Augusta (18+9) and Bethpage (5 courses) still Tier 1 (tag).
- `map_to_area` scopes Sawgrass to its own 36 holes, so neighbouring Sawgrass Country
  Club (East/West/South) and The Yards holes don't leak into the split.
 glossary unchanged.
- Debug build `** BUILD SUCCEEDED **`. All changes uncommitted on `fix/layer-draw-order`.

## Bound osmCache with an LRU cache
- [x] Added `caddie/LRUCache.swift`: `@MainActor final class LRUCache<Key,Value>`,
      subscript get(touch MRU)/set(upsert+evict)/nil-remove, removeValue/removeAll/count,
      DEBUG `osmLog` on eviction
- [x] No pbxproj edit needed (filesystem-synchronized group auto-includes the file)
 `LRUCache<String, OSMCourse>(capacity: osmCacheCapacity)`,
      added `osmCacheCapacity = 16` constant + rationale; 5 call sites unchanged
- [x] Debug build `** BUILD SUCCEEDED **` (proves call sites compile against subscript)
- [x] 14/14 LRU assertions pass (eviction, read-promotion, update-in-place, nil-remove,
      clamp, removeAll, order-array no-leak)

### Review
- Reference type (class) chosen over a struct so read-time recency touches don't
  reassign `@State` and redraw the view. No locks (MainActor-default isolation).
- Capacity 16 (named constant) bounds L1 at ~16 decoded courses (tens of MB worst
  case); evicted courses self-heal from L2/L3 on next selection (~280 ms off-main).
- Decision (per 6): left `clearOSMCache()` as L2-only (self-heals); did NOT addplan 
  an L1  kept the diff surgical. Capacity 16 + DEBUG eviction log included.bridge 
- All changes uncommitted on `fix/layer-draw-order` per the leave-uncommitted pref.

## Fix boundary hidden under rough (Pebble Beach) + document layer model
 rough fill
      composited over it). Same mechanism as hole centerlines.
- [x] Documented the two-tier model: MapKit LEVEL = coarse z (can't be crossed),
      `drawOrder` = fine z within `.aboveRoads` only. Clarified that structure layers'
      drawOrder values are unread; restack via `.mapOverlayLevel`.
- [x] Added a why-comment at the boundary render site in ContentView.
- [x] Debug build `** BUILD SUCCEEDED **`.

### Review
- One-line behavioural fix (level pin) + comment-only docs in OverlaySettings/ContentView.
- `drawOrder` could not have fixed  boundary was in a lower LEVEL than the turf.this 
- All changes uncommitted on `fix/layer-draw-order` per the leave-uncommitted pref.
