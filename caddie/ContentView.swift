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
    @State private var cameraPosition: MapCameraPosition = .automatic
    
    var body: some View {
        NavigationSplitView {
          courseSidebar
            .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 300)
        } detail: {
            Map(position: $cameraPosition) {
                if let displayedCourse {
                    Marker(displayedCourse.name, coordinate: displayedCourse.coordinate)
                }
            }
            .mapStyle(MapStyle.imagery(elevation: .realistic))
        }
        .navigationTitle("Courses")
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
            cameraPosition = .region(MKCoordinateRegion(
                center: course.coordinate,
                latitudinalMeters: 2000,
                longitudinalMeters: 2000
            ))
            recordRecent(course)
            Task { await ensureOSMData(for: course) }
        }
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
            guard let outcome = try await osmFetcher.fetch(
                identifier: id,
                name: course.name,
                latitude: course.latitude,
                longitude: course.longitude
            ) else {
                osmLog("fetch returned nil (already in-flight)")
                return
            }

            switch outcome {
            case .found(let osmCourse):
                let encoded = try JSONEncoder().encode(osmCourse)
                logOSMCourse(osmCourse, encoded: encoded, identifier: id)
                upsertOSMData(courseIdentifier: id, encoded: encoded, status: "ok", existing: existing)
            case .notFound:
                osmLog("notFound id=\(id) name=\(course.name)")
                upsertOSMData(courseIdentifier: id, encoded: nil, status: "notFound", existing: existing)
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
        osmLog("      features: \(osmCourse.features.count) (raw elements: \(osmCourse.raw.elements.count))")

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

