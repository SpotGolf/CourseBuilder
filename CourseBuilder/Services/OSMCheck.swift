import Foundation
import CourseDataSwift

enum OSMCheck {
    /// Whether an OSM result holds anything to import.
    static func hasCourseData(_ result: OverpassAPIClient.ParsedResult) -> Bool {
        !result.features.isEmpty || !result.centerlines.isEmpty
    }
}
