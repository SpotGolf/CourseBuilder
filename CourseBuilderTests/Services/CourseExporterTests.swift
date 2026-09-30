import Foundation
import Testing
@testable import CourseBuilder
import CourseDataSwift

struct CourseExporterTests {
    @Test func exportKeepsComboTees() throws {
        let course = Course(
            name: "Test Course",
            location: CourseLocation(
                address: "",
                city: "Denver",
                state: "CO",
                country: "US",
                coordinate: Coordinate(latitude: 39, longitude: -105)
            ),
            tees: [TeeDefinition(name: "Blue", color: "#0000FF"), TeeDefinition(name: "White", color: "#FFFFFF")],
            comboTees: [ComboTeeDefinition(name: "Blue/White", tees: ["Blue", "White"])],
            features: [Feature(id: 1, type: .tee, polygon: [Coordinate(latitude: 39, longitude: -105, elevation: 1600)])],
            subCourses: [SubCourse(
                name: "Front",
                holes: [Hole(
                    number: 1,
                    par: 4,
                    yardages: ["Blue": 400, "White": 380],
                    features: [1],
                    tees: ["Blue": 1, "White": 1],
                    comboTees: ["Blue/White": "White"]
                )],
                comboTees: ["Blue/White": SubCourseTee(male: TeeInformation(rating: 35, slope: 125))]
            )]
        )

        let (json, gzip) = try CourseExporter.export(course)

        #expect(try gzip.gzipDecompressed() == json)
        let decoded = try JSONDecoder().decode(Course.self, from: gzip.gzipDecompressed())
        #expect(decoded == course)

        let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let comboTees = try #require(object["comboTees"] as? [[String: Any]])
        #expect(comboTees.first?["name"] as? String == "Blue/White")
        #expect(comboTees.first?["tees"] as? [String] == ["Blue", "White"])
        let subCourse = try #require((object["subCourses"] as? [[String: Any]])?.first)
        #expect((subCourse["comboTees"] as? [String: Any])?["Blue/White"] != nil)
        let hole = try #require((subCourse["holes"] as? [[String: Any]])?.first)
        #expect(hole["comboTees"] as? [String: String] == ["Blue/White": "White"])
    }
}
