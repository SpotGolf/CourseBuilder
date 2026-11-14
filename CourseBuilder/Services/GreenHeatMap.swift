import Foundation
import CourseDataSwift

/// The slope of a green, worked out from its elevation surface, for drawing a heat map.
struct GreenHeatMap: Equatable {
    /// One 1 m square of the green.
    struct Cell: Equatable {
        let column: Int
        let row: Int
        /// Meters above sea level.
        let elevation: Double
        /// The steepness of the ground, as a percent grade.
        let slopePercent: Double
        /// The downhill direction as a unit vector, or zero where the ground is level.
        let downhillEast: Double
        let downhillNorth: Double
        /// Whether the center of the cell is inside the green's polygon.
        let isOnGreen: Bool
    }

    /// A range of slopes drawn in one color. The ranges match the prototype in `scripts/heatmap`.
    struct Band: Equatable {
        let label: String
        /// The slope the band ends below, in percent. The last band has no end.
        let upperBound: Double
        let red: Double
        let green: Double
        let blue: Double
    }

    /// Flat ground is bright green, and the color moves through yellow and orange to red as the
    /// ground gets steeper.
    static let bands: [Band] = [
        Band(label: "<1%", upperBound: 1, red: 0x1e / 255.0, green: 0xe0 / 255.0, blue: 0x28 / 255.0),
        Band(label: "1–2%", upperBound: 2, red: 0xa8 / 255.0, green: 0xf0 / 255.0, blue: 0x00 / 255.0),
        Band(label: "2–3%", upperBound: 3, red: 0xf2 / 255.0, green: 0xf2 / 255.0, blue: 0x00 / 255.0),
        Band(label: "3–4%", upperBound: 4, red: 0xff / 255.0, green: 0x9a / 255.0, blue: 0x00 / 255.0),
        Band(label: "4%+", upperBound: .infinity, red: 0xf5 / 255.0, green: 0x45 / 255.0, blue: 0x0f / 255.0),
    ]

    /// The color for a slope, as red, green, and blue from 0 to 1. Each band's color sits at the
    /// middle of its range (0.5%, 1.5%, and so on), and slopes in between get a blend of the two
    /// nearest colors. Slopes under 0.5% and over 4.5% get the first and last color.
    static func color(forSlopePercent slope: Double) -> (red: Double, green: Double, blue: Double) {
        let position = min(max(slope - 0.5, 0), Double(bands.count - 1))
        let lower = min(Int(position), bands.count - 2)
        let fraction = position - Double(lower)
        let from = bands[lower], to = bands[lower + 1]
        return (
            from.red + (to.red - from.red) * fraction,
            from.green + (to.green - from.green) * fraction,
            from.blue + (to.blue - from.blue) * fraction
        )
    }

    /// One slope per grid position, row by row from south to north, for drawing the heat map as
    /// a picture. A position with no cell takes the slope of a cell next to it, so the colors
    /// stay clean right up to the edge of the green. `nil` further out.
    var slopeGrid: [Double?] {
        var grid = [Double?](repeating: nil, count: columns * rows)
        for cell in cells {
            grid[cell.row * columns + cell.column] = cell.slopePercent
        }
        for _ in 0..<2 {
            let known = grid
            for row in 0..<rows {
                for column in 0..<columns where known[row * columns + column] == nil {
                    var sum = 0.0, count = 0.0
                    for (dc, dr) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)] {
                        let c = column + dc, r = row + dr
                        guard c >= 0, c < columns, r >= 0, r < rows, let slope = known[r * columns + c] else { continue }
                        sum += slope
                        count += 1
                    }
                    if count > 0 {
                        grid[row * columns + column] = sum / count
                    }
                }
            }
        }
        return grid
    }

    /// The index in ``bands`` of the band a slope falls in.
    static func bandIndex(forSlopePercent slope: Double) -> Int {
        bands.firstIndex { slope < $0.upperBound } ?? bands.count - 1
    }

    let origin: Coordinate
    let spacing: Double
    let columns: Int
    let rows: Int
    /// Every cell whose slope can be worked out, row by row from south to north.
    let cells: [Cell]

    /// - Parameters:
    ///   - surface: The green's elevation surface.
    ///   - polygon: The green's outline. Cells outside it are kept, but left out of the figures.
    init(surface: ElevationSurface, polygon: some RandomAccessCollection<Coordinate>) {
        origin = surface.origin
        spacing = surface.spacing
        columns = surface.columns
        rows = surface.rows

        var cells: [Cell] = []
        for row in 0..<surface.rows {
            for column in 0..<surface.columns {
                guard let elevation = surface.elevation(column: column, row: row),
                      let east = Self.gradient(
                          before: surface.elevation(column: column - 1, row: row),
                          at: elevation,
                          after: surface.elevation(column: column + 1, row: row),
                          spacing: surface.spacing
                      ),
                      let north = Self.gradient(
                          before: surface.elevation(column: column, row: row - 1),
                          at: elevation,
                          after: surface.elevation(column: column, row: row + 1),
                          spacing: surface.spacing
                      ) else { continue }
                let steepness = (east * east + north * north).squareRoot()
                let center = Self.coordinate(origin: surface.origin, spacing: surface.spacing, column: Double(column), row: Double(row))
                cells.append(Cell(
                    column: column,
                    row: row,
                    elevation: elevation,
                    slopePercent: steepness * 100,
                    downhillEast: steepness > 0 ? -east / steepness : 0,
                    downhillNorth: steepness > 0 ? -north / steepness : 0,
                    isOnGreen: PolygonGeometry.contains(center, in: polygon)
                ))
            }
        }
        self.cells = cells
    }

    /// The rise per meter through a cell along one axis. Uses the cells on both sides where it
    /// can, and one side at the edge of the surface. `nil` if the cell has no neighbor.
    private static func gradient(before: Double?, at elevation: Double, after: Double?, spacing: Double) -> Double? {
        switch (before, after) {
        case (let before?, let after?): (after - before) / (2 * spacing)
        case (let before?, nil): (elevation - before) / spacing
        case (nil, let after?): (after - elevation) / spacing
        case (nil, nil): nil
        }
    }

    /// The point `column` and `row` cells east and north of the origin. Whole numbers are cell
    /// centers, and half numbers are cell edges.
    func coordinate(column: Double, row: Double) -> Coordinate {
        Self.coordinate(origin: origin, spacing: spacing, column: column, row: row)
    }

    private static func coordinate(origin: Coordinate, spacing: Double, column: Double, row: Double) -> Coordinate {
        let metersPerDegree = GreenSurfaceUpdater.metersPerDegree
        return Coordinate(
            lat: origin.lat + row * spacing / metersPerDegree,
            lon: origin.lon + column * spacing / (metersPerDegree * cos(origin.lat * .pi / 180))
        )
    }

    /// The four corners of a cell, going around it.
    func corners(of cell: Cell) -> [Coordinate] {
        let column = Double(cell.column), row = Double(cell.row)
        return [
            coordinate(column: column - 0.5, row: row - 0.5),
            coordinate(column: column + 0.5, row: row - 0.5),
            coordinate(column: column + 0.5, row: row + 0.5),
            coordinate(column: column - 0.5, row: row + 0.5),
        ]
    }

    // MARK: - Figures for the cells on the green

    private var greenCells: [Cell] {
        cells.filter(\.isOnGreen)
    }

    /// The height difference between the highest and lowest cell on the green, in meters.
    var relief: Double {
        let elevations = greenCells.map(\.elevation)
        guard let low = elevations.min(), let high = elevations.max() else { return 0 }
        return high - low
    }

    var meanSlopePercent: Double {
        let slopes = greenCells.map(\.slopePercent)
        return slopes.isEmpty ? 0 : slopes.reduce(0, +) / Double(slopes.count)
    }

    var maxSlopePercent: Double {
        greenCells.map(\.slopePercent).max() ?? 0
    }

    /// The share of the green in each band, from 0 to 1, in the order of ``bands``.
    var bandShares: [Double] {
        let onGreen = greenCells
        var counts = [Int](repeating: 0, count: Self.bands.count)
        for cell in onGreen {
            counts[Self.bandIndex(forSlopePercent: cell.slopePercent)] += 1
        }
        return counts.map { onGreen.isEmpty ? 0 : Double($0) / Double(onGreen.count) }
    }
}
