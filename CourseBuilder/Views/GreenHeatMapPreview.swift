import SwiftUI
import CourseDataSwift

extension GreenHeatMap.Band {
    var color: Color {
        Color(red: red, green: green, blue: blue)
    }
}

/// A smooth picture of a green's slope heat map with downhill arrows, a legend, and key figures.
struct GreenHeatMapPreview: View {
    let heatMap: GreenHeatMap
    let polygon: [Coordinate]

    private static let inchesPerMeter = 39.3701

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Canvas { context, size in
                let fit = Fit(heatMap: heatMap, size: size)
                GreenHeatMapDrawing.draw(heatMap, polygon: polygon, in: &context, point: fit.point(for:))
                GreenHeatMapDrawing.drawArrows(heatMap, in: &context, scale: fit.scale, point: fit.point(for:))
            }
            .aspectRatio(CGFloat(max(heatMap.columns, 1)) / CGFloat(max(heatMap.rows, 1)), contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 220)

            let shares = heatMap.bandShares
            VStack(spacing: 2) {
                // Each band's color sits at the middle of its column, as it does in the heat map.
                LinearGradient(
                    stops: GreenHeatMap.bands.enumerated().map { index, band in
                        Gradient.Stop(color: band.color, location: (CGFloat(index) + 0.5) / CGFloat(GreenHeatMap.bands.count))
                    },
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 8)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                HStack(spacing: 0) {
                    ForEach(Array(GreenHeatMap.bands.enumerated()), id: \.offset) { index, band in
                        VStack(spacing: 2) {
                            Text(band.label)
                            Text("\(Int((shares[index] * 100).rounded()))%")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .font(.caption2)

            Text(String(
                format: "Relief %.1f in · Mean slope %.1f%% · Steepest %.1f%%",
                heatMap.relief * Self.inchesPerMeter, heatMap.meanSlopePercent, heatMap.maxSlopePercent
            ))
            .font(.caption)
            Text("North is up. Arrows point downhill.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Fits the whole surface into a view, with north up.
    private struct Fit {
        let heatMap: GreenHeatMap
        let scale: CGFloat
        let size: CGSize

        init(heatMap: GreenHeatMap, size: CGSize) {
            self.heatMap = heatMap
            self.size = size
            scale = min(size.width / CGFloat(max(heatMap.columns, 1)), size.height / CGFloat(max(heatMap.rows, 1)))
        }

        func point(for coordinate: Coordinate) -> CGPoint {
            let metersPerDegree = GreenSurfaceUpdater.metersPerDegree
            let east = (coordinate.lon - heatMap.origin.lon) * metersPerDegree * cos(heatMap.origin.lat * .pi / 180)
            let north = (coordinate.lat - heatMap.origin.lat) * metersPerDegree
            // Cell centers run from 0 to columns - 1, so the surface starts half a cell before 0.
            let column = east / heatMap.spacing + 0.5
            let row = north / heatMap.spacing + 0.5
            let width = CGFloat(heatMap.columns) * scale
            let height = CGFloat(heatMap.rows) * scale
            return CGPoint(
                x: (size.width - width) / 2 + CGFloat(column) * scale,
                y: (size.height + height) / 2 - CGFloat(row) * scale
            )
        }
    }
}

enum GreenHeatMapDrawing {
    /// Draws the slope colors as a smooth picture, cut to the green's outline, then draws the
    /// outline. The picture has one pixel per cell and is blended as it is scaled up.
    ///
    /// - Parameter point: Where a coordinate is drawn. North must be up.
    static func draw(
        _ heatMap: GreenHeatMap,
        polygon: [Coordinate],
        in context: inout GraphicsContext,
        point: (Coordinate) -> CGPoint
    ) {
        guard polygon.count >= 3 else { return }
        var outline = Path()
        outline.addLines(polygon.map(point))
        outline.closeSubpath()

        if let image = image(of: heatMap) {
            // The picture covers every cell, from the outer edge of the first to that of the last.
            let topLeft = point(heatMap.coordinate(column: -0.5, row: Double(heatMap.rows) - 0.5))
            let bottomRight = point(heatMap.coordinate(column: Double(heatMap.columns) - 0.5, row: -0.5))
            var clipped = context
            clipped.clip(to: outline)
            clipped.draw(
                Image(decorative: image, scale: 1).interpolation(.high),
                in: CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
            )
        }

        context.stroke(outline, with: .color(.black.opacity(0.8)), lineWidth: 1.5)
    }

    /// A picture of the slope colors with one pixel per cell and north at the top.
    static func image(of heatMap: GreenHeatMap) -> CGImage? {
        let columns = heatMap.columns, rows = heatMap.rows
        guard columns > 0, rows > 0 else { return nil }
        let grid = heatMap.slopeGrid
        var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
        for row in 0..<rows {
            for column in 0..<columns {
                guard let slope = grid[row * columns + column] else { continue }
                let color = GreenHeatMap.color(forSlopePercent: slope)
                // Image rows run from the top, and surface rows from the south.
                let offset = ((rows - 1 - row) * columns + column) * 4
                pixels[offset] = UInt8((color.red * 255).rounded())
                pixels[offset + 1] = UInt8((color.green * 255).rounded())
                pixels[offset + 2] = UInt8((color.blue * 255).rounded())
                pixels[offset + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: columns,
            height: rows,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: columns * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// Draws a downhill arrow on every second cell of the green. Steeper ground gets a longer arrow.
    static func drawArrows(
        _ heatMap: GreenHeatMap,
        in context: inout GraphicsContext,
        scale: CGFloat,
        point: (Coordinate) -> CGPoint
    ) {
        var arrows = Path()
        for cell in heatMap.cells
        where cell.isOnGreen && cell.column % 2 == 0 && cell.row % 2 == 0 && cell.slopePercent >= 0.5 {
            let center = point(heatMap.coordinate(column: Double(cell.column), row: Double(cell.row)))
            // 0.5 cells long at 1%, up to 1.6 cells at 4% and more. North is up, so y is flipped.
            let length = scale * min(1.6, 0.4 * cell.slopePercent + 0.1)
            let dx = CGFloat(cell.downhillEast), dy = -CGFloat(cell.downhillNorth)
            let tail = CGPoint(x: center.x - dx * length / 2, y: center.y - dy * length / 2)
            let tip = CGPoint(x: center.x + dx * length / 2, y: center.y + dy * length / 2)
            let head = min(length * 0.45, scale * 0.45)
            arrows.move(to: tail)
            arrows.addLine(to: tip)
            for turn in [2.6, -2.6] {
                let angle = atan2(dy, dx) + turn
                arrows.move(to: tip)
                arrows.addLine(to: CGPoint(x: tip.x + cos(angle) * head, y: tip.y + sin(angle) * head))
            }
        }
        context.stroke(arrows, with: .color(.black.opacity(0.75)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
    }
}
