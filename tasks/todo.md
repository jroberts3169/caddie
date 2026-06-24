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