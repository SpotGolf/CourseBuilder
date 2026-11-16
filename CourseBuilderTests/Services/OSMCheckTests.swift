import Foundation
import Testing
@testable import CourseBuilder
import CourseDataSwift

@Suite("OSM check")
struct OSMCheckTests {
    @Test func resultHasCourseData() {
        let feature = OverpassAPIClient.ParsedFeature(type: .green, polygon: [Coordinate(lat: 40, lon: -105)])
        let centerline = OverpassAPIClient.ParsedCenterline(holeNumber: 1, coordinates: [])

        #expect(!OSMCheck.hasCourseData(.init(features: [], centerlines: [], courseBoundary: nil)))
        #expect(!OSMCheck.hasCourseData(.init(features: [], centerlines: [], courseBoundary: [Coordinate(lat: 40, lon: -105)])))
        #expect(OSMCheck.hasCourseData(.init(features: [feature], centerlines: [], courseBoundary: nil)))
        #expect(OSMCheck.hasCourseData(.init(features: [], centerlines: [centerline], courseBoundary: nil)))
    }
}
