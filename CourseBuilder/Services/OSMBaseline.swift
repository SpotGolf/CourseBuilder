import Foundation
import CourseDataSwift

/// What OpenStreetMap had for each of a course's features the last time the app and OSM agreed.
/// Publishing compares the course to this to find what changed.
struct OSMBaseline: Codable, Equatable {
    struct Entry: Codable, Equatable {
        /// The OSM element in short form, such as `w123456789`.
        var osmID: String
        /// The element's OSM version. Nil when unknown.
        var version: Int?
        var type: FeatureType
        /// Points as `[latitude, longitude]`. Elevation is not kept.
        var points: [[Double]]

        init(osmID: String, version: Int?, type: FeatureType, points: [[Double]]) {
            self.osmID = osmID
            self.version = version
            self.type = type
            self.points = points
        }

        init(feature: Feature, osmID: String, version: Int?) {
            self.init(osmID: osmID, version: version, type: feature.type, points: feature.polygon.map { [$0.lat, $0.lon] })
        }

        var coordinates: [Coordinate] {
            points.map { Coordinate(lat: $0[0], lon: $0[1]) }
        }

        /// Whether the feature's type or points differ from this entry.
        func differs(from feature: Feature) -> Bool {
            feature.type != type || !OSMChangeDetector.samePoints(Array(feature.polygon), coordinates)
        }

        /// The feature with this entry's type and points. Elevations are dropped and looked up again.
        func reverted(_ feature: Feature) -> Feature {
            Feature(id: feature.id, type: type, polygon: CoordinatePath(coordinates), osmID: feature.osmID)
        }
    }

    /// Entries by OSM ID.
    var entries: [String: Entry] = [:]

    /// Fairways to make into multipolygons on the next publish.
    var pendingMultipolygons: [PendingMultipolygon] = []

    /// A baseline of every course feature that has an OSM ID.
    ///
    /// - Parameter versions: Known OSM versions by OSM ID. Features not in it get an unknown version.
    init(course: Course, versions: [String: Int] = [:]) {
        for feature in course.features {
            guard let osmID = feature.osmID else { continue }
            entries[osmID] = Entry(feature: feature, osmID: osmID, version: versions[osmID])
        }
    }

    init(entries: [String: Entry] = [:], pendingMultipolygons: [PendingMultipolygon] = []) {
        self.entries = entries
        self.pendingMultipolygons = pendingMultipolygons
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decode([String: Entry].self, forKey: .entries)
        // Baselines saved before multipolygon support have no pending list.
        pendingMultipolygons = try container.decodeIfPresent([PendingMultipolygon].self, forKey: .pendingMultipolygons) ?? []
    }
}

/// Reads and writes each course's ``OSMBaseline``.
///
/// Baselines live in their own folder because ``CourseStore`` loads every `.json` file in the
/// courses folder as a course.
struct OSMBaselineStore {
    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directory = appSupport.appendingPathComponent("CourseBuilder/osm-baselines", isDirectory: true)
        }
    }

    func load(courseID: UUID) throws -> OSMBaseline? {
        let url = fileURL(for: courseID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(OSMBaseline.self, from: Data(contentsOf: url))
    }

    func save(_ baseline: OSMBaseline, courseID: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(baseline).write(to: fileURL(for: courseID), options: .atomic)
    }

    /// The course's baseline. A course without one gets a baseline made from its current
    /// features, which is saved so later edits are found.
    func loadOrCreate(for course: Course) throws -> OSMBaseline {
        if let baseline = try load(courseID: course.id) {
            return baseline
        }
        let baseline = OSMBaseline(course: course)
        try save(baseline, courseID: course.id)
        return baseline
    }

    private func fileURL(for courseID: UUID) -> URL {
        directory.appendingPathComponent("\(courseID).json")
    }
}
