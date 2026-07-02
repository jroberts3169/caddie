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

/// How the map should frame its subject: a flat top-down region (for a whole
/// course) or a tilted, heading-aware 3D camera (for a single hole aimed down
/// the fairway).
enum MapFraming: Equatable {
    /// Flat, straight-down framing of a coordinate region — used when a course is
    /// first selected so its entire footprint fills the screen.
    case topDown(MKCoordinateRegion)
    /// Tilted camera looking at `center` from `distance` metres
    /// (`centerCoordinateDistance`, NOT altitude), pitched and rotated to
    /// `heading` — used to frame a hole down its tee→pin axis.
    case camera(
        center: CLLocationCoordinate2D,
        distance: CLLocationDistance,
        pitch: CGFloat,
        heading: CLLocationDirection
    )

    static func == (lhs: MapFraming, rhs: MapFraming) -> Bool {
        switch (lhs, rhs) {
        case let (.topDown(a), .topDown(b)):
            return a.center.latitude == b.center.latitude
                && a.center.longitude == b.center.longitude
                && a.span.latitudeDelta == b.span.latitudeDelta
                && a.span.longitudeDelta == b.span.longitudeDelta
        case let (.camera(ac, ad, ap, ah), .camera(bc, bd, bp, bh)):
            return ac.latitude == bc.latitude && ac.longitude == bc.longitude
                && ad == bd && ap == bp && ah == bh
        default:
            return false
        }
    }
}

/// A framing the map should apply, tagged with an identity token so re-applying
/// the *same* framing (e.g. re-selecting a course, or re-focusing the same hole)
/// still takes effect. SwiftUI would otherwise diff two equal values as "no
/// change" and skip the update.
struct MapFramingRequest: Equatable {
    var framing: MapFraming
    var id: UUID = UUID()

    static func == (lhs: MapFramingRequest, rhs: MapFramingRequest) -> Bool {
        lhs.id == rhs.id
    }
}

/// Small spherical-geometry helpers for framing a hole down its tee→pin axis.
enum Geo {
    /// Great-circle distance in metres.
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// Initial bearing (compass degrees, 0 = north) from `a` to `b`.
    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CLLocationDirection {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Midpoint along the great-circle arc between `a` and `b`.
    static func midpoint(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let lat1 = a.latitude * .pi / 180, lon1 = a.longitude * .pi / 180
        let lat2 = b.latitude * .pi / 180, dLon = (b.longitude - a.longitude) * .pi / 180
        let bx = cos(lat2) * cos(dLon)
        let by = cos(lat2) * sin(dLon)
        let lat3 = atan2(sin(lat1) + sin(lat2),
                         sqrt((cos(lat1) + bx) * (cos(lat1) + bx) + by * by))
        let lon3 = lon1 + atan2(by, cos(lat1) + bx)
        return CLLocationCoordinate2D(latitude: lat3 * 180 / .pi, longitude: lon3 * 180 / .pi)
    }
}

/// Flat, `Equatable` snapshot of the per-layer style (resolved `NSColor` + a
/// visibility flag) the map needs to draw. Built by `ContentView` from the
/// `@Observable` `OverlaySettings` so SwiftUI's dependency tracking sees the read
/// and the representable re-syncs when colors/visibility change.
struct MapStyleConfig: Equatable {
    var colors: [OverlayLayer: NSColorBox]
    var visible: [OverlayLayer: Bool]
    var showMapLabels: Bool

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
    /// The framing to apply, or `nil` to leave the camera where it is.
    var framingRequest: MapFramingRequest?
    /// Recorded shots for the hole currently focused in Play mode.
    var shots: [Shot]
    /// The hole currently focused in Play mode.
    var currentHole: OSMHole?
    /// Whether the map is in Play mode (clicking records a shot).
    var isPlayMode: Bool
    /// Latest mouse-hover location in the map's local coordinate space, or `nil`
    /// when the pointer is outside the map. Fed from SwiftUI's `.onContinuousHover`
    /// (an external `NSTrackingArea` on `MKMapView` proved unreliable) so hovering a
    /// dimmed hole in Play mode can lift it back to full opacity.
    var hoverLocation: CGPoint?
    /// Called with the map coordinate of a click while in Play mode.
    var onAddShot: (CLLocationCoordinate2D) -> Void
    /// Called with a hole's OSM id when its tee marker is tapped in Play mode.
    var onSelectHole: (Int64) -> Void
    /// Called with a nearby course's identifier when its flag is tapped on the
    /// browse map, so that course can be opened.
    var onSelectCourse: (String) -> Void
    /// Called with the new region after the user pans/zooms the map (not fired for
    /// programmatic camera moves), so a "Search here" affordance can be offered.
    var onCameraMoved: (MKCoordinateRegion) -> Void

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
        context.coordinator.onSelectHole = onSelectHole
        context.coordinator.onSelectCourse = onSelectCourse
        context.coordinator.onCameraMoved = onCameraMoved
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
            currentHole: currentHole,
            framingRequest: framingRequest
        )
        // Re-run after `sync` (which owns `currentHoleID`) so a hover computed here
        // dims/undims against the up-to-date focused hole.
        context.coordinator.hover(at: hoverLocation)
    }
}

// MARK: - Overlays

/// The structural role of a map overlay, used by the renderer to pick the right
/// fill/stroke treatment independent of which `OverlayLayer` colors it.
private enum OverlayRole: String {
    case boundary
    case feature
    case hole
    case shot
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
    /// For `.hole` centerlines, the owning hole's OSM id, so the renderer can dim
    /// every non-focused hole to match the tee/pin/label emphasis in Play mode.
    var osmIdentifier: Int64?
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
    let osmIdentifier: Int64
    let glyph: String
    let title: String?
    init(coordinate: CLLocationCoordinate2D, osmIdentifier: Int64, glyph: String, title: String?) {
        self.coordinate = coordinate
        self.osmIdentifier = osmIdentifier
        self.glyph = glyph
        self.title = title
    }
}

/// Small filled disc at a hole's green (the pin position).
private final class HolePinAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let osmIdentifier: Int64
    init(coordinate: CLLocationCoordinate2D, osmIdentifier: Int64) {
        self.coordinate = coordinate
        self.osmIdentifier = osmIdentifier
    }
}

/// Par/distance text label beneath a hole's tee (e.g. "Par 4 · 410y"). We draw
/// it ourselves rather than lean on the tee marker's native `title`: MapKit
/// renders a marker's floating title in a separate layer that ignores the
/// annotation view's `alphaValue`, so the native title can't be dimmed in step
/// with the rest of the hole's markers. Owning it lets `emphasisAlpha` fade it.
private final class HoleTitleAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let osmIdentifier: Int64
    let text: String
    init(coordinate: CLLocationCoordinate2D, osmIdentifier: Int64, text: String) {
        self.coordinate = coordinate
        self.osmIdentifier = osmIdentifier
        self.text = text
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

/// Small yardage pill anchored near a shot segment.
private final class ShotYardageAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let label: String
    let shotNumber: Int

    init(coordinate: CLLocationCoordinate2D, label: String, shotNumber: Int) {
        self.coordinate = coordinate
        self.label = label
        self.shotNumber = shotNumber
    }
}

// MARK: - Coordinator

extension CourseMapView {
    final class Coordinator: NSObject, MKMapViewDelegate, NSGestureRecognizerDelegate {
        weak var map: MKMapView?
        /// Called with the clicked coordinate while in Play mode.
        var onAddShot: ((CLLocationCoordinate2D) -> Void)?
        /// Called with a tapped tee's hole OSM id while in Play mode.
        var onSelectHole: ((Int64) -> Void)?
        /// Called with a tapped nearby course's identifier on the browse map.
        var onSelectCourse: ((String) -> Void)?
        /// Called with the new region after a user-initiated pan/zoom.
        var onCameraMoved: ((MKCoordinateRegion) -> Void)?
        /// Whether a click should record a shot.
        var isPlayMode: Bool = false
        /// OSM id of the hole currently focused in Play mode. Every other hole's
        /// tee/pin marker is dimmed so the active hole reads as the subject.
        var currentHoleID: Int64?
        /// OSM id of the hole whose marker the mouse is currently hovering (Play
        /// mode). A hovered dimmed hole is lifted back to full opacity so it can be
        /// previewed without leaving the active hole.
        private var hoveredHoleID: Int64?

        /// Hash of the inputs that determine the overlay set, so we only rebuild
        /// overlays (an expensive add/remove) when the geometry or style changes.
        private var appliedOverlayHash: Int?
        /// Hash of the inputs that determine the static annotation set (course
        /// marker, hole tees/pins, nearby flags) — everything except shots.
        private var appliedStaticAnnotationHash: Int?
        /// Hash of the inputs that determine the shot annotation set.
        private var appliedShotAnnotationHash: Int?
        /// Identity of the last applied region request, so the same region can be
        /// re-framed but an unchanged one isn't reapplied every update pass.
        private var appliedRegionID: UUID?
        /// True while we're driving a programmatic `setRegion`, so the resulting
        /// `regionDidChangeAnimated` callback can be told apart from a user pan/zoom.
        private var isApplyingRegion = false
        /// Whether we've framed the map at least once. MapKit fires a region change
        /// as it settles its initial region on launch; suppressing reports until
        /// after our first framing keeps that from popping the "Search here" button.
        private var hasFramedOnce = false

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
            currentHole: OSMHole?,
            framingRequest: MapFramingRequest?
        ) {
            currentHoleID = currentHole?.osmIdentifier
            let segments = shotSegments(shots: shots, currentHole: currentHole)
            syncMapConfiguration(map: map, style: style)
            syncOverlays(
                map: map,
                outlines: outlines,
                features: features,
                holes: holes,
                style: style,
                shots: shots,
                currentHole: currentHole,
                segments: segments
            )
            syncAnnotations(
                map: map,
                holes: holes,
                displayedCourse: displayedCourse,
                courseMarkerCoordinate: courseMarkerCoordinate,
                nearbyCourses: nearbyCourses,
                style: style,
                shots: shots,
                segments: segments
            )
            applyFraming(map: map, framingRequest: framingRequest)
            updateHoleEmphasis(map: map)
        }

        /// Applies map-level configuration (e.g. POI label filter) when the style changes.
        private var currentShowMapLabels: Bool?

        private func syncMapConfiguration(map: MKMapView, style: MapStyleConfig) {
            guard style.showMapLabels != currentShowMapLabels else { return }
            currentShowMapLabels = style.showMapLabels
            if let config = map.preferredConfiguration as? MKHybridMapConfiguration {
                config.pointOfInterestFilter = style.showMapLabels ? nil : .excludingAll
                map.preferredConfiguration = config
            }
        }

        // MARK: Clicks

        /// Handles a Play-mode click: a click on a hole's tee marker switches focus
        /// to that hole; otherwise the click records a shot. `map.hitTest` is
        /// unreliable for `MKMarkerAnnotationView` (its balloon is drawn above the
        /// coordinate anchor, so the view's frame doesn't line up with the visible
        /// glyph), so the tee glyphs are hit-tested geometrically: each tee's
        /// coordinate is projected to its on-screen tip and a balloon-shaped rect is
        /// anchored there. The nearest tee whose balloon contains the click wins.
        @objc func handleMapClick(_ gesture: NSClickGestureRecognizer) {
            guard let map else { return }
            let point = gesture.location(in: map)

            // On the browse map a click on a nearby course's flag opens that course.
            if let nearby = nearestNearbyCourse(to: point, in: map) {
                onSelectCourse?(nearby.identifier)
                return
            }

            guard isPlayMode else { return }

            if let tee = nearestTee(to: point, in: map) {
                onSelectHole?(tee.osmIdentifier)
                return
            }
            // Clicks landing on any other annotation glyph (course pin, shot marker)
            // shouldn't also drop a shot underneath it.
            var view = map.hitTest(point)
            while let current = view {
                if current is MKAnnotationView { return }
                view = current.superview
            }

            let coordinate = map.convert(point, toCoordinateFrom: map)
            onAddShot?(coordinate)
        }

        // MARK: Hover

        /// Lifts the hovered hole to full opacity. Only meaningful in Play mode
        /// (where other holes are dimmed). `point` is in the map's local coordinate
        /// space (as delivered by SwiftUI's `.onContinuousHover`), or `nil` when the
        /// pointer leaves the map. The hit test reuses the tee glyph geometry so
        /// hovering a hole's numbered marker previews that hole's tee, dotted
        /// centerline and stats label without switching the active hole.
        func hover(at point: CGPoint?) {
            guard let map else { return }
            // `.onContinuousHover` reports in the SwiftUI view's coordinate space,
            // which is offset from the MKMapView's own bounds (the map ignores the
            // safe area and extends under the title bar), so its point can't be
            // hit-tested against `map.convert`-projected tee tips. Read the pointer
            // straight from the map's window instead — that lands in the exact same
            // space as a click's `gesture.location(in: map)`, where the tee geometry
            // is known to be correct. The passed point only signals hover vs. exit.
            guard point != nil, let window = map.window else {
                updateHover(to: nil, map: map)
                return
            }
            let inMap = map.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            let holeID = hoveredHole(at: inMap, in: map)
            updateHover(to: holeID, map: map)
        }

        /// Applies a new hovered-hole id, re-running the emphasis pass only when it
        /// actually changes so a continuous mouse move doesn't thrash the map.
        private func updateHover(to holeID: Int64?, map: MKMapView) {
            guard holeID != hoveredHoleID else { return }
            hoveredHoleID = holeID
            updateHoleEmphasis(map: map)
        }

        /// The OSM id of the hole whose tee glyph is nearest `point` (within its
        /// hit rect), or `nil` if the mouse is over no marker.
        private func hoveredHole(at point: CGPoint, in map: MKMapView) -> Int64? {
            var best: (id: Int64, distance: CGFloat)?
            for tee in map.annotations.compactMap({ $0 as? HoleTeeAnnotation }) {
                let rect = teeHitRect(for: tee, in: map)
                guard rect.contains(point) else { continue }
                let dx = point.x - rect.midX, dy = point.y - rect.midY
                let distance = (dx * dx + dy * dy).squareRoot()
                if best == nil || distance < best!.distance {
                    best = (tee.osmIdentifier, distance)
                }
            }
            return best?.id
        }

        /// Screen-space hit rect for a tee's balloon glyph, in the map's coordinate
        /// space. Prefers the annotation view's ACTUAL frame — MapKit positions and
        /// billboards that view at a constant screen size regardless of camera
        /// pitch/zoom, so its frame is reliable where a geometrically-estimated glyph
        /// center is not — padded outward for an easier target. Falls back to a
        /// balloon rect anchored at the projected coordinate tip when the view isn't
        /// materialized (off-screen, or not yet drawn after an add).
        private func teeHitRect(for tee: HoleTeeAnnotation, in map: MKMapView) -> CGRect {
            let pad: CGFloat = 14
            if let view = map.view(for: tee) {
                return view.frame.insetBy(dx: -pad, dy: -pad)
            }
            // MKMarkerAnnotationView balloon: ~40pt wide, tip at bottom-center,
            // rising ~52pt above the tip.
            let tip = map.convert(tee.coordinate, toPointTo: map)
            return CGRect(x: tip.x - 20, y: tip.y - 52, width: 40, height: 52)
                .insetBy(dx: -pad, dy: -pad)
        }

        /// The tee annotation whose balloon glyph contains `point`, or `nil` if the
        /// click missed every tee. When balloons overlap, the one whose hit rect
        /// center is nearest the click wins (not the first in iteration order).
        private func nearestTee(to point: CGPoint, in map: MKMapView) -> HoleTeeAnnotation? {
            var best: (tee: HoleTeeAnnotation, distance: CGFloat)?
            for tee in map.annotations.compactMap({ $0 as? HoleTeeAnnotation }) {
                // The current hole's own tee is where you record your tee shot, so it
                // isn't a hole-switch target — clicks there fall through to `addShot`.
                if tee.osmIdentifier == currentHoleID { continue }
                // Hit-test against the marker's actual rendered frame (see
                // `teeHitRect`), which stays accurate when the map is tilted into a
                // hole where a geometric glyph-center estimate drifts.
                let rect = teeHitRect(for: tee, in: map)
                guard rect.contains(point) else { continue }
                let dx = point.x - rect.midX, dy = point.y - rect.midY
                let distance = (dx * dx + dy * dy).squareRoot()
                if best == nil || distance < best!.distance {
                    best = (tee, distance)
                }
            }
            return best?.tee
        }

        /// The nearby-course flag whose balloon glyph contains `point`, or `nil` if
        /// the click missed every flag. Uses the same balloon-geometry hit test as
        /// the tees (an `MKMarkerAnnotationView`'s frame doesn't line up with its
        /// visible glyph). When flags overlap, the one whose tip is nearest wins.
        private func nearestNearbyCourse(to point: CGPoint, in map: MKMapView) -> NearbyCourseAnnotation? {
            var best: (course: NearbyCourseAnnotation, distance: CGFloat)?
            for course in map.annotations.compactMap({ $0 as? NearbyCourseAnnotation }) {
                let tip = map.convert(course.coordinate, toPointTo: map)
                let balloon = CGRect(x: tip.x - 24, y: tip.y - 56, width: 48, height: 60)
                guard balloon.contains(point) else { continue }
                let dx = point.x - tip.x, dy = point.y - tip.y
                let distance = (dx * dx + dy * dy).squareRoot()
                if best == nil || distance < best!.distance {
                    best = (course, distance)
                }
            }
            return best?.course
        }

        // MARK: Overlays

        private func syncOverlays(
            map: MKMapView,
            outlines: [[CLLocationCoordinate2D]],
            features: [OSMFeature],
            holes: [OSMHole],
            style: MapStyleConfig,
            shots: [Shot],
            currentHole: OSMHole?,
            segments: [ShotSegment]
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
            for s in shots {
                hasher.combine(s.id)
                hasher.combine(s.coordinate.latitude)
                hasher.combine(s.coordinate.longitude)
            }
            hasher.combine(currentHole?.osmIdentifier)
            if let tee = currentHole?.coordinates.first {
                hasher.combine(tee.lat)
                hasher.combine(tee.lon)
            }
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
                    line.osmIdentifier = hole.osmIdentifier
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
            // Shot segments sit above labels so they are always visible over terrain.
            for segment in segments {
                var coords = [segment.from, segment.to]
                let line = StyledPolyline(coordinates: &coords, count: coords.count)
                line.layer = .unknown
                line.role = .shot
                map.addOverlay(line, level: .aboveLabels)
            }
            map.removeOverlays(old)
        }

        // MARK: Delegate

        /// Reports user-initiated pan/zoom so the map host can offer a "Search
        /// here" affordance. Our own programmatic camera moves (course framing,
        /// "Search here" itself) set `isApplyingRegion` around `setRegion`, so the
        /// resulting callback is recognized as ours and filtered out — everything
        /// else is the user dragging or zooming.
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            if isApplyingRegion {
                isApplyingRegion = false
                hasFramedOnce = true
                return
            }
            guard hasFramedOnce else { return }
            onCameraMoved?(mapView.region)
        }

        /// The app drives all marker emphasis itself (hole focus, the flag on the
        /// current pin, dimming) and navigates on tap, so MapKit's built-in
        /// annotation selection is unwanted: a selected `MKMarkerAnnotationView`
        /// enlarges its balloon and lifts its glyph, which reads as a hole number
        /// "shifting" vertically and — because nothing else deselects it — persists
        /// as you move between holes. Immediately deselecting keeps every marker in
        /// its resting layout, killing that shift at the source (the `dequeueMarker`
        /// reset only catches recycled views, not one selected while on the map).
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            mapView.deselectAnnotation(view.annotation, animated: false)
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
                if line.role == .shot {
                    renderer.strokeColor = NSColor.systemOrange.withAlphaComponent(0.85)
                    renderer.lineWidth = 3
                } else if line.role == .hole {
                    renderer.lineWidth = 2
                    renderer.lineDashPattern = [6, 4]
                    if let id = line.osmIdentifier {
                        renderer.strokeColor = color.withAlphaComponent(emphasisAlpha(for: id))
                    }
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
            shots: [Shot],
            segments: [ShotSegment]
        ) {
            currentStyle = style
            syncStaticAnnotations(
                map: map,
                holes: holes,
                displayedCourse: displayedCourse,
                courseMarkerCoordinate: courseMarkerCoordinate,
                nearbyCourses: nearbyCourses,
                style: style
            )
            syncShotAnnotations(map: map, shots: shots, segments: segments)
        }

        /// Rebuilds the course marker, hole tees/pins, and nearby flags. This set
        /// changes only on course selection / nearby load / holes style change —
        /// never when a shot is recorded — so dropping a shot no longer tears down
        /// and recycles every tee/pin glyph (MapKit recycles the view during removal
        /// and hands back a stale cached image for one frame, which read as a flash).
        /// Gated on its own hash so an unrelated update is a no-op.
        private func syncStaticAnnotations(
            map: MKMapView,
            holes: [OSMHole],
            displayedCourse: GolfCourse?,
            courseMarkerCoordinate: CLLocationCoordinate2D?,
            nearbyCourses: [GolfCourse],
            style: MapStyleConfig
        ) {
            var hasher = Hasher()
            if let course = displayedCourse {
                hasher.combine(course.identifier)
                let c = courseMarkerCoordinate ?? course.coordinate
                hasher.combine(c.latitude); hasher.combine(c.longitude)
            } else {
                for course in nearbyCourses { hasher.combine(course.identifier) }
            }
            for h in holes { hasher.combine(h.osmIdentifier) }
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
            guard hash != appliedStaticAnnotationHash else { return }
            appliedStaticAnnotationHash = hash

            // Remove only the static glyphs (leave the user-location dot and any
            // shot/yardage annotations in place), then rebuild them.
            let toRemove = map.annotations.filter {
                $0 is CourseMarkerAnnotation
                    || $0 is HoleTeeAnnotation
                    || $0 is HolePinAnnotation
                    || $0 is HoleTitleAnnotation
                    || $0 is NearbyCourseAnnotation
            }
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
                                osmIdentifier: hole.osmIdentifier,
                                glyph: hole.displayGlyph,
                                title: Self.holeTitle(hole)
                            ))
                            map.addAnnotation(HoleTitleAnnotation(
                                coordinate: tee,
                                osmIdentifier: hole.osmIdentifier,
                                text: Self.holeTitle(hole)
                            ))
                        }
                        if let pin = coords.last, coords.count >= 2 {
                            map.addAnnotation(HolePinAnnotation(coordinate: pin, osmIdentifier: hole.osmIdentifier))
                        }
                    }
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

        /// Reconciles the recorded-shot markers and yardage pills incrementally:
        /// matching annotations are left untouched (no recycle, no flash); only
        /// genuinely new shot/segment annotations are inserted and stale ones
        /// removed. So recording a shot adds one marker without redrawing the
        /// markers already on screen — and never touches the tees/pins/course pin.
        private func syncShotAnnotations(
            map: MKMapView,
            shots: [Shot],
            segments: [ShotSegment]
        ) {
            var hasher = Hasher()
            for s in shots {
                hasher.combine(s.id)
                hasher.combine(s.coordinate.latitude)
                hasher.combine(s.coordinate.longitude)
            }
            for seg in segments {
                hasher.combine(seg.shotNumber)
                hasher.combine(seg.yards)
            }
            let hash = hasher.finalize()
            guard hash != appliedShotAnnotationHash else { return }
            appliedShotAnnotationHash = hash

            // Reconcile shot markers by number. Existing markers whose coordinate
            // still matches are kept as-is; only genuinely new shots are added and
            // stale ones removed.
            var shotByNumber: [Int: ShotAnnotation] = [:]
            for shot in map.annotations.compactMap({ $0 as? ShotAnnotation }) {
                shotByNumber[shot.number] = shot
            }
            var addShots: [ShotAnnotation] = []
            for (index, shot) in shots.enumerated() {
                let number = index + 1
                if let existing = shotByNumber[number],
                   existing.coordinate.latitude == shot.coordinate.latitude,
                   existing.coordinate.longitude == shot.coordinate.longitude {
                    shotByNumber[number] = nil
                } else {
                    addShots.append(ShotAnnotation(coordinate: shot.coordinate, number: number))
                }
            }
            let removeShots = Array(shotByNumber.values)

            // Same reconcile for the yardage pills, keyed by their shot number.
            var yardageByNumber: [Int: ShotYardageAnnotation] = [:]
            for yardage in map.annotations.compactMap({ $0 as? ShotYardageAnnotation }) {
                yardageByNumber[yardage.shotNumber] = yardage
            }
            var addYardage: [ShotYardageAnnotation] = []
            for segment in segments {
                let label = "\(segment.yards)y"
                if let existing = yardageByNumber[segment.shotNumber],
                   existing.label == label,
                   existing.coordinate.latitude == segment.midpoint.latitude,
                   existing.coordinate.longitude == segment.midpoint.longitude {
                    yardageByNumber[segment.shotNumber] = nil
                } else {
                    addYardage.append(ShotYardageAnnotation(
                        coordinate: segment.midpoint,
                        label: label,
                        shotNumber: segment.shotNumber
                    ))
                }
            }
            let removeYardage = Array(yardageByNumber.values)

            map.removeAnnotations(removeShots + removeYardage)
            map.addAnnotations(addShots + addYardage)
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
                // The par/distance text is drawn by our own `HoleTitleAnnotation`
                // so it can be dimmed; MapKit's native marker title can't be, so
                // suppress it here to avoid an un-dimmable duplicate.
                view.titleVisibility = .hidden
                view.subtitleVisibility = .hidden
                view.alphaValue = emphasisAlpha(for: tee.osmIdentifier)
                return view

            case let pin as HolePinAnnotation:
                if isPlayMode && pin.osmIdentifier == currentHoleID {
                    // Focused hole: flag on the standard balloon marker.
                    let view = dequeueMarker(mapView, id: "holePinFlag", for: pin)
                    view.markerTintColor = currentStyle?.color(.holes) ?? .systemBlue
                    view.glyphImage = NSImage(systemSymbolName: "flag.fill", accessibilityDescription: nil)
                    view.displayPriority = .required
                    view.canShowCallout = false
                    view.alphaValue = 1
                    return view
                }
                // Other holes: small disc.
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
                view.alphaValue = emphasisAlpha(for: pin.osmIdentifier)
                return view

            case let label as HoleTitleAnnotation:
                let id = "holeTitle"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: label, reuseIdentifier: id)
                view.annotation = label
                view.canShowCallout = false
                view.displayPriority = .required
                // Sit just below the tee marker's coordinate tip (positive y is down),
                // where MapKit's native marker title used to float.
                view.centerOffset = CGPoint(x: 0, y: 29)
                view.image = holeTitleLabelImage(label.text)
                view.alphaValue = emphasisAlpha(for: label.osmIdentifier)
                return view

            case let shot as ShotAnnotation:
                let view = dequeueMarker(mapView, id: "shot", for: shot)
                view.markerTintColor = .systemOrange
                view.glyphText = "\(shot.number)"
                view.displayPriority = .required
                view.canShowCallout = false
                return view

            case let yardage as ShotYardageAnnotation:
                let id = "shotYardage"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: yardage, reuseIdentifier: id)
                view.annotation = yardage
                view.canShowCallout = false
                view.displayPriority = .required
                view.centerOffset = CGPoint(x: 0, y: -12)

                let text = yardage.label
                let pillSize = pillSizeForYardage(text)
                let paraStyle = NSMutableParagraphStyle()
                paraStyle.alignment = .center
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.white,
                    .paragraphStyle: paraStyle
                ]
                // Drawing handler renders at the target context's scale factor,
                // so the pill is sharp on Retina displays without manual scaling.
                let image = NSImage(size: pillSize, flipped: false) { rect in
                    let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
                    NSColor.black.withAlphaComponent(0.72).setFill()
                    path.fill()
                    let textRect = NSRect(x: 7, y: 3, width: rect.width - 14, height: rect.height - 6)
                    text.draw(in: textRect, withAttributes: attrs)
                    return true
                }
                view.image = image
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
            // Reset mutable visual state that survives recycling. A marker that was
            // selected (which enlarges the balloon and lifts its glyph) leaves the
            // glyph label vertically offset when the view is later reused for a
            // different annotation — visible as hole numbers sitting too high on the
            // tee markers after a sub-course switch removes+re-adds every tee. Clear
            // the glyph and offset here so each caller starts from a clean marker.
            view.setSelected(false, animated: false)
            view.centerOffset = .zero
            view.glyphText = nil
            view.glyphImage = nil
            return view
        }

        /// Opacity a hole's tee/pin marker should render at. In Play mode every hole
        /// other than the focused one is dimmed so the active hole stands out; in
        /// Plan mode (or before a hole is chosen) all markers are fully opaque. A
        /// hovered hole is also lifted to full opacity so it can be previewed.
        private func emphasisAlpha(for holeID: Int64) -> CGFloat {
            guard isPlayMode, let current = currentHoleID else { return 1 }
            if holeID == current || holeID == hoveredHoleID { return 1 }
            return 0.3
        }

        /// Re-applies `emphasisAlpha` to the tee/pin views already on the map, and
        /// refreshes each pin's flag/disc styling. MapKit only calls `viewFor` on
        /// add/recycle, so when the focused hole changes (advancing holes, switching
        /// sub-course, entering/leaving Play) the existing markers must be updated in
        /// place. Fades so the change reads as a deliberate emphasis shift rather
        /// than a pop.
        private func updateHoleEmphasis(map: MKMapView) {
            // A pin's view CLASS depends on whether it's the focused hole (balloon
            // flag marker vs. plain disc). MapKit caches the last view it built, so a
            // hole change needs the stale pin views re-materialized to pick up the
            // right class. Remove+re-add only the pins whose kind actually changed.
            let staleFlags = map.annotations.compactMap { annotation -> HolePinAnnotation? in
                guard let pin = annotation as? HolePinAnnotation,
                      let view = map.view(for: pin) else { return nil }
                let wantsFlag = isPlayMode && pin.osmIdentifier == currentHoleID
                let hasFlag = view is MKMarkerAnnotationView
                return wantsFlag != hasFlag ? pin : nil
            }
            if !staleFlags.isEmpty {
                map.removeAnnotations(staleFlags)
                map.addAnnotations(staleFlags)
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.allowsImplicitAnimation = true
                for annotation in map.annotations {
                    let holeID: Int64
                    switch annotation {
                    case let tee as HoleTeeAnnotation: holeID = tee.osmIdentifier
                    case let pin as HolePinAnnotation: holeID = pin.osmIdentifier
                    case let label as HoleTitleAnnotation: holeID = label.osmIdentifier
                    default: continue
                    }
                    guard let view = map.view(for: annotation) else { continue }
                    let target = emphasisAlpha(for: holeID)
                    if view.alphaValue != target {
                        view.animator().alphaValue = target
                    }
                }
            }
            // The dotted hole centerlines dim the same way, but overlay renderers
            // aren't part of the AppKit animation graph — re-stroke each cached hole
            // renderer with the new emphasis alpha and mark it for redraw.
            for overlay in map.overlays {
                guard let line = overlay as? StyledPolyline, line.role == .hole,
                      let id = line.osmIdentifier,
                      let renderer = map.renderer(for: overlay) as? MKPolylineRenderer else { continue }
                let color = currentStyle?.color(line.layer) ?? .white
                renderer.strokeColor = color.withAlphaComponent(emphasisAlpha(for: id))
                renderer.setNeedsDisplay()
            }
        }

        /// Compact hole label, e.g. "Par 4 · 410y". Falls back to the
        /// coordinate-derived tee-to-pin distance when OSM lacks a length tag.
        private static func holeTitle(_ hole: OSMHole) -> String {
            var parts: [String] = []
            if let par = hole.par { parts.append("Par \(par)") }
            let meters = hole.lengthMeters ?? teeToGreenMeters(hole)
            if let meters {
                parts.append("\(Int((meters * 1.09361).rounded()))y")
            }
            return parts.isEmpty ? "Hole" : parts.joined(separator: " · ")
        }

        /// Straight-line tee-to-pin distance in metres, derived from the hole's
        /// first and last coordinates. Returns `nil` when fewer than 2 points exist.
        private static func teeToGreenMeters(_ hole: OSMHole) -> Double? {
            guard hole.coordinates.count >= 2,
                  let tee = hole.coordinates.first,
                  let pin = hole.coordinates.last else { return nil }
            return CLLocation(latitude: tee.lat, longitude: tee.lon)
                .distance(from: CLLocation(latitude: pin.lat, longitude: pin.lon))
        }

        private struct ShotSegment {
            let shotNumber: Int
            let from: CLLocationCoordinate2D
            let to: CLLocationCoordinate2D
            let midpoint: CLLocationCoordinate2D
            let yards: Int
        }

        /// Creates one segment per recorded shot. Shot 1 starts at the hole tee
        /// when available, then each following shot starts at the prior shot.
        private func shotSegments(shots: [Shot], currentHole: OSMHole?) -> [ShotSegment] {
            var segments: [ShotSegment] = []
            var previous: CLLocationCoordinate2D?
            if let tee = currentHole?.coordinates.first {
                previous = CLLocationCoordinate2D(latitude: tee.lat, longitude: tee.lon)
            }

            for (index, shot) in shots.enumerated() {
                guard let from = previous else {
                    previous = shot.coordinate
                    continue
                }
                let yards = Int((distanceMeters(from: from, to: shot.coordinate) * 1.09361).rounded())
                let midpoint = CLLocationCoordinate2D(
                    latitude: (from.latitude + shot.coordinate.latitude) / 2,
                    longitude: (from.longitude + shot.coordinate.longitude) / 2
                )
                segments.append(ShotSegment(
                    shotNumber: index + 1,
                    from: from,
                    to: shot.coordinate,
                    midpoint: midpoint,
                    yards: yards
                ))
                previous = shot.coordinate
            }
            return segments
        }

        private func distanceMeters(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> CLLocationDistance {
            CLLocation(latitude: from.latitude, longitude: from.longitude)
                .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
        }

        private func pillSizeForYardage(_ text: String) -> CGSize {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]
            let textSize = text.size(withAttributes: attrs)
            return CGSize(width: max(34, ceil(textSize.width) + 14), height: 20)
        }

        /// Renders a hole's "Par 4 · 410y" label the way MapKit's native marker
        /// title looked — white text with a soft dark shadow for legibility over
        /// imagery, no pill — so the whole-view `alphaValue` can dim it in step with
        /// the hole's markers. Padding leaves room for the shadow blur.
        private func holeTitleLabelImage(_ text: String) -> NSImage {
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: para,
                .shadow: shadow
            ]
            let textSize = text.size(withAttributes: attrs)
            let pad: CGFloat = 6
            let size = CGSize(width: ceil(textSize.width) + pad * 2, height: ceil(textSize.height) + pad * 2)
            return NSImage(size: size, flipped: false) { rect in
                text.draw(in: rect.insetBy(dx: pad, dy: pad), withAttributes: attrs)
                return true
            }
        }

        // MARK: Region

        private func applyFraming(map: MKMapView, framingRequest: MapFramingRequest?) {
            guard let request = framingRequest, request.id != appliedRegionID else { return }
            appliedRegionID = request.id
            // Animate only short hops; a long cross-country jump animated would make
            // MapKit stream imagery along the whole flight path and stall (leaving the
            // base map blank while overlays float).
            let from = map.camera.centerCoordinate
            let to: CLLocationCoordinate2D
            switch request.framing {
            case let .topDown(region): to = region.center
            case let .camera(center, _, _, _): to = center
            }
            let jump = CLLocation(latitude: from.latitude, longitude: from.longitude)
                .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
            let animated = jump < 5_000
            // Mark this as our own move so the ensuing regionDidChange isn't
            // mistaken for a user pan/zoom (which would pop the "Search here" button).
            isApplyingRegion = true
            switch request.framing {
            case let .topDown(region):
                // Draw the full-course overview straight at its final framing rather
                // than animating a zoom-in to it — the pull-back/zoom read as awkward.
                map.setRegion(region, animated: false)
            case let .camera(center, distance, pitch, heading):
                // `fromDistance` is centerCoordinateDistance (camera→look-at point),
                // NOT altitude — passing an altitude here would snap the camera far
                // closer than intended.
                let camera = MKMapCamera(
                    lookingAtCenter: center,
                    fromDistance: distance,
                    pitch: pitch,
                    heading: heading
                )
                if animated {
                    // MapKit's default `setCamera(animated:)` duration is quite
                    // brisk; wrapping the call in an explicit `NSAnimationContext`
                    // makes MapKit adopt that duration, so the hole-to-hole glide is
                    // slower and easier to follow. `allowsImplicitAnimation` lets the
                    // camera change ride the context's timing.
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = Self.holeCameraDuration
                        ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        ctx.allowsImplicitAnimation = true
                        map.setCamera(camera, animated: true)
                    }
                } else {
                    map.setCamera(camera, animated: false)
                }
            }
        }

        /// How long the tilted per-hole camera glide takes, in seconds. Bumped well
        /// above MapKit's brisk default so moving between holes reads as a smooth
        /// fly-over rather than a snap.
        private static let holeCameraDuration: TimeInterval = 1.6
    }
}
