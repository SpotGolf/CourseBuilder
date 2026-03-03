import Foundation

actor GolfCourseAPIClient {
    // MARK: - Configuration

    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession

    init(apiKey: String, baseURL: URL = URL(string: "https://api.golfcourseapi.com/v1")!, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - API Response Types

    struct SearchResponse: Codable {
        let courses: [CourseSearchResult]
    }

    struct CourseSearchResult: Codable {
        let id: Int
        let clubName: String
        let courseName: String
        let location: APILocation
        let holes: Int

        enum CodingKeys: String, CodingKey {
            case id
            case clubName = "club_name"
            case courseName = "course_name"
            case location
            case holes
        }
    }

    struct APILocation: Codable {
        let address: String?
        let city: String
        let state: String
        let country: String?
        let zipCode: String?

        enum CodingKeys: String, CodingKey {
            case address
            case city
            case state
            case country
            case zipCode = "zip_code"
        }
    }

    struct CourseDetail: Codable {
        let courseName: String
        let clubName: String
        let location: APILocation
        let tees: TeeSets

        enum CodingKeys: String, CodingKey {
            case courseName = "course_name"
            case clubName = "club_name"
            case location
            case tees
        }
    }

    struct TeeSets: Codable {
        let male: [TeeSet]?
        let female: [TeeSet]?
    }

    struct TeeSet: Codable {
        let teeName: String
        let courseRating: Double?
        let slopeRating: Int?
        let totalYards: Int?
        let parTotal: Int?
        let holes: [APIHole]

        enum CodingKeys: String, CodingKey {
            case teeName = "tee_name"
            case courseRating = "course_rating"
            case slopeRating = "slope_rating"
            case totalYards = "total_yards"
            case parTotal = "par_total"
            case holes
        }
    }

    struct APIHole: Codable {
        let holeNumber: Int
        let par: Int
        let yardage: Int
        let handicap: Int

        enum CodingKeys: String, CodingKey {
            case holeNumber = "hole_number"
            case par
            case yardage
            case handicap
        }
    }

    // MARK: - Network Methods

    func search(query: String) async throws -> SearchResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("courses/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "search_query", value: query)]

        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")

        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(SearchResponse.self, from: data)
    }

    func fetchCourse(id: Int) async throws -> CourseDetail {
        let url = baseURL.appendingPathComponent("courses/\(id)")

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")

        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(CourseDetail.self, from: data)
    }

    // MARK: - Conversion

    static func convertToCourse(detail: CourseDetail) -> Course {
        let location = CourseLocation(
            city: detail.location.city,
            state: detail.location.state,
            coordinate: Coordinate(latitude: 0, longitude: 0)
        )

        let courseID = Course.generateID(
            name: detail.courseName,
            city: detail.location.city,
            state: detail.location.state
        )

        // Build tee definitions — male first, then female
        var teeDefinitions: [TeeDefinition] = []

        // Collect all hole data grouped by hole number
        // Key: hole number, Value: (par, handicap, yardages dict)
        var holeDataMap: [Int: (par: Int, handicap: Int, yardages: [String: Int])] = [:]

        // Process male tees
        if let maleTees = detail.tees.male {
            for teeSet in maleTees {
                let teeDef = TeeDefinition(
                    name: teeSet.teeName,
                    color: defaultColor(for: teeSet.teeName),
                    gender: .male,
                    rating: teeSet.courseRating,
                    slope: teeSet.slopeRating
                )
                teeDefinitions.append(teeDef)

                for hole in teeSet.holes {
                    if var existing = holeDataMap[hole.holeNumber] {
                        existing.yardages[teeSet.teeName] = hole.yardage
                        holeDataMap[hole.holeNumber] = existing
                    } else {
                        holeDataMap[hole.holeNumber] = (
                            par: hole.par,
                            handicap: hole.handicap,
                            yardages: [teeSet.teeName: hole.yardage]
                        )
                    }
                }
            }
        }

        // Process female tees
        if let femaleTees = detail.tees.female {
            for teeSet in femaleTees {
                let teeDef = TeeDefinition(
                    name: teeSet.teeName,
                    color: defaultColor(for: teeSet.teeName),
                    gender: .female,
                    rating: teeSet.courseRating,
                    slope: teeSet.slopeRating
                )
                teeDefinitions.append(teeDef)

                for hole in teeSet.holes {
                    if var existing = holeDataMap[hole.holeNumber] {
                        existing.yardages[teeSet.teeName] = hole.yardage
                        holeDataMap[hole.holeNumber] = existing
                    } else {
                        holeDataMap[hole.holeNumber] = (
                            par: hole.par,
                            handicap: hole.handicap,
                            yardages: [teeSet.teeName: hole.yardage]
                        )
                    }
                }
            }
        }

        // Build holes sorted by hole number
        let holes = holeDataMap.keys.sorted().map { number -> Hole in
            let data = holeDataMap[number]!
            return Hole(
                number: number,
                par: data.par,
                handicap: data.handicap,
                yardages: data.yardages
            )
        }

        return Course(
            id: courseID,
            name: detail.courseName,
            location: location,
            tees: teeDefinitions,
            holes: holes
        )
    }

    // MARK: - Helpers

    private static func defaultColor(for teeName: String) -> String {
        switch teeName.lowercased() {
        case "black":
            return "#000000"
        case "gold":
            return "#FFD700"
        case "blue":
            return "#0000FF"
        case "white":
            return "#FFFFFF"
        case "silver":
            return "#C0C0C0"
        case "red":
            return "#FF0000"
        case "green":
            return "#008000"
        default:
            return "#808080"
        }
    }
}
