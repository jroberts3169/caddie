//
//  ElevationProvider.swift
//  caddie
//
//  Terrain-height lookup for shot arcs. MapKit renders `.realistic` elevation
//  but exposes no API to READ the ground height at a coordinate, and
//  `MKMapView.convert(_:toPointTo:)` is a pure 2-D map-projection transform that
//  ignores terrain. To make a shot arc ride the real hillside we need an
//  external Digital Elevation Model. This actor wraps the free, key-less
//  Open-Meteo Elevation API (Copernicus GLO-90, ~90 m DEM), batches lookups,
//  coalesces duplicate in-flight requests, and caches results in memory keyed by
//  a coarse coordinate grid (terrain is static, and the DEM resolution is ~90 m
//  so sub-grid precision buys nothing).
//

import CoreLocation
import Foundation

@inlinable
nonisolated func elevationLog(_ message: @autoclosure () -> String) {
    #if ELEVATION_DEBUG
    print("[ELEV] \(message())")
    #endif
}

/// Actor that resolves ground elevation (metres above sea level) for
/// coordinates, cached in memory. A single shared instance keeps the cache warm
/// across every call site.
actor ElevationProvider {
    static let shared = ElevationProvider()

    /// Cache key: coordinate rounded to a grid. 4 decimal places ≈ 11 m, which
    /// is finer than the ~90 m DEM, so distinct golf-relevant points keep
    /// distinct keys while trivially-close repeats coalesce.
    private struct GridKey: Hashable {
        let lat: Int
        let lon: Int
        init(_ c: CLLocationCoordinate2D) {
            lat = Int((c.latitude * 10_000).rounded())
            lon = Int((c.longitude * 10_000).rounded())
        }
    }

    private let session: URLSession
    private let endpoint = URL(string: "https://api.open-meteo.com/v1/elevation")!
    private let userAgent = "Caddie/1.0"
    /// Open-Meteo accepts up to 100 coordinates per request.
    private let maxBatch = 100

    private var cache: [GridKey: Double] = [:]
    /// In-flight batch requests keyed by grid cell, so concurrent callers asking
    /// for the same point join one network round-trip instead of racing.
    private var inFlight: [GridKey: Task<Double?, Never>] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Returns the cached elevation for a coordinate without hitting the network,
    /// or `nil` if it hasn't been fetched yet. Safe to call from a render loop.
    func cachedElevation(for coordinate: CLLocationCoordinate2D) -> Double? {
        cache[GridKey(coordinate)]
    }

    /// Resolves elevations for a set of coordinates, returning one value per input
    /// (in order). Cached cells resolve instantly; misses are batched into as few
    /// network requests as needed. Returns `nil` for any cell that fails to
    /// resolve, so callers can fall back to a flat arc.
    func elevations(for coordinates: [CLLocationCoordinate2D]) async -> [Double?] {
        guard !coordinates.isEmpty else { return [] }

        // Partition into already-cached vs. needs-fetching (deduped by grid cell).
        var missing: [GridKey: CLLocationCoordinate2D] = [:]
        for c in coordinates {
            let key = GridKey(c)
            if cache[key] == nil, inFlight[key] == nil {
                missing[key] = c
            }
        }

        if !missing.isEmpty {
            await fetchAndCache(Array(missing.values))
        }

        // Join any in-flight tasks covering the requested cells (started here or
        // by a concurrent caller) so every input has its best chance to resolve.
        for c in coordinates {
            let key = GridKey(c)
            if cache[key] == nil, let task = inFlight[key] {
                _ = await task.value
            }
        }

        return coordinates.map { cache[GridKey($0)] }
    }

    /// Fetches elevations for the given (already-deduped) coordinates in batches,
    /// registering an in-flight task per cell so duplicate concurrent requests
    /// coalesce, and stores successful results in the cache.
    private func fetchAndCache(_ coordinates: [CLLocationCoordinate2D]) async {
        for batch in stride(from: 0, to: coordinates.count, by: maxBatch).map({
            Array(coordinates[$0..<min($0 + maxBatch, coordinates.count)])
        }) {
            let task = Task<[Double?], Never> { [weak self] in
                guard let self else { return Array(repeating: nil, count: batch.count) }
                return await self.performFetch(batch)
            }

            // Register a per-cell in-flight marker so a concurrent caller joins.
            for (i, c) in batch.enumerated() {
                let key = GridKey(c)
                inFlight[key] = Task { await task.value[safe: i] ?? nil }
            }

            let results = await task.value
            for (c, value) in zip(batch, results) {
                let key = GridKey(c)
                if let value { cache[key] = value }
                inFlight[key] = nil
            }
        }
    }

    /// Single network round-trip for one batch. Returns one value per input in
    /// order, `nil` where the response was missing/unparseable.
    private func performFetch(_ batch: [CLLocationCoordinate2D]) async -> [Double?] {
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: batch.map { String($0.latitude) }.joined(separator: ",")),
            URLQueryItem(name: "longitude", value: batch.map { String($0.longitude) }.joined(separator: ",")),
        ]
        guard let url = comps.url else { return Array(repeating: nil, count: batch.count) }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                elevationLog("http status=\(http.statusCode) for \(batch.count) coords")
                return Array(repeating: nil, count: batch.count)
            }
            let decoded = try JSONDecoder().decode(ElevationResponse.self, from: data)
            let heights = decoded.elevation
            guard heights.count == batch.count else {
                elevationLog("count mismatch: got \(heights.count) for \(batch.count) coords")
                return Array(repeating: nil, count: batch.count)
            }
            return heights.map { $0 }
        } catch {
            elevationLog("fetch failed: \(error)")
            return Array(repeating: nil, count: batch.count)
        }
    }
}

/// Open-Meteo elevation response: `{ "elevation": [38.0, 40.0, ...] }`.
private struct ElevationResponse: Decodable {
    let elevation: [Double]
}

private extension Array {
    /// Bounds-checked subscript so a coalesced in-flight task can index a
    /// batch result without trapping if the batch shape ever changed.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
