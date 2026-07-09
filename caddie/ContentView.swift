//
//  ContentView.swift
//  caddie
//
//  Created by Jeff Roberts on 6/23/26.
//

import CoreLocation
import MapKit
import Observation
import SwiftData
import SwiftUI

struct GolfCourse: Codable, Identifiable, Hashable {
    var id: String { identifier }
    let identifier: String
    let name: String
    let address: String
    let city: String
    let state: String
    let country: String
    let countryCode: String
    let phone: String
    let website: String
    let latitude: Double
    let longitude: Double
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

@Model
final class RecentCourse {
    @Attribute(.unique) var identifier: String
    var name: String
    var address: String
    var city: String
    var state: String = ""
    var country: String
    var countryCode: String
    var phone: String
    var website: String
    var latitude: Double
    var longitude: Double
    var lastVisited: Date

    init(from course: GolfCourse, lastVisited: Date = .now) {
        self.identifier = course.identifier
        self.name = course.name
        self.address = course.address
        self.city = course.city
        self.state = course.state
        self.country = course.country
        self.countryCode = course.countryCode
        self.phone = course.phone
        self.website = course.website
        self.latitude = course.latitude
        self.longitude = course.longitude
        self.lastVisited = lastVisited
    }

    var asGolfCourse: GolfCourse {
        GolfCourse(
            identifier: identifier,
            name: name,
            address: address,
            city: city,
            state: state,
            country: country,
            countryCode: countryCode,
            phone: phone,
            website: website,
            latitude: latitude,
            longitude: longitude
        )
    }
}

@Model
final class FavoriteCourse {
    @Attribute(.unique) var identifier: String
    var name: String
    var address: String
    var city: String
    var state: String = ""
    var country: String
    var countryCode: String
    var phone: String
    var website: String
    var latitude: Double
    var longitude: Double
    var dateFavorited: Date

    init(from course: GolfCourse, dateFavorited: Date = .now) {
        self.identifier = course.identifier
        self.name = course.name
        self.address = course.address
        self.city = course.city
        self.state = course.state
        self.country = course.country
        self.countryCode = course.countryCode
        self.phone = course.phone
        self.website = course.website
        self.latitude = course.latitude
        self.longitude = course.longitude
        self.dateFavorited = dateFavorited
    }

    var asGolfCourse: GolfCourse {
        GolfCourse(
            identifier: identifier,
            name: name,
            address: address,
            city: city,
            state: state,
            country: country,
            countryCode: countryCode,
            phone: phone,
            website: website,
            latitude: latitude,
            longitude: longitude
        )
    }
}

@Model
final class OSMCourseData {
    @Attribute(.unique) var courseIdentifier: String
    var encodedCourse: Data?
    var fetchedAt: Date
    var fetchStatus: String
    /// The `currentBuilderVersion` in effect when this row was written. Defaults to
    /// `0` so rows persisted before versioning existed migrate as "pre-v1" and are
    /// refetched once. New/refreshed rows are stamped with the current version.
    var builderVersion: Int = 0

    init(courseIdentifier: String, encodedCourse: Data? = nil, fetchedAt: Date = .now, fetchStatus: String = "pending", builderVersion: Int = 0) {
        self.courseIdentifier = courseIdentifier
        self.encodedCourse = encodedCourse
        self.fetchedAt = fetchedAt
        self.fetchStatus = fetchStatus
        self.builderVersion = builderVersion
    }
}

enum SidebarSelection: Hashable {
    case favorite(GolfCourse)
    case recent(GolfCourse)
    case result(GolfCourse)

    var course: GolfCourse {
        switch self {
        case .favorite(let c), .recent(let c), .result(let c): return c
        }
    }
}

/// Capacity of the in-memory decoded-course cache (`ContentView.osmCache`). A user
/// realistically revisits a handful of courses per session, so 16 comfortably covers
/// a working set (recents + a few comparisons) while bounding worst-case memory at
/// ~16 decoded courses (tens of MB). Tunable here in one place.
private let osmCacheCapacity = 16

/// Version of the OSM course-building logic (`OSMCourseBuilder.makeCourse`). Bump
/// this whenever a change alters the SHAPE of a built `OSMCourse` (sub-course
/// splitting, hole parsing, feature attribution) so persisted blobs produced by an
/// older builder are treated as stale and refetched, rather than served forever
/// within the 30-day success TTL. History:
///   1 — ref-embedded nine-name sub-courses + numeric hole-ref parsing (Steele Canyon).
private let currentBuilderVersion = 1

enum AppMode: String, CaseIterable {
    case plan = "Plan"
    case play = "Play"

    /// SF Symbol shown in the toolbar toggle for this mode.
    var symbol: String {
        switch self {
        case .plan: return "map"
        case .play: return "figure.golf"
        }
    }

    /// The mode this one toggles to.
    var toggled: AppMode {
        switch self {
        case .plan: return .play
        case .play: return .plan
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.osmFetcher) private var osmFetcher
    @Environment(OverlaySettings.self) private var overlay
    @Query(sort: \RecentCourse.lastVisited, order: .reverse) private var recents: [RecentCourse]
    @Query(sort: \FavoriteCourse.name, order: .forward) private var favorites: [FavoriteCourse]
    @State private var searchText: String = ""
    @State private var searchResults: [GolfCourse] = []
    /// Whether a course text search is currently in flight, so the Results section
    /// can show progress instead of a dead-looking empty list while MapKit works.
    @State private var isSearching: Bool = false
    /// The most recent search task, cancelled on each keystroke so a slow earlier
    /// query can't overwrite the results (or clear the progress) of a newer one.
    @State private var searchTask: Task<Void, Never>?
    @State private var selection: SidebarSelection?
    @State private var displayedCourse: GolfCourse?
    @State private var courseOutlines: [[CLLocationCoordinate2D]] = []
    @State private var courseFeatures: [OSMFeature] = []
    @State private var courseHoles: [OSMHole] = []
    /// Sub-courses of the displayed facility (empty for an ordinary single course);
    /// drives both the sidebar disclosure and the on-map segmented picker.
    @State private var displayedSubCourses: [OSMSubCourse] = []
    /// The sub-course currently shown, or `nil` when the displayed course is a single
    /// course (or, transiently, before its OSM data has loaded).
    @State private var activeSubCourseID: String?
    /// Latest pointer location over the map (map-local coordinates), or `nil` when
    /// the pointer is elsewhere. Drives the Play-mode hover preview that lifts a
    /// dimmed hole back to full opacity.
    @State private var mapHoverLocation: CGPoint?
    /// The framing the map should apply (top-down course region or a tilted
    /// per-hole camera). Tagged with an identity token so re-selecting the same
    /// course re-frames it (an equal value would otherwise be diffed as "no
    /// change"). `nil` until the first frame request.
    @State private var framingRequest: MapFramingRequest?
    /// The course whose real footprint we have already top-down framed, so the
    /// coarse selection frame is upgraded to a footprint frame exactly once (when
    /// geometry first loads) rather than on every cached/network redraw.
    @State private var framedFootprintCourseID: String?
    /// Cancellable handle for the progressive feature renderer (see `renderChunked`),
    /// so a new selection can stop a paint that is still in progress.
    @State private var featureRenderTask: Task<Void, Never>?
    /// In-memory decoded-geometry cache, keyed by course id, so re-selecting a
    /// course in the same session skips the SwiftData fetch + JSON decode. Bounded
    /// (LRU) so a long browsing session can't grow it without limit; an evicted
    /// course simply re-decodes from L2 (SwiftData) or refetches on next selection.
    @State private var osmCache = LRUCache<String, OSMCourse>(capacity: osmCacheCapacity)
    /// Reference-counted set of course ids with an in-flight network fetch. A count
    /// (not a flag) keeps the spinner visible when two fetches for the same course
    /// overlap — the dedup'd second call must not clear it early.
    @State private var loadingCounts: [String: Int] = [:]
    /// Shared in-flight fetch tasks keyed by course id. Overlapping selections of
    /// the same course JOIN the same task and both apply its result, instead of the
    /// second caller racing the first (and going blank if the first is cancelled).
    @State private var inFlightFetches: [String: Task<OSMCourse?, Error>] = [:]
    /// Geocoded coordinate for the course marker, resolved from the full street
    /// address + city + country. `nil` while geocoding is in flight or if it fails,
    /// in which case the marker falls back to `displayedCourse.coordinate`.
    @State private var markerCoordinate: CLLocationCoordinate2D?
    /// Owns the `CLLocationManager` so it stays retained for the view's lifetime;
    /// without a strong reference the system permission prompt never appears.
    @State private var locationManager = LocationManager()
    /// Golf courses found within `nearbyRadiusMeters` of the person's location,
    /// shown as markers on the map. Empty until a fix resolves.
    @State private var nearbyCourses: [GolfCourse] = []
    /// Whether the user is planning (browsing) or actively playing the course.
    @State private var appMode: AppMode = .plan
    /// The hole currently focused in the Play detail pane.
    @State private var currentHoleIndex: Int = 0
    /// Recorded shots keyed by hole OSM id, for the displayed course. Reset when a
    /// new course is selected.
    @State private var shotsByHole: [Int64: [Shot]] = [:]
    /// Region the user has panned/zoomed to on the nearby map but not yet searched;
    /// non-nil drives the "Search here" button. Cleared once a search runs.
    @State private var pendingSearchRegion: MKCoordinateRegion?

    #if DEBUG
    /// Whether the developer JSON inspector panel is shown (DEBUG builds only).
    @State private var showDataInspector = false
    /// Memoizes the encoded inspector sources. Building a `DevInspectorSource`
    /// JSON-encodes the entire OSM course (every feature and coordinate), so doing
    /// it inside `body` re-encodes the whole course on every re-render — and map
    /// hover/pan/zoom rebuild `body` constantly. Cache by a cheap course key so the
    /// encoding runs once per course load instead of once per frame.
    @State private var inspectorSourceCache = InspectorSourceCache()
    #endif

    /// Radius for the "courses near me" search: 50 miles in meters.
    private static let nearbyRadiusMeters: CLLocationDistance = 80_467

    
    var body: some View {
        NavigationSplitView {
          courseSidebar
            .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 300)
        } detail: {
            courseMap
                .inspector(isPresented: inspectorPresented) {
                    inspectorContent
                }
        }
        .navigationTitle(displayedCourse?.name ?? "Caddie")
        .navigationSubtitle(displayedCourse.map { locationSubtitle(for: $0) ?? "" } ?? "")
        .background(FullScreenToolbarAutoHide())
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search for a course")
        .onChange(of: searchText) { _, newValue in
            searchTask?.cancel()
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                searchResults = []
                isSearching = false
                return
            }
            isSearching = true
            searchTask = Task {
                await performSearch(query: trimmed)
            }
        }
        .onChange(of: selection) { _, newValue in
            guard let course = newValue?.course else {
                // Returning to the nearby browse map: tear down the opened course
                // and its overlays, then re-frame so every nearby flag is visible.
                appMode = .plan
                displayedCourse = nil
                markerCoordinate = nil
                courseOutlines = []
                courseFeatures = []
                courseHoles = []
                displayedSubCourses = []
                activeSubCourseID = nil
                currentHoleIndex = 0
                shotsByHole = [:]
                pendingSearchRegion = nil
                framedFootprintCourseID = nil
                featureRenderTask?.cancel()
                if !nearbyCourses.isEmpty {
                    framingRequest = MapFramingRequest(
                        framing: .topDown(regionFitting(nearbyCourses.map(\.coordinate)))
                    )
                } else {
                    // No nearby results cached (e.g. opened straight from search):
                    // re-run the local search around the user's location.
                    Task {
                        guard let coordinate = await locationManager.currentCoordinate() else { return }
                        await loadNearbyCourses(around: coordinate)
                    }
                }
                return
            }
            displayedCourse = course
            markerCoordinate = nil
            Task {
                let query = [course.address, course.city, course.country]
                    .filter { !$0.isEmpty }
                    .joined(separator: ", ")
                let mapItems = try? await MKGeocodingRequest(addressString: query)?.mapItems
                guard displayedCourse?.identifier == course.identifier else { return }
                markerCoordinate = mapItems?.first?.location.coordinate
            }
            courseOutlines = []
            courseFeatures = []
            courseHoles = []
            displayedSubCourses = []
            activeSubCourseID = nil
            currentHoleIndex = 0
            shotsByHole = [:]
            pendingSearchRegion = nil
            framedFootprintCourseID = nil
            // Stop any progressive overlay render still painting the previous course.
            featureRenderTask?.cancel()
            // A coarse top-down frame for instant feedback (and to cover a far,
            // cross-country jump); upgraded to the real footprint once geometry loads.
            framingRequest = MapFramingRequest(framing: .topDown(MKCoordinateRegion(
                center: course.coordinate,
                latitudinalMeters: 2000,
                longitudinalMeters: 2000
            )))
            recordRecent(course)
            // Cancel any in-flight fetch for a course the user has already moved past
            // so the new selection doesn't have to compete with it for the same
            // Overpass mirror.
            for (id, task) in inFlightFetches where id != course.identifier {
                task.cancel()
            }
            // Draw whatever is already cached (decoded off the main thread) and then
            // progressively refresh from the network (boundary first, features after).
            Task {
                let cached = await cachedCourse(for: course)
                drawCourse(cached, for: course)
                await ensureOSMData(for: course)
            }
        }
        .onChange(of: activeSubCourseID) {
            // Switching sub-course (from the sidebar or the on-map picker) re-filters
            // the boundary, holes and features to the newly active course.
            guard let course = displayedCourse, let osmCourse = osmCache[course.identifier] else { return }
            // "All" merges every sub-course's holes, and sub-courses share hole
            // numbers (Balboa's Championship + Executive both run 1–9), so hole-by-hole
            // play over the merged set shows each low number twice. Play mode therefore
            // requires a concrete sub-course: if it's cleared to "All" here, snap to the
            // largest so navigation stays 1…N with no duplicates.
            if appMode == .play, activeSubCourseID == nil, displayedSubCourses.count > 1 {
                activeSubCourseID = displayedSubCourses.first?.id
                return
            }
            applyOutline(from: osmCourse, for: course)
            applyFeatures(from: osmCourse, for: course)
            if appMode == .play {
                // The active sub-course changed the hole set; keep the index in range
                // and re-frame the (possibly different) current hole.
                currentHoleIndex = min(currentHoleIndex, max(0, courseHoles.count - 1))
                frameCurrentHole()
            }
        }
        .onChange(of: appMode) {
            // Entering Play mode drops into the current hole's tilted camera; leaving
            // it returns to the top-down course footprint.
            guard let course = displayedCourse else { return }
            if appMode == .play {
                // On a multi-course facility "All" is a Plan-mode overview only; scope
                // Play to the largest sub-course so its holes don't collide with a
                // sibling course's identical hole numbers.
                if activeSubCourseID == nil, displayedSubCourses.count > 1 {
                    currentHoleIndex = 0
                    activeSubCourseID = displayedSubCourses.first?.id
                    // Framing happens once the sub-course change refreshes courseHoles.
                } else {
                    frameCurrentHole()
                }
            } else {
                frameCourseFootprint(for: course)
            }
        }
        .onChange(of: currentHoleIndex) {
            // Navigating holes in Play mode swings the camera to the new hole's
            // tee→pin heading.
            frameCurrentHole()
        }
        .task {
            // Resolve the person's location once, find golf courses within 50 miles,
            // and frame the map so every marker (and the user dot) is visible.
            guard displayedCourse == nil,
                  let coordinate = await locationManager.currentCoordinate() else { return }
            await loadNearbyCourses(around: coordinate)
        }
        .toolbar {
            if displayedCourse != nil {
                ToolbarItem(placement: .navigation) {
                    Button {
                        // Deselecting returns to the nearby browse map (handled by
                        // `.onChange(of: selection)`), where the local-area search is
                        // available again.
                        selection = nil
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.backward")
                                .frame(width: 16)
                            Text("Courses")
                                .fixedSize()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                    }
                    .help("Back to nearby courses")
                    .accessibilityIdentifier("backToNearbyButton")
                }
            }
            if displayedCourse != nil {
                ToolbarItem(placement: .navigation) {
                    Button {
                        appMode = appMode.toggled
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: appMode.symbol)
                                .frame(width: 16)
                            Text(appMode.rawValue)
                                .fixedSize()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                    }
                    .help("Switch to \(appMode.toggled.rawValue) mode")
                    .accessibilityIdentifier("modeToggleButton")
                }
            }
            if displayedSubCourses.count > 1 {
                ToolbarItem(placement: .navigation) {
                    Menu {
                        Button {
                            activeSubCourseID = nil
                        } label: {
                            HStack {
                                Text("All")
                                if activeSubCourseID == nil {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .accessibilityIdentifier("subCourseItem_all")
                        Divider()
                        ForEach(displayedSubCourses) { sub in
                            Button {
                                activeSubCourseID = sub.id
                            } label: {
                                HStack {
                                    Text(subCourseLabel(sub))
                                    if activeSubCourseID == sub.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            .accessibilityIdentifier("subCourseItem_\(sub.id)")
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "flag")
                                .frame(width: 16)
                            Text(activeSubCourseLabel)
                                .fixedSize()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                    }
                    .menuStyle(.button)
                    .accessibilityIdentifier("subCoursePickerButton")
                    .accessibilityValue(activeSubCourseLabel)
                }
            }
            #if DEBUG
            if displayedCourse != nil {
                ToolbarItem(placement: .automatic) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showDataInspector.toggle()
                        }
                    } label: {
                        Image(systemName: "curlybraces")
                    }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
                    .help("Toggle the JSON data inspector")
                    .accessibilityIdentifier("dataInspectorToggle")
                }
            }
            #endif
        }
    }

    private var activeSubCourseLabel: String {
        guard let id = activeSubCourseID,
              let sub = displayedSubCourses.first(where: { $0.id == id }) else {
            return "All"
        }
        return subCourseLabel(sub)
    }

    /// OSM id of the hole currently focused in the Play pane, or `nil` if none.
    private var currentHoleID: Int64? {
        guard courseHoles.indices.contains(currentHoleIndex) else { return nil }
        return courseHoles[currentHoleIndex].osmIdentifier
    }

    /// Shots recorded on the currently focused hole. Only surfaced in Play mode;
    /// switching back to Plan hides them from the map without discarding them, so
    /// returning to Play restores the same shots.
    private var currentHoleShots: [Shot] {
        guard appMode == .play, let id = currentHoleID else { return [] }
        return shotsByHole[id] ?? []
    }

    /// Appends a shot at `coordinate` to the currently focused hole.
    private func addShotToCurrentHole(_ coordinate: CLLocationCoordinate2D) {
        guard let id = currentHoleID else { return }
        shotsByHole[id, default: []].append(Shot(coordinate: coordinate))
    }

    /// Removes every shot on the currently focused hole.
    private func clearCurrentHoleShots() {
        guard let id = currentHoleID else { return }
        shotsByHole[id] = nil
    }

    /// Removes the most recently recorded shot on the currently focused hole, e.g.
    /// in response to cmd+z. No-op when the hole has no shots.
    private func undoLastShot() {
        guard let id = currentHoleID, var holeShots = shotsByHole[id], !holeShots.isEmpty else { return }
        holeShots.removeLast()
        shotsByHole[id] = holeShots.isEmpty ? nil : holeShots
    }

    /// Switches the Play focus to the hole with the given OSM id, e.g. when its
    /// tee marker is tapped on the map.
    private func selectHole(withID id: Int64) {
        guard let index = courseHoles.firstIndex(where: { $0.osmIdentifier == id }) else { return }
        currentHoleIndex = index
    }

    private var courseMap: some View {
        CourseMapView(
            outlines: courseOutlines,
            features: courseFeatures,
            holes: courseHoles,
            displayedCourse: displayedCourse,
            courseMarkerCoordinate: markerCoordinate,
            nearbyCourses: nearbyCourses,
            style: mapStyleConfig,
            framingRequest: framingRequest,
            shots: currentHoleShots,
            currentHole: courseHoles.indices.contains(currentHoleIndex) ? courseHoles[currentHoleIndex] : nil,
            isPlayMode: appMode == .play && displayedCourse != nil,
            hoverLocation: mapHoverLocation,
            onAddShot: addShotToCurrentHole,
            onSelectHole: selectHole(withID:),
            onSelectCourse: { identifier in
                // Tapping a nearby course flag opens that course, exactly as if it
                // had been picked from the sidebar.
                guard let course = nearbyCourses.first(where: { $0.identifier == identifier }) else { return }
                selection = .result(course)
            },
            onCameraMoved: { region in
                // Offer a re-search only while browsing the nearby map (no course
                // open) — panning around an opened course shouldn't prompt it.
                guard displayedCourse == nil else { return }
                pendingSearchRegion = region
            }
        )
        .ignoresSafeArea()
        .onContinuousHover { phase in
            // Feed the pointer location to the map so hovering a dimmed hole in Play
            // mode lifts it to full opacity. `.local` matches the map's top-left,
            // y-down coordinate space (MKMapView is flipped), so it needs no flip.
            switch phase {
            case .active(let location): mapHoverLocation = location
            case .ended: mapHoverLocation = nil
            }
        }
        .overlay(alignment: .bottom) {
            searchHereButton
        }
        .overlay(alignment: .center) {
            loadingBanner
        }
    }

    /// Whether the trailing inspector is open, and the binding that closes it. The
    /// Play detail pane owns the inspector normally; in DEBUG the data inspector can
    /// also open it (taking precedence), so both presentations funnel through here.
    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: {
                #if DEBUG
                if showDataInspector { return true }
                #endif
                return appMode == .play && displayedCourse != nil
            },
            set: { open in
                if !open {
                    #if DEBUG
                    showDataInspector = false
                    #endif
                    appMode = .plan
                }
            }
        )
    }

    /// The trailing inspector's content: the DEBUG data inspector when toggled,
    /// otherwise the Play detail pane.
    @ViewBuilder
    private var inspectorContent: some View {
        #if DEBUG
        if showDataInspector {
            DevDataInspectorPanel(
                sources: devInspectorSources,
                isPresented: $showDataInspector
            )
        } else {
            playDetailInspector
        }
        #else
        playDetailInspector
        #endif
    }

    private var playDetailInspector: some View {
        PlayDetailPane(
            holes: courseHoles,
            currentHoleIndex: $currentHoleIndex,
            shots: currentHoleShots,
            onClearShots: clearCurrentHoleShots,
            onUndoShot: undoLastShot
        )
    }

    #if DEBUG
    /// Encodable snapshots offered to the JSON inspector: the built `OSMCourse` (when
    /// loaded) and the lightweight `GolfCourse` metadata for the displayed course.
    /// Memoized via `inspectorSourceCache`: encoding the full OSM course is expensive
    /// and this is read from `body`, which re-evaluates on every map interaction.
    private var devInspectorSources: [DevInspectorSource] {
        guard let course = displayedCourse else { return [] }
        let osm = osmCache[course.identifier]
        // OSM data for a given identifier is immutable once loaded, so the course
        // identifier plus "is the OSM payload present yet" fully captures when the
        // encoded sources need to change.
        let key = "\(course.identifier)|\(osm != nil)"
        if inspectorSourceCache.key == key {
            return inspectorSourceCache.sources
        }
        var sources: [DevInspectorSource] = []
        if let osm {
            sources.append(DevInspectorSource(name: "OSM Course", osm))
        }
        sources.append(DevInspectorSource(name: "Metadata", course))
        inspectorSourceCache.key = key
        inspectorSourceCache.sources = sources
        return sources
    }
    #endif
    /// Rendered unconditionally and driven by opacity so its subtree is never
    /// inserted/removed adjacent to the Map view.
    private var searchHereButton: some View {
        let region = pendingSearchRegion
        return Button {
            if let region { Task { await searchHere(in: region) } }
        } label: {
            Label("Search this area", systemImage: "arrow.trianglehead.clockwise")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(radius: 4, y: 2)
        .padding(.top, 12)
        .opacity(region != nil ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: region != nil)
        .allowsHitTesting(region != nil)
    }

    /// Flattens the `@Observable` `OverlaySettings` into a value-type snapshot the
    /// `CourseMapView` representable can diff. Reading `overlay` here (in the view
    /// body) is what registers the dependency, so a Settings change re-renders.
    private var mapStyleConfig: MapStyleConfig {
        var colors: [OverlayLayer: NSColorBox] = [:]
        var visible: [OverlayLayer: Bool] = [:]
        for layer in OverlayLayer.allCases {
            colors[layer] = NSColorBox(color: NSColor(overlay.color(for: layer)))
            visible[layer] = overlay.isVisible(layer)
        }
        return MapStyleConfig(colors: colors, visible: visible, showMapLabels: overlay.showMapLabels, useMetricDistance: overlay.useMetricDistance)
    }

    /// Subtle, non-blocking progress chip shown while the displayed course's data is
    /// loading from the network. Rendered unconditionally and driven by opacity so
    /// the overlay subtree is never inserted/removed near the Map view.
    private var loadingBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.large)
            Text("Loading course…")
                .font(.callout)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, 12)
        .opacity(isLoadingDisplayed ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isLoadingDisplayed)
        .allowsHitTesting(false)
    }

    /// Compact label for a sub-course segment: the name with a trailing
    /// "Course"/"Golf Course" trimmed so segments stay short ("Championship").
    private func subCourseLabel(_ sub: OSMSubCourse) -> String {
        guard let name = sub.name, !name.isEmpty else { return "Course" }
        let trimmed = name
            .replacingOccurrences(of: " Golf Course", with: "")
            .replacingOccurrences(of: " Course", with: "")
            .trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name : trimmed
    }

    /// True when the currently displayed course has an in-flight network fetch.
    private var isLoadingDisplayed: Bool {
        guard let id = displayedCourse?.identifier else { return false }
        return loadingCounts[id] != nil
    }

    private func beginLoading(_ id: String) {
        loadingCounts[id, default: 0] += 1
    }

    private func endLoading(_ id: String) {
        guard let count = loadingCounts[id] else { return }
        if count > 1 {
            loadingCounts[id] = count - 1
        } else {
            loadingCounts[id] = nil
        }
    }
    /// Decodes the cached OSM course for the given identifier, if present. Consults
    /// the in-memory cache first to avoid a SwiftData fetch + JSON decode on
    /// re-selection; falls back to the on-disk store and warms the memory cache.
    func cachedCourse(for course: GolfCourse) async -> OSMCourse? {
        let id = course.identifier
        if let cached = osmCache[id] {
            return cached
        }
        let descriptor = FetchDescriptor<OSMCourseData>(predicate: #Predicate { $0.courseIdentifier == id })
        guard let data = (try? modelContext.fetch(descriptor).first)?.encodedCourse else { return nil }
        // Decode off the main thread. A full course is a large JSON blob and was
        // previously decoded synchronously inside `.onChange`, stalling the UI
        // ~280 ms (per Instruments). `OSMCourse` is `nonisolated`/`Sendable`, so it
        // crosses the detached-task boundary safely.
        let decoded = await Task.detached(priority: .userInitiated) {
            try? JSONDecoder().decode(OSMCourse.self, from: data)
        }.value
        if let decoded {
            osmCache[id] = decoded
        }
        return decoded
    }

    /// Draws a course end-to-end: resolves which sub-course (if any) is active, then
    /// paints the boundary, holes and features filtered to it. The single entry point
    /// for the cached, joined-fetch and freshly-fetched draw paths so all three stay
    /// in sync on the sub-course state.
    func drawCourse(_ osmCourse: OSMCourse?, for course: GolfCourse) {
        applySubCourseState(from: osmCourse, for: course)
        applyOutline(from: osmCourse, for: course)
        applyFeatures(from: osmCourse, for: course)
        // Once real geometry first arrives for this course, upgrade the coarse
        // selection frame to the actual footprint (or, if already in Play mode,
        // the current hole). Gated on the course id so cached-then-network redraws
        // don't re-frame a map the user may have since panned.
        guard displayedCourse?.identifier == course.identifier,
              framedFootprintCourseID != course.identifier,
              !courseOutlines.isEmpty || !courseHoles.isEmpty else { return }
        framedFootprintCourseID = course.identifier
        if appMode == .play {
            frameCurrentHole()
        } else {
            frameCourseFootprint(for: course)
        }
    }

    /// Frames the whole course top-down so its footprint fills the screen. Prefers
    /// the boundary rings, falls back to hole geometry, then to a fixed box around
    /// the course point when no geometry is available.
    private func frameCourseFootprint(for course: GolfCourse) {
        let ringCoords = courseOutlines.flatMap { $0 }
        let holeCoords = courseHoles.flatMap { hole in
            hole.coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        }
        let coords = ringCoords.isEmpty ? holeCoords : ringCoords
        let region = coords.isEmpty
            ? MKCoordinateRegion(center: course.coordinate, latitudinalMeters: 2000, longitudinalMeters: 2000)
            : regionTightlyFitting(coords)
        framingRequest = MapFramingRequest(framing: .topDown(region))
    }

    /// Like `regionFitting` but tuned for a single course footprint rather than the
    /// 50-mile browse map: minimal edge padding and a small minimum span so a
    /// compact course fills the screen instead of sitting as a speck. The generous
    /// 0.05° floor / 1.3× padding in `regionFitting` are deliberately kept for the
    /// nearby-courses view and would otherwise leave a course zoomed too far out.
    private func regionTightlyFitting(_ coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let first = coordinates.first else { return MKCoordinateRegion(.world) }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coordinates.dropFirst() {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        // ~8% edge padding, and a ~300 m minimum span so a tiny parcel or a
        // single-hole course doesn't zoom to street level.
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.08, 0.0027),
            longitudeDelta: max((maxLon - minLon) * 1.08, 0.0027)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    /// Frames the current hole with a tilted, heading-aware camera aimed down its
    /// tee→pin axis. No-op unless in Play mode with a course open and the hole has
    /// at least a tee and a pin. Distance is derived from the hole length so short
    /// par-3s and long par-5s both frame sensibly.
    private func frameCurrentHole() {
        guard appMode == .play, displayedCourse != nil,
              courseHoles.indices.contains(currentHoleIndex) else { return }
        let coords = courseHoles[currentHoleIndex].coordinates
        guard coords.count >= 2, let teeC = coords.first, let pinC = coords.last else { return }
        let tee = CLLocationCoordinate2D(latitude: teeC.lat, longitude: teeC.lon)
        let pin = CLLocationCoordinate2D(latitude: pinC.lat, longitude: pinC.lon)
        let length = Geo.distance(tee, pin)
        // Fit the tee→pin span with headroom; clamp so a stray coordinate can't
        // fling the camera to space or bury it in the turf.
        let distance = min(max(length * 1.6 + 150, 300), 4_000)
        framingRequest = MapFramingRequest(framing: .camera(
            center: Geo.midpoint(tee, pin),
            distance: distance,
            pitch: 55,
            heading: Geo.bearing(from: tee, to: pin)
        ))
    }

    /// Publishes the facility's sub-courses and defaults the active selection to
    /// "All" (`nil`) — the whole facility, so untagged features (a driving range,
    /// the clubhouse area) stay visible and a multi-course park reads as one. Keeps a
    /// still-valid existing selection so a network refresh doesn't snap the user back
    /// off a sub-course they switched to from the cached draw.
    func applySubCourseState(from osmCourse: OSMCourse?, for course: GolfCourse) {
        guard displayedCourse?.identifier == course.identifier else { return }
        let subs = osmCourse?.subCourses ?? []
        displayedSubCourses = subs
        if let active = activeSubCourseID, subs.contains(where: { $0.id == active }) {
            return
        }
        activeSubCourseID = nil
    }

    /// The currently active sub-course within `osmCourse`, or `nil` when none is
    /// selected — an ordinary single course, or a facility shown in full ("All").
    func activeSubCourse(in osmCourse: OSMCourse) -> OSMSubCourse? {
        guard let id = activeSubCourseID else { return nil }
        return osmCourse.subCourses.first { $0.id == id }
    }

    /// Holes attributed to the active sub-course; all holes when no sub-course is
    /// active. Attribution is precomputed at build time (`holeIDs`), so render is a
    /// pure membership filter.
    func visibleHoles(in osmCourse: OSMCourse) -> [OSMHole] {
        let holes: [OSMHole]
        if let sub = activeSubCourse(in: osmCourse) {
            let ids = Set(sub.holeIDs)
            holes = osmCourse.holes.filter { ids.contains($0.osmIdentifier) }
        } else {
            holes = osmCourse.holes
        }
        // Re-sort numerically here as well as at build time: cache rows written
        // before the numeric-sort fix are still stored in lexicographic order
        // ("1, 10, 11 … 2 …"), which would make hole navigation jump 1→10 until the
        // course is refetched. Sorting at display time fixes those immediately.
        return holes.sorted { lhs, rhs in
            let l = lhs.holeNumber ?? Int.max
            let r = rhs.holeNumber ?? Int.max
            if l != r { return l < r }
            return (lhs.ref ?? "") < (rhs.ref ?? "")
        }
    }

    /// Features attributed to the active sub-course; all features when no sub-course
    /// is active. Attribution is precomputed at build time (`featureIDs`).
    func visibleFeatures(in osmCourse: OSMCourse) -> [OSMFeature] {
        guard let sub = activeSubCourse(in: osmCourse) else { return osmCourse.features }
        let ids = Set(sub.featureIDs)
        return osmCourse.features.filter { ids.contains($0.osmIdentifier) }
    }

    /// Assigns the boundary outline(s), ignoring stale results for a course that is
    /// no longer the displayed one. A boundary is a multi-ring polygon (a course can
    /// be several disjoint parcels), so each ring becomes its own `MapPolygon`.
    ///  - Active sub-course → that sub-course's rings.
    ///  - "All" or a single course → the facility's primary boundary rings.
    func applyOutline(from osmCourse: OSMCourse?, for course: GolfCourse) {
        guard displayedCourse?.identifier == course.identifier, let osmCourse else { return }
        func clRings(_ polygon: [[Coordinate]]) -> [[CLLocationCoordinate2D]] {
            polygon
                .filter { $0.count >= 3 }
                .map { ring in ring.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) } }
        }
        if let sub = activeSubCourse(in: osmCourse) {
            courseOutlines = clRings(sub.boundary)
        } else {
            courseOutlines = clRings(osmCourse.boundary)
        }
    }

    /// Assigns the course features, ignoring stale results for a course that is no
    /// longer the displayed one. Features are published progressively (see
    /// `renderChunked`) so MapKit meshes a bounded batch per runloop turn instead of
    /// one large synchronous mesh — the latter blocked the main thread ~400 ms in
    /// VectorKit (per Instruments). Holes are cheap framing geometry, drawn at once.
    func applyFeatures(from osmCourse: OSMCourse?, for course: GolfCourse) {
        guard displayedCourse?.identifier == course.identifier, let osmCourse else { return }
        // OSM features arrive in arbitrary (dictionary) order, so the rough could
        // composite over greens/fairways. Sort into a stable painter order so the
        // turf stacks back-to-front (rough ▸ fairway ▸ green ▸ detail features);
        // within the `.aboveRoads` level, declaration order is the z-order.
        let sorted = visibleFeatures(in: osmCourse).sorted {
            OverlayLayer.forFeature($0.kind).drawOrder < OverlayLayer.forFeature($1.kind).drawOrder
        }
        courseHoles = visibleHoles(in: osmCourse)

        featureRenderTask?.cancel()
        courseFeatures = []
        featureRenderTask = Task {
            await renderChunked(sorted, chunk: Self.featureRenderChunk, for: course) {
                courseFeatures.append(contentsOf: $0)
            }
        }
    }

    /// Number of features appended per runloop turn during progressive rendering.
    /// Sized so a single turn's MapKit mesh stays well under the 250 ms hang threshold.
    private static let featureRenderChunk = 25
    /// One ~display frame between chunks, so each batch commits and meshes before
    /// the next is appended rather than coalescing back into one large update.
    private static let renderFramePause: Duration = .milliseconds(16)

    /// Appends `items` to a map-overlay array in `chunk`-sized batches, pausing one
    /// frame between batches so MapKit meshes incrementally. Bails out if the render
    /// is cancelled or the displayed course changes mid-flight, leaving the new
    /// selection's overlays untouched.
    private func renderChunked<T>(
        _ items: [T],
        chunk: Int,
        for course: GolfCourse,
        append: ([T]) -> Void
    ) async {
        guard !items.isEmpty else { return }
        var start = 0
        while start < items.count {
            if Task.isCancelled || displayedCourse?.identifier != course.identifier { return }
            let end = min(start + chunk, items.count)
            append(Array(items[start..<end]))
            start = end
            if start < items.count {
                try? await Task.sleep(for: Self.renderFramePause)
            }
        }
    }

    func ensureOSMData(for course: GolfCourse) async {
        let id = course.identifier
        osmLog("ensureOSMData start id=\(id) name=\(course.name)")

        // If a fetch for this course is already running, join it rather than
        // starting a second request. The owner task runs to completion
        // independently of who started it, so both callers apply the shared result.
        if let inflight = inFlightFetches[id] {
            osmLog("joining in-flight fetch id=\(id)")
            let result = try? await inflight.value
            drawCourse(result ?? osmCache[id], for: course)
            return
        }

        let descriptor = FetchDescriptor<OSMCourseData>(predicate: #Predicate { $0.courseIdentifier == id })
        let existing = try? modelContext.fetch(descriptor).first

        let successTTL: TimeInterval = 60 * 60 * 24 * 30
        // notFound is often caused by a transient name-mismatch (e.g. Apple Maps
        // names with "(South)" suffixes). Retry after a day so a bad cache entry
        // doesn't permanently suppress a course that is actually in OSM.
        let notFoundTTL: TimeInterval = 60 * 60 * 24
        // Short error window: a transient failure (e.g. a rate-limited mirror)
        // should be retried soon, not frozen out for an hour.
        let errorTTL: TimeInterval = 60 * 2

        if let existing {
            let age = Date().timeIntervalSince(existing.fetchedAt)
            osmLog("cache row found status=\(existing.fetchStatus) age=\(Int(age))s")
            switch existing.fetchStatus {
            case "ok" where age < successTTL && existing.builderVersion >= currentBuilderVersion:
                osmLog("cache hit (ok), skipping fetch")
                return
            case "notFound" where age < notFoundTTL:
                osmLog("cache hit (notFound), skipping fetch")
                return
            case "error" where age < errorTTL:
                osmLog("cache hit (error within TTL), skipping fetch")
                return
            default:
                // Includes legacy "partial" rows from the old two-stage fetch, which
                // simply refetch to produce a complete course.
                osmLog("cache stale, refetching")
            }
        } else {
            osmLog("no cache row, fetching")
        }

        // Start the owner task as an unstructured Task so it survives cancellation
        // of whoever kicked it off (a selection the user moves past is cancelled).
        // It clears its own in-flight entry on completion.
        let task = Task<OSMCourse?, Error> {
            defer { inFlightFetches[id] = nil }
            return await performOSMFetch(for: course, existing: existing)
        }
        inFlightFetches[id] = task
        _ = try? await task.value
    }

    /// Runs the two-stage network fetch, applying each stage to the map and
    /// persisting the result. Returns the best course produced (complete, or the
    /// boundary-only fallback) so a joining caller can apply it directly.
    @discardableResult
    private func performOSMFetch(for course: GolfCourse, existing: OSMCourseData?) async -> OSMCourse? {
        let id = course.identifier
        var bestCourse: OSMCourse?
        do {
            osmLog("calling fetcher.fetch")
            beginLoading(id)
            defer { endLoading(id) }
            for try await stage in osmFetcher.fetch(
                identifier: id,
                name: course.name,
                latitude: course.latitude,
                longitude: course.longitude
            ) {
                switch stage {
                case .complete(let osmCourse):
                    let encoded = try JSONEncoder().encode(osmCourse)
                    logOSMCourse(osmCourse, encoded: encoded, identifier: id)
                    osmCache[id] = osmCourse
                    bestCourse = osmCourse
                    drawCourse(osmCourse, for: course)
                    upsertOSMData(courseIdentifier: id, encoded: encoded, status: "ok", existing: existing)
                case .notFound:
                    osmLog("notFound id=\(id) name=\(course.name)")
                    upsertOSMData(courseIdentifier: id, encoded: nil, status: "notFound", existing: existing)
                }
            }
        } catch {
            if error is CancellationError || Task.isCancelled {
                // The user selected a different course before this one finished.
                // Whatever already drew/persisted stays put — just stop here.
                osmLog("fetch cancelled id=\(id)")
                return bestCourse
            }
            osmLog("error id=\(id) name=\(course.name): \(error)")
            if case OSMFetchError.rateLimited = error {
                // Transient: don't poison the cache. Leave any existing row intact
                // (or none) so the next selection retries immediately.
            } else if case OSMFetchError.transport = error {
                // Transient (offline / mirror down): same — allow an immediate retry.
            } else {
                upsertOSMData(courseIdentifier: id, encoded: nil, status: "error", existing: existing)
            }
        }
        return bestCourse
    }

    private func logOSMCourse(_ osmCourse: OSMCourse, encoded: Data, identifier: String) {
        osmLog("fetched id=\(identifier)")
        osmLog("      osm: \(osmCourse.osmType) \(osmCourse.osmIdentifier) name=\(osmCourse.name ?? "nil")")
        osmLog("      boundary: \(osmCourse.boundary.count) ring(s), \(osmCourse.boundary.reduce(0) { $0 + $1.count }) points")
        osmLog("      holes: \(osmCourse.holes.count)")
        osmLog("      features: \(osmCourse.features.count)")

        let pretty = JSONEncoder()
        pretty.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? pretty.encode(osmCourse), let json = String(data: data, encoding: .utf8) {
            osmLog(json)
        } else if let json = String(data: encoded, encoding: .utf8) {
            osmLog(json)
        }
    }

    private func upsertOSMData(courseIdentifier: String, encoded: Data?, status: String, existing: OSMCourseData?) {
        if let existing {
            existing.encodedCourse = encoded
            existing.fetchedAt = .now
            existing.fetchStatus = status
            existing.builderVersion = currentBuilderVersion
        } else {
            modelContext.insert(OSMCourseData(
                courseIdentifier: courseIdentifier,
                encodedCourse: encoded,
                fetchedAt: .now,
                fetchStatus: status,
                builderVersion: currentBuilderVersion
            ))
        }
    }
    
    func isFavorite(_ course: GolfCourse) -> Bool {
        favorites.contains { $0.identifier == course.identifier }
    }

    func toggleFavorite(_ course: GolfCourse) {
        let id = course.identifier
        let descriptor = FetchDescriptor<FavoriteCourse>(predicate: #Predicate { $0.identifier == id })
        if let existing = try? modelContext.fetch(descriptor).first {
            modelContext.delete(existing)
        } else {
            modelContext.insert(FavoriteCourse(from: course))
        }
    }

    func recordRecent(_ course: GolfCourse) {
        let id = course.identifier
        let descriptor = FetchDescriptor<RecentCourse>(predicate: #Predicate { $0.identifier == id })
        let alreadyRecorded = (try? modelContext.fetch(descriptor).first) != nil
        guard !alreadyRecorded else { return }

        modelContext.insert(RecentCourse(from: course))

        let all = (try? modelContext.fetch(
            FetchDescriptor<RecentCourse>(sortBy: [SortDescriptor(\.lastVisited, order: .reverse)])
        )) ?? []
        for old in all.dropFirst(10) {
            modelContext.delete(old)
        }
    }

    func deleteRecent(_ recent: RecentCourse) {
        if case .recent(let course) = selection, course.identifier == recent.identifier {
            selection = nil
        }
        modelContext.delete(recent)
    }

    func performSearch(query: String) async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.golf])

        let search = MKLocalSearch(request: request)
        let response = try? await search.start()

        // A newer keystroke cancelled this search; drop its now-stale outcome so it
        // can't overwrite the fresher query's results or clear its progress spinner.
        if Task.isCancelled { return }

        let results = response?.mapItems.map(golfCourse(from:)) ?? []

        await MainActor.run {
            guard !Task.isCancelled else { return }
            searchResults = results
            isSearching = false
        }
    }

    /// Converts an `MKMapItem` from a local search into the app's `GolfCourse`,
    /// peeling the state/region out of the formatted city context. Shared by the
    /// text search and the nearby search.
    private func golfCourse(from item: MKMapItem) -> GolfCourse {
        let representations = item.addressRepresentations
        let coordinate = item.location.coordinate
        let cityName = representations?.cityName ?? ""
        // `cityWithContext(.short)` yields e.g. "Pebble Beach, CA"; peel off the
        // leading city to isolate the state/region for separate display.
        let cityContext = representations?.cityWithContext(.short) ?? ""
        let state: String
        if !cityName.isEmpty, cityContext.hasPrefix(cityName + ", ") {
            state = String(cityContext.dropFirst(cityName.count + 2))
        } else {
            state = ""
        }
        return GolfCourse(
            identifier: item.url?.absoluteString ?? UUID().uuidString,
            name: item.name ?? "Unknown",
            address: item.address?.shortAddress ?? item.address?.fullAddress ?? "",
            city: cityName,
            state: state,
            country: representations?.regionName ?? "",
            countryCode: representations?.region?.identifier ?? "",
            phone: item.phoneNumber ?? "",
            website: item.url?.absoluteString ?? "",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }

    /// Runs a golf-course `MKLocalSearch` over a ~100-mile box around `center`,
    /// keeps the results inside the 50-mile radius (local search biases toward the
    /// region but doesn't hard-clip it), and frames the map so every marker and the
    /// user dot are visible.
    private func loadNearbyCourses(around center: CLLocationCoordinate2D) async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "golf course"
        request.resultTypes = [.pointOfInterest]
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.golf])
        request.region = MKCoordinateRegion(
            center: center,
            latitudinalMeters: Self.nearbyRadiusMeters * 2,
            longitudinalMeters: Self.nearbyRadiusMeters * 2
        )

        let search = MKLocalSearch(request: request)
        guard let response = try? await search.start() else { return }

        let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
        func distance(_ course: GolfCourse) -> CLLocationDistance {
            origin.distance(from: CLLocation(latitude: course.latitude, longitude: course.longitude))
        }
        let courses = response.mapItems
            .map(golfCourse(from:))
            .filter { distance($0) <= Self.nearbyRadiusMeters }
            .sorted { distance($0) < distance($1) }

        nearbyCourses = courses

        // Frame everything: all course markers plus the user's own location.
        guard displayedCourse == nil else { return }
        framingRequest = MapFramingRequest(
            framing: .topDown(regionFitting(courses.map(\.coordinate) + [center]))
        )
    }

    /// Re-runs the golf-course search over the region the user has panned/zoomed
    /// to, replacing the nearby markers with what's in view. Unlike the initial
    /// search it does *not* re-frame the camera — the user is already looking at
    /// the area they want — and it uses the visible span (not the fixed 50-mile
    /// radius) so results match what's on screen.
    private func searchHere(in region: MKCoordinateRegion) async {
        pendingSearchRegion = nil

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "golf course"
        request.resultTypes = [.pointOfInterest]
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.golf])
        request.region = region

        let search = MKLocalSearch(request: request)
        guard let response = try? await search.start() else { return }

        let origin = CLLocation(latitude: region.center.latitude, longitude: region.center.longitude)
        nearbyCourses = response.mapItems
            .map(golfCourse(from:))
            .sorted {
                origin.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
                    < origin.distance(from: CLLocation(latitude: $1.latitude, longitude: $1.longitude))
            }
    }

    /// Builds an `MKCoordinateRegion` that encloses every coordinate with a little
    /// padding so edge markers aren't clipped. Enforces a minimum span so a single
    /// (or tightly clustered) set of markers doesn't zoom in to street level.
    private func regionFitting(_ coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let first = coordinates.first else {
            return MKCoordinateRegion(.world)
        }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coordinates.dropFirst() {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.3, 0.05),
            longitudeDelta: max((maxLon - minLon) * 1.3, 0.05)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    var courseSidebar: some View {
        List(selection: $selection) {
            if !favorites.isEmpty {
                Section("Favorites") {
                    ForEach(favorites) { favorite in
                        let course = favorite.asGolfCourse
                        courseRow(course: course, subtitle: nil, kind: "favorite")
                            .tag(SidebarSelection.favorite(course))
                        subCourseRows(for: course)
                        
                    }
                }
            }
            if !recents.isEmpty {
                Section("Recents") {
                    ForEach(recents) { recent in
                        let course = recent.asGolfCourse
                        courseRow(course: course, subtitle: nil, kind: "recent")
                            .tag(SidebarSelection.recent(course))
                            .contextMenu {
                                Button("Remove from Recents", systemImage: "trash", role: .destructive) {
                                    deleteRecent(recent)
                                }
                            }
                        subCourseRows(for: course)
                    }
                }
            }
            if !trimmedSearchText.isEmpty {
                Section("Results") {
                    if searchResults.isEmpty {
                        if isSearching {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Searching…")
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityIdentifier("searchProgressRow")
                        } else {
                            Text("No courses found")
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("searchNoResultsRow")
                        }
                    } else {
                        ForEach(searchResults) { course in
                            courseRow(course: course, subtitle: locationSubtitle(for: course), kind: "result")
                                .tag(SidebarSelection.result(course))
                            subCourseRows(for: course)
                        }
                    }
                }
            }
        }
        .overlay {
            // Pristine sidebar — nothing saved and no active search — so point the
            // user at the search field instead of showing a blank pane.
            if favorites.isEmpty, recents.isEmpty, trimmedSearchText.isEmpty {
                ContentUnavailableView {
                    Label("Find a Course", systemImage: "magnifyingglass")
                } description: {
                    Text("Search for a golf course to get started.")
                }
                .accessibilityIdentifier("sidebarEmptyState")
            }
        }
    }

    /// `searchText` with surrounding whitespace stripped. The sidebar keys its
    /// Results section and the "get started" empty state off this so a stray space
    /// isn't treated as an active search.
    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "City, State" for the Results subtitle, gracefully omitting whichever part
    /// MapKit didn't supply. Returns `nil` when neither is known so the row falls
    /// back to its single-line title layout.
    func locationSubtitle(for course: GolfCourse) -> String? {
        let parts = [course.city, course.state].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    @ViewBuilder
    func courseRow(course: GolfCourse, subtitle: String?, kind: String) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(course.name)
                    .font(subtitle == nil ? .body : .headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                toggleFavorite(course)
            } label: {
                Image(systemName: isFavorite(course) ? "star.fill" : "star")
                    .foregroundStyle(isFavorite(course) ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("favoriteToggle_\(kind)_\(course.identifier)")
        }
        .contentShape(Rectangle())
        // `.contain` keeps the star toggle addressable as its own accessibility
        // element; without it the row-level identifier below clears descendant
        // identifiers (so UI tests can't find `favoriteToggle_…`).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("courseRow_\(kind)_\(course.identifier)")
    }

    /// Indented child rows for a multi-course facility, emitted right beneath its
    /// sidebar row. Each is a button (not a `List` selection) that activates its
    /// sub-course, so the `List` selection stays on the facility while the active
    /// sub-course is reflected here and in the on-map picker. Hidden unless `course`
    /// is the displayed facility and it has more than one sub-course.
    @ViewBuilder
    func subCourseRows(for course: GolfCourse) -> some View {
        if isDisplayedFacility(course), displayedSubCourses.count > 1 {
            Button {
                activeSubCourseID = nil
            } label: {
                HStack {
                    Label("All", systemImage: "square.stack")
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer()
                    if activeSubCourseID == nil {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)
            ForEach(displayedSubCourses) { sub in
                Button {
                    activeSubCourseID = sub.id
                } label: {
                    HStack {
                        Label(sub.name ?? "Course", systemImage: "flag")
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                        if activeSubCourseID == sub.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 16)
            }
        }
    }

    /// Whether `course` is the course currently shown on the map — the only one
    /// whose (post-fetch) sub-courses we know about.
    private func isDisplayedFacility(_ course: GolfCourse) -> Bool {
        displayedCourse?.identifier == course.identifier
    }
}

private struct OSMFetcherKey: EnvironmentKey {
    static let defaultValue: OSMFetcher = OSMFetcher()
}

extension EnvironmentValues {
    var osmFetcher: OSMFetcher {
        get { self[OSMFetcherKey.self] }
        set { self[OSMFetcherKey.self] = newValue }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [RecentCourse.self, FavoriteCourse.self, OSMCourseData.self], inMemory: true)
        .environment(OverlaySettings())
}

