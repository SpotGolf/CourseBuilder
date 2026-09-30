import Foundation
import CourseDataSwift

/// Builds the gzipped JSON file that the SpotGolf app reads.
enum CourseExporter {
    /// Returns the course as JSON and as gzipped JSON.
    static func export(_ course: Course) throws -> (json: Data, gzip: Data) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(course)
        return (json, try json.gzipCompressed())
    }
}
