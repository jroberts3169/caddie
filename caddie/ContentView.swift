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
    
    var body: some View {
        NavigationSplitView {
          courseSidebar
            .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 300)
        } detail: {
            Map(position: $cameraPosition) {
                if courseOutline.count >= 3 {
                    MapPolygon(coordinates: courseOutline)
                        .foregroundStyle(.gray.opacity(0.0))
                        .stroke(.white, lineWidth: 3)
                }
                ForEach(courseFeatures, id: \.osmIdentifier) { feature in
                    featureOverlay(feature)
                }
                ForEach(courseHoles, id: \.osmIdentifier) { hole in
                    holeOverlay(hole)
                }
                ForEach(Array(courseTrees.enumerated()), id: \.offset) { _, tree in
                    MapCircle(center: tree, radius: 4)
                        .foregroundStyle(Color(.courseTree).opacity(0.85))
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
    /// (greens, bunkers, water…), stroked line for open paths.
    @MapContentBuilder
    func featureOverlay(_ feature: OSMFeature) -> some MapContent {
        let coords = feature.coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        let color = featureColor(for: feature.kind)
        if feature.isClosed, coords.count >= 3 {
            MapPolygon(coordinates: coords)
                .foregroundStyle(color.opacity(0.55))
                .stroke(color, lineWidth: 1)
        } else if coords.count >= 2 {
            MapPolyline(coordinates: coords)
                .stroke(color, lineWidth: 2)
        }
    }

    /// Map overlay for a single hole: the tee→green centerline plus a numbered
    /// marker at the tee carrying par/length detail.
    @MapContentBuilder
    func holeOverlay(_ hole: OSMHole) -> some MapContent {
        let coords = hole.coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        if coords.count >= 2 {
            MapPolyline(coordinates: coords)
                .stroke(Color(.courseHole), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        }
        if let tee = coords.first {
            Marker(holeMarkerTitle(hole), coordinate: tee)
                .tint(Color(.courseHole))
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

    private func featureColor(for kind: OSMFeature.Kind) -> Color {
        switch kind {
        case .green: return Color(.courseGreen)
        case .fairway: return Color(.courseFairway)
        case .tee: return Color(.courseTee)
        case .bunker: return Color(.courseBunker)
        case .rough: return Color(.courseRough)
        case .waterHazard: return Color(.courseWater)
        case .cartpath, .path: return Color(.coursePath)
        case .drivingRange: return Color(.courseDrivingRange)
        case .unknown: return Color(.courseUnknown)
        }
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
        courseFeatures = osmCourse.features
        courseHoles = osmCourse.holes
        courseTrees = osmCourse.trees.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    func ensureOSMData(for course: GolfCourse) async {
        let id = course.identifier
        osmLog("ensureOSMData start id=\(id) name=\(course.name)")

        let descriptor = FetchDescriptor<OSMCourseData>(predicate: #Predicate { $0.courseIdentifier == id })
        let existing = try? modelContext.fetch(descriptor).first

        let successTTL: TimeInterval = 60 * 60 * 24 * 30
        let errorTTL: TimeInterval = 60 * 60

        if let existing {
            let age = Date().timeIntervalSince(existing.fetchedAt)
            osmLog("cache row found status=\(existing.fetchStatus) age=\(Int(age))s")
            switch existing.fetchStatus {
            case "ok" where age < successTTL:
                osmLog("cache hit (ok), skipping fetch")
                return
            case "notFound" where age < successTTL:
                osmLog("cache hit (notFound), skipping fetch")
                return
            case "error" where age < errorTTL:
                osmLog("cache hit (error within TTL), skipping fetch")
                return
            default:
                osmLog("cache stale, refetching")
            }
        } else {
            osmLog("no cache row, fetching")
        }

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
                    applyOutline(from: osmCourse, for: course)
                case .complete(let osmCourse):
                    let encoded = try JSONEncoder().encode(osmCourse)
                    logOSMCourse(osmCourse, encoded: encoded, identifier: id)
                    osmCache[id] = osmCourse
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
            upsertOSMData(courseIdentifier: id, encoded: nil, status: "error", existing: existing)
        }
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
}

