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
