//
//  LocationManager.swift
//  caddie
//
//  Created by Jeff Roberts on 6/28/26.
//

import CoreLocation

/// Thin wrapper over `CLLocationManager` that surfaces the system permission
/// prompt and resolves a single coordinate used to centre the map on the person.
/// The blue location dot itself is drawn by MapKit's `UserAnnotation`.
///
/// The whole module defaults to `MainActor` isolation, so this class and the
/// `CLLocationManager` it owns live on the main actor. CoreLocation delivers its
/// delegate callbacks on that thread, so the delegate methods are `nonisolated`
/// and hop back via `MainActor.assumeIsolated`.
final class LocationManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    /// Pending one-shot fix request, resumed by either the first valid location
    /// or the timeout (with nil). Cleared on resume so it can only fire once.
    private var fixContinuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Shows the system permission prompt, but only while the status is still
    /// undetermined. Once the person has answered, macOS never shows it again, so
    /// calling this on every launch is safe — it's a no-op after the first answer.
    func requestAuthorization() {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    /// Resolves a single coordinate to centre the map on. Returns `nil` if access
    /// isn't granted or no valid fix arrives within `timeout`. Prompts for
    /// permission first if the status is still undetermined.
    func currentCoordinate(timeout: Duration = .seconds(10)) async -> CLLocationCoordinate2D? {
        requestAuthorization()
        let status = manager.authorizationStatus
        guard status == .authorizedAlways || status == .notDetermined else { return nil }
        return await withCheckedContinuation { continuation in
            fixContinuation = continuation
            manager.startUpdatingLocation()
            // Bound the wait so the UI doesn't hang if no fix arrives. The delegate
            // clears `fixContinuation` on a real fix, making this a no-op.
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                guard let pending = fixContinuation else { return }
                fixContinuation = nil
                manager.stopUpdatingLocation()
                pending.resume(returning: nil)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // No-op: the dot and camera react to authorization automatically.
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            // Ignore the invalid "null island" (0,0) cached fix CoreLocation sometimes
            // delivers first; wait for a genuinely valid one.
            guard let fix = locations.last(where: {
                $0.horizontalAccuracy >= 0
                    && CLLocationCoordinate2DIsValid($0.coordinate)
                    && !($0.coordinate.latitude == 0 && $0.coordinate.longitude == 0)
            }) else { return }
            guard let pending = fixContinuation else { return }
            fixContinuation = nil
            manager.stopUpdatingLocation()
            pending.resume(returning: fix.coordinate)
        }
    }
}
