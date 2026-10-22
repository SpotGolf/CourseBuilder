import Foundation

/// The OpenStreetMap server changes are published to. Features are imported from production, so
/// they are published there too.
enum OSMServer {
    /// The website, which also handles OAuth.
    static let webURL = URL(string: "https://www.openstreetmap.org")!

    static let apiURL = URL(string: "https://api.openstreetmap.org/api/0.6")!

    /// The client ID of the CourseBuilder OAuth app.
    static let clientID = "DjtJ7LerCVe-Kqz44KXxxJz5_f_Fkp3FTk7RiTRjTac"

    static var host: String { webURL.host() ?? webURL.absoluteString }

    /// The path of an element, such as `way/123` for the short OSM ID `w123`.
    static func elementPath(osmID: String) -> String? {
        guard let (kind, id) = OSMChangeBuilder.parse(osmID) else { return nil }
        switch kind {
        case "n": return "node/\(id)"
        case "w": return "way/\(id)"
        case "r": return "relation/\(id)"
        default: return nil
        }
    }

    /// The element's page on the website.
    static func elementURL(osmID: String) -> URL? {
        elementPath(osmID: osmID).map { webURL.appendingPathComponent($0) }
    }

    static func changesetURL(id: Int) -> URL {
        webURL.appendingPathComponent("changeset/\(id)")
    }
}
