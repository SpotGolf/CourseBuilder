import SwiftUI
import CourseDataSwift

/// A polygon or line drawn on the map.
struct MapShape {
    enum Kind {
        case polygon
        case polyline
    }

    let kind: Kind
    let coordinates: [Coordinate]
    var fill: Color?
    let stroke: Color
    let lineWidth: CGFloat
    var dash: [CGFloat] = []
}

/// A round point drawn on the map, such as a vertex handle.
struct MapMarker: Identifiable {
    let id: String
    let coordinate: Coordinate
    let diameter: CGFloat
    let fill: Color
    let stroke: Color
    let strokeWidth: CGFloat
    var isHidden = false
    var onTap: (() -> Void)?
}

/// Draws shapes in order, so later shapes are on top.
struct MapShapesLayer: View {
    let camera: MapCamera
    let shapes: [MapShape]

    var body: some View {
        let projection = camera.projection
        Canvas { context, _ in
            for shape in shapes where shape.coordinates.count >= 2 {
                var path = Path()
                path.addLines(shape.coordinates.map(projection.point(for:)))
                if shape.kind == .polygon {
                    path.closeSubpath()
                    if let fill = shape.fill {
                        context.fill(path, with: .color(fill))
                    }
                }
                context.stroke(
                    path,
                    with: .color(shape.stroke),
                    style: StrokeStyle(lineWidth: shape.lineWidth, lineCap: .round, lineJoin: .round, dash: shape.dash)
                )
            }
        }
        .allowsHitTesting(false)
    }
}

/// Draws markers above the shapes. Markers with `onTap` can be clicked.
struct MapMarkersLayer: View {
    let camera: MapCamera
    let markers: [MapMarker]

    var body: some View {
        let projection = camera.projection
        ZStack {
            ForEach(markers) { marker in
                Circle()
                    .fill(marker.fill)
                    .stroke(marker.stroke, lineWidth: marker.strokeWidth)
                    .frame(width: marker.diameter, height: marker.diameter)
                    .opacity(marker.isHidden ? 0 : 1)
                    .contentShape(Circle())
                    .onTapGesture { marker.onTap?() }
                    .allowsHitTesting(marker.onTap != nil)
                    .position(projection.point(for: marker.coordinate))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
