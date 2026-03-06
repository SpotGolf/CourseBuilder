import AppKit
import Foundation

@MainActor
class ScorecardImporter: ObservableObject {
    enum ImportSource {
        case api
        case scraped(URL)
        case ocr(NSImage)
        case manual
    }

    enum ImportError: LocalizedError {
        case apiKeyMissing
        case courseNotFound
        case allSourcesFailed(String)

        var errorDescription: String? {
            switch self {
            case .apiKeyMissing: return "Golf Course API key not configured"
            case .courseNotFound: return "Course not found in any data source"
            case .allSourcesFailed(let detail): return "All import sources failed: \(detail)"
            }
        }
    }

    @Published var status: String = ""
    @Published var isLoading = false

    private let apiClient: GolfCourseAPIClient?

    init(apiKey: String?) {
        self.apiClient = apiKey.map { GolfCourseAPIClient(apiKey: $0) }
    }

    /// Try API first, then scraping, return partial Course (no GPS coords yet)
    func importScorecard(courseName: String, city: String, state: String) async throws -> Course {
        isLoading = true
        defer { isLoading = false }

        // Try API
        if let apiClient {
            do {
                status = "Searching GolfCourseAPI.com..."
                let response = try await apiClient.search(query: courseName)
                if let match = response.courses.first {
                    status = "Fetching scorecard data..."
                    let detail = try await apiClient.fetchCourse(id: match.id)
                    let course = try GolfCourseAPIClient.convertToCourse(detail: detail)
                    status = "Imported from API"
                    return course
                }
            } catch {
                status = "API failed: \(error.localizedDescription)"
            }
        }

        // Try scraping GolfLink
        do {
            status = "Trying GolfLink..."
            let citySlug = city
                .lowercased()
                .replacing(/[^a-z0-9\s]/, with: "")
                .replacing(/\s+/, with: "-")
            let courseSlug = courseName
                .lowercased()
                .replacing(/[^a-z0-9\s]/, with: "")
                .replacing(/\s+/, with: "-")
            let url = URL(string: "https://www.golflink.com/golf-courses/\(state.lowercased())/\(citySlug)/\(courseSlug)")!
            let data = try await ScorecardScraper.fetchAndParse(url: url)
            let course = buildCourse(from: data, name: courseName, city: city, state: state)
            status = "Imported from GolfLink"
            return course
        } catch {
            status = "GolfLink failed: \(error.localizedDescription)"
        }

        throw ImportError.courseNotFound
    }

    /// Import from a scorecard image using OCR
    func importFromImage(_ image: NSImage, name: String, city: String, state: String) throws -> Course {
        let data = try ScorecardOCR.parseScorecard(from: image)
        return buildCourse(from: data, name: name, city: city, state: state)
    }

    /// Create an empty course shell for manual entry
    func createManualCourse(name: String, city: String, state: String, holeCount: Int = 18) -> Course {
        let subCourses: [SubCourse]
        if holeCount <= 9 {
            let holes = (1...holeCount).map { Hole(number: $0, par: 4) }
            subCourses = [SubCourse(name: "Front", holes: holes)]
        } else {
            let halfCount = holeCount / 2
            let frontHoles = (1...halfCount).map { Hole(number: $0, par: 4) }
            let backHoles = (1...(holeCount - halfCount)).map { Hole(number: $0, par: 4) }
            subCourses = [
                SubCourse(name: "Front", holes: frontHoles),
                SubCourse(name: "Back", holes: backHoles),
            ]
        }
        return Course(
            name: name,
            location: CourseLocation(address: "", city: city, state: state, country: "", coordinate: Coordinate(latitude: 0, longitude: 0)),
            subCourses: subCourses
        )
    }

    func buildCourse(from data: ScorecardData, name: String, city: String, state: String) -> Course {
        let tees = data.teeNames.map { teeName in
            TeeDefinition(
                name: teeName,
                color: TeeDefinition.defaultColor(for: teeName)
            )
        }

        let holeGroups = Hole.splitIntoSubCourses(data.holes, names: ["Front", "Back"])
        let subCourses = holeGroups.map { SubCourse(name: $0.name, holes: $0.holes) }

        return Course(
            name: name,
            location: CourseLocation(address: "", city: city, state: state, country: "", coordinate: Coordinate(latitude: 0, longitude: 0)),
            tees: tees,
            subCourses: subCourses
        )
    }

}
