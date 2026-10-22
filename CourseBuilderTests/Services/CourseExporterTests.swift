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
                coordinate: Coordinate(lat: 39, lon: -105)
            ),
            tees: [TeeDefinition(name: "Blue", color: "#0000FF"), TeeDefinition(name: "White", color: "#FFFFFF")],
            comboTees: [ComboTeeDefinition(name: "Blue/White", tees: ["Blue", "White"])],
            features: [Feature(id: 1, type: .tee, polygon: [Coordinate(lat: 39, lon: -105, ele: 1600)])],
            subCourses: [SubCourse(
                name: "Front",
                holes: [Hole(
                    number: 1,
                    par: 4,
                    yardages: ["Blue": 400, "White": 380],
                    features: [1],
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
        // Tee boxes are not tied to tee names.
        #expect(hole["tees"] == nil)
    }

    // MARK: - CourseData layout

    private func course(name: String, city: String, state: String, country: String) -> Course {
        Course(
            name: name,
            location: CourseLocation(address: "", city: city, state: state, country: country, coordinate: Coordinate(lat: 39, lon: -105))
        )
    }

    @Test func pathFollowsCourseDataLayout() throws {
        #expect(try CourseExporter.relativePath(for: course(name: "Colorado Golf Club", city: "Parker", state: "CO", country: "United States"))
                == "US/CO/Parker/Colorado-Golf-Club.json.gz")
        #expect(try CourseExporter.relativePath(for: course(name: "The Broadlands Golf Course", city: "broomfield", state: "Colorado", country: "US"))
                == "US/CO/Broomfield/Broadlands-Golf-Course.json.gz")
        #expect(try CourseExporter.relativePath(for: course(name: "Cherry Hills Country Club", city: "Cherry Hills Village", state: "CO", country: "USA"))
                == "US/CO/Cherry Hills Village/Cherry-Hills-Country-Club.json.gz")
    }

    @Test func courseNameRules() {
        #expect(CourseExporter.fileName(for: "Bear's Dance Golf Club") == "Bears-Dance-Golf-Club")
        #expect(CourseExporter.fileName(for: "McDonald Park & Links") == "McDonald-Park-Links")
        #expect(CourseExporter.fileName(for: "The Links") == "Links")
        #expect(CourseExporter.fileName(for: "The") == "The")
    }

    @Test func countryCodes() {
        #expect(CourseExporter.countryCode("United States") == "US")
        #expect(CourseExporter.countryCode("ca") == "CA")
        #expect(CourseExporter.countryCode("Canada") == "CA")
        #expect(CourseExporter.countryCode("") == nil)
    }

    @Test func missingLocationIsAnError() {
        #expect(throws: CourseExporter.ExportError.missingLocation("city")) {
            try CourseExporter.relativePath(for: course(name: "Test", city: " ", state: "CO", country: "US"))
        }
    }

    @Test func writeCreatesFoldersUnderData() throws {
        let repository = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: repository) }
        let course = course(name: "Colorado Golf Club", city: "Parker", state: "CO", country: "United States")

        let saved = try CourseExporter.write(course, toCourseData: repository)

        #expect(saved.url.path == repository.appendingPathComponent("Data/US/CO/Parker/Colorado-Golf-Club.json.gz").path)
        let decoded = try JSONDecoder().decode(Course.self, from: Data(contentsOf: saved.url).gzipDecompressed())
        #expect(decoded == course)

        // Choosing the Data folder itself saves to the same place.
        let again = try CourseExporter.write(course, toCourseData: repository.appendingPathComponent("Data"))
        #expect(again.url.path == saved.url.path)
    }
}
