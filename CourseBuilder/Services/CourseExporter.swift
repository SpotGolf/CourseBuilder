import Foundation
import CourseDataSwift

/// Builds the gzipped JSON file that the SpotGolf app reads, and saves it into a CourseData
/// repository.
enum CourseExporter {
    enum ExportError: LocalizedError, Equatable {
        case missingLocation(String)

        var errorDescription: String? {
            switch self {
            case .missingLocation(let field): "Set the course's \(field) before exporting."
            }
        }
    }

    /// Returns the course as JSON and as gzipped JSON.
    static func export(_ course: Course) throws -> (json: Data, gzip: Data) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(course)
        return (json, try json.gzipCompressed())
    }

    /// Saves the gzipped course into a CourseData repository, creating any missing folders.
    ///
    /// - Parameter directory: The CourseData repository, or its `Data` folder.
    /// - Returns: The saved file and the JSON and gzip sizes.
    @discardableResult
    static func write(_ course: Course, toCourseData directory: URL) throws -> (url: URL, jsonSize: Int, gzipSize: Int) {
        let dataDirectory = directory.lastPathComponent == "Data" ? directory : directory.appendingPathComponent("Data", isDirectory: true)
        let fileURL = dataDirectory.appendingPathComponent(try relativePath(for: course))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (json, gzip) = try export(course)
        try gzip.write(to: fileURL, options: .atomic)
        return (fileURL, json.count, gzip.count)
    }

    // MARK: - CourseData naming

    /// The file's path inside CourseData's `Data` folder: `{Country}/{State}/{City}/{Course-Name}.json.gz`.
    static func relativePath(for course: Course) throws -> String {
        let location = course.location
        guard let country = countryCode(location.country) else { throw ExportError.missingLocation("country") }
        let state = stateCode(location.state, country: country)
        guard !state.isEmpty else { throw ExportError.missingLocation("state") }
        let city = cityName(location.city)
        guard !city.isEmpty else { throw ExportError.missingLocation("city") }
        let name = fileName(for: course.name)
        guard !name.isEmpty else { throw ExportError.missingLocation("name") }
        return "\(country)/\(state)/\(city)/\(name).json.gz"
    }

    /// The ISO 3166-1 two-letter code for a country name or code, such as `US` for "United States".
    static func countryCode(_ country: String) -> String? {
        let trimmed = country.trimmingCharacters(in: .whitespaces)
        let regions = Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 }
        if trimmed.count == 2, regions.contains(trimmed.uppercased()) {
            return trimmed.uppercased()
        }
        let english = Locale(identifier: "en_US")
        let aliases = ["usa": "US", "united states of america": "US", "uk": "GB"]
        if let code = aliases[trimmed.lowercased()] { return code }
        return regions.first { english.localizedString(forRegionCode: $0)?.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// The ISO 3166-2 subdivision code (without the country) for a state, such as `CO` for
    /// "Colorado". US state names are turned into their codes; anything else is used as given.
    static func stateCode(_ state: String, country: String) -> String {
        let trimmed = state.trimmingCharacters(in: .whitespaces)
        if country == "US", let code = usStateCodes[trimmed.lowercased()] { return code }
        return trimmed.count <= 3 ? trimmed.uppercased() : trimmed
    }

    /// The city's full name with each word capitalized, such as "Cherry Hills Village".
    static func cityName(_ city: String) -> String {
        city.split(separator: " ").map { capitalizingFirstLetter(String($0)) }.joined(separator: " ")
    }

    /// The course name hyphenated, without a leading "The": "The Broadlands Golf Course"
    /// becomes `Broadlands-Golf-Course`. Apostrophes are dropped: "Bear's" becomes `Bears`.
    static func fileName(for name: String) -> String {
        var words = name
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        if words.count > 1, words[0].lowercased() == "the" {
            words.removeFirst()
        }
        return words.map(capitalizingFirstLetter).joined(separator: "-")
    }

    /// Upper-cases the first letter and leaves the rest alone, so "McDonald" stays as it is.
    private static func capitalizingFirstLetter(_ word: String) -> String {
        word.prefix(1).uppercased() + word.dropFirst()
    }

    private static let usStateCodes: [String: String] = [
        "alabama": "AL", "alaska": "AK", "arizona": "AZ", "arkansas": "AR", "california": "CA",
        "colorado": "CO", "connecticut": "CT", "delaware": "DE", "district of columbia": "DC",
        "florida": "FL", "georgia": "GA", "hawaii": "HI", "idaho": "ID", "illinois": "IL",
        "indiana": "IN", "iowa": "IA", "kansas": "KS", "kentucky": "KY", "louisiana": "LA",
        "maine": "ME", "maryland": "MD", "massachusetts": "MA", "michigan": "MI", "minnesota": "MN",
        "mississippi": "MS", "missouri": "MO", "montana": "MT", "nebraska": "NE", "nevada": "NV",
        "new hampshire": "NH", "new jersey": "NJ", "new mexico": "NM", "new york": "NY",
        "north carolina": "NC", "north dakota": "ND", "ohio": "OH", "oklahoma": "OK", "oregon": "OR",
        "pennsylvania": "PA", "rhode island": "RI", "south carolina": "SC", "south dakota": "SD",
        "tennessee": "TN", "texas": "TX", "utah": "UT", "vermont": "VT", "virginia": "VA",
        "washington": "WA", "west virginia": "WV", "wisconsin": "WI", "wyoming": "WY",
        "puerto rico": "PR",
    ]
}
