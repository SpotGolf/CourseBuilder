import Foundation

struct TeeInformation: Codable, Equatable, Hashable {
    var rating: Double?
    var slope: Int?
    var totalYards: Int?
    var parTotal: Int?
}

struct SubCourseTee: Codable, Equatable, Hashable {
    var male: TeeInformation?
    var female: TeeInformation?
}

struct SubCourse: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var holes: [Hole]
    var tees: [String: SubCourseTee]

    init(
        id: UUID = UUID(),
        name: String,
        holes: [Hole] = [],
        tees: [String: SubCourseTee] = [:]
    ) {
        self.id = id
        self.name = name
        self.holes = holes
        self.tees = tees
    }
}

struct TeeDefinition: Codable, Equatable, Hashable, Identifiable {
    var id: String { name }
    let name: String
    let color: String
}

struct CourseLocation: Codable, Equatable, Hashable {
    var address: String
    var city: String
    var state: String
    var country: String
    var coordinate: Coordinate
}

struct Course: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var clubName: String
    var golfCourseAPIIds: [Int]
    var location: CourseLocation
    var tees: [TeeDefinition]
    var subCourses: [SubCourse]

    init(
        id: UUID = UUID(),
        name: String,
        clubName: String = "",
        golfCourseAPIIds: [Int] = [],
        location: CourseLocation,
        tees: [TeeDefinition] = [],
        subCourses: [SubCourse] = []
    ) {
        self.id = id
        self.name = name
        self.clubName = clubName
        self.golfCourseAPIIds = golfCourseAPIIds
        self.location = location
        self.tees = tees
        self.subCourses = subCourses
    }
}
