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

        // Each sub-course gets half of course_rating, not rounded, and the whole slope_rating
        let frontBlack = course.subCourses[0].tees["Black"]
        XCTAssertEqual(frontBlack?.male?.rating, 36.75)
        XCTAssertEqual(frontBlack?.male?.slope, 137)

        let backBlack = course.subCourses[1].tees["Black"]
        XCTAssertEqual(backBlack?.male?.rating, 36.75)
        XCTAssertEqual(backBlack?.male?.slope, 137)

        // Female tee ratings
        let frontRed = course.subCourses[0].tees["Red"]
        XCTAssertEqual(frontRed?.female?.rating, 34.55)
        XCTAssertEqual(frontRed?.female?.slope, 121)
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

    /// A result whose tees all have the same holes, rating, and slope. Each nine is given by its
    /// first yardage. Its holes get male handicaps that go up by two, as on a front or back nine,
    /// and female handicaps that go down by two.
    private func makeDetail(
        id: String,
        name: String,
        club: String = "Test Club",
        nines: [Int],
        rating: Double? = 72.0,
        slope: Int? = 130,
        tees: [String] = ["Blue"],
        femaleTees: [String] = []
    ) -> GolfCourseAPIClient.CourseDetail {
        func teeSets(_ names: [String], handicap: (Int) -> Int) -> [GolfCourseAPIClient.TeeSet] {
            var holes: [GolfCourseAPIClient.APIHole] = []
            for (nineIndex, firstYardage) in nines.enumerated() {
                for (holeIndex, par) in Self.ninePars.enumerated() {
                    holes.append(GolfCourseAPIClient.APIHole(par: par, yardage: firstYardage + holeIndex, handicap: handicap(holeIndex) * 2 + 1 + nineIndex))
                }
            }
            return names.map { name in
                GolfCourseAPIClient.TeeSet(
                    teeName: name,
                    courseRating: rating,
                    slopeRating: slope,
                    totalYards: holes.map(\.yardage).reduce(0, +),
                    parTotal: holes.map(\.par).reduce(0, +),
                    holes: holes
                )
            }
        }
        return GolfCourseAPIClient.CourseDetail(
            id: id,
            courseName: name,
            clubName: club,
            location: GolfCourseAPIClient.APILocation(address: "", city: "Denver", state: "CO", country: "US", zipCode: "", latitude: 39.7, longitude: -105.0),
            tees: GolfCourseAPIClient.TeeSets(male: teeSets(tees) { $0 }, female: teeSets(femaleTees) { 8 - $0 })
        )
    }

    // MARK: - Rating, slope, and handicaps

    func testEighteenHoleResultSplitsRatingAndKeepsSlopeAndHandicaps() throws {
        let course = try GolfCourseAPIClient.convertToCourse(details: [
            makeDetail(id: "a", name: "Broadlands Golf Course", nines: [300, 400], rating: 73.5, slope: 137, femaleTees: ["Red"])
        ])

        for subCourse in course.subCourses {
            XCTAssertEqual(subCourse.tees["Blue"]?.male?.rating, 36.75)
            XCTAssertEqual(subCourse.tees["Blue"]?.male?.slope, 137)
            XCTAssertNil(subCourse.tees["Blue"]?.female)
            XCTAssertEqual(subCourse.tees["Red"]?.female?.rating, 36.75)
            XCTAssertEqual(subCourse.tees["Red"]?.female?.slope, 137)
        }
        XCTAssertEqual(course.teeInformation(subCourseIndices: [0, 1], tee: "Blue", gender: .male)?.rating, 73.5)
        XCTAssertEqual(course.teeInformation(subCourseIndices: [0, 1], tee: "Blue", gender: .male)?.slope, 137)

        // Handicaps are stored as the scorecard prints them.
        XCTAssertEqual(course.subCourses[0].holes.map(\.maleHandicap), [1, 3, 5, 7, 9, 11, 13, 15, 17])
        XCTAssertEqual(course.subCourses[1].holes.map(\.maleHandicap), [2, 4, 6, 8, 10, 12, 14, 16, 18])
        XCTAssertEqual(course.subCourses[0].holes.map(\.femaleHandicap), [17, 15, 13, 11, 9, 7, 5, 3, 1])
        XCTAssertEqual(course.subCourses[1].holes.map(\.femaleHandicap), [18, 16, 14, 12, 10, 8, 6, 4, 2])
    }

    func testNineHoleResultKeepsItsRating() throws {
        let course = try GolfCourseAPIClient.convertToCourse(details: [
            makeDetail(id: "a", name: "Short Course", nines: [300], rating: 35.4, slope: 121)
        ])

        XCTAssertEqual(course.subCourses[0].tees["Blue"]?.male?.rating, 35.4)
        XCTAssertEqual(course.subCourses[0].tees["Blue"]?.male?.slope, 121)
    }

    /// Vista is 35.0 / 120, Canyon is 36.2 / 130, and Sunshine is 37.1 / 140. A pair's rating is
    /// the sum of its nines' ratings, and its slope is their average.
    private func threePairs(sunshineTees: [String] = ["Blue"]) -> [GolfCourseAPIClient.CourseDetail] {
        [
            makeDetail(id: "a", name: "Vista/Canyon", nines: [300, 400], rating: 71.2, slope: 125, femaleTees: ["Blue"]),
            makeDetail(id: "b", name: "Canyon/Sunshine", nines: [400, 500], rating: 73.3, slope: 135, tees: sunshineTees, femaleTees: ["Blue"]),
            makeDetail(id: "c", name: "Vista/Sunshine", nines: [300, 500], rating: 72.1, slope: 130, femaleTees: ["Blue"])
        ]
    }

    func testThreePairsGiveEachNineItsOwnRatingAndSlope() throws {
        let course = try GolfCourseAPIClient.convertToCourse(details: threePairs())

        XCTAssertEqual(course.subCourses.map(\.name), ["Vista", "Canyon", "Sunshine"])
        for gender in Gender.allCases {
            let information = course.subCourses.map { $0.tees["Blue"]?.information(for: gender) }
            XCTAssertEqual(information[0]?.rating ?? 0, 35.0, accuracy: 1e-9)
            XCTAssertEqual(information[1]?.rating ?? 0, 36.2, accuracy: 1e-9)
            XCTAssertEqual(information[2]?.rating ?? 0, 37.1, accuracy: 1e-9)
            XCTAssertEqual(information.map { $0?.slope }, [120, 130, 140])
            XCTAssertEqual(information.map { $0?.parTotal }, [36, 36, 36])
        }

        // A round over two nines gives back the pair's own values.
        let round = course.teeInformation(subCourseIndices: [1, 2], tee: "Blue", gender: .male)
        XCTAssertEqual(round?.rating, 73.3)
        XCTAssertEqual(round?.slope, 135)
    }

    func testThreePairsDoNotDependOnTheOrderOfTheResults() throws {
        let details = threePairs()
        let course = try GolfCourseAPIClient.convertToCourse(details: [details[2], details[1], details[0]])

        XCTAssertEqual(course.subCourses.map(\.name), ["Vista", "Sunshine", "Canyon"])
        XCTAssertEqual(course.subCourses.map { $0.tees["Blue"]?.male?.slope }, [120, 140, 130])
        XCTAssertEqual(course.subCourses[1].tees["Blue"]?.male?.rating ?? 0, 37.1, accuracy: 1e-9)
    }

    func testThreePairsRankEachNinesHandicaps() throws {
        let course = try GolfCourseAPIClient.convertToCourse(details: threePairs())

        for subCourse in course.subCourses {
            XCTAssertEqual(subCourse.holes.map(\.maleHandicap), [1, 2, 3, 4, 5, 6, 7, 8, 9], subCourse.name)
            XCTAssertEqual(subCourse.holes.map(\.femaleHandicap), [9, 8, 7, 6, 5, 4, 3, 2, 1], subCourse.name)
        }
    }

    func testThreePairsLeaveMissingHandicapsAlone() throws {
        let course = try GolfCourseAPIClient.convertToCourse(details: [
            makeDetail(id: "a", name: "Vista/Canyon", nines: [300, 400]),
            makeDetail(id: "b", name: "Canyon/Sunshine", nines: [400, 500]),
            makeDetail(id: "c", name: "Vista/Sunshine", nines: [300, 500])
        ])

        XCTAssertEqual(course.subCourses[0].holes.map(\.femaleHandicap), Array(repeating: 0, count: 9))
    }

    func testThreePairsSkipATeeThatIsNotInAllThreeResults() throws {
        let course = try GolfCourseAPIClient.convertToCourse(details: threePairs(sunshineTees: ["Blue", "Gold"]))

        // Gold is only in Canyon/Sunshine, and Canyon was taken from Vista/Canyon.
        XCTAssertNil(course.subCourses[1].tees["Gold"])
        let gold = try XCTUnwrap(course.subCourses[2].tees["Gold"]?.male)
        XCTAssertNil(gold.rating)
        XCTAssertNil(gold.slope)
        XCTAssertEqual(gold.parTotal, 36)
        XCTAssertEqual(course.subCourses[2].tees["Blue"]?.male?.slope, 140)
    }

    func testResultsThatAreNotThreePairsKeepTheirOwnValues() throws {
        let course = try GolfCourseAPIClient.convertToCourse(details: [
            makeDetail(id: "a", name: "North", nines: [300, 400], rating: 71.0, slope: 125),
            makeDetail(id: "b", name: "South", nines: [500, 600], rating: 73.0, slope: 135)
        ])

        XCTAssertEqual(course.subCourses.map { $0.tees["Blue"]?.male?.rating }, [35.5, 35.5, 36.5, 36.5])
        XCTAssertEqual(course.subCourses.map { $0.tees["Blue"]?.male?.slope }, [125, 125, 135, 135])
        XCTAssertEqual(course.subCourses[2].holes.map(\.maleHandicap), [1, 3, 5, 7, 9, 11, 13, 15, 17])
    }

    // MARK: - Combining results (continued)

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
