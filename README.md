# Caddie

A native macOS app for finding golf courses and viewing them on a realistic 3D
satellite map. Search for any course, star your favorites, and Caddie keeps
track of the ones you've recently viewed — while fetching detailed course
geometry (boundaries, holes, greens, bunkers, fairways) from OpenStreetMap in
the background.

## Table of Contents

- [Caddie](#caddie)
  - [Table of Contents](#table-of-contents)
  - [Features](#features)
  - [Screenshots](#screenshots)
  - [Requirements](#requirements)
  - [Getting Started](#getting-started)
    - [Debug logging](#debug-logging)
  - [Architecture](#architecture)
    - [Data Models](#data-models)
    - [OpenStreetMap Integration](#openstreetmap-integration)
  - [Project Structure](#project-structure)
  - [Documentation](#documentation)
  - [Roadmap](#roadmap)

## Features

- **Course search** — find golf courses anywhere using Apple's `MKLocalSearch`,
  filtered to golf points of interest.
- **Realistic satellite map** — selected courses are framed on a 3D imagery map
  with elevation.
- **Favorites** — star courses to keep them at the top of the sidebar.
- **Recents** — the last 10 courses you viewed are remembered automatically.
- **OpenStreetMap enrichment** — course boundaries, holes, and features (greens,
  fairways, tees, bunkers, hazards, cart paths) are fetched from the Overpass
  API and cached locally for offline reuse.
- **Customizable overlays** — an **Overlay Settings** window (⌘,) lets you recolor
  every map overlay layer and toggle each one's visibility.

## Screenshots

> _Add screenshots of the Course Sidebar and Map Detail Pane here._

## Requirements

- macOS 26
- Xcode 26
- Swift 6

## Getting Started

No API keys or accounts are required. The OpenStreetMap data comes from the
public [Overpass API](https://overpass-api.de/), which Caddie queries politely
with built-in throttling and back-off.

### Debug logging

OpenStreetMap fetch logging is gated behind the `OSM_DEBUG` compilation
condition. Add `OSM_DEBUG` to the scheme's *Swift Compiler – Custom Flags →
Active Compilation Conditions* to print Overpass queries and responses to the
console.

`DEBUG` builds also add a **Debug ▸ Clear OSM Cache** menu command (⌘⇧K) that
deletes every cached `OSMCourseData` row so courses re-fetch fresh geometry,
leaving favorites and recents untouched.

## Architecture

Caddie is a SwiftUI app backed by SwiftData for persistence. The entire UI is a
`NavigationSplitView` with a searchable **Course Sidebar** and a **Map Detail
Pane** (see [docs/ui-glossary.md](docs/ui-glossary.md) for the full UI naming
contract).

### Data Models

All persistence uses [SwiftData](https://developer.apple.com/documentation/swiftdata)
`@Model` types defined in [caddie/ContentView.swift](caddie/ContentView.swift):

| Model | Purpose |
| --- | --- |
| `RecentCourse` | The 10 most recently viewed courses |
| `FavoriteCourse` | User-starred courses |
| `OSMCourseData` | Cached OpenStreetMap geometry with a fetch status and timestamp |

`GolfCourse` is the lightweight, `Codable` value type used throughout the UI and
search layer.

### OpenStreetMap Integration

When a course is selected, Caddie fetches detailed geometry from the Overpass
API:

- [OSMFetcher.swift](caddie/OSMFetcher.swift) — an `actor` that builds Overpass
  QL queries, posts them, handles rate-limiting (HTTP 429/503) with exponential
  back-off, and deduplicates in-flight requests.
- [OSMCourse.swift](caddie/OSMCourse.swift) — the domain model and the
  `OSMCourseBuilder` that walks an Overpass response, resolves node references
  into coordinate arrays, and produces a structured `OSMCourse` (boundary,
  holes, and typed features).

Cached results are stored as `OSMCourseData` with a 30-day TTL for successful
fetches and a 1-hour TTL for errors, so reopening a course is instant and
network-free.

## Project Structure

```
caddie/
  caddieApp.swift          App entry point; SwiftData container + Settings scene
  ContentView.swift        UI, SwiftData models, search, and selection handling
  OverlaySettings.swift    Observable per-overlay color/visibility store
  OverlaySettingsView.swift Overlay Settings window (⌘,)
  OSMCourse.swift          OpenStreetMap domain model + Overpass response parsing
  OSMFetcher.swift         Overpass API client (actor) with throttling and caching
  Assets.xcassets          App icon, accent color, and per-overlay course colors
docs/
  ui-glossary.md      Canonical names for every visible UI element
```

## Documentation

Project documentation lives in the [docs/](docs) directory:

- [UI/UX Glossary](docs/ui-glossary.md) — canonical names for every visible
  element in the app.
- [iCloud Sync](docs/icloud-sync.md) — design and implementation plan for
  syncing favorites, recents, and overlay settings across Macs (planned; not yet
  implemented).

## Roadmap

- Surface search and fetch errors in the UI instead of failing silently.
- Add a loading indicator for search results.
- Add an empty-state placeholder to the **Course Sidebar**.
