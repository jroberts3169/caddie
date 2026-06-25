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

    var course: OSMCourse? {
        guard let encodedCourse else { return nil }
        return try? JSONDecoder().decode(OSMCourse.self, from: encodedCourse)
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

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.osmFetcher) private var osmFetcher
    @Environment(OverlaySettings.self) private var overlay
    @Query(sort: \RecentCourse.lastVisited, order: .reverse) private var recents: [RecentCourse]
    @Query(sort: \FavoriteCourse.dateFavorited, order: .reverse) private var favorites: [FavoriteCourse]
    @State private var searchText: String = ""
    @State private var searchResults: [GolfCourse] = []
    @State private var selection: SidebarSelection?
    @State private var displayedCourse: GolfCourse?
    @State private var courseOutline: [CLLocationCoordinate2D] = []
    @State private var courseFeatures: [OSMFeature] = []
    @State private var courseTrees: [CLLocationCoordinate2D] = []
    @State private var courseHoles: [OSMHole] = []
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var hoverPrefetchTasks: [String: Task<Void, Never>] = [:]
    /// In-memory decoded-geometry cache, keyed by course id, so re-selecting a
    /// course in the same session skips the SwiftData fetch + JSON decode.
    @State private var osmCache: [String: OSMCourse] = [:]
    /// Reference-counted set of course ids with an in-flight network fetch. A count
    /// (not a flag) keeps the spinner visible when a hover prefetch and the click
    /// that follows overlap — the dedup'd second call must not clear it early.
    @State private var loadingCounts: [String: Int] = [:]
    /// Shared in-flight fetch tasks keyed by course id. A hover prefetch and the
    /// click that follows JOIN the same task and both apply its result, instead of
    /// the second caller racing the first (and going blank if the first is
    /// cancelled when the pointer leaves the row on selection).
    @State private var inFlightFetches: [String: Task<OSMCourse?, Error>] = [:]
    
    var body: some View {
        NavigationSplitView {
          courseSidebar
            .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 300)
        } detail: {
            Map(position: $cameraPosition) {
                if overlay.isVisible(.boundary), courseOutline.count >= 3 {
                    MapPolygon(coordinates: courseOutline)
                        .foregroundStyle(.gray.opacity(0.0))
                        .stroke(overlay.color(for: .boundary), lineWidth: 3)
                }
                ForEach(courseFeatures, id: \.osmIdentifier) { feature in
                    featureOverlay(feature)
                }
                if overlay.isVisible(.trees) {
                    ForEach(Array(courseTrees.enumerated()), id: \.offset) { _, tree in
                        MapCircle(center: tree, radius: 4)
                            .foregroundStyle(overlay.color(for: .trees).opacity(0.85))
                    }
                }
                // Drawn last so the dashed hole centerlines sit on top of the
                // fairway/green fills rather than being composited under them.
                if overlay.isVisible(.holes) {
                    ForEach(courseHoles, id: \.osmIdentifier) { hole in
                        holeOverlay(hole)
                    }
                }
                if let displayedCourse {
                    Marker(displayedCourse.name, coordinate: displayedCourse.coordinate)
                }
            }
            .mapStyle(MapStyle.imagery(elevation: .realistic))
            .overlay(alignment: .top) {
                loadingBanner
            }
        }
        .navigationTitle("Caddie")
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
            guard let course = newValue?.course else { return }
            displayedCourse = course
            courseOutline = []
            courseFeatures = []
            courseTrees = []
            courseHoles = []
            cameraPosition = .region(MKCoordinateRegion(
                center: course.coordinate,
                latitudinalMeters: 2000,
                longitudinalMeters: 2000
            ))
            recordRecent(course)
            // Draw whatever is already cached immediately, then progressively
            // refresh from the network (boundary first, features after).
            let cached = cachedCourse(for: course)
            applyOutline(from: cached, for: course)
            applyFeatures(from: cached, for: course)
            Task { await ensureOSMData(for: course) }
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
                .controlSize(.small)
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
    func cachedCourse(for course: GolfCourse) -> OSMCourse? {
        let id = course.identifier
        if let cached = osmCache[id] {
            return cached
        }
        let descriptor = FetchDescriptor<OSMCourseData>(predicate: #Predicate { $0.courseIdentifier == id })
        let decoded = (try? modelContext.fetch(descriptor).first)?.course
        if let decoded {
            osmCache[id] = decoded
        }
        return decoded
    }

    /// Assigns the boundary outline, ignoring stale results for a course that is no
    /// longer the displayed one.
    func applyOutline(from osmCourse: OSMCourse?, for course: GolfCourse) {
        guard displayedCourse?.identifier == course.identifier, let osmCourse else { return }
        courseOutline = osmCourse.boundary.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    /// Assigns the course features, ignoring stale results for a course that is no
    /// longer the displayed one.
    func applyFeatures(from osmCourse: OSMCourse?, for course: GolfCourse) {
        guard displayedCourse?.identifier == course.identifier, let osmCourse else { return }
        // OSM features arrive in arbitrary (dictionary) order, so the rough could
        // composite over greens/fairways. Sort into a stable painter order so the
        // turf stacks back-to-front (rough ▸ fairway ▸ green ▸ detail features);
        // within the `.aboveRoads` level, declaration order is the z-order.
        courseFeatures = osmCourse.features.sorted {
            OverlayLayer.forFeature($0.kind).drawOrder < OverlayLayer.forFeature($1.kind).drawOrder
        }
        courseHoles = osmCourse.holes
        courseTrees = osmCourse.trees.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    func ensureOSMData(for course: GolfCourse) async {
        let id = course.identifier
        osmLog("ensureOSMData start id=\(id) name=\(course.name)")

        // If a fetch for this course is already running (e.g. a hover prefetch),
        // join it rather than starting a second request. The owner task runs to
        // completion independently of who started it, so a cancelled hover can't
        // leave the click with no data — both apply the shared result.
        if let inflight = inFlightFetches[id] {
            osmLog("joining in-flight fetch id=\(id)")
            let result = try? await inflight.value
            applyOutline(from: result ?? osmCache[id], for: course)
            applyFeatures(from: result ?? osmCache[id], for: course)
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
            case "partial":
                // Boundary is cached (and already drawn via cachedCourse), but the
                // feature stage never completed — always refetch to finish it.
                osmLog("cache partial, refetching to complete features")
            default:
                osmLog("cache stale, refetching")
            }
        } else {
            osmLog("no cache row, fetching")
        }

        // Start the owner task as an unstructured Task so it survives cancellation
        // of whoever kicked it off (a hover prefetch is cancelled when the pointer
        // leaves the row). It clears its own in-flight entry on completion.
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
        // Track the boundary so a Stage B failure can still persist Stage A's result.
        var boundaryCourse: OSMCourse?
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
                case .boundary(let osmCourse):
                    osmLog("stage boundary id=\(id) points=\(osmCourse.boundary.count)")
                    boundaryCourse = osmCourse
                    bestCourse = osmCourse
                    applyOutline(from: osmCourse, for: course)
                case .complete(let osmCourse):
                    let encoded = try JSONEncoder().encode(osmCourse)
                    logOSMCourse(osmCourse, encoded: encoded, identifier: id)
                    osmCache[id] = osmCourse
                    bestCourse = osmCourse
                    applyOutline(from: osmCourse, for: course)
                    applyFeatures(from: osmCourse, for: course)
                    upsertOSMData(courseIdentifier: id, encoded: encoded, status: "ok", existing: existing)
                case .notFound:
                    osmLog("notFound id=\(id) name=\(course.name)")
                    upsertOSMData(courseIdentifier: id, encoded: nil, status: "notFound", existing: existing)
                }
            }
        } catch {
            osmLog("error id=\(id) name=\(course.name): \(error)")
            if let boundaryCourse, let encoded = try? JSONEncoder().encode(boundaryCourse) {
                // Stage A succeeded before the failure — keep the boundary so the
                // course still renders its outline and refetches features next time.
                osmCache[id] = boundaryCourse
                upsertOSMData(courseIdentifier: id, encoded: encoded, status: "partial", existing: existing)
            } else if case OSMFetchError.rateLimited = error {
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
        osmLog("      boundary points: \(osmCourse.boundary.count)")
        osmLog("      holes: \(osmCourse.holes.count)")
        osmLog("      features: \(osmCourse.features.count)")
        osmLog("      trees: \(osmCourse.trees.count)")

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

        let results = response.mapItems.map { item in
            let representations = item.addressRepresentations
            let coordinate = item.location.coordinate
            return GolfCourse(
                identifier: item.url?.absoluteString ?? UUID().uuidString,
                name: item.name ?? "Unknown",
                address: item.address?.shortAddress ?? item.address?.fullAddress ?? "",
                city: representations?.cityName ?? "",
                country: representations?.regionName ?? "",
                countryCode: representations?.region?.identifier ?? "",
                phone: item.phoneNumber ?? "",
                website: item.url?.absoluteString ?? "",
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        }

        await MainActor.run {
            searchResults = results
        }
    }

    var courseSidebar: some View {
        List(selection: $selection) {
            if !favorites.isEmpty {
                Section("Favorites") {
                    ForEach(favorites) { favorite in
                        courseRow(course: favorite.asGolfCourse, subtitle: nil)
                            .tag(SidebarSelection.favorite(favorite.asGolfCourse))
                    }
                }
            }
            if !recents.isEmpty {
                Section("Recents") {
                    ForEach(recents) { recent in
                        courseRow(course: recent.asGolfCourse, subtitle: nil)
                            .tag(SidebarSelection.recent(recent.asGolfCourse))
                            .contextMenu {
                                Button("Remove from Recents", systemImage: "trash", role: .destructive) {
                                    deleteRecent(recent)
                                }
                            }
                    }
                }
            }
            if !searchResults.isEmpty {
                Section("Results") {
                    ForEach(searchResults) { course in
                        courseRow(course: course, subtitle: course.city.isEmpty ? nil : course.city)
                            .tag(SidebarSelection.result(course))
                    }
                }
            }
        }
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
        .onHover { hovering in
            prefetchOnHover(hovering, course: course)
        }
    }

    /// Warms the OSM cache when the pointer rests on a row, so a subsequent click
    /// usually finds the data already cached. A short debounce avoids firing for
    /// rows the pointer merely passes over; the actor's in-flight dedup coalesces a
    /// hover prefetch with the click that follows.
    func prefetchOnHover(_ hovering: Bool, course: GolfCourse) {
        let id = course.identifier
        guard hovering else {
            hoverPrefetchTasks[id]?.cancel()
            hoverPrefetchTasks[id] = nil
            return
        }
        guard hoverPrefetchTasks[id] == nil else { return }
        hoverPrefetchTasks[id] = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            await ensureOSMData(for: course)
        }
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

