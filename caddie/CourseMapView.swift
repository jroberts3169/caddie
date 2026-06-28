//
//  CourseMapView.swift
//  caddie
//
//  NSViewRepresentable wrapper around a native MKMapView. SwiftUI's `Map`
//  re-projects its `Marker`/`Annotation` content every frame, so on a streaming
//  `.realistic` terrain mesh the glyphs visibly bob/jitter as the ground height
//  under each one resolves. A native MKMapView anchors each MKAnnotationView to
//  the screen projection of its 2-D coordinate and keeps it pinned there, so the
//  glyphs stay rock-steady while keeping realistic elevation always on.
//

import AppKit
import CoreLocation
import MapKit
import SwiftUI

// MARK: - Inputs

/// A single recorded shot on a hole: just a map coordinate plus a stable id so
/// SwiftUI lists and the map annotation set can diff it.
struct Shot: Identifiable, Equatable {
    let id: UUID
    var coordinate: CLLocationCoordinate2D

    init(id: UUID = UUID(), coordinate: CLLocationCoordinate2D) {
        self.id = id
        self.coordinate = coordinate
    }

    static func == (lhs: Shot, rhs: Shot) -> Bool {
        lhs.id == rhs.id
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

/// A region the map should frame, tagged with an identity token so re-applying
/// the *same* region (e.g. re-selecting a course) still takes effect. SwiftUI
/// would otherwise diff two equal regions as "no change" and skip the update.
struct MapRegionRequest: Equatable {
    var region: MKCoordinateRegion
    var id: UUID = UUID()

    static func == (lhs: MapRegionRequest, rhs: MapRegionRequest) -> Bool {
        lhs.id == rhs.id
    }
}

/// Flat, `Equatable` snapshot of the per-layer style (resolved `NSColor` + a
/// visibility flag) the map needs to draw. Built by `ContentView` from the
/// `@Observable` `OverlaySettings` so SwiftUI's dependency tracking sees the read
/// and the representable re-syncs when colors/visibility change.
struct MapStyleConfig: Equatable {
    var colors: [OverlayLayer: NSColorBox]
    var visible: [OverlayLayer: Bool]

    func color(_ layer: OverlayLayer) -> NSColor { colors[layer]?.color ?? .white }
    func isVisible(_ layer: OverlayLayer) -> Bool { visible[layer] ?? true }
}

/// `Equatable`/`Hashable` wrapper so an `NSColor` can live inside an `Equatable`
/// value type. Compares by sRGB component values, not object identity, so two
/// equal colors don't trigger a spurious re-style.
struct NSColorBox: Equatable {
    let color: NSColor

    static func == (lhs: NSColorBox, rhs: NSColorBox) -> Bool {
        let a = lhs.color.usingColorSpace(.sRGB)
        let b = rhs.color.usingColorSpace(.sRGB)
        return a?.redComponent == b?.redComponent
            && a?.greenComponent == b?.greenComponent
            && a?.blueComponent == b?.blueComponent
            && a?.alphaComponent == b?.alphaComponent
    }
}

// MARK: - Representable

struct CourseMapView: NSViewRepresentable {
    /// Boundary outline rings of the displayed course (each ring its own polygon).
    var outlines: [[CLLocationCoordinate2D]]
    /// Turf/detail features of the displayed course.
    var features: [OSMFeature]
    /// Holes of the displayed course (centerline + tee/pin markers).
    var holes: [OSMHole]
    /// The course currently opened, or `nil` when browsing the nearby map.
    var displayedCourse: GolfCourse?
    /// Geocoded coordinate for the displayed course's pin (falls back to the
    /// course's own coordinate when geocoding hasn't resolved).
    var courseMarkerCoordinate: CLLocationCoordinate2D?
    /// Golf courses within range of the user, shown as flags on the nearby map.
    var nearbyCourses: [GolfCourse]
    /// Resolved per-layer colors + visibility.
    var style: MapStyleConfig
    /// The region to frame, or `nil` to leave the camera where it is.
    var regionRequest: MapRegionRequest?
    /// Recorded shots for the hole currently focused in Play mode.
    var shots: [Shot]
    /// Whether the map is in Play mode (clicking records a shot).
    var isPlayMode: Bool
    /// Called with the map coordinate of a click while in Play mode.
    var onAddShot: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        // Start with a real, non-zero frame. SwiftUI lays the NSView out a beat
        // later, but `MKMapView.setRegion` is a silent no-op while bounds are
        // `.zero`, so an early region set here would otherwise never stick.
        let initialFrame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        let container = NSView(frame: initialFrame)
        container.autoresizesSubviews = true

        let map = MKMapView(frame: container.bounds)
        map.autoresizingMask = [.width, .height]
        map.delegate = context.coordinator
        // Realistic elevation, always. Hybrid keeps roads/labels over the imagery.
        map.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .realistic)
        map.showsCompass = true
        map.showsZoomControls = true
        map.showsUserLocation = true
        container.addSubview(map)
        context.coordinator.map = map

        // Click-to-record-a-shot (gated to Play mode in the handler). A plain click
        // recognizer fires reliably on a zero-movement click; MapKit's own pan still
        // owns drags, so the map stays freely pannable.
        let click = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleMapClick(_:))
        )
        click.delegate = context.coordinator
        map.addGestureRecognizer(click)

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let map = context.coordinator.map else { return }
        context.coordinator.onAddShot = onAddShot
        context.coordinator.isPlayMode = isPlayMode
        context.coordinator.sync(
            map: map,
            outlines: outlines,
            features: features,
            holes: holes,
            displayedCourse: displayedCourse,
            courseMarkerCoordinate: courseMarkerCoordinate,
            nearbyCourses: nearbyCourses,
            style: style,
            shots: shots,
            regionRequest: regionRequest
        )
    }
}

// MARK: - Overlays

/// The structural role of a map overlay, used by the renderer to pick the right
/// fill/stroke treatment independent of which `OverlayLayer` colors it.
private enum OverlayRole: String {
    case boundary
    case feature
    case hole
}

/// `MKPolygon` that remembers which layer/role styles it. Subclassing lets the
/// renderer recover the styling without a side table; MapKit instantiates the
/// subclass because the points-based initializer is the designated initializer.
private final class StyledPolygon: MKPolygon {
    var layer: OverlayLayer = .unknown
    var role: OverlayRole = .feature
}

/// `MKPolyline` counterpart of `StyledPolygon` (open features, hole centerlines).
private final class StyledPolyline: MKPolyline {
    var layer: OverlayLayer = .unknown
    var role: OverlayRole = .feature
}

// MARK: - Annotations

/// Pin for the course currently opened on the map.
private final class CourseMarkerAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let title: String?
    init(coordinate: CLLocationCoordinate2D, title: String?) {
        self.coordinate = coordinate
        self.title = title
    }
}

/// Flag for one of the nearby golf courses on the browse map.
private final class NearbyCourseAnnotation: NSObject, MKAnnotation {
    let identifier: String
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let title: String?
    init(identifier: String, coordinate: CLLocationCoordinate2D, title: String?) {
        self.identifier = identifier
        self.coordinate = coordinate
        self.title = title
    }
}

/// Numbered marker at a hole's tee, carrying par/length detail in its callout.
private final class HoleTeeAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let glyph: String
    let title: String?
    init(coordinate: CLLocationCoordinate2D, glyph: String, title: String?) {
        self.coordinate = coordinate
        self.glyph = glyph
        self.title = title
    }
}

/// Small filled disc at a hole's green (the pin position).
private final class HolePinAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }
}

/// Numbered marker for a recorded shot on the active hole.
private final class ShotAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let number: Int
    init(coordinate: CLLocationCoordinate2D, number: Int) {
        self.coordinate = coordinate
        self.number = number
    }
}

// MARK: - Coordinator

extension CourseMapView {
    final class Coordinator: NSObject, MKMapViewDelegate, NSGestureRecognizerDelegate {
        weak var map: MKMapView?
        /// Called with the clicked coordinate while in Play mode.
        var onAddShot: ((CLLocationCoordinate2D) -> Void)?
        /// Whether a click should record a shot.
        var isPlayMode: Bool = false

        /// Hash of the inputs that determine the overlay set, so we only rebuild
        /// overlays (an expensive add/remove) when the geometry or style changes.
        private var appliedOverlayHash: Int?
        /// Hash of the inputs that determine the annotation set.
        private var appliedAnnotationHash: Int?
        /// Identity of the last applied region request, so the same region can be
        /// re-framed but an unchanged one isn't reapplied every update pass.
        private var appliedRegionID: UUID?

        // MARK: Sync entry point

        func sync(
            map: MKMapView,
            outlines: [[CLLocationCoordinate2D]],
            features: [OSMFeature],
            holes: [OSMHole],
            displayedCourse: GolfCourse?,
            courseMarkerCoordinate: CLLocationCoordinate2D?,
            nearbyCourses: [GolfCourse],
            style: MapStyleConfig,
            shots: [Shot],
            regionRequest: MapRegionRequest?
        ) {
            syncOverlays(map: map, outlines: outlines, features: features, holes: holes, style: style)
            syncAnnotations(
                map: map,
                holes: holes,
                displayedCourse: displayedCourse,
                courseMarkerCoordinate: courseMarkerCoordinate,
                nearbyCourses: nearbyCourses,
                style: style,
                shots: shots
            )
            applyRegion(map: map, regionRequest: regionRequest)
        }

        // MARK: Clicks

        /// Records a shot at the clicked coordinate when in Play mode. Ignores
        /// clicks that land on an existing annotation so tapping a marker doesn't
        /// also drop a shot underneath it.
        @objc func handleMapClick(_ gesture: NSClickGestureRecognizer) {
            guard isPlayMode, let map else { return }
            let point = gesture.location(in: map)
            // Ignore clicks that land on an existing annotation glyph.
            var view = map.hitTest(point)
            while let current = view {
                if current is MKAnnotationView { return }
                view = current.superview
            }
            let coordinate = map.convert(point, toCoordinateFrom: map)
            onAddShot?(coordinate)
        }

        // MARK: Overlays

        private func syncOverlays(
            map: MKMapView,
            outlines: [[CLLocationCoordinate2D]],
            features: [OSMFeature],
            holes: [OSMHole],
            style: MapStyleConfig
        ) {
            var hasher = Hasher()
            for ring in outlines {
                hasher.combine(ring.count)
                if let f = ring.first { hasher.combine(f.latitude); hasher.combine(f.longitude) }
            }
            for f in features {
                hasher.combine(f.osmIdentifier)
                hasher.combine(f.isClosed)
            }
            for h in holes { hasher.combine(h.osmIdentifier) }
            // Style affects which overlays exist (visibility) and is cheap to fold in
            // so a Settings color/visibility change re-renders.
            for layer in OverlayLayer.allCases {
                hasher.combine(layer)
                hasher.combine(style.isVisible(layer))
                if let c = style.colors[layer]?.color.usingColorSpace(.sRGB) {
                    hasher.combine(c.redComponent)
                    hasher.combine(c.greenComponent)
                    hasher.combine(c.blueComponent)
                    hasher.combine(c.alphaComponent)
                }
            }
            let hash = hasher.finalize()
            guard hash != appliedOverlayHash else { return }
            appliedOverlayHash = hash

            let old = map.overlays
            // Add the new overlays first, then remove the old, so the map never
            // flashes empty between the two operations.
            // Features, painter-ordered, on the `.aboveRoads` level.
            let sortedFeatures = features.sorted {
                OverlayLayer.forFeature($0.kind).drawOrder < OverlayLayer.forFeature($1.kind).drawOrder
            }
            for feature in sortedFeatures {
                let layer = OverlayLayer.forFeature(feature.kind)
                guard style.isVisible(layer) else { continue }
                let coords = feature.coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                if feature.isClosed, coords.count >= 3 {
                    let poly = StyledPolygon(coordinates: coords, count: coords.count)
                    poly.layer = layer
                    poly.role = .feature
                    map.addOverlay(poly, level: .aboveRoads)
                } else if coords.count >= 2 {
                    let line = StyledPolyline(coordinates: coords, count: coords.count)
                    line.layer = layer
                    line.role = .feature
                    map.addOverlay(line, level: .aboveRoads)
                }
            }
            // Hole centerlines on `.aboveLabels` so they sit over the turf fills.
            if style.isVisible(.holes) {
                for hole in holes {
                    let coords = hole.coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                    guard coords.count >= 2 else { continue }
                    let line = StyledPolyline(coordinates: coords, count: coords.count)
                    line.layer = .holes
                    line.role = .hole
                    map.addOverlay(line, level: .aboveLabels)
                }
            }
            // Boundary rings on `.aboveLabels`, above the feature fills.
            if style.isVisible(.boundary) {
                for ring in outlines where ring.count >= 3 {
                    let poly = StyledPolygon(coordinates: ring, count: ring.count)
                    poly.layer = .boundary
                    poly.role = .boundary
                    map.addOverlay(poly, level: .aboveLabels)
                }
            }
            map.removeOverlays(old)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let poly = overlay as? StyledPolygon {
                let renderer = MKPolygonRenderer(polygon: poly)
                let color = currentStyle?.color(poly.layer) ?? .white
                switch poly.role {
                case .boundary:
                    renderer.fillColor = .clear
                    renderer.strokeColor = color
                    renderer.lineWidth = 3
                default:
                    renderer.fillColor = color.withAlphaComponent(0.55)
                    renderer.strokeColor = color
                    renderer.lineWidth = 1
                }
                return renderer
            }
            if let line = overlay as? StyledPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                let color = currentStyle?.color(line.layer) ?? .white
                renderer.strokeColor = color
                if line.role == .hole {
                    renderer.lineWidth = 2
                    renderer.lineDashPattern = [6, 4]
                } else {
                    renderer.lineWidth = 2
                }
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        /// The most recent style, stashed so `rendererFor` (called lazily by MapKit
        /// outside the `sync` call) can resolve current colors.
        private var currentStyle: MapStyleConfig?

        // MARK: Annotations

        private func syncAnnotations(
            map: MKMapView,
            holes: [OSMHole],
            displayedCourse: GolfCourse?,
            courseMarkerCoordinate: CLLocationCoordinate2D?,
            nearbyCourses: [GolfCourse],
            style: MapStyleConfig,
            shots: [Shot]
        ) {
            currentStyle = style

            var hasher = Hasher()
            if let course = displayedCourse {
                hasher.combine(course.identifier)
                let c = courseMarkerCoordinate ?? course.coordinate
                hasher.combine(c.latitude); hasher.combine(c.longitude)
            } else {
                for course in nearbyCourses { hasher.combine(course.identifier) }
            }
            for h in holes { hasher.combine(h.osmIdentifier) }
            for s in shots {
                hasher.combine(s.id)
                hasher.combine(s.coordinate.latitude)
                hasher.combine(s.coordinate.longitude)
            }
            hasher.combine(style.isVisible(.holes))
            // Fold in the holes color so a color-only Settings change rebuilds the
            // tee/pin annotations: their tint is baked in by `viewFor`, which MapKit
            // only re-invokes on add/recycle, not when `currentStyle` changes.
            if let c = style.colors[.holes]?.color.usingColorSpace(.sRGB) {
                hasher.combine(c.redComponent)
                hasher.combine(c.greenComponent)
                hasher.combine(c.blueComponent)
                hasher.combine(c.alphaComponent)
            }
            let hash = hasher.finalize()
            guard hash != appliedAnnotationHash else { return }
            appliedAnnotationHash = hash

            // Drop every annotation except the user-location dot, then rebuild. These
            // sets change only on course selection / nearby load, never per frame, so
            // a discrete rebuild here doesn't reintroduce the per-frame jitter that
            // motivated the move to a native map.
            let toRemove = map.annotations.filter { !($0 is MKUserLocation) }
            map.removeAnnotations(toRemove)

            if let course = displayedCourse {
                let coord = courseMarkerCoordinate ?? course.coordinate
                map.addAnnotation(CourseMarkerAnnotation(coordinate: coord, title: course.name))
                if style.isVisible(.holes) {
                    for hole in holes {
                        let coords = hole.coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                        if let tee = coords.first {
                            map.addAnnotation(HoleTeeAnnotation(
                                coordinate: tee,
                                glyph: hole.ref ?? "",
                                title: Self.holeTitle(hole)
                            ))
                        }
                        if let pin = coords.last, coords.count >= 2 {
                            map.addAnnotation(HolePinAnnotation(coordinate: pin))
                        }
                    }
                }
                // Recorded shots for the active hole, numbered in tap order.
                for (index, shot) in shots.enumerated() {
                    map.addAnnotation(ShotAnnotation(coordinate: shot.coordinate, number: index + 1))
                }
            } else {
                for course in nearbyCourses {
                    map.addAnnotation(NearbyCourseAnnotation(
                        identifier: course.identifier,
                        coordinate: course.coordinate,
                        title: course.name
                    ))
                }
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            switch annotation {
            case is MKUserLocation:
                return nil // system blue dot

            case let course as CourseMarkerAnnotation:
                let view = dequeueMarker(mapView, id: "courseMarker", for: course)
                view.markerTintColor = .systemRed
                view.glyphImage = NSImage(systemSymbolName: "flag.fill", accessibilityDescription: nil)
                view.displayPriority = .required
                view.canShowCallout = true
                return view

            case let nearby as NearbyCourseAnnotation:
                let view = dequeueMarker(mapView, id: "nearbyCourse", for: nearby)
                view.markerTintColor = .systemGreen
                view.glyphImage = NSImage(systemSymbolName: "flag.fill", accessibilityDescription: nil)
                view.displayPriority = .required
                view.canShowCallout = true
                return view

            case let tee as HoleTeeAnnotation:
                let view = dequeueMarker(mapView, id: "holeTee", for: tee)
                view.markerTintColor = currentStyle?.color(.holes) ?? .systemBlue
                view.glyphText = tee.glyph
                view.displayPriority = .required
                view.canShowCallout = true
                return view

            case let pin as HolePinAnnotation:
                let id = "holePin"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: pin, reuseIdentifier: id)
                view.annotation = pin
                view.canShowCallout = false
                let size: CGFloat = 9
                view.frame = NSRect(x: 0, y: 0, width: size, height: size)
                view.wantsLayer = true
                let layer = view.layer ?? CALayer()
                layer.frame = view.bounds
                layer.cornerRadius = size / 2
                layer.backgroundColor = (currentStyle?.color(.holes) ?? .systemBlue).cgColor
                view.layer = layer
                return view

            case let shot as ShotAnnotation:
                let view = dequeueMarker(mapView, id: "shot", for: shot)
                view.markerTintColor = .systemOrange
                view.glyphText = "\(shot.number)"
                view.displayPriority = .required
                view.canShowCallout = false
                return view

            default:
                return nil
            }
        }

        private func dequeueMarker(
            _ mapView: MKMapView,
            id: String,
            for annotation: MKAnnotation
        ) -> MKMarkerAnnotationView {
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            return view
        }

        /// Compact hole label, e.g. "3 · Par 4 · 410y".
        private static func holeTitle(_ hole: OSMHole) -> String {
            var parts: [String] = []
            // if let ref = hole.ref, !ref.isEmpty { parts.append(ref) }
            if let par = hole.par { parts.append("Par \(par)") }
            if let meters = hole.lengthMeters {
                parts.append("\(Int((meters * 1.09361).rounded()))y")
            }
            return parts.isEmpty ? "Hole" : parts.joined(separator: " · ")
        }

        // MARK: Region

        private func applyRegion(map: MKMapView, regionRequest: MapRegionRequest?) {
            guard let request = regionRequest, request.id != appliedRegionID else { return }
            appliedRegionID = request.id
            // Animate only short hops; a long cross-country jump animated would make
            // MapKit stream imagery along the whole flight path and stall.
            let from = map.region.center
            let to = request.region.center
            let jump = CLLocation(latitude: from.latitude, longitude: from.longitude)
                .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
            map.setRegion(request.region, animated: jump < 5_000)
        }
    }
}
