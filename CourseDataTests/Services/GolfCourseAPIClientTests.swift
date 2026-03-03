import XCTest
@testable import CourseData

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
                            { "hole_number": 1, "par": 4, "yardage": 401, "handicap": 13 },
                            { "hole_number": 2, "par": 5, "yardage": 545, "handicap": 3 }
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
                            { "hole_number": 1, "par": 4, "yardage": 298, "handicap": 13 },
                            { "hole_number": 2, "par": 5, "yardage": 430, "handicap": 3 }
                        ]
                    }
                ]
            }
        }
        """.data(using: .utf8)!

        let detail = try JSONDecoder().decode(GolfCourseAPIClient.CourseDetail.self, from: json)
        let course = GolfCourseAPIClient.convertToCourse(detail: detail)

        XCTAssertEqual(course.name, "Broadlands Golf Course")
        XCTAssertEqual(course.location.city, "Broomfield")
        XCTAssertEqual(course.location.state, "CO")
        XCTAssertEqual(course.tees.count, 2)
        XCTAssertEqual(course.tees[0].name, "Black")
        XCTAssertEqual(course.tees[0].gender, .male)
        XCTAssertEqual(course.tees[0].rating, 73.5)
        XCTAssertEqual(course.tees[0].slope, 137)
        XCTAssertEqual(course.holes.count, 2)
        XCTAssertEqual(course.holes[0].par, 4)
        XCTAssertEqual(course.holes[0].yardages["Black"], 401)
        XCTAssertEqual(course.holes[0].yardages["Red"], 298)
        XCTAssertEqual(course.holes[1].handicap, 3)
    }
}
