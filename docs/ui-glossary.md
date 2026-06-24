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
- [3. Map Detail Pane](#3-map-detail-pane)
- [4. Behaviors](#4-behaviors)
  - [4.1 Selection](#41-selection)
  - [4.2 Favoriting](#42-favoriting)
  - [4.3 Search](#43-search)
  - [4.4 Recents Tracking](#44-recents-tracking)
- [5. States](#5-states)
- [6. Where Do I Click To…](#6-where-do-i-click-to)
- [7. Known Issues to Address](#7-known-issues-to-address)

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

---

## 3. Map Detail Pane

Source: the `detail:` closure in [ContentView.swift](../caddie/ContentView.swift#L162-L169).

| Element | Canonical name | Source | Notes |
| --- | --- | --- | --- |
| Map view | **Map Surface** | [ContentView.swift](../caddie/ContentView.swift#L163-L168) | `Map(position:)` with `.mapStyle(.imagery(elevation: .realistic))` — 3D satellite imagery |
| Selected-course pin | **Course Marker** | [ContentView.swift](../caddie/ContentView.swift#L164-L166) | A `Marker` labeled with the course name at the course coordinate; only rendered when `displayedCourse` is non-nil |

> The **Map Surface** has no overlays, controls, or annotations beyond the
> single **Course Marker**. OSM course geometry (boundary, holes, features) is
> fetched and cached ([ContentView.swift](../caddie/ContentView.swift#L193-L283))
> but is **not yet drawn** on the **Map Surface**.

---

## 4. Behaviors

### 4.1 Selection

- Selecting a **Course Row** sets `selection` and triggers the `.onChange(of:
  selection)` handler ([ContentView.swift](../caddie/ContentView.swift#L183-L190)).
- Selection: sets `displayedCourse`, animates the **Map Surface** camera to a
  2000m × 2000m region around the course, records the course into **Recents**,
  and kicks off the OSM data fetch.
- Selection identity is a `SidebarSelection` enum case — `.favorite`, `.recent`,
  or `.result` ([ContentView.swift](../caddie/ContentView.swift#L143-L153)) — so
  the same course can be selected from different sections.

### 4.2 Favoriting

- Clicking the **Favorite Star Button** calls `toggleFavorite`
  ([ContentView.swift](../caddie/ContentView.swift#L292-L301)): inserts a
  `FavoriteCourse` if absent, deletes it if present.
- Favoriting does not select the row or move the **Map Surface** camera.

### 4.3 Search

- Typing in the **Search Field** runs `performSearch`
  ([ContentView.swift](../caddie/ContentView.swift#L303-L321)) via `MKLocalSearch`
  filtered to `.golf` points of interest.
- Clearing the **Search Field** empties the **Results Section** immediately.

### 4.4 Recents Tracking

- `recordRecent` ([ContentView.swift](../caddie/ContentView.swift#L256-L272))
  inserts the course and trims the **Recents Section** to the 10 most recent
  entries.

---

## 5. States

| Surface | Empty state | Loading state | Error state |
| --- | --- | --- | --- |
| **Course Sidebar** | All three sections hidden → blank list with only the **Search Field** | No spinner; **Results Section** simply stays hidden until results arrive | Search failures are silent (`guard … else { return }`) — no error UI |
| **Map Detail Pane** | No **Course Marker** until a course is selected; **Map Surface** shows default `.automatic` camera | No tile-loading indicator beyond MapKit's own | OSM fetch errors are logged/cached only, never surfaced to the UI |

---

## 6. Where Do I Click To…

| Goal | Click target |
| --- | --- |
| Look up a course | **Search Field** |
| View a course on the map | Any **Course Row** |
| Mark/unmark a favorite | **Favorite Star Button** on that row |
| Return to a course you viewed before | A **Course Row** in the **Recents Section** |

---

## 7. Known Issues to Address

- OSM geometry (boundary, holes, greens, bunkers, fairways) is fetched and
  cached but never rendered on the **Map Surface** — only the single
  **Course Marker** appears.
- Search failures and OSM fetch errors have no user-visible **error state**;
  they fail silently.
- There is no loading indicator anywhere; the **Results Section** and
  **Course Marker** just appear when their data is ready.
- The **Course Sidebar** has no empty-state placeholder — with no favorites,
  recents, or results, it is a blank column below the **Search Field**.
