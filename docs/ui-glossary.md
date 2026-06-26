# Caddie UI/UX Glossary

This document assigns a single **canonical name** to every visible element in
the Caddie app so we can refer to each control unambiguously when filing bugs or
requesting changes. It is a naming contract, not a tutorial. All UI is defined
under the app source folder [caddie/](../caddie); the entire interface currently
lives in [caddie/ContentView.swift](../caddie/ContentView.swift), hosted by
[caddie/caddieApp.swift](../caddie/caddieApp.swift).

## Table of Contents

- [1. Top-Level Layout](#1-top-level-layout)
  - [1.1 Course Sidebar](#11-course-sidebar)
  - [1.2 Map Detail Pane](#12-map-detail-pane)
- [2. Course Sidebar](#2-course-sidebar)
  - [2.1 Search Field](#21-search-field)
  - [2.2 Sidebar Sections](#22-sidebar-sections)
  - [2.3 Course Row](#23-course-row)
  - [2.4 Sub-Course Rows](#24-sub-course-rows)
- [3. Map Detail Pane](#3-map-detail-pane)
  - [3.1 Map Overlay Layers](#31-map-overlay-layers)
  - [3.2 Sub-Course Picker](#32-sub-course-picker)
- [4. Overlay Settings Window](#4-overlay-settings-window)
- [5. Behaviors](#5-behaviors)
  - [5.1 Selection](#51-selection)
  - [5.2 Favoriting](#52-favoriting)
  - [5.3 Search](#53-search)
  - [5.4 Recents Tracking](#54-recents-tracking)
  - [5.5 Overlay Styling](#55-overlay-styling)
- [6. States](#6-states)
- [7. Where Do I Click To…](#7-where-do-i-click-to)
- [8. Known Issues to Address](#8-known-issues-to-address)

---

## 1. Top-Level Layout

The app is a single window driven by a `NavigationSplitView` with two columns:
a sidebar and a map detail pane.

```
┌──────────────────────── Courses Window ─────────────────────────────┐
│ ┌──────────────────┐ ┌──────────────────────────────────────────┐   │
│ │  Course Sidebar  │ │            Map Detail Pane               │   │
│ │ ┌──────────────┐ │ │                                          │   │
│ │ │ Search Field │ │ │            (satellite imagery)           │   │
│ │ └──────────────┘ │ │                                          │   │
│ │  ▸ Favorites     │ │                  📍                      │   │
│ │  ▸ Recents       │ │           Course Marker                  │   │
│ │  ▸ Results       │ │                                          │   │
│ │                  │ │                                          │   │
│ └──────────────────┘ └──────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
```

| Region | Canonical name | Source |
| --- | --- | --- |
| Whole window | **Courses Window** | [ContentView.swift](../caddie/ContentView.swift#L157-L191), [caddieApp.swift](../caddie/caddieApp.swift#L11-L19) |
| Left column | **Course Sidebar** | [ContentView.swift](../caddie/ContentView.swift#L158-L161) |
| Right column | **Map Detail Pane** | [ContentView.swift](../caddie/ContentView.swift#L162-L169) |

> The window's title is **Courses** (`.navigationTitle("Courses")`). There is no
> custom toolbar, status bar, or tab bar — the window chrome is the standard
> macOS title bar plus the split-view divider.

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
> 300 pts via `.navigationSplitViewColumnWidth` ([ContentView.swift](../caddie/ContentView.swift#L159-L160)).

### 1.2 Map Detail Pane

| Sub-region | Canonical name | Visibility | Role |
| --- | --- | --- | --- |
| Satellite map surface | **Map Surface** | Always | Realistic imagery map |
| Pin on the selected course | **Course Marker** | Only when a course is displayed | Marks the selected course coordinate |
| Drawn OSM geometry | **Map Overlay Layers** | Per layer, when fetched and the layer is enabled | Boundary, holes, and course-feature fills (see [§3.1](#31-map-overlay-layers)) |
| Floating segmented switcher | **Sub-Course Picker** | Only when the displayed facility has more than one sub-course | Switches the active sub-course of a multi-course facility (see [§3.2](#32-sub-course-picker)) |

> The color and visibility of every **Map Overlay Layer** are user-configurable in
> the **Overlay Settings Window** (see [§4](#4-overlay-settings-window)), opened
> from **caddie ▸ Settings…** (⌘,).

---

## 2. Course Sidebar

Source: `courseSidebar` in [ContentView.swift](../caddie/ContentView.swift#L323-L351).

### 2.1 Search Field

| Element | Canonical name | Source | Notes |
| --- | --- | --- | --- |
| Sidebar search box | **Search Field** | [ContentView.swift](../caddie/ContentView.swift#L171) | Prompt text is "Search for a course"; bound to `searchText` |

> The **Search Field** uses `.searchable(text:placement:.sidebar)`. Clearing it
> empties the **Results Section**; typing triggers a debounced `MKLocalSearch`
> filtered to golf points of interest.

### 2.2 Sidebar Sections

| Element | Canonical name | Source | Visibility rule |
| --- | --- | --- | --- |
| "Favorites" header | **Favorites Section Header** | [ContentView.swift](../caddie/ContentView.swift#L325-L332) | Hidden when `favorites.isEmpty` |
| "Recents" header | **Recents Section Header** | [ContentView.swift](../caddie/ContentView.swift#L333-L340) | Hidden when `recents.isEmpty` |
| "Results" header | **Results Section Header** | [ContentView.swift](../caddie/ContentView.swift#L341-L349) | Hidden when `searchResults.isEmpty` |

> Each section is a standard `List` `Section`. The three are stacked in fixed
> order: Favorites, then Recents, then Results. There is no collapse/expand
> control, drag-to-reorder, or count badge.

### 2.3 Course Row

A single row rendered by `courseRow(course:subtitle:)`
([ContentView.swift](../caddie/ContentView.swift#L353-L379)).

```
┌─────────────────────────────────────────────┐
│ Course Name Label              ⭐ Favorite   │
│ City Subtitle Label              Star Button │
└─────────────────────────────────────────────┘
```

| Element | Canonical name | Icon / Source | Notes |
| --- | --- | --- | --- |
| Primary course name text | **Course Name Label** | [ContentView.swift](../caddie/ContentView.swift#L356-L357) | `.headline` when a subtitle exists, otherwise `.body` |
| Secondary city text | **City Subtitle Label** | [ContentView.swift](../caddie/ContentView.swift#L358-L362) | Only present in the **Results Section** when the course has a non-empty city |
| Star toggle | **Favorite Star Button** | `star` / `star.fill`, [ContentView.swift](../caddie/ContentView.swift#L364-L373) | Yellow filled star when favorited; secondary-gray outline when not |

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
| Indented "All Courses" button | **All-Courses Row** | `square.stack`, `subCourseRows(for:)` in [ContentView.swift](../caddie/ContentView.swift) | Listed first; sets `activeSubCourseID` to `nil` to show the whole facility (every hole/feature, including untagged ones like a driving range) |
| Indented sub-course button | **Sub-Course Row** | `flag`, `subCourseRows(for:)` in [ContentView.swift](../caddie/ContentView.swift) | One per `displayedSubCourses` entry; sets `activeSubCourseID` |
| Trailing check on the active row | **Sub-Course Checkmark** | `checkmark`, [ContentView.swift](../caddie/ContentView.swift) | Tint-colored; marks the active row (the **All-Courses Row** when no sub-course is selected) |

> **Sub-Course Rows** appear only beneath the **displayed facility** and only
> when it has more than one sub-course, always led by the **All-Courses Row**.
> They are buttons, not `List` selections — the `List` selection stays on the
> facility while the active sub-course is shown here and in the **Sub-Course
> Picker**, which stay in sync. A facility opens on **All Courses** by default. An
> ordinary single course shows no **Sub-Course Rows**.

---

## 3. Map Detail Pane

Source: the `detail:` closure in [ContentView.swift](../caddie/ContentView.swift#L162-L169).

| Element | Canonical name | Source | Notes |
| --- | --- | --- | --- |
| Map view | **Map Surface** | [ContentView.swift](../caddie/ContentView.swift#L163-L168) | `Map(position:)` with `.mapStyle(.imagery(elevation: .realistic))` — 3D satellite imagery |
| Selected-course pin | **Course Marker** | [ContentView.swift](../caddie/ContentView.swift#L164-L166) | A `Marker` labeled with the course name at the course coordinate; only rendered when `displayedCourse` is non-nil |

> The **Map Surface** also draws **Map Overlay Layers** (boundary, holes, and
> per-feature fills) for the selected course's OSM geometry. Each layer's
> color and on/off state come from the **Overlay Settings Window** ([§4](#4-overlay-settings-window)).

### 3.1 Map Overlay Layers

Each layer is drawn only when its data is present **and** its **Layer Visibility
Switch** is on. Colors default to the values below (the asset-catalog course
colors, white for the boundary) until overridden in the **Overlay Settings
Window**.

| Element | Canonical name | Source | Default color | Settings layer |
| --- | --- | --- | --- | --- |
| Course outline polygon stroke | **Course Boundary Overlay** | [ContentView.swift](../caddie/ContentView.swift#L187-L191) | White | Course Boundary |
| Dashed tee→green centerline | **Hole Centerline** | [ContentView.swift](../caddie/ContentView.swift#L276-L289) | `CourseHole` | Holes |
| Numbered marker at each tee | **Hole Tee Marker** | [ContentView.swift](../caddie/ContentView.swift#L285-L288) | `CourseHole` | Holes |
| Filled/stroked feature geometry | **Feature Overlay** | [ContentView.swift](../caddie/ContentView.swift#L254-L271) | Per kind (below) | Per kind (below) |

The **Feature Overlay** is one shape per OSM feature, colored by kind. Closed
areas render as a translucent filled polygon; open paths as a stroked polyline.

| Feature kind | Canonical name | Default color | Settings layer |
| --- | --- | --- | --- |
| Green | **Green Overlay** | `CourseGreen` | Greens |
| Fairway | **Fairway Overlay** | `CourseFairway` | Fairways |
| Tee | **Tee Overlay** | `CourseTee` | Tees |
| Bunker | **Bunker Overlay** | `CourseBunker` | Bunkers |
| Rough | **Rough Overlay** | `CourseRough` | Rough |
| Water hazard | **Water Hazard Overlay** | `CourseWater` | Water Hazards |
| Cart path / path | **Cart Path Overlay** | `CoursePath` | Cart Paths |
| Driving range | **Driving Range Overlay** | `CourseDrivingRange` | Driving Range |
| Unknown | **Other Feature Overlay** | `CourseUnknown` | Other Features |

> A **Settings layer** maps one-to-one to a row in the **Overlay Settings
> Window**. The nine **Feature Overlay** kinds collapse cart paths and generic
> paths onto a single **Cart Paths** layer.

### 3.2 Sub-Course Picker

A floating segmented control over the bottom of the **Map Surface**, produced by
the `subCoursePicker` view, for facilities that contain more than one course
(e.g. Balboa Park's Championship and Executive courses).

```
              ┌──────────────────────────────────────────┐
              │  All  │  Championship  │   Executive   │  ← Sub-Course Picker
              └──────────────────────────────────────────┘
```

| Element | Canonical name | Source | Notes |
| --- | --- | --- | --- |
| Segmented course switcher | **Sub-Course Picker** | `subCoursePicker` in [ContentView.swift](../caddie/ContentView.swift) | `.pickerStyle(.segmented)` in a `.regularMaterial` capsule; bound to `activeSubCourseID` |
| Leading "All" segment | **All Segment** | [ContentView.swift](../caddie/ContentView.swift) | Tagged `nil`; the default, draws the whole facility (every hole/feature) so a multi-course park reads as one |
| One segment per sub-course | **Sub-Course Segment** | [ContentView.swift](../caddie/ContentView.swift) | Label is the sub-course name with a trailing "Course"/"Golf Course" trimmed |

> The **Sub-Course Picker** is hidden unless `displayedSubCourses.count > 1`, and
> opens on the **All Segment**. It mirrors the **Sub-Course Rows** in the sidebar
> ([§2.4](#24-sub-course-rows)) — both read and write `activeSubCourseID`, so
> switching from either updates the other and re-filters the **Map Overlay
> Layers**: a sub-course segment shows its own boundary and the holes/features
> that fall inside it, while **All** shows the facility boundary and everything.

---

## 4. Overlay Settings Window

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
| Whole settings window | **Overlay Settings Window** | [caddieApp.swift](../caddie/caddieApp.swift#L40-L43), [OverlaySettingsView.swift](../caddie/OverlaySettingsView.swift) | A grouped `Form` in the `Settings` scene; fixed 440×560 |
| "Course Structure" group | **Course Structure Section** | [OverlaySettingsView.swift](../caddie/OverlaySettingsView.swift) | Boundary, Holes rows |
| "Course Features" group | **Course Features Section** | [OverlaySettingsView.swift](../caddie/OverlaySettingsView.swift) | The nine feature-kind rows |
| One layer's row | **Overlay Layer Row** | [OverlaySettingsView.swift](../caddie/OverlaySettingsView.swift) | Color well + name + visibility switch |
| Leading color picker well | **Layer Color Well** | `ColorPicker`, [OverlaySettingsView.swift](../caddie/OverlaySettingsView.swift) | Opens the system color panel; supports opacity |
| Trailing on/off switch | **Layer Visibility Switch** | `Toggle(.switch)`, [OverlaySettingsView.swift](../caddie/OverlaySettingsView.swift) | Shows/hides the matching **Map Overlay Layer** |
| Reset button | **Reset to Defaults Button** | [OverlaySettingsView.swift](../caddie/OverlaySettingsView.swift) | Clears every override, reverting all layers to their default color and visible |

> The **Overlay Settings Window** is the only window besides the **Courses
> Window**. Edits apply to the **Map Surface** immediately and persist across
> launches.

---

## 5. Behaviors

### 5.1 Selection

- Selecting a **Course Row** sets `selection` and triggers the `.onChange(of:
  selection)` handler ([ContentView.swift](../caddie/ContentView.swift#L183-L190)).
- Selection: sets `displayedCourse`, animates the **Map Surface** camera to a
  2000m × 2000m region around the course, records the course into **Recents**,
  and kicks off the OSM data fetch.
- Selection identity is a `SidebarSelection` enum case — `.favorite`, `.recent`,
  or `.result` ([ContentView.swift](../caddie/ContentView.swift#L143-L153)) — so
  the same course can be selected from different sections.

### 5.2 Favoriting

- Clicking the **Favorite Star Button** calls `toggleFavorite`
  ([ContentView.swift](../caddie/ContentView.swift#L292-L301)): inserts a
  `FavoriteCourse` if absent, deletes it if present.
- Favoriting does not select the row or move the **Map Surface** camera.

### 5.3 Search

- Typing in the **Search Field** runs `performSearch`
  ([ContentView.swift](../caddie/ContentView.swift#L303-L321)) via `MKLocalSearch`
  filtered to `.golf` points of interest.
- Clearing the **Search Field** empties the **Results Section** immediately.

### 5.4 Recents Tracking

- `recordRecent` ([ContentView.swift](../caddie/ContentView.swift#L256-L272))
  inserts the course and trims the **Recents Section** to the 10 most recent
  entries.

### 5.5 Overlay Styling

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

## 6. States

| Surface | Empty state | Loading state | Error state |
| --- | --- | --- | --- |
| **Course Sidebar** | All three sections hidden → blank list with only the **Search Field** | No spinner; **Results Section** simply stays hidden until results arrive | Search failures are silent (`guard … else { return }`) — no error UI |
| **Map Detail Pane** | No **Course Marker** until a course is selected; **Map Surface** shows default `.automatic` camera | No tile-loading indicator beyond MapKit's own | OSM fetch errors are logged/cached only, never surfaced to the UI |

---

## 7. Where Do I Click To…

| Goal | Click target |
| --- | --- |
| Look up a course | **Search Field** |
| View a course on the map | Any **Course Row** |
| Mark/unmark a favorite | **Favorite Star Button** on that row |
| Return to a course you viewed before | A **Course Row** in the **Recents Section** |
| Recolor or hide a map overlay | The matching **Overlay Layer Row** in the **Overlay Settings Window** (⌘,) |

---

## 8. Known Issues to Address

- Search failures and OSM fetch errors have no user-visible **error state**;
  they fail silently.
- There is no loading indicator anywhere; the **Results Section** and
  **Course Marker** just appear when their data is ready.
- The **Course Sidebar** has no empty-state placeholder — with no favorites,
  recents, or results, it is a blank column below the **Search Field**.
