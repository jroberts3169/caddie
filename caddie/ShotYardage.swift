//
//  ShotYardage.swift
//  caddie
//

import CoreLocation

/// Pure, view-independent yardage math shared by the play inspector and the map.
///
/// Extracted from `PlayDetailPane` so the segment logic can be unit-tested without
/// standing up a SwiftUI view. `nonisolated` so tests (and any off-main caller) can
/// use it directly.
nonisolated enum ShotYardage {
    /// Meters → yards conversion factor (1 m = 1.09361 yd).
    static let yardsPerMeter = 1.09361

    /// Yardage for each shot, parallel to `shots`. Shot 1 is measured from `tee`
    /// (the hole's first coordinate) when available; every later shot is measured
    /// from the previous shot. An element is `nil` when there's no reference point
    /// yet — i.e. shot 1 on a hole with no tee geometry.
    static func yards(
        tee: CLLocationCoordinate2D?,
        shots: [CLLocationCoordinate2D]
    ) -> [Int?] {
        var result: [Int?] = []
        var previous: CLLocationCoordinate2D? = tee
        for shot in shots {
            if let from = previous {
                let meters = CLLocation(latitude: from.latitude, longitude: from.longitude)
                    .distance(from: CLLocation(latitude: shot.latitude, longitude: shot.longitude))
                result.append(Int((meters * yardsPerMeter).rounded()))
            } else {
                result.append(nil)
            }
            previous = shot
        }
        return result
    }
}
