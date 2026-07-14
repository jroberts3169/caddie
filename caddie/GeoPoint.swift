//
//  GeoPoint.swift
//  caddie
//
//  A latitude/longitude pair stored as a single Codable value, so the SwiftData
//  shot models keep one coordinate attribute instead of loose `lat`/`lon`
//  `Double` pairs. Ported from the golf-gen project.
//

import CoreLocation
import Foundation

struct GeoPoint: Codable, Hashable, Sendable {
    var lat: Double
    var lon: Double

    init(latitude: Double, longitude: Double) {
        self.lat = latitude
        self.lon = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.lat = coordinate.latitude
        self.lon = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
