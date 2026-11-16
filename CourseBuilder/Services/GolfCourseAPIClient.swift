import Foundation
import os
import CourseDataSwift

private let logger = Logger(subsystem: "golf.spot.CourseBuilder", category: "GolfCourseAPI")

actor GolfCourseAPIClient {
    // MARK: - Errors

    enum APIError: LocalizedError {
        case emptyDetails
        case httpError(Int)
        case invalidURL

        var errorDescription: String? {
            switch self {
            case .emptyDetails: "convertToCourse requires at least one CourseDetail"
            case .httpError(let code): "HTTP error \(code)"
            case .invalidURL: "Invalid URL"
            }
        }
    }

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

    struct CourseSearchResult: Codable, Hashable, Identifiable {
        let id: String
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

        /// Whether the result says where the course is. Without that, the course cannot be
        /// looked for in OpenStreetMap or shown on the map.
        var hasCoordinate: Bool {
            guard let latitude = location.latitude, let longitude = location.longitude else { return false }
            return latitude != 0 || longitude != 0
        }
    }

    struct APILocation: Codable, Hashable {
        let address: String?
        let city: String?
        let state: String?
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
        let id: String?
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
        guard var components = URLComponents(url: baseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "search_query", value: query)]

        guard let url = components.url else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")

        logger.debug("Search request: \(request.httpMethod ?? "GET", privacy: .public) \(request.url?.absoluteString ?? "nil", privacy: .public)")

        let (data, response) = try await session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw APIError.httpError(httpResponse.statusCode)
        }
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

    func fetchCourse(id: String) async throws -> CourseDetail {
        guard let url = URLComponents(url: baseURL.appendingPathComponent("courses/\(id)"), resolvingAgainstBaseURL: false)?.url else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")

        logger.debug("FetchCourse request: \(request.httpMethod ?? "GET", privacy: .public) \(request.url?.absoluteString ?? "nil", privacy: .public)")

        let (data, response) = try await session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw APIError.httpError(httpResponse.statusCode)
        }
        if let httpResponse = response as? HTTPURLResponse {
            logger.debug("FetchCourse response status: \(httpResponse.statusCode, privacy: .public)")
        }
        let bodyString = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        logger.debug("FetchCourse response body: \(bodyString, privacy: .public)")

        do {
            let wrapper = try JSONDecoder().decode(CourseDetailResponse.self, from: data)
            return wrapper.course
        } catch {
            logger.error("FetchCourse decode failed: \(error, privacy: .public)\nBody: \(bodyString, privacy: .public)")
            throw error
        }
    }

    // MARK: - Conversion

    /// Convert a single CourseDetail into a Course with sub-courses.
    static func convertToCourse(detail: CourseDetail) throws -> Course {
        return try convertToCourse(details: [detail])
    }

    /// Combines one or more results into a single course.
    ///
    /// Each result gives one sub-course, or two when it has an even number of holes, such as a
    /// front and back nine. A result named with slashes, such as "Vista/Canyon", gives one
    /// sub-course per part. A sub-course that plays the same holes as one already taken from an
    /// earlier result is dropped, so "Vista/Canyon" and "Canyon/Sunshine" give Vista, Canyon, and
    /// Sunshine.
    ///
    /// A course made from one result takes that result's course name. A course made from several
    /// takes the club name.
    static func convertToCourse(details: [CourseDetail]) throws -> Course {
        guard let first = details.first else {
            throw APIError.emptyDetails
        }

        let location = CourseLocation(
            address: first.location.address ?? "",
            city: first.location.city ?? "",
            state: first.location.state ?? "",
            country: first.location.country ?? "",
            coordinate: Coordinate(
                lat: first.location.latitude ?? 0,
                lon: first.location.longitude ?? 0
            )
        )

        var allTeeDefinitions: [String: TeeDefinition] = [:]
        var allSubCourses: [SubCourse] = []
        var golfCourseAPIIds: [String] = []

        for detail in details {
            if let detailId = detail.id {
                golfCourseAPIIds.append(detailId)
            }

            // Collect all hole data grouped by hole number
            var holeDataMap: [Int: (par: Int, maleHandicap: Int, femaleHandicap: Int, yardages: [String: Int])] = [:]

            // Track tee names and their API data for building sub-course tees
            struct TeeAPIData {
                let teeName: String
                let frontCourseRating: Double?
                let frontSlopeRating: Int?
                let backCourseRating: Double?
                let backSlopeRating: Int?
            }
            var maleTeeData: [TeeAPIData] = []
            var femaleTeeData: [TeeAPIData] = []

            // Process male tees
            if let maleTees = detail.tees.male {
                for teeSet in maleTees {
                    allTeeDefinitions[teeSet.teeName] = TeeDefinition(
                        name: teeSet.teeName,
                        color: TeeDefinition.defaultColor(for: teeSet.teeName)
                    )
                    maleTeeData.append(TeeAPIData(
                        teeName: teeSet.teeName,
                        frontCourseRating: teeSet.frontCourseRating,
                        frontSlopeRating: teeSet.frontSlopeRating,
                        backCourseRating: teeSet.backCourseRating,
                        backSlopeRating: teeSet.backSlopeRating
                    ))

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
                    if allTeeDefinitions[teeSet.teeName] == nil {
                        allTeeDefinitions[teeSet.teeName] = TeeDefinition(
                            name: teeSet.teeName,
                            color: TeeDefinition.defaultColor(for: teeSet.teeName)
                        )
                    }
                    femaleTeeData.append(TeeAPIData(
                        teeName: teeSet.teeName,
                        frontCourseRating: teeSet.frontCourseRating,
                        frontSlopeRating: teeSet.frontSlopeRating,
                        backCourseRating: teeSet.backCourseRating,
                        backSlopeRating: teeSet.backSlopeRating
                    ))

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

            // Build all holes sorted by number
            let allHoles = holeDataMap.keys.sorted().map { number -> Hole in
                let data = holeDataMap[number]!
                return Hole(
                    number: number,
                    par: data.par,
                    maleHandicap: data.maleHandicap,
                    femaleHandicap: data.femaleHandicap,
                    yardages: data.yardages
                )
            }

            let subCourseNames = subCourseNames(for: detail, holeCount: allHoles.count, isOnlyResult: details.count == 1)
            let holeGroups = Hole.splitIntoSubCourses(allHoles, names: subCourseNames)

            // Build sub-courses with tee information
            for (groupIndex, group) in holeGroups.enumerated() {
                guard !allSubCourses.contains(where: { playsSameHoles($0, name: group.name, holes: group.holes) }) else { continue }

                let renumberedHoles = group.holes

                // Build sub-course tees
                var subCourseTees: [String: SubCourseTee] = [:]
                let allTeeNames = Set(maleTeeData.map(\.teeName) + femaleTeeData.map(\.teeName))

                for teeName in allTeeNames {
                    var subCourseTee = SubCourseTee()

                    // Male tee info
                    if let maleData = maleTeeData.first(where: { $0.teeName == teeName }) {
                        let rating: Double?
                        let slope: Int?
                        if groupIndex == 0 {
                            rating = maleData.frontCourseRating
                            slope = maleData.frontSlopeRating
                        } else {
                            rating = maleData.backCourseRating
                            slope = maleData.backSlopeRating
                        }
                        let totalYards = renumberedHoles.compactMap { $0.yardages[teeName] }.reduce(0, +)
                        let parTotal = renumberedHoles.map(\.par).reduce(0, +)
                        subCourseTee.male = TeeInformation(
                            rating: rating,
                            slope: slope,
                            totalYards: totalYards > 0 ? totalYards : nil,
                            parTotal: parTotal > 0 ? parTotal : nil
                        )
                    }

                    // Female tee info
                    if let femaleData = femaleTeeData.first(where: { $0.teeName == teeName }) {
                        let rating: Double?
                        let slope: Int?
                        if groupIndex == 0 {
                            rating = femaleData.frontCourseRating
                            slope = femaleData.frontSlopeRating
                        } else {
                            rating = femaleData.backCourseRating
                            slope = femaleData.backSlopeRating
                        }
                        let totalYards = renumberedHoles.compactMap { $0.yardages[teeName] }.reduce(0, +)
                        let parTotal = renumberedHoles.map(\.par).reduce(0, +)
                        subCourseTee.female = TeeInformation(
                            rating: rating,
                            slope: slope,
                            totalYards: totalYards > 0 ? totalYards : nil,
                            parTotal: parTotal > 0 ? parTotal : nil
                        )
                    }

                    subCourseTees[teeName] = subCourseTee
                }

                allSubCourses.append(SubCourse(
                    name: unusedName(group.name, in: allSubCourses),
                    holes: renumberedHoles,
                    tees: subCourseTees
                ))
            }
        }

        return Course(
            name: details.count > 1 && !first.clubName.isEmpty ? first.clubName : first.courseName,
            clubName: first.clubName,
            golfCourseAPIIds: golfCourseAPIIds,
            location: location,
            tees: Array(allTeeDefinitions.values).sorted { teeA, teeB in
                let allHoles = allSubCourses.flatMap(\.holes)
                let totalA = allHoles.compactMap { $0.yardages[teeA.name] }.reduce(0, +)
                let totalB = allHoles.compactMap { $0.yardages[teeB.name] }.reduce(0, +)
                return totalA > totalB
            },
            subCourses: allSubCourses
        )
    }

    /// The names of the sub-courses a result gives, one per sub-course.
    ///
    /// - A result named with slashes whose parts divide its holes evenly gives one sub-course per
    ///   part: "Vista/Canyon" gives Vista and Canyon.
    /// - Any other result gives two sub-courses when it has an even number of holes, and one when
    ///   it does not, such as a 9-hole course.
    /// - When it is the only result, they are named "Front" and "Back". When several results are
    ///   combined, they are named after the result so they can be told apart.
    private static func subCourseNames(for detail: CourseDetail, holeCount: Int, isOnlyResult: Bool) -> [String] {
        let parts = detail.courseName.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if parts.count >= 2, holeCount > 1, holeCount % parts.count == 0 {
            return parts
        }

        let isSplitInTwo = holeCount > 1 && holeCount % 2 == 0
        if isOnlyResult {
            return isSplitInTwo ? ["Front", "Back"] : ["Front"]
        }
        let resultName = detail.courseName.isEmpty ? detail.clubName : detail.courseName
        return isSplitInTwo ? ["\(resultName) Front", "\(resultName) Back"] : [resultName]
    }

    /// Whether a sub-course plays the same holes as `holes`: the same pars, and the same yardage
    /// on every tee both have. Handicaps are not compared, since a nine has different handicaps
    /// as a front nine than as a back nine. When the two share no tee, they must also share a name.
    private static func playsSameHoles(_ subCourse: SubCourse, name: String, holes: [Hole]) -> Bool {
        guard subCourse.holes.map(\.par) == holes.map(\.par) else { return false }
        var sharesTee = false
        for (kept, hole) in zip(subCourse.holes, holes) {
            for (tee, yardage) in hole.yardages {
                guard let keptYardage = kept.yardages[tee] else { continue }
                guard keptYardage == yardage else { return false }
                sharesTee = true
            }
        }
        return sharesTee || subCourse.name.caseInsensitiveCompare(name) == .orderedSame
    }

    /// `name`, or `name` with the lowest number added that makes it differ from every sub-course's name.
    private static func unusedName(_ name: String, in subCourses: [SubCourse]) -> String {
        func isUsed(_ candidate: String) -> Bool {
            subCourses.contains { $0.name.caseInsensitiveCompare(candidate) == .orderedSame }
        }
        guard isUsed(name) else { return name }
        var number = 2
        while isUsed("\(name) \(number)") {
            number += 1
        }
        return "\(name) \(number)"
    }

}
