# Lessons

Patterns captured after corrections, so the same mistake isn't repeated.

## OSM / Overpass

### Multi-course facilities: detect sub-courses by relation MEMBERSHIP, not spatial containment

While adding selectable sub-courses (Balboa Park = Championship + Executive), the
first approach attributed sub-courses by point-in-polygon containment inside the
largest "facility" boundary. That was **wrong for the real data** and was caught
only by simulating `makeCourse` against a live Overpass response:

- Balboa's facility is a `type=multipolygon` relation whose members ARE the
  courses — way `25841862` "Championship Course" as role `outer`, way `31522542`
  "Executive Course" as role `inner`.
- The two courses are **geographically disjoint** (adjacent), despite the
  outer/inner roles. The Executive course is NOT inside the Championship ring, so
  containment dropped all 9 Executive holes into "none".

Fix: detect sub-courses from the relation's member ways first (any member that is
itself `leisure=golf_course` with no `golf=*` tag), then add spatially-enclosed
course polygons as a secondary signal for true facility shapes. Attribute each
hole/feature to the **smallest** containing sub-course so nested cases also work.

> Always validate an OSM tagging/geometry assumption against the live API before
> building detection logic on top of it. Roles like `inner`/`outer` describe
> polygon construction, not "is one course inside another".

### `map_to_area` on a multipolygon is a donut — map member ways too

`map_to_area` of a multipolygon relation produces `outer − inner` (a donut), so
`way(area)["golf"]` cannot see features inside an inner-ring sub-course. To fetch
an inner sub-course's holes/features, fold the relation's member ways into the
set and `map_to_area` those as well (`way(r.named)->.members; (.named; .members;)`),
making the area set the UNION of the facility and every sub-course.

### Curl-testing Overpass

Always send `-A "Caddie/1.0"` (matches the app's User-Agent); the default curl UA
gets `406 Not Acceptable`. Mirrors rate-limit rapid repeats — space calls with
`sleep` and `--max-time`. A single dropped/empty response (HTTP 429) will look
like "0 elements"; re-run before trusting a count.

### A third facility topology: tag-grouped courses with no boundary (Augusta)

Augusta National is ONE `leisure=golf_course` ring containing TWO courses. Neither
sub-course has its own polygon; instead every **hole** carries an explicit
`golf:course:name` ("Augusta National" 18 + "Par 3 Course" 9). Features
(greens/tees/bunkers) carry NO course tag. So detection is a **signal cascade**:

1. **Tier  `golf:course:name` on holes.** Group holes by the tag; 2 values,if 1 
   each group is a sub-course. Synthesize its boundary as a **convex hull** of all
   its holes' coordinates (lightly buffered ~8% so edge bunkers/greens are caught),
   and attribute untagged features by the **smallest** hull whose interior holds the
   feature centroid (Par 3's hull nests inside the 18's, so its features win).
2. **Tier  child boundary polygons** (Balboa: relation members / nesting).2 
3. **Tier  single course** (Coronado).3 

> Attribute holes/features to sub-courses ONCE at build time (precomputed
> `holeIDs`/`featureIDs`), not geometrically at every render. Render then is a pure
> membership  cheaper and cache-friendly.filter 

### A 4 km area query sweeps in neighbouring  match the nameclubs 

Augusta National's area query also returns "Augusta **Country** Club" (a different
club). Picking the primary as "largest boundary in the response" risked a neighbour
hijacking the displayed course. Thread the user's selected name into the builder and
prefer the boundary whose simplified name matches, area only as a tie-break, falling
back to largest when nothing matches (OSM names are loose). Note the looseApple
match can let two names both match (" "augusta  the areanational") augusta" 
tie-break must still pick the right one.

### Bethpage confirms Tier 1, and why "All" must exist

Checked Bethpage State Park live before coding: it is ONE `leisure=golf_course`
way ("Bethpage State Park Golf Courses") containing 90 holes, each tagged
`golf:course:name` = Black/Red/Green/Blue/Yellow (18 apiece).  like Augusta So 
it is **Tier 1 (tag-grouped)**, NOT five boundary polygons. No new detection was
needed; the existing tag tier already splits it into five hull sub-courses.

Filtering to one sub-course hides everything not attributed to  a facility'sit 
driving range, clubhouse, and other untagged features vanish, and you can no longer
see a multi-course park as a whole. Fix: an **"All" selection** (`activeSubCourseID
== nil`) that renders the full facility boundary + every hole/feature. Make it the
DEFAULT so a facility opens whole; drilling into a course is opt-in. Render already
fell back to the full course for `nil` active, so "All" was purely a UI/default add
(an "All" picker segment tagged `nil` + an "All Courses" sidebar  no model orrow) 
builder change.

### Multipolygon courses need MULTI-RING boundaries (TPC Sawgrass)

TPC Sawgrass is a FOURTH topology: `relation 1783123`, `type=multipolygon`, ~60
outer ways that assemble into **4 disjoint closed rings** (the course is split
across several parcels), and the holes carry NO `golf:course:name` tag. The old
`stitchRing` built ONE ring and stopped when no segment touched its endpoints,
silently dropping the other 3 rings (28  so 9/36 holes fell outside thesegments) 
drawn boundary.

Fixes / rules:
- A course boundary is `[[Coordinate]]` (rings), not `[Coordinate]`. `OSMCourse`
  and `OSMSubCourse` both store rings; render flattens to one `MapPolyline` per ring.
- `assembleRings` extends a ring from EITHER endpoint but **stops as soon as the
  ring closes** (`first == last`), then peels the next ring from the leftovers.
  Never keep extending across a closure or you merge disjoint loops into garbage.
- Inside-test across disjoint rings uses the **even-odd rule** (`isInside(_,rings:)`
 in;
 out. Correct for BOTH disjoint outers and holes.
- Disjoint-centroid gotcha: the area-weighted centroid of disjoint rings can land
  in the GAP between parcels (outside all of them). For the spatial sub-course
  containment test use `centroid(ofRings:)` = centroid of the LARGEST ring, which
  is guaranteed inside.
- Changing `boundary`'s on-disk shape breaks cached SwiftData rows. Use a TOLERANT
  decoder: try `[[Coordinate]]`, fall back to legacy `[Coordinate]` wrapped as one
 `[]` so a single bad field
  can't strand the whole row (blank map within the cache TTL).
- Keep `stitchRing` for multipolygon FEATURE stitching (fairways/ thosegreens) 
  are single loops; only the COURSE boundary needed the multi-ring assembler.
- Verified live: TPC = 4 rings, 0/36 outside; Bethpage/Augusta still Tier-1,
  Coronado single, Balboa still Tier-2 (its 9 executive holes sit outside the
  championship primary by  they're a separate sub-course polygon, not adesign 
  regression).

### Tier  split a course by hole-NAME prefix (TPC Sawgrass two courses)1b 

TPC Sawgrass is a FIFTH topology. It really holds two 18-hole  THE PLAYERScourses 
Stadium Course and Dye's Valley  but the holes carry NO `golf:course:name`Course 
tag (so Tier 1 misses them) and there are NO per-course mapped polygons (so Tier 2
misses them). The only signal is the hole `name`: "Stadium "Stadium 18" and1"
"Valley "Valley 18". So the app showed one course.1"

Fix: add **Tier  group holes by the `name` PREFIX (the name with its trailing1b** 
hole number stripped; strip the `ref` when the name ends with it, else trailing
 sub-courses, with convex-hull
boundaries exactly like the tag tier (real polygon preferred when a candidate name
matches; hull used for feature attribution).

 single**. Real mapped polygons
(Tier 2) must win over synthesized hulls, so hole-name only runs after the polygon
tier returns empty. Guard: skip Tier 1b entirely if ANY hole has `golf:course:name`
(that's Tier 1's job). Verified live via the app's `map_to_area` query:
 Stadium 18 + Valley 18 (the East/West/South holes belong to the
  neighbouring Sawgrass Country Club and The Yards; `map_to_area` scopes them out,
  so only 36 holes reach the  clean 2-way split).builder 
 no split; Balboa still Tier 2.
 Tier 1b skipped).

Gotcha to remember: name-prefix can't tell "two separate 18-hole courses" from
"front/back nine of ONE course" by names alone. We accept that risk because OSM
convention puts genuinely separate courses behind distinct relations/tags; lone
name prefixes are the last-resort signal. Group case-insensitively ("West"/"west").

### Bidirectional nameMatches is too loose for sub-course polygon preference

`nameMatches` strips "country club", "golf", etc. and returns true when EITHER
normalized string contains the other. For the PRIMARY selection this is fine (user's
loose search term vs OSM name). But in the sub-course polygon-preference lookup it's
a footgun:

 normalized "augusta national"
 normalized "augusta"
 country club hijacks the
  boundary of the Augusta National sub-course. Visually: selecting "Augusta National"
  showed the Augusta Country Club polygon.

Fix: add ` a STRICT one-directional check wherecandidateContainsGroupName(_:_:)` 
the **candidate polygon's** normalized name must contain the **group name** normalized
 correct.

Use `nameMatches` only for primary selection (bidirectional is fine there, because
user input and OSM names can differ in either direction). Use
`candidateContainsGroupName` wherever a polygon candidate is being matched against a
known group name in `tagBasedSubCourses` and `holeNameSubCourses`.

### Bounding a SwiftUI in-memory cache: use a reference type, not a struct

`osmCache` (the L1 decoded-course cache) grew unbounded. Bounding it with an LRU
surfaced a SwiftUI-specific design rule: an LRU **touches recency on every read**, so
if the cache is a VALUE type held in `@State`, each lookup reassigns the `@State` and
**invalidates the  a redraw per cache hit, possibly self-feeding if `body`view** 
reads the cache. A `final class` held in `@State` is mutated in place; the stored
reference never changes, so SwiftUI is NOT redrawn by a touch. `@State` then only
provides a stable lifetime across body recomputations. (This is a deliberate
exception to the project's @Observable-maximalist rule: here observation is exactly
what we must avoid.)

No locking needed: with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, an unannotated/
`@MainActor` class is main-actor isolated, and all cache access is already on main
(the only off-main work is the JSON decode, whose result is assigned back on main).

Implementing a `subscript(key) -> Value?` (get touches MRU, set upserts+evicts, nil
removes) on the class let all 5 existing `osmCache[id]` call sites compile **byte-for
-byte  only the declaration line changed. Array-order LRU (LRU at indexunchanged** 
0, MRU at end) is O(n) per touch but trivial 16. Eviction is always safecap
because L2 (SwiftData) + L3 (network) sit behind L1 and self-heal (one ~280 ms
off-main re-decode on a later selection).

Project note: `caddie.xcodeproj` uses `PBXFileSystemSynchronizedRootGroup`, so a new
`.swift` file dropped into `caddie/` is compiled  no pbxproj edit.automatically 

### Two-tier map layering: levels are coarse, drawOrder is fine (boundary under rough)

At Pebble Beach the course boundary was covered by the rough. Root cause: the app has
TWO independent z mechanisms and they were conflated.

1. **MapKit overlay LEVEL** (`.mapOverlayLevel( the coarse z-axis with twolevel:)`) 
   buckets, `.aboveRoads` and `.aboveLabels`. Everything at `.aboveLabels` draws above
   everything at `.aboveRoads`, unconditionally. `drawOrder` CANNOT cross this.
2. **`OverlayLayer.drawOrder:  only sorts the `courseFeatures` array *withinInt`** 
   the single `.aboveRoads` pass* (in `applyFeatures`). Within one level, array order
   is z-order.

Turf features are pinned to `.aboveRoads`; the boundary `MapPolygon` had NO level, so
the rough's translucent fill (`opacity 0.55`) composited over the outline. Fix: pin
the boundary to `. the SAME mechanism already used for hole centerlines.aboveLabels` 
"Ordering it like the others" via `drawOrder` could never have fixed it (wrong level).

Model to remember:
- **Structure layers** (boundary, holes) = their own `body` blocks, geometry differs
  from features, pinned to `.aboveLabels`. Their `drawOrder` values (-1, 99) are UNREAD
 they exist only to keep the switch exhaustive. To restack them, change their  
  `.mapOverlayLevel` in `ContentView`, not `drawOrder`.
- **Feature layers** (turf) = the sorted `featureOverlay` loop at `.aboveRoads`, ordered
  by `drawOrder`.

## MapKit (native MKMapView wrapper)

### A single new annotation must NOT blanket-rebuild the whole annotation set (glyph flash)

Recording a shot in Play mode made **every** glyph flash — the course pin, all hole
tees, all pins, and all existing shots — not just the new shot. Root cause in
`CourseMapView.Coordinator.syncAnnotations`: one hash-gated block whose hash folded in
every shot's id+coordinate, so adding a shot changed the hash and ran:

```swift
let toRemove = map.annotations.filter { !($0 is MKUserLocation) }
map.removeAnnotations(toRemove)   // course marker + ALL tees + ALL pins + ALL shots
// …then re-add every one from scratch
```

MapKit recycles each annotation view during removal and serves a stale cached image for
one render frame before the new one draws → visible flash across every glyph. The code's
own comment ("these sets change only on course selection / nearby load, never per frame")
was the wrong assumption — shots mutate per click.

Fix: split the sync into two independently hash-gated phases:
- `syncStaticAnnotations` — course marker, hole tees/pins, nearby flags. Its hash
  EXCLUDES shots, so recording a shot leaves it untouched; it also removes only those
  static annotation TYPES, not `map.annotations.filter { !($0 is MKUserLocation) }`.
- `syncShotAnnotations` — reconciles shot markers + yardage pills INCREMENTALLY by shot
  number: an existing annotation whose coordinate/label still matches is kept as-is (no
  remove → no recycle → no flash); only genuinely new ones are added and stale ones
  removed.

> Same root cause as the SwiftUI-`Map` glyph-flash lesson: blanket `removeAnnotations` +
> re-`addAnnotation` on any coordinate change recycles views and flashes. Whenever a
> per-action mutation (a shot) shares a rebuild path with a per-selection set
> (marker/tees/pins), give each its OWN hash gate and reconcile the frequently-changing
> set incrementally instead of tearing both down together.

## Zoom-out ceiling: use MKMapView.setCameraZoomRange, not setRegion snap-back

To cap how far the user can zoom out (e.g. keep them within a selected course),
do NOT try to detect over-zoom in `regionDidChangeAnimated` and call `setRegion`
to snap  reentrant region sets from inside that delegate callback areback 
unreliable/ignored and fight the user's gesture. Instead install a native
`MKMapView.CameraZoomRange(maxCenterCoordinateDistance:)` via
`map.setCameraZoomRange(_:animated:)`. Compute the max distance by reading
`map.camera.centerCoordinateDistance` right AFTER the footprint `setRegion` (so
it reflects the applied framing) and multiply for headroom. Clear it with
`setCameraZoomRange(nil, animated:false)` when no course is open.
