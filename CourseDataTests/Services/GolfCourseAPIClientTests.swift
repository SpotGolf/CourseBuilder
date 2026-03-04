import XCTest
@testable import CourseData

private func loadAPIKey() throws -> String {
    // #filePath gives us the real filesystem path, bypassing sandbox remapping
    let filePath = #filePath
    let components = filePath.split(separator: "/")
    guard components.count >= 2 else {
        throw NSError(domain: "TestConfig", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot determine home directory from \(filePath)"])
    }
    let home = "/\(components[0])/\(components[1])"
    let path = "\(home)/.config/CourseData/test/keys.plist"
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    guard let key = plist?["golfCourseAPIKey"] as? String else {
        throw NSError(domain: "TestConfig", code: 1, userInfo: [NSLocalizedDescriptionKey: "golfCourseAPIKey not found in keys.plist"])
    }
    return key
}

final class GolfCourseAPIClientTests: XCTestCase {
    func testParseCourseSearchResponse() throws {
        let json = """
        {
            "courses": [
                {
                    "id": 12345,
                    "club_name": "The Broadlands Golf Club",
                    "course_name": "Broadlands Golf Course",
                    "location": {
                        "address": "4380 W 144th Ave",
                        "city": "Broomfield",
                        "state": "CO",
                        "country": "US",
                        "zip_code": "80023"
                    },
                    "holes": 18
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(GolfCourseAPIClient.SearchResponse.self, from: json)
        XCTAssertEqual(response.courses.count, 1)
        XCTAssertEqual(response.courses[0].courseName, "Broadlands Golf Course")
        XCTAssertEqual(response.courses[0].location.city, "Broomfield")
    }

    func testParseCourseDetailResponse() throws {
        let json = """
        {
            "id": 12345,
            "course_name": "Broadlands Golf Course",
            "club_name": "The Broadlands Golf Club",
            "location": {
                "address": "4380 W 144th Ave",
                "city": "Broomfield",
                "state": "CO",
                "country": "US",
                "zip_code": "80023"
            },
            "tees": {
                "male": [
                    {
                        "tee_name": "Black",
                        "course_rating": 73.5,
                        "slope_rating": 137,
                        "total_yards": 7289,
                        "par_total": 72,
                        "holes": [
                            { "par": 4, "yardage": 401, "handicap": 13 },
                            { "par": 5, "yardage": 545, "handicap": 3 }
                        ]
                    }
                ],
                "female": [
                    {
                        "tee_name": "Red",
                        "course_rating": 69.1,
                        "slope_rating": 121,
                        "total_yards": 5200,
                        "par_total": 72,
                        "holes": [
                            { "par": 4, "yardage": 298, "handicap": 13 },
                            { "par": 5, "yardage": 430, "handicap": 3 }
                        ]
                    }
                ]
            }
        }
        """.data(using: .utf8)!

        let detail = try JSONDecoder().decode(GolfCourseAPIClient.CourseDetail.self, from: json)
        let course = GolfCourseAPIClient.convertToCourse(detail: detail)

        XCTAssertEqual(course.name, "Broadlands Golf Course")
        XCTAssertEqual(course.clubName, "The Broadlands Golf Club")
        XCTAssertEqual(course.golfCourseAPIId, 12345)
        XCTAssertEqual(course.location.city, "Broomfield")
        XCTAssertEqual(course.location.state, "CO")
        XCTAssertEqual(course.location.address, "4380 W 144th Ave")
        XCTAssertEqual(course.location.country, "US")
        XCTAssertEqual(course.tees.count, 2)
        let blackTee = course.tees.first { $0.name == "Black" }
        let redTee = course.tees.first { $0.name == "Red" }
        XCTAssertNotNil(blackTee)
        XCTAssertEqual(blackTee?.male?.courseRating, 73.5)
        XCTAssertEqual(blackTee?.male?.slopeRating, 137)
        XCTAssertEqual(blackTee?.male?.totalYards, 7289)
        XCTAssertEqual(blackTee?.male?.parTotal, 72)
        XCTAssertNotNil(redTee)
        XCTAssertEqual(redTee?.female?.courseRating, 69.1)
        XCTAssertEqual(redTee?.female?.slopeRating, 121)
        XCTAssertEqual(redTee?.female?.totalYards, 5200)
        XCTAssertEqual(redTee?.female?.parTotal, 72)
        XCTAssertEqual(course.holes.count, 2)
        XCTAssertEqual(course.holes[0].par, 4)
        XCTAssertEqual(course.holes[0].yardages["Black"], 401)
        XCTAssertEqual(course.holes[0].yardages["Red"], 298)
        XCTAssertEqual(course.holes[1].maleHandicap, 3)
    }

    func testLiveSearchAPI() async throws {
        let apiKey = try loadAPIKey()
        let client = GolfCourseAPIClient(apiKey: apiKey)
        let response = try await client.search(query: "Broadlands")
        XCTAssertFalse(response.courses.isEmpty, "Expected at least one search result")
        print("Search returned \(response.courses.count) results:")
        for course in response.courses {
            print("  [\(course.id)] \(course.courseName) - \(course.clubName) (\(course.location.city), \(course.location.state))")
        }
    }

    func testLiveFetchCourse() async throws {
        let apiKey = try loadAPIKey()
        let client = GolfCourseAPIClient(apiKey: apiKey)

        // Search first to get a valid course ID
        let response = try await client.search(query: "Broadlands")
        let firstResult = try XCTUnwrap(response.courses.first, "Expected at least one search result")

        // Fetch the full course detail
        let detail = try await client.fetchCourse(id: firstResult.id)
        print("Fetched course: \(detail.courseName) (\(detail.clubName))")
        print("Location: \(detail.location.city), \(detail.location.state)")
        print("Male tees: \(detail.tees.male?.count ?? 0), Female tees: \(detail.tees.female?.count ?? 0)")

        let course = GolfCourseAPIClient.convertToCourse(detail: detail)
        XCTAssertFalse(course.name.isEmpty)
        XCTAssertFalse(course.holes.isEmpty, "Expected holes in course detail")
        XCTAssertFalse(course.tees.isEmpty, "Expected tees in course detail")

        print("Converted course: \(course.name), \(course.holes.count) holes, \(course.tees.count) tees")
        for tee in course.tees {
            print("  Tee: \(tee.name)")
        }
    }
}
