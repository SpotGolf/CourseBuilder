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
        /// The element's tags. Nil when unknown, such as for baselines saved before tags were kept.
        var tags: [String: String]?
        /// For a relation, its members. Nil for a way, and for a relation whose members are unknown.
        var members: [OSMRelation.Member]?

        init(osmID: String, version: Int?, type: FeatureType, points: [[Double]], tags: [String: String]? = nil, members: [OSMRelation.Member]? = nil) {
            self.osmID = osmID
            self.version = version
            self.type = type
            self.points = points
            self.tags = tags
            self.members = members
        }

        init(feature: Feature, osmID: String, details: OSMElementDetails?) {
            self.init(
                osmID: osmID,
                version: details?.version,
                type: feature.type,
                points: feature.polygon.map { [$0.lat, $0.lon] },
                tags: details?.tags,
                members: details?.members
            )
        }

        /// Whether the tags, and for a relation the members, are unknown.
        var detailsUnknown: Bool {
            tags == nil || (osmID.hasPrefix("r") && members == nil)
        }

        /// Takes the tags and members sent to OSM for this element. Nothing changes when nothing was sent.
        mutating func takeSent(_ sent: OSMElementDetails?) {
            guard let sent else { return }
            tags = sent.tags
            if sent.members != nil { members = sent.members }
        }

        /// For a relation, its inner way members. Nil when the members are unknown.
        var innerOSMIDs: [String]? {
            members?.filter { $0.type == "way" && $0.role == "inner" }.map { "w\($0.ref)" }
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

    /// Fairways to make into multipolygons, or fairway relations to add greens to, on the next publish.
    var pendingMultipolygons: [PendingMultipolygon] = []

    /// The `leisure=golf_course` element that is not a usable course outline, found by the last import.
    var misplacedCourseElement: MisplacedCourseElement?

    /// A new course outline to publish, taking tags from ``misplacedCourseElement``.
    var pendingCourseOutline: PendingCourseOutline?

    /// Whether OSM was searched for a misplaced `leisure=golf_course` element. Courses imported
    /// before the import looked for one are searched when they are opened.
    var checkedCourseElement = false

    /// A baseline of every course feature that has an OSM ID.
    ///
    /// - Parameter details: Known OSM details by OSM ID. Features not in it get an unknown
    ///   version, tags, and members.
    init(course: Course, details: [String: OSMElementDetails] = [:]) {
        for feature in course.features {
            guard let osmID = feature.osmID else { continue }
            entries[osmID] = Entry(feature: feature, osmID: osmID, details: details[osmID])
        }
    }

    /// The OSM IDs whose tags or members are unknown, such as entries saved before they were kept.
    var osmIDsWithUnknownDetails: [String] {
        entries.values.filter(\.detailsUnknown).map(\.osmID).sorted()
    }

    /// Sets the tags and members of entries whose details are unknown. Versions are not changed,
    /// since they are what the conflict check compares to.
    mutating func fillDetails(_ details: [String: OSMElementDetails]) {
        for (osmID, detail) in details where entries[osmID]?.detailsUnknown == true {
            entries[osmID]?.tags = detail.tags
            entries[osmID]?.members = detail.members
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
        // Baselines saved before course outline support have neither.
        misplacedCourseElement = try container.decodeIfPresent(MisplacedCourseElement.self, forKey: .misplacedCourseElement)
        pendingCourseOutline = try container.decodeIfPresent(PendingCourseOutline.self, forKey: .pendingCourseOutline)
        checkedCourseElement = try container.decodeIfPresent(Bool.self, forKey: .checkedCourseElement) ?? false
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
