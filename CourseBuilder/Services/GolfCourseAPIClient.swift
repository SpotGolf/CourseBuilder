import Foundation
import os

private let logger = Logger(subsystem: "com.spotgolf.CourseBuilder", category: "GolfCourseAPI")

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

    struct CourseSearchResult: Codable, Hashable {
        let id: Int
        let clubName: String
        let courseName: String
        let location: APILocation
        let holes: Int?

        enum CodingKeys: String, CodingKey {
            case id
            case clubName = "club_name"
            case courseName = "course_name"
            case location
            case holes
        }
    }

    struct APILocation: Codable, Hashable {
        let address: String?
        let city: String
        let state: String
        let country: String?
        let zipCode: String?
        let latitude: Double?
        let longitude: Double?

        enum CodingKeys: String, CodingKey {
            case address
            case city
            case state
            case country
            case zipCode = "zip_code"
            case latitude
            case longitude
        }
    }

    struct CourseDetailResponse: Codable {
        let course: CourseDetail
    }

    struct CourseDetail: Codable {
        let id: Int?
        let courseName: String
        let clubName: String
        let location: APILocation
        let tees: TeeSets

        enum CodingKeys: String, CodingKey {
            case id
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
        let frontCourseRating: Double?
        let frontSlopeRating: Int?
        let backCourseRating: Double?
        let backSlopeRating: Int?
        let holes: [APIHole]

        enum CodingKeys: String, CodingKey {
            case teeName = "tee_name"
            case courseRating = "course_rating"
            case slopeRating = "slope_rating"
            case totalYards = "total_yards"
            case parTotal = "par_total"
            case frontCourseRating = "front_course_rating"
            case frontSlopeRating = "front_slope_rating"
            case backCourseRating = "back_course_rating"
            case backSlopeRating = "back_slope_rating"
            case holes
        }
    }

    struct APIHole: Codable {
        let par: Int
        let yardage: Int
        let handicap: Int
    }

    // MARK: - Network Methods

    func search(query: String) async throws -> SearchResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "search_query", value: query)]

        var request = URLRequest(url: components.url!)
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")

        logger.debug("Search request: \(request.httpMethod ?? "GET", privacy: .public) \(request.url?.absoluteString ?? "nil", privacy: .public)")

        let (data, response) = try await session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            logger.debug("Search response status: \(httpResponse.statusCode, privacy: .public)")
        }
        let bodyString = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        logger.debug("Search response body: \(bodyString, privacy: .public)")

        do {
            return try JSONDecoder().decode(SearchResponse.self, from: data)
        } catch {
            logger.error("Search decode failed: \(error, privacy: .public)\nBody: \(bodyString, privacy: .public)")
            throw error
        }
    }

    func fetchCourse(id: Int) async throws -> CourseDetail {
        let url = baseURL.appendingPathComponent("courses/\(id)")

        var request = URLRequest(url: url)
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")

        logger.debug("FetchCourse request: \(request.httpMethod ?? "GET", privacy: .public) \(request.url?.absoluteString ?? "nil", privacy: .public)")

        let (data, response) = try await session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            logger.debug("FetchCourse response status: \(httpResponse.statusCode, privacy: .public)")
        }
        let bodyString = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        logger.debug("FetchCourse response body: \(bodyString, privacy: .public)")
        print("[GolfCourseAPI] FetchCourse response body: \(bodyString)")

        do {
            let wrapper = try JSONDecoder().decode(CourseDetailResponse.self, from: data)
            return wrapper.course
        } catch {
            logger.error("FetchCourse decode failed: \(error, privacy: .public)\nBody: \(bodyString, privacy: .public)")
            throw error
        }
    }

    // MARK: - Conversion

    static func convertToCourse(detail: CourseDetail) -> Course {
        let location = CourseLocation(
            address: detail.location.address ?? "",
            city: detail.location.city,
            state: detail.location.state,
            country: detail.location.country ?? "",
            coordinate: Coordinate(
                latitude: detail.location.latitude ?? 0,
                longitude: detail.location.longitude ?? 0
            )
        )

        // Build tee definitions, merging male/female by name
        var teeMap: [String: TeeDefinition] = [:]

        // Collect all hole data grouped by hole number
        var holeDataMap: [Int: (par: Int, maleHandicap: Int, femaleHandicap: Int, yardages: [String: Int])] = [:]

        // Process male tees
        if let maleTees = detail.tees.male {
            for teeSet in maleTees {
                let info = TeeInformation(
                    courseRating: teeSet.courseRating,
                    slopeRating: teeSet.slopeRating,
                    frontCourseRating: teeSet.frontCourseRating,
                    frontSlopeRating: teeSet.frontSlopeRating,
                    backCourseRating: teeSet.backCourseRating,
                    backSlopeRating: teeSet.backSlopeRating,
                    totalYards: teeSet.totalYards,
                    parTotal: teeSet.parTotal
                )
                if var existing = teeMap[teeSet.teeName] {
                    existing.male = info
                    teeMap[teeSet.teeName] = existing
                } else {
                    teeMap[teeSet.teeName] = TeeDefinition(
                        name: teeSet.teeName,
                        color: defaultColor(for: teeSet.teeName),
                        male: info
                    )
                }

                for (index, hole) in teeSet.holes.enumerated() {
                    let holeNumber = index + 1
                    if var existing = holeDataMap[holeNumber] {
                        existing.yardages[teeSet.teeName] = hole.yardage
                        existing.maleHandicap = hole.handicap
                        holeDataMap[holeNumber] = existing
                    } else {
                        holeDataMap[holeNumber] = (
                            par: hole.par,
                            maleHandicap: hole.handicap,
                            femaleHandicap: 0,
                            yardages: [teeSet.teeName: hole.yardage]
                        )
                    }
                }
            }
        }

        // Process female tees
        if let femaleTees = detail.tees.female {
            for teeSet in femaleTees {
                let info = TeeInformation(
                    courseRating: teeSet.courseRating,
                    slopeRating: teeSet.slopeRating,
                    frontCourseRating: teeSet.frontCourseRating,
                    frontSlopeRating: teeSet.frontSlopeRating,
                    backCourseRating: teeSet.backCourseRating,
                    backSlopeRating: teeSet.backSlopeRating,
                    totalYards: teeSet.totalYards,
                    parTotal: teeSet.parTotal
                )
                if var existing = teeMap[teeSet.teeName] {
                    existing.female = info
                    teeMap[teeSet.teeName] = existing
                } else {
                    teeMap[teeSet.teeName] = TeeDefinition(
                        name: teeSet.teeName,
                        color: defaultColor(for: teeSet.teeName),
                        female: info
                    )
                }

                for (index, hole) in teeSet.holes.enumerated() {
                    let holeNumber = index + 1
                    if var existing = holeDataMap[holeNumber] {
                        existing.yardages[teeSet.teeName] = hole.yardage
                        existing.femaleHandicap = hole.handicap
                        holeDataMap[holeNumber] = existing
                    } else {
                        holeDataMap[holeNumber] = (
                            par: hole.par,
                            maleHandicap: 0,
                            femaleHandicap: hole.handicap,
                            yardages: [teeSet.teeName: hole.yardage]
                        )
                    }
                }
            }
        }

        let teeDefinitions = Array(teeMap.values)

        // Build holes sorted by hole number
        let holes = holeDataMap.keys.sorted().map { number -> Hole in
            let data = holeDataMap[number]!
            return Hole(
                number: number,
                par: data.par,
                maleHandicap: data.maleHandicap,
                femaleHandicap: data.femaleHandicap,
                yardages: data.yardages
            )
        }

        return Course(
            name: detail.courseName,
            clubName: detail.clubName,
            golfCourseAPIId: detail.id,
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
