import XCTest
@testable import CourseBuilder

private func loadAPIKey() throws -> String {
    // #filePath gives us the real filesystem path, bypassing sandbox remapping
    let filePath = #filePath
    let components = filePath.split(separator: "/")
    guard components.count >= 2 else {
        throw NSError(domain: "TestConfig", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot determine home directory from \(filePath)"])
    }
    let home = "/\(components[0])/\(components[1])"
    let path = "\(home)/.config/CourseBuilder/test/keys.plist"
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
                        "front_course_rating": 37.6,
                        "front_slope_rating": 134,
                        "back_course_rating": 35.9,
                        "back_slope_rating": 140,
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
                        "front_course_rating": 34.2,
                        "front_slope_rating": 118,
                        "back_course_rating": 34.9,
                        "back_slope_rating": 124,
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
        XCTAssertEqual(course.golfCourseAPIIds, [12345])
        XCTAssertEqual(course.location.city, "Broomfield")
        XCTAssertEqual(course.tees.count, 2)

        // Should have Front and Back sub-courses
        XCTAssertEqual(course.subCourses.count, 2)
        XCTAssertEqual(course.subCourses[0].name, "Front")
        XCTAssertEqual(course.subCourses[1].name, "Back")

        // Front sub-course gets hole 1 (renumbered to 1)
        XCTAssertEqual(course.subCourses[0].holes.count, 1)
        XCTAssertEqual(course.subCourses[0].holes[0].par, 4)
        XCTAssertEqual(course.subCourses[0].holes[0].yardages["Black"], 401)
        XCTAssertEqual(course.subCourses[0].holes[0].yardages["Red"], 298)

        // Back sub-course gets hole 2 (renumbered to 1)
        XCTAssertEqual(course.subCourses[1].holes.count, 1)
        XCTAssertEqual(course.subCourses[1].holes[0].number, 1)
        XCTAssertEqual(course.subCourses[1].holes[0].par, 5)

        // Front sub-course tee ratings from front_course_rating
        let frontBlack = course.subCourses[0].tees["Black"]
        XCTAssertEqual(frontBlack?.male?.rating, 37.6)
        XCTAssertEqual(frontBlack?.male?.slope, 134)

        // Back sub-course tee ratings from back_course_rating
        let backBlack = course.subCourses[1].tees["Black"]
        XCTAssertEqual(backBlack?.male?.rating, 35.9)
        XCTAssertEqual(backBlack?.male?.slope, 140)

        // Female tee ratings
        let frontRed = course.subCourses[0].tees["Red"]
        XCTAssertEqual(frontRed?.female?.rating, 34.2)
        XCTAssertEqual(frontRed?.female?.slope, 118)
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

        let response = try await client.search(query: "Broadlands")
        let firstResult = try XCTUnwrap(response.courses.first)

        let detail = try await client.fetchCourse(id: firstResult.id)
        let course = GolfCourseAPIClient.convertToCourse(detail: detail)

        XCTAssertFalse(course.name.isEmpty)
        XCTAssertFalse(course.subCourses.isEmpty, "Expected sub-courses")
        XCTAssertFalse(course.tees.isEmpty, "Expected tees")

        print("Converted: \(course.name), \(course.subCourses.count) sub-courses, \(course.tees.count) tees")
        for sub in course.subCourses {
            print("  \(sub.name): \(sub.holes.count) holes")
        }
    }
}
