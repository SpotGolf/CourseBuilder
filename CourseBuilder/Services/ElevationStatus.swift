import Foundation
import CourseDataSwift

/// What USGS is known not to have for a course, so the app does not keep asking for it.
///
/// A point or green is listed by where it is. Once it moves it is no longer listed, and is
/// asked for again.
struct ElevationStatus: Codable, Equatable {
    /// The points USGS has no elevation for. They are left with no elevation.
    var pointsWithoutData: Set<ElevationUpdater.Location> = []
    /// The greens USGS has no 1 m lidar data for, by feature ID, with the positions of the
    /// polygon they were sampled for. They are left with no surface.
    var greensWithoutData: [Int: [ElevationUpdater.Location]] = [:]

    var isEmpty: Bool {
        pointsWithoutData.isEmpty && greensWithoutData.isEmpty
    }

    /// Whether the green is known to have no lidar data, as it is drawn now.
    func hasNoData(forGreen green: Feature) -> Bool {
        greensWithoutData[green.id] == GreenSurfaceUpdater.positions(of: green.polygon)
    }

    /// Forgets points and greens that are no longer in the course as they were: deleted, moved,
    /// or given an elevation or a surface.
    mutating func prune(to course: Course) {
        pointsWithoutData.formIntersection(ElevationUpdater.missingCoordinates(in: course).map(ElevationUpdater.Location.init))
        let greens = Dictionary(
            course.features.filter { $0.type == .green && $0.surface == nil }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        greensWithoutData = greensWithoutData.filter { id, positions in
            greens[id].map { GreenSurfaceUpdater.positions(of: $0.polygon) == positions } ?? false
        }
    }
}

/// Reads and writes each course's ``ElevationStatus``. They live outside the courses folder,
/// since ``CourseStore`` loads every `.json` file there as a course.
struct ElevationStatusStore {
    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directory = appSupport.appendingPathComponent("CourseBuilder/elevation-status", isDirectory: true)
        }
    }

    /// The course's status. Empty when nothing was saved or the file cannot be read.
    func load(courseID: UUID) -> ElevationStatus {
        guard let data = try? Data(contentsOf: fileURL(for: courseID)),
              let status = try? JSONDecoder().decode(ElevationStatus.self, from: data) else {
            return ElevationStatus()
        }
        return status
    }

    /// Saves the status. An empty status removes the file.
    func save(_ status: ElevationStatus, courseID: UUID) throws {
        let url = fileURL(for: courseID)
        guard !status.isEmpty else {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(status).write(to: url, options: .atomic)
    }

    private func fileURL(for courseID: UUID) -> URL {
        directory.appendingPathComponent("\(courseID).json")
    }
}
