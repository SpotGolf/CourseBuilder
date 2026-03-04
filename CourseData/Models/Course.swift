import Foundation

struct TeeInformation: Codable, Equatable, Hashable {
    var courseRating: Double?
    var slopeRating: Int?
    var frontCourseRating: Double?
    var frontSlopeRating: Int?
    var backCourseRating: Double?
    var backSlopeRating: Int?
    var totalYards: Int?
    var parTotal: Int?
}

struct TeeDefinition: Codable, Equatable, Hashable, Identifiable {
    var id: String { name }
    let name: String
    let color: String
    var male: TeeInformation?
    var female: TeeInformation?
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
    var golfCourseAPIId: Int?
    var location: CourseLocation
    var tees: [TeeDefinition]
    var holes: [Hole]

    init(
        id: UUID = UUID(),
        name: String,
        clubName: String = "",
        golfCourseAPIId: Int? = nil,
        location: CourseLocation,
        tees: [TeeDefinition] = [],
        holes: [Hole] = []
    ) {
        self.id = id
        self.name = name
        self.clubName = clubName
        self.golfCourseAPIId = golfCourseAPIId
        self.location = location
        self.tees = tees
        self.holes = holes
    }
}
