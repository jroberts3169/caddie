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

    init(courseIdentifier: String, encodedCourse: Data? = nil, fetchedAt: Date = .now, fetchStatus: String = "pending") {
        self.courseIdentifier = courseIdentifier
        self.encodedCourse = encodedCourse
        self.fetchedAt = fetchedAt
        self.fetchStatus = fetchStatus
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

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.osmFetcher) private var osmFetcher
    @Environment(OverlaySettings.self) private var overlay
    @Query(sort: \RecentCourse.lastVisited, order: .reverse) private var recents: [RecentCourse]
    @Query(sort: \FavoriteCourse.name, order: .forward) private var favorites: [FavoriteCourse]
    @State private var searchText: String = ""
    @State private var searchResults: [GolfCourse] = []
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
    @State private var cameraPosition: MapCameraPosition = .automatic
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

    /// Radius for the "courses near me" search: 50 miles in meters.
    private static let nearbyRadiusMeters: CLLocationDistance = 80_467

    
    var body: some View {
        NavigationSplitView {
          courseSidebar
            .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 300)
        } detail: {
            courseMap
        }
        .navigationTitle(displayedCourse?.name ?? "Caddie")
        .navigationSubtitle(displayedCourse.map { locationSubtitle(for: $0) ?? "" } ?? "")
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search for a course")
        .onChange(of: searchText) { _, newValue in
            if newValue.isEmpty {
                searchResults = []
            } else {
                Task {
                    await performSearch(query: newValue)
                }
            }
        }
        .onChange(of: selection) { _, newValue in
            guard let course = newValue?.course else {
                markerCoordinate = nil
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
            // Stop any progressive overlay render still painting the previous course.
            featureRenderTask?.cancel()
            cameraPosition = .region(MKCoordinateRegion(
                center: course.coordinate,
                latitudinalMeters: 2000,
                longitudinalMeters: 2000
            ))
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
            applyOutline(from: osmCourse, for: course)
            applyFeatures(from: osmCourse, for: course)
        }
        .task {
            // Resolve the person's location once, find golf courses within 50 miles,
            // and frame the map so every marker (and the user dot) is visible.
            guard displayedCourse == nil,
                  let coordinate = await locationManager.currentCoordinate() else { return }
            await loadNearbyCourses(around: coordinate)
        }
    }

    private var courseMap: some View {
        Map(position: $cameraPosition) {
            // Pinned to `.aboveLabels` (the top overlay level, same as holes) so
            // the outline draws above the translucent turf fills at `.aboveRoads`
            // — otherwise edge-hugging rough composites over it (e.g. Pebble Beach).
            if overlay.isVisible(.boundary) {
                ForEach(courseOutlines.indices, id: \.self) { i in
                    MapPolygon(coordinates: courseOutlines[i])
                        .foregroundStyle(.gray.opacity(0.0))
                        .stroke(overlay.color(for: .boundary), lineWidth: 3)
                        .mapOverlayLevel(level: .aboveLabels)
                }
            }
            ForEach(courseFeatures, id: \.osmIdentifier) { feature in
                featureOverlay(feature)
            }
            // Drawn last so the dashed hole centerlines sit on top of the
            // fairway/green fills rather than being composited under them.
            if overlay.isVisible(.holes) {
                ForEach(courseHoles, id: \.osmIdentifier) { hole in
                    holeOverlay(hole)
                }
            }
            if let displayedCourse {
                Marker(displayedCourse.name, coordinate: markerCoordinate ?? displayedCourse.coordinate)
            }
            // Golf courses within 50 miles of the person's location. Hidden once a
            // specific course is opened so its overlays aren't cluttered by pins.
            if displayedCourse == nil {
                ForEach(nearbyCourses) { course in
                    Marker(course.name, systemImage: "flag.fill", coordinate: course.coordinate)
                        .tint(.green)
                }
            }
            // System-styled blue dot at the person's current location.
            UserAnnotation()
        }
        .mapStyle(MapStyle.imagery(elevation: .realistic))
        .overlay(alignment: .center) {
            loadingBanner
        }
        .overlay(alignment: .bottom) {
            subCoursePicker
        }
    }

    /// Map overlay for a single OSM feature: filled polygon for closed areas
    /// (greens, bunkers, water…), stroked line for open paths. Pinned to the
    /// `.aboveRoads` level so the hole centerlines (drawn at `.aboveLabels`) stay
    /// on top of these fills.
    @MapContentBuilder
    func featureOverlay(_ feature: OSMFeature) -> some MapContent {
        let layer = OverlayLayer.forFeature(feature.kind)
        if overlay.isVisible(layer) {
            let coords = feature.coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            let color = overlay.color(for: layer)
            if feature.isClosed, coords.count >= 3 {
                MapPolygon(coordinates: coords)
                    .foregroundStyle(color.opacity(0.55))
                    .stroke(color, lineWidth: 1)
                    .mapOverlayLevel(level: .aboveRoads)
            } else if coords.count >= 2 {
                MapPolyline(coordinates: coords)
                    .stroke(color, lineWidth: 2)
                    .mapOverlayLevel(level: .aboveRoads)
            }
        }
    }

    /// Map overlay for a single hole: the tee→green centerline plus a numbered
    /// marker at the tee carrying par/length detail.
    @MapContentBuilder
    func holeOverlay(_ hole: OSMHole) -> some MapContent {
        let holeColor = overlay.color(for: .holes)
        let coords = hole.coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        if coords.count >= 2 {
            MapPolyline(coordinates: coords)
                .stroke(holeColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .mapOverlayLevel(level: .aboveLabels)
        }
        if let tee = coords.first {
            Marker(holeMarkerTitle(hole), coordinate: tee)
                .tint(holeColor)
        }

        if let pin = coords.last {
            Annotation("", coordinate: pin) {
                Circle()
                    .fill(holeColor)
                    .frame(width: 9, height: 9)
            }
        }
    }

    /// Compact hole label, e.g. "3 · Par 4 · 410y".
    private func holeMarkerTitle(_ hole: OSMHole) -> String {
        var parts: [String] = []
        if let ref = hole.ref, !ref.isEmpty { parts.append(ref) }
        if let par = hole.par { parts.append("Par \(par)") }
        if let meters = hole.lengthMeters {
            parts.append("\(Int((meters * 1.09361).rounded()))y")
        }
        return parts.isEmpty ? "Hole" : parts.joined(separator: " · ")
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

    /// Floating segmented control for switching between a facility's sub-courses
    /// (e.g. Balboa Park's Championship / Executive). Hidden for ordinary single
    /// courses. Mirrors — and is kept in sync with — the sidebar disclosure.
    @ViewBuilder
    private var subCoursePicker: some View {
        if displayedSubCourses.count > 1 {
            Picker("Course", selection: $activeSubCourseID) {
                Text("All").tag(String?.none)
                ForEach(displayedSubCourses) { sub in
                    Text(subCourseLabel(sub)).tag(sub.id as String?)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(8)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 16)
        }
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
        guard let sub = activeSubCourse(in: osmCourse) else { return osmCourse.holes }
        let ids = Set(sub.holeIDs)
        return osmCourse.holes.filter { ids.contains($0.osmIdentifier) }
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
            case "ok" where age < successTTL:
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
        } else {
            modelContext.insert(OSMCourseData(
                courseIdentifier: courseIdentifier,
                encodedCourse: encoded,
                fetchedAt: .now,
                fetchStatus: status
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
        guard let response = try? await search.start() else { return }

        let results = response.mapItems.map(golfCourse(from:))

        await MainActor.run {
            searchResults = results
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
        cameraPosition = .region(regionFitting(courses.map(\.coordinate) + [center]))
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
                        courseRow(course: course, subtitle: nil)
                            .tag(SidebarSelection.favorite(course))
                        subCourseRows(for: course)
                        
                    }
                }
            }
            if !recents.isEmpty {
                Section("Recents") {
                    ForEach(recents) { recent in
                        let course = recent.asGolfCourse
                        courseRow(course: course, subtitle: nil)
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
            if !searchResults.isEmpty {
                Section("Results") {
                    ForEach(searchResults) { course in
                        courseRow(course: course, subtitle: locationSubtitle(for: course))
                            .tag(SidebarSelection.result(course))
                        subCourseRows(for: course)
                    }
                }
            }
        }
    }

    /// "City, State" for the Results subtitle, gracefully omitting whichever part
    /// MapKit didn't supply. Returns `nil` when neither is known so the row falls
    /// back to its single-line title layout.
    func locationSubtitle(for course: GolfCourse) -> String? {
        let parts = [course.city, course.state].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    @ViewBuilder
    func courseRow(course: GolfCourse, subtitle: String?) -> some View {
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
        }
        .contentShape(Rectangle())
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
                    Label("All Courses", systemImage: "square.stack")
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

