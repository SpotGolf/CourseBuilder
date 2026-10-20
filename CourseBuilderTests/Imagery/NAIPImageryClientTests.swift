import Foundation
import Testing
@testable import CourseBuilder
import CourseDataSwift

struct NAIPImageryClientTests {
    typealias BoundingBox = OverpassAPIClient.BoundingBox

    @Test func parseNewestYearPicksNewestAndCoarsestPixelSize() throws {
        let json = """
        {"features":[
          {"properties":{"datetime":"2021-07-28T16:00:00Z","gsd":0.6}},
          {"properties":{"datetime":"2023-09-25T16:00:00Z","gsd":0.3}},
          {"properties":{"datetime":"2023-09-26T16:00:00Z","gsd":0.6}},
          {"properties":{"datetime":"2019-08-03T16:00:00Z","gsd":0.6}}
        ]}
        """
        let newest = try #require(try NAIPImageryClient.parseNewestYear(data: Data(json.utf8)))
        #expect(newest.year == 2023)
        #expect(newest.gsd == 0.6)
    }

    @Test func parseNewestYearReturnsNilWithNoImagery() throws {
        #expect(try NAIPImageryClient.parseNewestYear(data: Data(#"{"features":[]}"#.utf8)) == nil)
    }

    @Test func parseSearchID() throws {
        let id = try NAIPImageryClient.parseSearchID(data: Data(#"{"searchid":"abc123","links":[]}"#.utf8))
        #expect(id == "abc123")
        #expect(throws: (any Error).self) { try NAIPImageryClient.parseSearchID(data: Data("{}".utf8)) }
    }

    @Test func zoomFromPixelSize() {
        #expect(NAIPImageryClient.zoom(forGSD: 0.3) == 19)
        #expect(NAIPImageryClient.zoom(forGSD: 0.6) == 18)
        #expect(NAIPImageryClient.zoom(forGSD: 1.0) == 17)
    }

    @Test func registerRequestFiltersToYear() throws {
        let box = BoundingBox(south: 39.99, west: -105.05, north: 40.02, east: -105.0)
        let request = NAIPImageryClient.buildRegisterRequest(for: box, year: 2023)
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body.contains("2023-01-01T00:00:00Z"))
        #expect(body.contains("2023-12-31T23:59:59Z"))
        #expect(body.contains("\"naip\""))
    }

    @Test func tileURLHasBands() throws {
        let url = NAIPImageryClient.tileURL(searchID: "abc", zoom: 19, x: 10, y: 20, bands: .falseColor)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/api/data/v1/mosaic/abc/tiles/WebMercatorQuad/19/10/20")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["asset_bidx"] == "image|4,1,2")
        #expect(items["collection"] == "naip")
        #expect(items["format"] == "png")
    }

    @Test func tileRangeCoversBox() {
        let box = BoundingBox(around: Coordinate(lat: 40, lon: -105), radiusMeters: 40)
        let range = NAIPImageryClient.tileRange(for: box, zoom: 19)
        #expect(range.zoom == 19)
        let count = (range.maxX - range.minX + 1) * (range.maxY - range.minY + 1)
        #expect(count >= 4 && count <= 9)
    }

    @Test func tileRangeLowersZoomForLargeAreas() {
        let box = BoundingBox(around: Coordinate(lat: 40, lon: -105), radiusMeters: 400)
        let range = NAIPImageryClient.tileRange(for: box, zoom: 19)
        #expect(range.zoom < 19)
        #expect((range.maxX - range.minX + 1) * (range.maxY - range.minY + 1) <= NAIPImageryClient.maxTiles)
    }
}
