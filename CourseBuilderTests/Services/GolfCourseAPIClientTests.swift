import XCTest
@testable import CourseBuilder
import CourseDataSwift

/// The GolfCourseAPI.com key saved in the app's Settings. The tests run inside the app, so they
/// share its settings. Live tests are skipped when no key is saved.
private func loadAPIKey() throws -> String {
    guard let key = UserDefaults.standard.string(forKey: "golfCourseAPIKey"), !key.isEmpty else {
        throw XCTSkip("No GolfCourseAPI.com key is saved in the app's Settings")
    }
    return key
}

final class GolfCourseAPIClientTests: XCTestCase {
    func testParseCourseSearchResponse() throws {
        let json = """
        {
            "courses": [
                {
                    "id": "3cvjz0r9",
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
        XCTAssertEqual(response.courses[0].id, "3cvjz0r9")
        XCTAssertEqual(response.courses[0].courseName, "Broadlands Golf Course")
        XCTAssertEqual(response.courses[0].location.city, "Broomfield")
    }

    /// The live API omits `city` (and sometimes `state`) for some courses. One such result must
    /// not make the whole search response fail to decode.
    func testParseCourseSearchResponseWithMissingCity() throws {
        let json = """
        {
            "courses": [
                {
                    "id": "d0rc26ak",
                    "club_name": "Greensmere G & Cc",
                    "course_name": "Legacy",
                    "location": {
                        "state": "Unknown",
                        "country": "Unknown"
                    }
                },
                {
                    "id": "5h5cq4b5",
                    "club_name": "Legacy Ridge Golf Club",
                    "course_name": "Legacy Ridge Golf Club",
                    "location": {
                        "city": "Westminster",
                        "state": "CO",
                        "country": "US"
                    },
                    "holes": 18
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(GolfCourseAPIClient.SearchResponse.self, from: json)
        XCTAssertEqual(response.courses.count, 2)
        XCTAssertNil(response.courses[0].location.city)
        XCTAssertEqual(response.courses[0].location.state, "Unknown")
        XCTAssertEqual(response.courses[1].location.city, "Westminster")
    }

    func testParseCourseDetailResponse() throws {
        let json = """
        {
            "id": "3cvjz0r9",
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
        let course = try GolfCourseAPIClient.convertToCourse(detail: detail)

        XCTAssertEqual(course.name, "Broadlands Golf Course")
        XCTAssertEqual(course.clubName, "The Broadlands Golf Club")
        XCTAssertEqual(course.golfCourseAPIIds, ["3cvjz0r9"])
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
            print("  [\(course.id)] \(course.courseName) - \(course.clubName) (\(course.location.city ?? ""), \(course.location.state ?? ""))")
        }
    }

    func testLiveFetchCourse() async throws {
        let apiKey = try loadAPIKey()
        let client = GolfCourseAPIClient(apiKey: apiKey)

        let response = try await client.search(query: "Broadlands")
        let firstResult = try XCTUnwrap(response.courses.first)

        let detail = try await client.fetchCourse(id: firstResult.id)
        let course = try GolfCourseAPIClient.convertToCourse(detail: detail)

        XCTAssertFalse(course.name.isEmpty)
        XCTAssertFalse(course.subCourses.isEmpty, "Expected sub-courses")
        XCTAssertFalse(course.tees.isEmpty, "Expected tees")

        print("Converted: \(course.name), \(course.subCourses.count) sub-courses, \(course.tees.count) tees")
        for sub in course.subCourses {
            print("  \(sub.name): \(sub.holes.count) holes")
        }
    }

    func testExtractSubCourseNamesWithSlash() throws {
        let json = """
        {
            "id": "7k2m9qb4",
            "course_name": "Vista/Canyon",
            "club_name": "Test Club",
            "location": { "address": "", "city": "Denver", "state": "CO", "country": "US", "zip_code": "" },
            "tees": {
                "male": [{
                    "tee_name": "Blue",
                    "course_rating": 72.0, "slope_rating": 130,
                    "front_course_rating": 36.0, "front_slope_rating": 128,
                    "back_course_rating": 36.0, "back_slope_rating": 132,
                    "total_yards": 6800, "par_total": 72,
                    "holes": [
                        { "par": 4, "yardage": 400, "handicap": 1 },
                        { "par": 4, "yardage": 410, "handicap": 2 },
                        { "par": 4, "yardage": 420, "handicap": 3 },
                        { "par": 4, "yardage": 430, "handicap": 4 }
                    ]
                }],
                "female": []
            }
        }
        """.data(using: .utf8)!

        let detail = try JSONDecoder().decode(GolfCourseAPIClient.CourseDetail.self, from: json)
        let course = try GolfCourseAPIClient.convertToCourse(detail: detail)

        XCTAssertEqual(course.subCourses.count, 2)
        XCTAssertEqual(course.subCourses[0].name, "Vista")
        XCTAssertEqual(course.subCourses[1].name, "Canyon")
    }

    func testConvertToCourseMultipleDetails() throws {
        let makeDetail: (String, String) -> GolfCourseAPIClient.CourseDetail = { id, name in
            let json = """
            {
                "id": "\(id)",
                "course_name": "\(name)",
                "club_name": "Test Club",
                "location": { "address": "", "city": "Denver", "state": "CO", "country": "US", "zip_code": "" },
                "tees": {
                    "male": [{
                        "tee_name": "Blue",
                        "course_rating": 36.0, "slope_rating": 130,
                        "front_course_rating": 36.0, "front_slope_rating": 128,
                        "back_course_rating": 36.0, "back_slope_rating": 132,
                        "total_yards": 3400, "par_total": 36,
                        "holes": [
                            { "par": 4, "yardage": 400, "handicap": 1 },
                            { "par": 3, "yardage": 180, "handicap": 9 }
                        ]
                    }],
                    "female": []
                }
            }
            """.data(using: .utf8)!
            return try! JSONDecoder().decode(GolfCourseAPIClient.CourseDetail.self, from: json)
        }

        let details = [makeDetail("7k2m9qb1", "Front Nine"), makeDetail("7k2m9qb2", "Back Nine")]
        let course = try GolfCourseAPIClient.convertToCourse(details: details)

        XCTAssertEqual(course.golfCourseAPIIds, ["7k2m9qb1", "7k2m9qb2"])
        XCTAssertFalse(course.subCourses.isEmpty)
    }

    func testConvertToCourseSortsTeesByDescendingTotalYardage() throws {
        // Create a course with three male tees where the shortest tee appears first
        let json = """
        {
            "id": "7k2m9qb9",
            "course_name": "Sort Test Course",
            "club_name": "Sort Test Club",
            "location": { "address": "", "city": "Denver", "state": "CO", "country": "US", "zip_code": "" },
            "tees": {
                "male": [
                    {
                        "tee_name": "Red",
                        "course_rating": 65.0, "slope_rating": 110,
                        "front_course_rating": 32.0, "front_slope_rating": 108,
                        "back_course_rating": 33.0, "back_slope_rating": 112,
                        "total_yards": 5000, "par_total": 72,
                        "holes": [
                            { "par": 4, "yardage": 300, "handicap": 1 },
                            { "par": 4, "yardage": 310, "handicap": 2 },
                            { "par": 4, "yardage": 280, "handicap": 3 },
                            { "par": 4, "yardage": 290, "handicap": 4 }
                        ]
                    },
                    {
                        "tee_name": "Blue",
                        "course_rating": 72.0, "slope_rating": 130,
                        "front_course_rating": 36.0, "front_slope_rating": 128,
                        "back_course_rating": 36.0, "back_slope_rating": 132,
                        "total_yards": 6800, "par_total": 72,
                        "holes": [
                            { "par": 4, "yardage": 420, "handicap": 1 },
                            { "par": 4, "yardage": 430, "handicap": 2 },
                            { "par": 4, "yardage": 400, "handicap": 3 },
                            { "par": 4, "yardage": 410, "handicap": 4 }
                        ]
                    },
                    {
                        "tee_name": "White",
                        "course_rating": 69.0, "slope_rating": 120,
                        "front_course_rating": 34.0, "front_slope_rating": 118,
                        "back_course_rating": 35.0, "back_slope_rating": 122,
                        "total_yards": 6200, "par_total": 72,
                        "holes": [
                            { "par": 4, "yardage": 370, "handicap": 1 },
                            { "par": 4, "yardage": 380, "handicap": 2 },
                            { "par": 4, "yardage": 350, "handicap": 3 },
                            { "par": 4, "yardage": 360, "handicap": 4 }
                        ]
                    }
                ],
                "female": []
            }
        }
        """.data(using: .utf8)!

        let detail = try JSONDecoder().decode(GolfCourseAPIClient.CourseDetail.self, from: json)
        let course = try GolfCourseAPIClient.convertToCourse(detail: detail)

        XCTAssertEqual(course.tees.count, 3)
        // Should be sorted by descending total yardage: Blue (1660), White (1460), Red (1180)
        XCTAssertEqual(course.tees[0].name, "Blue")
        XCTAssertEqual(course.tees[1].name, "White")
        XCTAssertEqual(course.tees[2].name, "Red")
    }

    func testSearchResultWithoutCoordinateIsNotUsable() throws {
        let json = """
        {
            "courses": [
                { "id": "a", "club_name": "A", "course_name": "A", "location": { "city": "Denver", "latitude": 39.7, "longitude": -105.0 } },
                { "id": "b", "club_name": "B", "course_name": "B", "location": { "city": "Denver" } },
                { "id": "c", "club_name": "C", "course_name": "C", "location": { "city": "Denver", "latitude": 39.7 } },
                { "id": "d", "club_name": "D", "course_name": "D", "location": { "city": "Denver", "latitude": 0, "longitude": 0 } }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(GolfCourseAPIClient.SearchResponse.self, from: json)

        XCTAssertEqual(response.courses.filter(\.hasCoordinate).map(\.id), ["a"])
    }

    // MARK: - Combining results

    /// The pars of a nine. Yardages are `firstYardage`, `firstYardage + 1`, and so on.
    private static let ninePars = [4, 4, 3, 5, 4, 4, 3, 5, 4]

    /// A result with one "Blue" tee. Each nine is given by its first yardage, and its holes get
    /// handicaps starting at `firstHandicap` and going up by two, as on a front or back nine.
    private func makeDetail(id: String, name: String, club: String = "Test Club", nines: [Int]) -> GolfCourseAPIClient.CourseDetail {
        var holes: [GolfCourseAPIClient.APIHole] = []
        for (nineIndex, firstYardage) in nines.enumerated() {
            for (holeIndex, par) in Self.ninePars.enumerated() {
                holes.append(GolfCourseAPIClient.APIHole(par: par, yardage: firstYardage + holeIndex, handicap: holeIndex * 2 + 1 + nineIndex))
            }
        }
        let tee = GolfCourseAPIClient.TeeSet(
            teeName: "Blue",
            courseRating: 72.0,
            slopeRating: 130,
            totalYards: holes.map(\.yardage).reduce(0, +),
            parTotal: holes.map(\.par).reduce(0, +),
            frontCourseRating: 36.0,
            frontSlopeRating: 128,
            backCourseRating: 36.0,
            backSlopeRating: 132,
            holes: holes
        )
        return GolfCourseAPIClient.CourseDetail(
            id: id,
            courseName: name,
            clubName: club,
            location: GolfCourseAPIClient.APILocation(address: "", city: "Denver", state: "CO", country: "US", zipCode: "", latitude: 39.7, longitude: -105.0),
            tees: GolfCourseAPIClient.TeeSets(male: [tee], female: [])
        )
    }

    func testCombinesThreeNineHoleResults() throws {
        let course = try GolfCourseAPIClient.convertToCourse(details: [
            makeDetail(id: "a", name: "Eldorado", nines: [300]),
            makeDetail(id: "b", name: "Vista", nines: [400]),
            makeDetail(id: "c", name: "Sunshine", nines: [500])
        ])

        XCTAssertEqual(course.name, "Test Club")
        XCTAssertEqual(course.golfCourseAPIIds, ["a", "b", "c"])
        XCTAssertEqual(course.subCourses.map(\.name), ["Eldorado", "Vista", "Sunshine"])
        XCTAssertEqual(course.subCourses.map(\.holes.count), [9, 9, 9])
        XCTAssertEqual(course.subCourses[1].holes[0].yardages["Blue"], 400)
    }

    func testCombinesPairedResultsThatShareNines() throws {
        // Canyon is a back nine in the first result and a front nine in the second, so its
        // handicaps differ between them.
        let course = try GolfCourseAPIClient.convertToCourse(details: [
            makeDetail(id: "a", name: "Vista/Canyon", nines: [300, 400]),
            makeDetail(id: "b", name: "Canyon/Sunshine", nines: [400, 500]),
            makeDetail(id: "c", name: "Vista/Sunshine", nines: [300, 500])
        ])

        XCTAssertEqual(course.name, "Test Club")
        XCTAssertEqual(course.subCourses.map(\.name), ["Vista", "Canyon", "Sunshine"])
        XCTAssertEqual(course.subCourses.map(\.holes.count), [9, 9, 9])
        XCTAssertEqual(course.subCourses.map { $0.holes[0].yardages["Blue"] }, [300, 400, 500])
    }

    func testSingleEighteenHoleResultIsFrontAndBack() throws {
        let course = try GolfCourseAPIClient.convertToCourse(details: [
            makeDetail(id: "a", name: "Broadlands Golf Course", nines: [300, 400])
        ])

        XCTAssertEqual(course.name, "Broadlands Golf Course")
        XCTAssertEqual(course.subCourses.map(\.name), ["Front", "Back"])
        XCTAssertEqual(course.subCourses.map(\.holes.count), [9, 9])
    }

    func testSingleNineHoleResultIsOneSubCourse() throws {
        let course = try GolfCourseAPIClient.convertToCourse(details: [
            makeDetail(id: "a", name: "Short Course", nines: [300])
        ])

        XCTAssertEqual(course.name, "Short Course")
        XCTAssertEqual(course.subCourses.map(\.name), ["Front"])
        XCTAssertEqual(course.subCourses[0].holes.count, 9)
    }

    func testCombinedEighteenHoleResultsAreNamedAfterTheResult() throws {
        let course = try GolfCourseAPIClient.convertToCourse(details: [
            makeDetail(id: "a", name: "North", nines: [300, 400]),
            makeDetail(id: "b", name: "South", nines: [500, 600])
        ])

        XCTAssertEqual(course.subCourses.map(\.name), ["North Front", "North Back", "South Front", "South Back"])
    }

    func testDifferentNinesWithTheSameNameAreBothKept() throws {
        let course = try GolfCourseAPIClient.convertToCourse(details: [
            makeDetail(id: "a", name: "Nine", nines: [300]),
            makeDetail(id: "b", name: "Nine", nines: [400])
        ])

        XCTAssertEqual(course.subCourses.map(\.name), ["Nine", "Nine 2"])
    }

    func testSameResultSelectedTwiceIsNotRepeated() throws {
        let course = try GolfCourseAPIClient.convertToCourse(details: [
            makeDetail(id: "a", name: "Eldorado", nines: [300]),
            makeDetail(id: "b", name: "Eldorado Nine", nines: [300])
        ])

        XCTAssertEqual(course.subCourses.map(\.name), ["Eldorado"])
    }

    func testConvertToCourseEmptyDetailsThrows() {
        XCTAssertThrowsError(try GolfCourseAPIClient.convertToCourse(details: [])) { error in
            XCTAssertTrue(error is GolfCourseAPIClient.APIError)
        }
    }
}
