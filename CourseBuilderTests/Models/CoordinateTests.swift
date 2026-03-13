import XCTest
import CoreLocation
@testable import CourseBuilder

final class CoordinateTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let coord = Coordinate(latitude: 39.9397, longitude: -105.0267)
        let data = try JSONEncoder().encode(coord)
        let decoded = try JSONDecoder().decode(Coordinate.self, from: data)
        XCTAssertEqual(coord, decoded)
    }

    func testCLLocationCoordinate2D() {
        let coord = Coordinate(latitude: 39.9397, longitude: -105.0267)
        let cl = coord.clCoordinate
        XCTAssertEqual(cl.latitude, 39.9397)
        XCTAssertEqual(cl.longitude, -105.0267)
    }

    func testCLLocation() {
        let coord = Coordinate(latitude: 39.9397, longitude: -105.0267)
        let loc = coord.clLocation
        XCTAssertEqual(loc.coordinate.latitude, 39.9397)
        XCTAssertEqual(loc.coordinate.longitude, -105.0267)
    }

    func testInitFromCLLocationCoordinate2D() {
        let cl = CLLocationCoordinate2D(latitude: 39.9397, longitude: -105.0267)
        let coord = Coordinate(cl)
        XCTAssertEqual(coord.latitude, 39.9397)
        XCTAssertEqual(coord.longitude, -105.0267)
    }

    func testCompactJSONEncoding() throws {
        let coord = Coordinate(latitude: 39.7879, longitude: -74.9580)
        let data = try JSONEncoder().encode(coord)
        let json = String(data: data, encoding: .utf8)!
        // Should be a JSON array [lat, lon], not an object
        let array = try JSONDecoder().decode([Double].self, from: data)
        XCTAssertEqual(array.count, 2)
        XCTAssertEqual(array[0], 39.7879, accuracy: 0.0001)
        XCTAssertEqual(array[1], -74.958, accuracy: 0.0001)
    }

    func testCompactJSONDecoding() throws {
        let json = "[39.7879, -74.958]"
        let data = json.data(using: .utf8)!
        let coord = try JSONDecoder().decode(Coordinate.self, from: data)
        XCTAssertEqual(coord.latitude, 39.7879, accuracy: 0.0001)
        XCTAssertEqual(coord.longitude, -74.958, accuracy: 0.0001)
    }
}
