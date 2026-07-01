# Caddie UI/UX Glossary

This document assigns a single **canonical name** to every visible element in
the Caddie app so we can refer to each control unambiguously when filing bugs or
requesting changes. It is a naming contract, not a tutorial. All UI is defined
under the app source folder [caddie/](../caddie). The interface spans four view
files, hosted by [caddie/caddieApp.swift](../caddie/caddieApp.swift):
the sidebar, window toolbar, and overlay plumbing in
[caddie/ContentView.swift](../caddie/ContentView.swift); the native map in
[caddie/CourseMapView.swift](../caddie/CourseMapView.swift); the Play-mode
inspector in [caddie/PlayDetailPane.swift](../caddie/PlayDetailPane.swift); and
the settings window in
[caddie/OverlaySettingsView.swift](../caddie/OverlaySettingsView.swift).

## Table of Contents

- [1. Top-Level Layout](#1-top-level-layout)
  - [1.1 Course Sidebar](#11-course-sidebar)
  - [1.2 Map Detail Pane](#12-map-detail-pane)
- [2. Course Sidebar](#2-course-sidebar)
  - [2.1 Search Field](#21-search-field)
  - [2.2 Sidebar Sections](#22-sidebar-sections)
  - [2.3 Course Row](#23-course-row)
  - [2.4 Sub-Course Rows](#24-sub-course-rows)
- [3. Window Toolbar](#3-window-toolbar)
  - [3.1 Mode Toggle Button](#31-mode-toggle-button)
  - [3.2 Sub-Course Picker Menu](#32-sub-course-picker-menu)
- [4. Map Detail Pane](#4-map-detail-pane)
  - [4.1 Map Surface & Controls](#41-map-surface--controls)
  - [4.2 Map Overlay Layers](#42-map-overlay-layers)
  - [4.3 Map Glyphs](#43-map-glyphs)
  - [4.4 Loading Banner](#44-loading-banner)
  - [4.5 Search This Area Button](#45-search-this-area-button)
- [5. Play Detail Pane](#5-play-detail-pane)
  - [5.1 Hole Navigation Header](#51-hole-navigation-header)
  - [5.2 Hole Stats](#52-hole-stats)
  - [5.3 Shots Section](#53-shots-section)
- [6. Overlay Settings Window](#6-overlay-settings-window)
- [7. Behaviors](#7-behaviors)
  - [7.1 Selection](#71-selection)
  - [7.2 Favoriting](#72-favoriting)
  - [7.3 Search](#73-search)
  - [7.4 Recents Tracking](#74-recents-tracking)
  - [7.5 Nearby Courses & Search This Area](#75-nearby-courses--search-this-area)
  - [7.6 Play Mode & Recording Shots](#76-play-mode--recording-shots)
  - [7.7 Sub-Course Switching](#77-sub-course-switching)
  - [7.8 Overlay Styling](#78-overlay-styling)
- [8. States](#8-states)
- [9. Where Do I Click To…](#9-where-do-i-click-to)
- [10. Known Issues to Address](#10-known-issues-to-address)

---

## 1. Top-Level Layout

The app is a single window driven by a `NavigationSplitView` with a sidebar and a
map detail pane, a **Window Toolbar** in the title bar, and — while a course is
open in **Play** mode — a trailing **Play Detail Pane** shown as an `.inspector`.

```
┌──────────────────────────── Caddie Window ─────────────────────────────────┐
│ [◱ Play] [⚑ All ▾]              Course Name          ← Window Toolbar        │
│ ┌──────────────────┐ ┌────────────────────────────┐ ┌────────────────────┐  │
│ │  Course Sidebar  │ │       Map Detail Pane      │ │  Play Detail Pane  │  │
│ │ ┌──────────────┐ │ │                            │ │ ◁   Hole 1    ▷    │  │
│ │ │ Search Field │ │ │      (satellite imagery)   │ │ Par            4   │  │
│ │ └──────────────┘ │ │              📍            │ │ Yards        410   │  │
│ │  ▸ Favorites     │ │        Course Marker       │ │ ── Shots ───────   │  │
│ │  ▸ Recents       │ │                            │ │ ① Shot 1   120 yd  │  │
│ │  ▸ Results       │ │                            │ │ [ Clear All Shots ]│  │
│ └──────────────────┘ └────────────────────────────┘ └────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
   (Play Detail Pane appears only in Play mode with a course open)
```

| Region | Canonical name | Source |
| --- | --- | --- |
| Whole window | **Caddie Window** | [ContentView.swift](../caddie/ContentView.swift#L245-L336), [caddieApp.swift](../caddie/caddieApp.swift#L23-L27) |
| Title-bar controls | **Window Toolbar** | [ContentView.swift](../caddie/ContentView.swift#L337-L407) |
| Left column | **Course Sidebar** | [ContentView.swift](../caddie/ContentView.swift#L246-L248) |
| Center column | **Map Detail Pane** | [ContentView.swift](../caddie/ContentView.swift#L249-L263) |
| Trailing inspector | **Play Detail Pane** | [ContentView.swift](../caddie/ContentView.swift#L250-L262), [PlayDetailPane.swift](../caddie/PlayDetailPane.swift) |

> The window's title is the displayed course's name (`.navigationTitle`), with a
> "City, State" **Navigation Subtitle** beneath it; both fall back to **Caddie** /
> empty when no course is open ([ContentView.swift](../caddie/ContentView.swift#L334-L335)).
> The only chrome besides the standard macOS title bar is the **Window Toolbar**
> ([§3](#3-window-toolbar)) and the split-view/inspector dividers.


### 1.1 Course Sidebar

```
┌──────────────────┐
│ ┌──────────────┐ │  ← Search Field (.searchable, placement: .sidebar)
│ │ 🔍 Search…   │ │
│ └──────────────┘ │
│ Favorites        │  ← Sidebar Section Header
│   Course Row     │
│   Course Row     │
│ Recents          │  ← Sidebar Section Header
│   Course Row     │
│ Results          │  ← Sidebar Section Header
│   Course Row     │
└──────────────────┘
```

| Sub-region | Canonical name | Visibility | Role |
| --- | --- | --- | --- |
| Search input | **Search Field** | Always | Drives the **Results Section** |
| "Favorites" group | **Favorites Section** | Only when at least one favorite exists | Lists starred courses |
| "Recents" group | **Recents Section** | Only when at least one recent exists | Lists recently viewed courses |
| "Results" group | **Results Section** | Only when a search returned hits | Lists search matches |
| Single list item | **Course Row** | Per course | Selects a course; toggles favorite |

> The **Course Sidebar** column width is constrained to min 180, ideal 240, max
> 300 pts via `.navigationSplitViewColumnWidth` ([ContentView.swift](../caddie/ContentView.swift#L247-L248)).

### 1.2 Map Detail Pane

| Sub-region | Canonical name | Visibility | Role |
| --- | --- | --- | --- |
| Native satellite map | **Map Surface** | Always | A native `MKMapView` (hybrid, realistic elevation) hosted in an `NSViewRepresentable` (see [§4.1](#41-map-surface--controls)) |
| Pin on the selected course | **Course Marker** | Only when a course is displayed | Marks the selected course, geocoded from its address (see [§4.3](#43-map-glyphs)) |
| Green flags near you | **Nearby Course Flag** | On the browse map, per course found near your location | One flag per nearby golf course (see [§4.3](#43-map-glyphs)) |
| Numbered tee / green glyphs | **Hole Glyphs** | Per hole, when hole geometry is loaded | Tee markers and green dots (see [§4.3](#43-map-glyphs)) |
| Drawn OSM geometry | **Map Overlay Layers** | Per layer, when fetched and the layer is enabled | Boundary, hole centerlines, and course-feature fills (see [§4.2](#42-map-overlay-layers)) |
| Centered progress chip | **Loading Banner** | While the displayed course's OSM data is being fetched | Non-blocking "Loading course…" spinner (see [§4.4](#44-loading-banner)) |
| Bottom "Search this area" pill | **Search This Area Button** | On the browse map after a pan/zoom | Re-runs the nearby search for the region in view (see [§4.5](#45-search-this-area-button)) |

> The color and visibility of every **Map Overlay Layer** are user-configurable in
> the **Overlay Settings Window** (see [§6](#6-overlay-settings-window)), opened
> from **caddie ▸ Settings…** (⌘,).


---

## 2. Course Sidebar

Source: `courseSidebar` in [ContentView.swift](../caddie/ContentView.swift#L1019-L1066).

### 2.1 Search Field

| Element | Canonical name | Source | Notes |
| --- | --- | --- | --- |
| Sidebar search box | **Search Field** | [ContentView.swift](../caddie/ContentView.swift#L336) | Prompt text is "Search for a course"; bound to `searchText` |

> The **Search Field** uses `.searchable(text:placement:.sidebar)`. Clearing it
> empties the **Results Section**; typing triggers a debounced `MKLocalSearch`
> filtered to golf points of interest.

### 2.2 Sidebar Sections

| Element | Canonical name | Source | Visibility rule |
| --- | --- | --- | --- |
| "Favorites" header | **Favorites Section Header** | [ContentView.swift](../caddie/ContentView.swift#L1021-L1031) | Hidden when `favorites.isEmpty` |
| "Recents" header | **Recents Section Header** | [ContentView.swift](../caddie/ContentView.swift#L1032-L1047) | Hidden when `recents.isEmpty` |
| "Results" header | **Results Section Header** | [ContentView.swift](../caddie/ContentView.swift#L1048-L1056) | Hidden when `searchResults.isEmpty` |

> Each section is a standard `List` `Section`. The three are stacked in fixed
> order: Favorites, then Recents, then Results. There is no collapse/expand
> control, drag-to-reorder, or count badge.

### 2.3 Course Row

A single row rendered by `courseRow(course:subtitle:kind:)`
([ContentView.swift](../caddie/ContentView.swift#L1067-L1097)). Each row and its
favorite toggle carry section-scoped accessibility identifiers
(`courseRow_<kind>_<id>`, `favoriteToggle_<kind>_<id>`, kind = favorite/recent/result).

```
┌─────────────────────────────────────────────┐
│ Course Name Label              ⭐ Favorite   │
│ City Subtitle Label              Star Button │
└─────────────────────────────────────────────┘
```

| Element | Canonical name | Icon / Source | Notes |
| --- | --- | --- | --- |
| Primary course name text | **Course Name Label** | [ContentView.swift](../caddie/ContentView.swift#L1070-L1071) | `.headline` when a subtitle exists, otherwise `.body` |
| Secondary city text | **City Subtitle Label** | [ContentView.swift](../caddie/ContentView.swift#L1072-L1076) | Only present in the **Results Section** when the course has a non-empty "City, State" |
| Star toggle | **Favorite Star Button** | `star` / `star.fill`, [ContentView.swift](../caddie/ContentView.swift#L1078-L1087) | Yellow filled star when favorited; secondary-gray outline when not |

> The **Favorite Star Button** uses `.buttonStyle(.plain)` so it is tappable
> independently of selecting the row. **Favorites Section** and **Recents
> Section** rows pass `subtitle: nil` (no **City Subtitle Label**); only
> **Results Section** rows show a city.

### 2.4 Sub-Course Rows

Indented child rows emitted by `subCourseRows(for:)` directly beneath the
**Course Row** of the currently displayed facility, one per sub-course.

```
┌─────────────────────────────────────────────┐
│ Balboa Park Golf Course        ⭐           │  ← Course Row (facility)
│   ▤ All Courses                   ✓        │  ← All-Courses Row (active)
│   ⚑ Championship Course                     │  ← Sub-Course Row
│   ⚑ Executive Course                        │  ← Sub-Course Row
└─────────────────────────────────────────────┘
```

| Element | Canonical name | Icon / Source | Notes |
| --- | --- | --- | --- |
| Indented "All Courses" button | **All-Courses Row** | `square.stack`, `subCourseRows(for:)` in [ContentView.swift](../caddie/ContentView.swift#L1105-L1121) | Listed first; sets `activeSubCourseID` to `nil` to show the whole facility (every hole/feature, including untagged ones like a driving range) |
| Indented sub-course button | **Sub-Course Row** | `flag`, `subCourseRows(for:)` in [ContentView.swift](../caddie/ContentView.swift#L1122-L1141) | One per `displayedSubCourses` entry; sets `activeSubCourseID` |
| Trailing check on the active row | **Sub-Course Checkmark** | `checkmark`, [ContentView.swift](../caddie/ContentView.swift#L1114-L1117) | Tint-colored; marks the active row (the **All-Courses Row** when no sub-course is selected) |

> **Sub-Course Rows** appear only beneath the **displayed facility** and only
> when it has more than one sub-course, always led by the **All-Courses Row**.
> They are buttons, not `List` selections — the `List` selection stays on the
> facility while the active sub-course is shown here and in the **Sub-Course
> Picker Menu** ([§3.2](#32-sub-course-picker-menu)), which stay in sync. A
> facility opens on **All Courses** by default. An ordinary single course shows
> no **Sub-Course Rows**.

---

## 3. Window Toolbar

The **Window Toolbar** holds two navigation-placement controls, both visible only
once a course is open. Source: the `.toolbar` modifier in
[ContentView.swift](../caddie/ContentView.swift#L337-L407).

```
┌─────────────────────────────────────────────┐
│ [ ◱ Play ]   [ ⚑ All ▾ ]        Course Name  │  ← Window Toolbar
└─────────────────────────────────────────────┘
   Mode Toggle    Sub-Course Picker Menu
```

| Element | Canonical name | Source | Visibility |
| --- | --- | --- | --- |
| Plan/Play switch | **Mode Toggle Button** | [ContentView.swift](../caddie/ContentView.swift#L338-L356) | Only when a course is displayed |
| Facility course menu | **Sub-Course Picker Menu** | [ContentView.swift](../caddie/ContentView.swift#L357-L406) | Only when the displayed facility has more than one sub-course |

### 3.1 Mode Toggle Button

| Element | Canonical name | Icon / Source | Notes |
| --- | --- | --- | --- |
| Mode toggle | **Mode Toggle Button** | `map` (Plan) / `figure.golf` (Play), [ContentView.swift](../caddie/ContentView.swift#L338-L356) | Toggles `appMode` between **Plan** and **Play**; its label shows the *current* mode's icon + name. Identifier `modeToggleButton` |

> **Plan** mode is browsing (map only). **Play** mode reveals the **Play Detail
> Pane** inspector ([§5](#5-play-detail-pane)) and makes the **Map Surface**
> record a shot on each click. Selecting a new course, or deselecting, resets to
> **Plan**.

### 3.2 Sub-Course Picker Menu

A toolbar `Menu` for facilities that contain more than one course (e.g. Balboa
Park's Championship and Executive courses).

```
   ┌ ⚑ All ▾ ┐
   ├──────────────────┐
   │ ✓ All            │  ← All Menu Item
   │ ──────────────   │
   │   Championship   │  ← Sub-Course Menu Item
   │   Executive      │  ← Sub-Course Menu Item
   └──────────────────┘
```

| Element | Canonical name | Source | Notes |
| --- | --- | --- | --- |
| Menu button | **Sub-Course Picker Menu** | [ContentView.swift](../caddie/ContentView.swift#L357-L406) | `flag`-led label showing the active sub-course; `.menuStyle(.button)`. Identifier `subCoursePickerButton`, accessibility value = active sub-course label |
| "All" menu item | **All Menu Item** | [ContentView.swift](../caddie/ContentView.swift#L359-L370) | Sets `activeSubCourseID` to `nil`; leading `checkmark` when active. Identifier `subCourseItem_all` |
| One item per sub-course | **Sub-Course Menu Item** | [ContentView.swift](../caddie/ContentView.swift#L371-L383) | Sets `activeSubCourseID`; label is the sub-course name with a trailing "Course"/"Golf Course" trimmed. Identifier `subCourseItem_<id>` |

> The **Sub-Course Picker Menu** is hidden unless `displayedSubCourses.count > 1`
> and opens on **All**. It mirrors the **Sub-Course Rows** in the sidebar
> ([§2.4](#24-sub-course-rows)) — both read and write `activeSubCourseID`, so
> switching from either updates the other and re-filters the **Map Overlay
> Layers**: a sub-course shows its own boundary and the holes/features inside it,
> while **All** shows the facility boundary and everything.

---

## 4. Map Detail Pane

The **Map Detail Pane** is the `detail:` column, a `CourseMapView` — a native
`MKMapView` wrapped in an `NSViewRepresentable`, **not** SwiftUI `Map`. (SwiftUI
`Map` re-projects its annotations every frame, so the glyphs visibly jitter over
realistic terrain; native `MKAnnotationView`s stay screen-anchored and steady.)
Source: [ContentView.swift](../caddie/ContentView.swift#L449-L479) (the `courseMap`
view) feeding value-type inputs to [CourseMapView.swift](../caddie/CourseMapView.swift).

### 4.1 Map Surface & Controls

| Element | Canonical name | Source | Notes |
| --- | --- | --- | --- |
| Native map view | **Map Surface** | [CourseMapView.swift](../caddie/CourseMapView.swift#L119-L129) | `MKMapView` with `MKHybridMapConfiguration(elevationStyle: .realistic)` — 3D satellite imagery with roads/labels |
| System compass | **Map Compass** | [CourseMapView.swift](../caddie/CourseMapView.swift#L127) | `showsCompass` |
| Zoom +/− control | **Map Zoom Controls** | [CourseMapView.swift](../caddie/CourseMapView.swift#L128) | `showsZoomControls` |
| Blue user-location dot | **User Location Dot** | [CourseMapView.swift](../caddie/CourseMapView.swift#L129) | `showsUserLocation`; MapKit's own blue dot |

> The camera is framed by a `MapRegionRequest` (a region + identity token so
> re-selecting the same course re-frames it). Overlays and glyphs are diffed by a
> hash so a course switch — not every frame — rebuilds them.

### 4.2 Map Overlay Layers

Vector geometry drawn on the **Map Surface** as `MKPolygon`/`MKPolyline`
overlays. Each layer is drawn only when its data is present **and** its **Layer
Visibility Switch** is on. Colors come from the **Overlay Settings Window** (the
defaults below until overridden). The renderer styles each overlay by its role —
boundary stroke, translucent feature fill, dashed hole line — in
`mapView(_:rendererFor:)` ([CourseMapView.swift](../caddie/CourseMapView.swift#L500-L532)).

| Element | Canonical name | Source | Default color | Settings layer |
| --- | --- | --- | --- | --- |
| Course outline polygon stroke | **Course Boundary Overlay** | [CourseMapView.swift](../caddie/CourseMapView.swift#L464-L465) | White | Course Boundary |
| Dashed tee→green centerline | **Hole Centerline** | [CourseMapView.swift](../caddie/CourseMapView.swift#L453-L461) | `holes` blue | Holes |
| Filled/stroked feature geometry | **Feature Overlay** | [CourseMapView.swift](../caddie/CourseMapView.swift#L433-L451) | Per kind (below) | Per kind (below) |

The **Feature Overlay** is one shape per OSM feature, colored by kind. Closed
areas render as a translucent filled polygon; open paths as a stroked polyline.
Feature kinds map to settings layers in
[OverlaySettings.swift](../caddie/OverlaySettings.swift#L37-L120).

| Feature kind | Canonical name | Settings layer |
| --- | --- | --- |
| Green | **Green Overlay** | Greens |
| Fairway | **Fairway Overlay** | Fairways |
| Tee | **Tee Overlay** | Tees |
| Bunker | **Bunker Overlay** | Bunkers |
| Rough | **Rough Overlay** | Rough |
| Water hazard | **Water Hazard Overlay** | Water Hazards |
| Cart path / path | **Cart Path Overlay** | Cart Paths |
| Driving range | **Driving Range Overlay** | Driving Range |
| Unknown | **Other Feature Overlay** | Other Features |

> A **Settings layer** maps one-to-one to a row in the **Overlay Settings
> Window** ([§6](#6-overlay-settings-window)). The nine **Feature Overlay** kinds
> collapse cart paths and generic paths onto a single **Cart Paths** layer.

### 4.3 Map Glyphs

Screen-anchored `MKAnnotationView`s built in
`mapView(_:viewFor:)` ([CourseMapView.swift](../caddie/CourseMapView.swift#L711-L799)).

| Element | Canonical name | Icon / Source | Notes |
| --- | --- | --- | --- |
| Red flag on the opened course | **Course Marker** | `flag.fill` (systemRed), [CourseMapView.swift](../caddie/CourseMapView.swift#L715-L721) | The opened course's pin; coordinate geocoded from its address, falling back to `displayedCourse.coordinate`. Shows a callout |
| Green flag on a nearby course | **Nearby Course Flag** | `flag.fill` (systemGreen), [CourseMapView.swift](../caddie/CourseMapView.swift#L723-L729) | One per nearby course on the browse map. Shows a callout |
| Numbered marker at a hole tee | **Hole Tee Marker** | glyph = hole ref, `holes` color, [CourseMapView.swift](../caddie/CourseMapView.swift#L731-L737) | Callout reads e.g. "Par 4 · 410y". In Play mode, clicking one focuses that hole |
| Small dot at a hole green | **Hole Green Dot** | disc, `holes` color, [CourseMapView.swift](../caddie/CourseMapView.swift#L739-L753) | The pin position; no callout |
| Orange numbered shot marker | **Shot Marker** | number glyph (systemOrange), [CourseMapView.swift](../caddie/CourseMapView.swift#L755-L761) | One per recorded shot on the focused hole (Play mode) |
| Black yardage pill | **Shot Yardage Pill** | "N yd" capsule, [CourseMapView.swift](../caddie/CourseMapView.swift#L763-L797) | Distance label near each shot segment |
| Orange connecting line | **Shot Segment Line** | polyline (systemOrange), [CourseMapView.swift](../caddie/CourseMapView.swift#L519-L523) | Tee→shot→shot path for the focused hole |

> The **Course Marker**, **Nearby Course Flag**, and tee/green glyphs are static —
> rebuilt only on course switch — while the **Shot Marker** / **Shot Yardage
> Pill** / **Shot Segment Line** are reconciled incrementally as shots are added,
> so dropping a shot doesn't flash the other glyphs.

### 4.4 Loading Banner

A centered, non-blocking progress chip over the **Map Surface**, shown while the
displayed course's OSM data is being fetched from the network.

```
              ┌────────────────────┐
              │  ◌  Loading course…  │  ← Loading Banner
              └────────────────────┘
```

| Element | Canonical name | Source | Notes |
| --- | --- | --- | --- |
| Progress chip | **Loading Banner** | `loadingBanner` in [ContentView.swift](../caddie/ContentView.swift#L520-L534) | A `ProgressView` + "Loading course…" label in a `.regularMaterial` capsule |

> The **Loading Banner** is rendered unconditionally and driven by opacity
> (`isLoadingDisplayed`) rather than inserted/removed, so the overlay subtree is
> never added next to the map view. It is non-interactive
> (`.allowsHitTesting(false)`) and reflects only the **displayed** course's
> in-flight fetch count.

### 4.5 Search This Area Button

A pill anchored to the bottom of the **Map Surface**, shown on the browse map
(no course open) after the user pans or zooms, to re-run the nearby search for the
region now in view.

```
              ┌────────────────────────┐
              │  ↻  Search this area    │  ← Search This Area Button
              └────────────────────────┘
```

| Element | Canonical name | Source | Notes |
| --- | --- | --- | --- |
| Re-search pill | **Search This Area Button** | `searchHereButton` in [ContentView.swift](../caddie/ContentView.swift#L484-L509) | `arrow.trianglehead.clockwise`-led capsule; visible (and hit-testable) only while `pendingSearchRegion` is non-nil |

> Like the **Loading Banner**, it's rendered unconditionally and driven by
> opacity. It only appears while browsing — panning around an opened course does
> not prompt it.

---

## 5. Play Detail Pane

The **Play Detail Pane** is the trailing `.inspector` shown when **Play** mode is
on and a course is open. Source: [PlayDetailPane.swift](../caddie/PlayDetailPane.swift),
presented from [ContentView.swift](../caddie/ContentView.swift#L250-L262).

```
┌──────────────────────┐
│  ◁    Hole 1     ▷   │  ← Hole Navigation Header
├──────────────────────┤
│  Par            4    │  ← Par Stat Row
│  Yards        410    │  ← Yards Stat Row
│  Meters       375    │  ← Meters Stat Row
├──────────────────────┤
│  Shots           2   │  ← Shots Section Header
│  ① Shot 1    120 yd │  ← Shot Row
│  ② Shot 2     85 yd │
│  [ Clear All Shots ] │  ← Clear Shots Button
└──────────────────────┘
```

### 5.1 Hole Navigation Header

| Element | Canonical name | Icon / Source | Notes |
| --- | --- | --- | --- |
| Previous-hole button | **Previous Hole Button** | `chevron.left`, [PlayDetailPane.swift](../caddie/PlayDetailPane.swift#L39-L47) | Disabled on the first hole (or when no holes). Identifier `holePrevButton` |
| Centered hole title | **Hole Title Label** | [PlayDetailPane.swift](../caddie/PlayDetailPane.swift#L52-L53) | "Hole N" (or the OSM `ref`); "No Holes" when the course has none. Identifier `holeTitleLabel` |
| Next-hole button | **Next Hole Button** | `chevron.right`, [PlayDetailPane.swift](../caddie/PlayDetailPane.swift#L56-L65) | Disabled on the last hole (or when no holes). Identifier `holeNextButton` |

### 5.2 Hole Stats

| Element | Canonical name | Source | Notes |
| --- | --- | --- | --- |
| Par row | **Par Stat Row** | [PlayDetailPane.swift](../caddie/PlayDetailPane.swift#L73) | "—" when unknown |
| Yards row | **Yards Stat Row** | [PlayDetailPane.swift](../caddie/PlayDetailPane.swift#L75) | Shown only when the hole has a length |
| Meters row | **Meters Stat Row** | [PlayDetailPane.swift](../caddie/PlayDetailPane.swift#L76) | Shown only when the hole has a length |

> When the course has no hole geometry the stats/shots are replaced by a
> **No Hole Data** `ContentUnavailableView` (`flag.slash`,
> [PlayDetailPane.swift](../caddie/PlayDetailPane.swift#L87-L93)).

### 5.3 Shots Section

| Element | Canonical name | Icon / Source | Notes |
| --- | --- | --- | --- |
| "Shots" header + count | **Shots Section Header** | [PlayDetailPane.swift](../caddie/PlayDetailPane.swift#L111-L121) | Trailing monospaced shot count |
| One recorded shot | **Shot Row** | `N.circle.fill` (orange), [PlayDetailPane.swift](../caddie/PlayDetailPane.swift#L133-L149) | "Shot N" + a trailing "N yd" yardage (from the tee for shot 1, else from the previous shot) |
| Empty-state text | **Shots Empty Label** | [PlayDetailPane.swift](../caddie/PlayDetailPane.swift#L122-L129) | "Click the map to record a shot." |
| Clear-all button | **Clear Shots Button** | `trash` (destructive), [PlayDetailPane.swift](../caddie/PlayDetailPane.swift#L153-L162) | Removes every shot on the focused hole; only present once a shot exists. Identifier `clearShotsButton` |

> A hidden **Undo Shot** command (⌘Z) removes the last shot on the focused hole
> ([PlayDetailPane.swift](../caddie/PlayDetailPane.swift#L97-L103)). Shots are kept
> per hole (`shotsByHole`) and reset when a new course is selected.


## 6. Overlay Settings Window

The **Overlay Settings Window** is the app's `Settings` scene, opened from
**caddie ▸ Settings…** (⌘,). It is the single place to recolor and show/hide the
**Map Overlay Layers**. Source: [OverlaySettingsView.swift](../caddie/OverlaySettingsView.swift),
backed by the observable [OverlaySettings.swift](../caddie/OverlaySettings.swift)
store (persisted to `UserDefaults`).

```
┌──────────── Overlay Settings Window ────────────┐
│ Course Structure                                │  ← Course Structure Section
│   ⬛  Course Boundary               ●━━━○        │  ← Overlay Layer Row
│   ⬛  Holes                         ●━━━○        │
│ Boundary outline and hole centerlines.          │
│                                                 │
│ Course Features                                 │  ← Course Features Section
│   ⬛  Greens                        ●━━━○        │
│   ⬛  Fairways                      ●━━━○        │
│   ⬛  …                             ●━━━○        │
│                                                 │
│            [ Reset to Defaults ]                │  ← Reset to Defaults Button
└─────────────────────────────────────────────────┘
   ⬛ = Layer Color Well        ●━━━○ = Layer Visibility Switch
```

| Element | Canonical name | Source | Notes |
| --- | --- | --- | --- |
| Whole settings window | **Overlay Settings Window** | [caddieApp.swift](../caddie/caddieApp.swift#L39-L42), [OverlaySettingsView.swift](../caddie/OverlaySettingsView.swift#L13-L36) | A grouped `Form` in the `Settings` scene; fixed 440×560 |
| "Course Structure" group | **Course Structure Section** | [OverlaySettingsView.swift](../caddie/OverlaySettingsView.swift#L14-L21) | Boundary, Holes rows; footer "Boundary outline and hole centerlines." |
| "Course Features" group | **Course Features Section** | [OverlaySettingsView.swift](../caddie/OverlaySettingsView.swift#L23-L25) | The nine feature-kind rows |
| One layer's row | **Overlay Layer Row** | [OverlaySettingsView.swift](../caddie/OverlaySettingsView.swift#L40-L51) | Color well + name + visibility switch |
| Leading color picker well | **Layer Color Well** | `ColorPicker`, [OverlaySettingsView.swift](../caddie/OverlaySettingsView.swift#L42-L46) | Opens the system color panel; supports opacity |
| Trailing on/off switch | **Layer Visibility Switch** | `Toggle(.switch)`, [OverlaySettingsView.swift](../caddie/OverlaySettingsView.swift#L48-L49) | Shows/hides the matching **Map Overlay Layer** |
| Reset button | **Reset to Defaults Button** | [OverlaySettingsView.swift](../caddie/OverlaySettingsView.swift#L27-L32) | Clears every override, reverting all layers to their default color and visible; footer "Hidden layers are still fetched and cached — they're just not drawn." |

> The **Overlay Settings Window** is the only window besides the **Caddie
> Window**. Edits apply to the **Map Surface** immediately and persist across
> launches.

---

## 7. Behaviors

### 7.1 Selection

- Selecting a **Course Row** sets `selection` and triggers the `.onChange(of:
  selection)` handler ([ContentView.swift](../caddie/ContentView.swift#L273-L328)).
- Selection: sets `displayedCourse`, geocodes the **Course Marker** coordinate
  from the course address, frames the **Map Surface** camera to a
  2000m × 2000m region around the course, resets to **Plan** mode, records the
  course into **Recents**, and kicks off the OSM data fetch (showing the
  **Loading Banner** while it runs).
- Selection identity is a `SidebarSelection` enum case — `.favorite`, `.recent`,
  or `.result` ([ContentView.swift](../caddie/ContentView.swift#L140-L151)) — so
  the same course can be selected from different sections.

### 7.2 Favoriting

- Clicking the **Favorite Star Button** calls `toggleFavorite`: inserts a
  `FavoriteCourse` if absent, deletes it if present.
- Favoriting does not select the row or move the **Map Surface** camera.

### 7.3 Search

- Typing in the **Search Field** runs `performSearch` via `MKLocalSearch`
  filtered to `.golf` points of interest.
- Clearing the **Search Field** empties the **Results Section** immediately.

### 7.4 Recents Tracking

- `recordRecent` inserts the course and trims the **Recents Section** to the 10
  most recent entries.
- Right-clicking a **Course Row** in the **Recents Section** opens a context
  menu with **Remove from Recents**, which deselects the course first if it is
  the one currently shown.

### 7.5 Nearby Courses & Search This Area

- On launch (no course open), the app resolves the user's location, searches for
  golf courses within 50 miles, and frames the **Map Surface** so every
  **Nearby Course Flag** and the **User Location Dot** are visible
  ([ContentView.swift](../caddie/ContentView.swift#L330-L336)).
- Panning or zooming the browse map sets `pendingSearchRegion`, which reveals the
  **Search This Area Button** ([§4.5](#45-search-this-area-button)); clicking it
  re-runs the search for the region in view. Panning around an *opened* course
  does not trigger it.

### 7.6 Play Mode & Recording Shots

- The **Mode Toggle Button** flips `appMode`; **Play** mode opens the **Play
  Detail Pane** inspector and puts the **Map Surface** into shot-recording mode.
- In Play mode, clicking the map records a **Shot** on the focused hole (drawing
  a **Shot Marker**, **Shot Segment Line**, and **Shot Yardage Pill**); clicking
  a **Hole Tee Marker** instead focuses that hole
  ([CourseMapView.swift](../caddie/CourseMapView.swift#L343-L361)).
- **Clear Shots Button** removes every shot on the focused hole; ⌘Z removes the
  last one. Shots are kept per hole and reset on course change.

### 7.7 Sub-Course Switching

- The **Sub-Course Picker Menu** ([§3.2](#32-sub-course-picker-menu)) and the
  **Sub-Course Rows** ([§2.4](#24-sub-course-rows)) both read/write
  `activeSubCourseID`; changing either re-filters the boundary, holes, and
  features to the active sub-course ([ContentView.swift](../caddie/ContentView.swift#L329-L336)).

### 7.8 Overlay Styling

- Each **Overlay Layer Row** in the **Overlay Settings Window** drives one
  **Map Overlay Layer**. Adjusting a **Layer Color Well** recolors that layer on
  the **Map Surface** live; flipping a **Layer Visibility Switch** shows or hides
  it.
- Settings persist to `UserDefaults` (color as `#RRGGBBAA` sRGB hex) and survive
  relaunch. Unset layers fall back to their default color and visible, so a fresh
  install renders identically to before the window existed.
- A hidden layer is still fetched and cached — visibility only gates drawing.
- The **Reset to Defaults Button** clears every override at once.

---

## 8. States

| Surface | Empty state | Loading state | Error state |
| --- | --- | --- | --- |
| **Course Sidebar** | All three sections hidden → blank list with only the **Search Field** | No spinner; **Results Section** simply stays hidden until results arrive | Search failures are silent (`guard … else { return }`) — no error UI |
| **Map Detail Pane** | No course open → the browse map with **Nearby Course Flags** (or MapKit's default camera before a fix resolves) | The **Loading Banner** shows while the displayed course's OSM data is fetched; no tile-loading indicator beyond MapKit's own | OSM fetch errors are logged/cached only, never surfaced to the UI |
| **Play Detail Pane** | "Click the map to record a shot." when a hole has no shots | — | **No Hole Data** placeholder when the course has no hole geometry |

---

## 9. Where Do I Click To…

| Goal | Click target |
| --- | --- |
| Look up a course | **Search Field** |
| View a course on the map | Any **Course Row** |
| Mark/unmark a favorite | **Favorite Star Button** on that row |
| Return to a course you viewed before | A **Course Row** in the **Recents Section** |
| Remove a course from recents | Right-click the **Course Row** in the **Recents Section** → **Remove from Recents** |
| Switch between Plan and Play | **Mode Toggle Button** in the **Window Toolbar** |
| Record a shot | Click the **Map Surface** while in **Play** mode |
| Focus a different hole | A **Hole Tee Marker** (Play mode) or the ◁ / ▷ **Hole Navigation Header** buttons |
| Clear recorded shots | **Clear Shots Button** in the **Play Detail Pane** |
| Switch a facility's sub-course | **Sub-Course Picker Menu** (toolbar) or a **Sub-Course Row** (sidebar) |
| Re-search the visible map area | **Search This Area Button** (browse map) |
| Recolor or hide a map overlay | The matching **Overlay Layer Row** in the **Overlay Settings Window** (⌘,) |

---

## 10. Known Issues to Address

- Search failures and OSM fetch errors have no user-visible **error state**;
  they fail silently.
- The **Results Section** has no loading indicator — results just appear when the
  search returns. (Map data now shows the **Loading Banner**.)
- The **Course Sidebar** has no empty-state placeholder — with no favorites,
  recents, or results, it is a blank column below the **Search Field**.
