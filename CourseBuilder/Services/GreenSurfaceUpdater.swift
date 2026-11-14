import Foundation
import CourseDataSwift

/// Builds the elevation surface of a green: a grid of ground heights that SpotGolf turns into
/// slope heat maps, contours, and downhill arrows.
enum GreenSurfaceUpdater {
    /// The distance between the centers of neighboring cells, in meters.
    static let spacing = 1.0
    /// How far outside the green a cell can be and still be sampled, in meters. Cells just
    /// outside the edge are kept so the slope at the edge can be worked out.
    static let edgeMargin = 1.0
    /// The meters in one degree of latitude. SpotGolf's `GroundPlane` uses the same value.
    static let metersPerDegree = 111_320.0
    /// The coarsest source data a surface is built from, in meters. Only 1 m data is made from
    /// lidar. Coarser data is too smooth to show the slopes of a green.
    static let maxResolution = 1.0

    /// Looks up one sample for each point, in order, with `nil` where there is no data.
    typealias Fetch = @Sendable ([Coordinate]) async throws -> [USGSElevationClient.Sample?]

    /// Samples USGS with bilinear interpolation. Measured against raw lidar on a green, it gives
    /// closer heights, slopes, and downhill directions than the service's default.
    static let usgsFetch: Fetch = { coordinates in
        try await USGSElevationClient().samples(for: coordinates, interpolation: .bilinear)
    }

    /// A polygon that needs more cells than this is not a green, so it gets no surface.
    static let maxCells = 20_000
    /// Slack for rounding, in meters, so a cell exactly on the margin is always kept.
    private static let tolerance = 0.001

    /// The cells to sample for one green.
    struct Grid: Equatable {
        /// The center of the south-west cell.
        let origin: Coordinate
        /// The number of cells from west to east.
        let columns: Int
        /// The number of cells from south to north.
        let rows: Int
        /// Whether each cell is sampled, row by row from south to north and west to east within
        /// a row. A cell is sampled if it is inside the green or within ``edgeMargin`` of its edge.
        let mask: [Bool]

        func isSampled(column: Int, row: Int) -> Bool {
            guard column >= 0, column < columns, row >= 0, row < rows else { return false }
            return mask[row * columns + column]
        }

        /// The center of a cell.
        func coordinate(column: Int, row: Int) -> Coordinate {
            let metersPerDegreeLongitude = metersPerDegree * cos(origin.lat * .pi / 180)
            return Coordinate(
                lat: origin.lat + Double(row) * spacing / metersPerDegree,
                lon: origin.lon + Double(column) * spacing / metersPerDegreeLongitude
            )
        }

        /// The centers of the sampled cells, in the order of ``mask``.
        var coordinates: [Coordinate] {
            mask.indices.compactMap { index in
                mask[index] ? coordinate(column: index % columns, row: index / columns) : nil
            }
        }
    }

    /// Returns the grid over a green's polygon, or `nil` if the polygon is not a closed shape
    /// or is far too large to be a green.
    static func grid(for polygon: some RandomAccessCollection<Coordinate>) -> Grid? {
        guard polygon.count >= 3,
              let south = polygon.map(\.lat).min(), let north = polygon.map(\.lat).max(),
              let west = polygon.map(\.lon).min(), let east = polygon.map(\.lon).max() else { return nil }

        let originLat = south - edgeMargin / metersPerDegree
        let metersPerDegreeLongitude = metersPerDegree * cos(originLat * .pi / 180)
        guard metersPerDegreeLongitude > 0 else { return nil }
        let origin = Coordinate(lat: originLat, lon: west - edgeMargin / metersPerDegreeLongitude)

        // The polygon in meters east (x) and north (y) of the origin.
        let points = polygon.map {
            (x: ($0.lon - origin.lon) * metersPerDegreeLongitude, y: ($0.lat - origin.lat) * metersPerDegree)
        }
        let width = (east - origin.lon) * metersPerDegreeLongitude + edgeMargin
        let height = (north - origin.lat) * metersPerDegree + edgeMargin
        let columns = Int(((width + tolerance) / spacing).rounded(.down)) + 1
        let rows = Int(((height + tolerance) / spacing).rounded(.down)) + 1
        guard columns * rows <= maxCells else { return nil }

        let reach = (edgeMargin + tolerance) * (edgeMargin + tolerance)
        var mask = [Bool](repeating: false, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let x = Double(column) * spacing
                let y = Double(row) * spacing
                mask[row * columns + column] = contains(x: x, y: y, in: points)
                    || squaredDistanceToEdge(x: x, y: y, of: points) <= reach
            }
        }
        return Grid(origin: origin, columns: columns, rows: rows, mask: mask)
    }

    /// Returns the surface for a grid, given one elevation per sampled cell in the order of
    /// ``Grid/coordinates``. Returns `nil` if any sampled cell has no elevation.
    static func surface(for grid: Grid, elevations: [Double?]) -> ElevationSurface? {
        let resolved = elevations.compactMap { $0 }
        guard !resolved.isEmpty, resolved.count == grid.mask.filter({ $0 }).count else { return nil }
        var next = resolved.makeIterator()
        return ElevationSurface(
            origin: grid.origin,
            spacing: spacing,
            columns: grid.columns,
            elevations: grid.mask.map { $0 ? next.next() : nil }
        )
    }

    /// Returns the surface for a grid, given one sample per sampled cell in the order of
    /// ``Grid/coordinates``. Returns `nil` if any sampled cell has no elevation, or if any
    /// elevation came from data coarser than ``maxResolution``.
    static func surface(for grid: Grid, samples: [USGSElevationClient.Sample?]) -> ElevationSurface? {
        guard samples.allSatisfy({ isLidar($0) }) else { return nil }
        return surface(for: grid, elevations: samples.map { $0?.elevation })
    }

    private static func isLidar(_ sample: USGSElevationClient.Sample?) -> Bool {
        guard let resolution = sample?.resolution else { return false }
        return resolution <= maxResolution + tolerance
    }

    /// The greens that have no surface and can have one, in file order.
    static func greensMissingSurface(in course: Course) -> [Feature] {
        course.features.filter { $0.type == .green && $0.surface == nil && grid(for: $0.polygon) != nil }
    }

    /// A polygon's points without their elevations. A surface belongs to the positions it was
    /// sampled for.
    static func positions(of polygon: CoordinatePath) -> [ElevationUpdater.Location] {
        polygon.map(ElevationUpdater.Location.init)
    }

    /// Samples the surface of a green's polygon.
    ///
    /// Returns `nil` if USGS has no 1 m lidar data for any sampled cell, for example because the
    /// green is outside the United States. Throws if the service cannot be reached or answers with an error.
    static func buildSurface(
        for polygon: CoordinatePath,
        fetch: Fetch = usgsFetch
    ) async throws -> ElevationSurface? {
        guard let grid = grid(for: polygon) else { return nil }
        do {
            return surface(for: grid, samples: try await fetch(grid.coordinates))
        } catch let error as USGSElevationClient.ElevationError where error.isOutsideUnitedStates {
            return nil
        }
    }

    /// The result of building the missing surfaces of a course.
    struct Update {
        var course: Course
        /// How many greens USGS has no 1 m lidar data for. They are left with no surface.
        var greensWithoutData: Int
    }

    /// Returns a copy of the course with a surface on every green that lacked one and that USGS
    /// has 1 m lidar data for. Throws if the service cannot be reached or answers with an error.
    static func update(_ course: Course, fetch: Fetch = usgsFetch) async throws -> Update {
        var update = Update(course: course, greensWithoutData: 0)
        for green in greensMissingSurface(in: course) {
            if let surface = try await buildSurface(for: green.polygon, fetch: fetch) {
                apply(surface, toGreen: green.id, sampledFor: positions(of: green.polygon), in: &update.course)
            } else {
                update.greensWithoutData += 1
            }
        }
        return update
    }

    /// Sets a green's surface, unless the green moved or got a surface since it was sampled.
    @discardableResult
    static func apply(
        _ surface: ElevationSurface,
        toGreen id: Int,
        sampledFor sampled: [ElevationUpdater.Location],
        in course: inout Course
    ) -> Bool {
        guard let index = course.features.firstIndex(where: { $0.id == id }),
              course.features[index].type == .green,
              course.features[index].surface == nil,
              positions(of: course.features[index].polygon) == sampled else { return false }
        course.features[index].surface = surface
        return true
    }

    /// Removes the surface of every green whose polygon was edited between `old` and `course`,
    /// so it gets built again. A change to the elevations of the points alone is not an edit.
    static func clearStaleSurfaces(in course: inout Course, comparedTo old: Course) {
        guard course.features != old.features else { return }
        var oldGreens: [Int: Feature] = [:]
        for feature in old.features where feature.surface != nil {
            oldGreens[feature.id] = feature
        }
        guard !oldGreens.isEmpty else { return }

        for index in course.features.indices {
            let feature = course.features[index]
            // A different surface came with its own polygon, for example from an undo.
            guard let surface = feature.surface, let oldGreen = oldGreens[feature.id], oldGreen.surface == surface,
                  feature.polygon != oldGreen.polygon,
                  positions(of: feature.polygon) != positions(of: oldGreen.polygon) else { continue }
            course.features[index].surface = nil
        }
    }

    // MARK: - Geometry in meters

    private typealias Point = (x: Double, y: Double)

    private static func contains(x: Double, y: Double, in polygon: [Point]) -> Bool {
        var inside = false
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            if (current.y > y) != (previous.y > y),
               x < (previous.x - current.x) * (y - current.y) / (previous.y - current.y) + current.x {
                inside.toggle()
            }
            previous = current
        }
        return inside
    }

    private static func squaredDistanceToEdge(x: Double, y: Double, of polygon: [Point]) -> Double {
        var nearest = Double.infinity
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            let dx = current.x - previous.x
            let dy = current.y - previous.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? max(0, min(1, ((x - previous.x) * dx + (y - previous.y) * dy) / lengthSquared)) : 0
            let offsetX = x - (previous.x + t * dx)
            let offsetY = y - (previous.y + t * dy)
            nearest = min(nearest, offsetX * offsetX + offsetY * offsetY)
            previous = current
        }
        return nearest
    }
}
