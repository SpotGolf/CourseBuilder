import Foundation
import Testing
@testable import CourseBuilder
import CourseDataSwift

@Suite("Green heat map")
struct GreenHeatMapTests {
    /// A 5 by 4 surface that rises 2 cm for each meter east and 1 cm for each meter south.
    private func tiltedSurface() -> ElevationSurface {
        var elevations: [Double?] = []
        for row in 0..<4 {
            for column in 0..<5 {
                elevations.append(100 + 0.02 * Double(column) - 0.01 * Double(row))
            }
        }
        return ElevationSurface(origin: Coordinate(lat: 39, lon: -105), columns: 5, elevations: elevations)
    }

    /// A polygon around the cells from (1, 1) to (3, 2).
    private func innerPolygon(of heatMap: GreenHeatMap) -> [Coordinate] {
        [
            heatMap.coordinate(column: 0.5, row: 0.5),
            heatMap.coordinate(column: 3.5, row: 0.5),
            heatMap.coordinate(column: 3.5, row: 2.5),
            heatMap.coordinate(column: 0.5, row: 2.5),
        ]
    }

    @Test func slopeAndDownhillDirectionOfATiltedPlane() throws {
        let heatMap = GreenHeatMap(surface: tiltedSurface(), polygon: [Coordinate]())

        #expect(heatMap.cells.count == 20)
        let expectedSlope = (0.02 * 0.02 + 0.01 * 0.01).squareRoot() * 100
        for cell in heatMap.cells {
            #expect(abs(cell.slopePercent - expectedSlope) < 0.001)
            // Downhill is west and north.
            #expect(abs(cell.downhillEast - (-0.02 / (expectedSlope / 100))) < 0.001)
            #expect(abs(cell.downhillNorth - (0.01 / (expectedSlope / 100))) < 0.001)
        }
    }

    @Test func cellWithNoNeighborOnAnAxisIsLeftOut() {
        // Row 0 has only its middle cell, so that cell has no east or west neighbor.
        let surface = ElevationSurface(origin: Coordinate(lat: 39, lon: -105), columns: 3, elevations: [
            nil, 10, nil,
            10, 10, 10,
            10, 10, 10,
        ])

        let heatMap = GreenHeatMap(surface: surface, polygon: [Coordinate]())

        #expect(heatMap.cells.count == 6)
        #expect(!heatMap.cells.contains { $0.row == 0 })
        #expect(heatMap.cells.allSatisfy { $0.slopePercent == 0 && $0.downhillEast == 0 && $0.downhillNorth == 0 })
    }

    @Test func figuresCoverOnlyCellsOnTheGreen() {
        let all = GreenHeatMap(surface: tiltedSurface(), polygon: [Coordinate]())
        let heatMap = GreenHeatMap(surface: tiltedSurface(), polygon: innerPolygon(of: all))

        #expect(all.relief == 0)
        #expect(heatMap.cells.filter(\.isOnGreen).count == 6)
        // Columns 1 to 3 rise 4 cm, and rows 1 to 2 fall 1 cm.
        #expect(abs(heatMap.relief - 0.05) < 0.0001)
        #expect(abs(heatMap.meanSlopePercent - 2.236) < 0.001)
        #expect(abs(heatMap.maxSlopePercent - 2.236) < 0.001)
        #expect(heatMap.bandShares == [0, 0, 1, 0, 0])
    }

    @Test func slopesFallIntoBands() {
        #expect(GreenHeatMap.bandIndex(forSlopePercent: 0) == 0)
        #expect(GreenHeatMap.bandIndex(forSlopePercent: 0.99) == 0)
        #expect(GreenHeatMap.bandIndex(forSlopePercent: 1) == 1)
        #expect(GreenHeatMap.bandIndex(forSlopePercent: 3.5) == 3)
        #expect(GreenHeatMap.bandIndex(forSlopePercent: 4) == 4)
        #expect(GreenHeatMap.bandIndex(forSlopePercent: 25) == 4)
    }

    @Test func cellCornersAreHalfACellFromItsCenter() {
        let heatMap = GreenHeatMap(surface: tiltedSurface(), polygon: [Coordinate]())
        let cell = heatMap.cells.first { $0.column == 2 && $0.row == 1 }!

        let corners = heatMap.corners(of: cell)
        let center = heatMap.coordinate(column: 2, row: 1)

        #expect(corners.count == 4)
        #expect(abs((corners[0].lat + corners[2].lat) / 2 - center.lat) < 1e-12)
        #expect(abs((corners[0].lon + corners[2].lon) / 2 - center.lon) < 1e-12)
        #expect(abs((corners[2].lat - corners[0].lat) * GreenSurfaceUpdater.metersPerDegree - 1) < 1e-6)
    }

    @Test func colorBlendsBetweenTheMiddlesOfTheBands() {
        let bands = GreenHeatMap.bands
        func isClose(_ color: (red: Double, green: Double, blue: Double), _ r: Double, _ g: Double, _ b: Double) -> Bool {
            abs(color.red - r) < 1e-9 && abs(color.green - g) < 1e-9 && abs(color.blue - b) < 1e-9
        }

        // Flat and very steep ground get the first and last color.
        #expect(isClose(GreenHeatMap.color(forSlopePercent: 0), bands[0].red, bands[0].green, bands[0].blue))
        #expect(isClose(GreenHeatMap.color(forSlopePercent: 12), bands[4].red, bands[4].green, bands[4].blue))
        // The middle of a band is that band's color.
        #expect(isClose(GreenHeatMap.color(forSlopePercent: 2.5), bands[2].red, bands[2].green, bands[2].blue))
        // The edge between two bands is half of each.
        #expect(isClose(
            GreenHeatMap.color(forSlopePercent: 3),
            (bands[2].red + bands[3].red) / 2, (bands[2].green + bands[3].green) / 2, (bands[2].blue + bands[3].blue) / 2
        ))
    }

    @Test func slopeGridFillsPositionsNextToCells() {
        // Only the middle column has neighbors on the north-south axis and the east-west axis.
        let surface = ElevationSurface(origin: Coordinate(lat: 39, lon: -105), columns: 5, elevations: [
            nil, nil, 10.00, nil, nil,
            nil, 10.00, 10.02, 10.04, nil,
            nil, nil, 10.04, nil, nil,
        ])
        let heatMap = GreenHeatMap(surface: surface, polygon: [Coordinate]())

        let grid = heatMap.slopeGrid

        #expect(heatMap.cells.count == 1)
        #expect(grid.count == 15)
        // The one cell keeps its own slope, and every position within two steps takes it.
        let slope = heatMap.cells[0].slopePercent
        #expect(grid[1 * 5 + 2] == slope)
        #expect(grid.allSatisfy { $0 != nil && abs($0! - slope) < 1e-9 })
    }
}
