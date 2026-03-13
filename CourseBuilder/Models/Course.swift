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
    var name: String
    var color: String

    init(name: String, color: String) {
        self.name = name
        self.color = color
    }

    enum CodingKeys: String, CodingKey {
        case name, color
    }

    static func defaultColor(for teeName: String) -> String {
        switch teeName.lowercased() {
        case "black": "#000000"
        case "gold": "#FFD700"
        case "blue": "#0000FF"
        case "white": "#FFFFFF"
        case "silver": "#C0C0C0"
        case "red": "#FF0000"
        case "green": "#008000"
        default: "#808080"
        }
    }
}

struct CourseLocation: Codable, Equatable, Hashable {
    var address: String
    var city: String
    var state: String
    var country: String
    var coordinate: Coordinate

    enum CodingKeys: String, CodingKey {
        case address, city, state, country
        case coordinate = "coordinates"
    }
}

struct Course: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var clubName: String
    var golfCourseAPIIds: [Int]
    var location: CourseLocation
    var tees: [TeeDefinition]
    var features: [Feature]
    var subCourses: [SubCourse]

    var nextFeatureID: Int {
        (features.map(\.id).max() ?? 0) + 1
    }

    init(
        id: UUID = UUID(),
        name: String,
        clubName: String = "",
        golfCourseAPIIds: [Int] = [],
        location: CourseLocation,
        tees: [TeeDefinition] = [],
        features: [Feature] = [],
        subCourses: [SubCourse] = []
    ) {
        self.id = id
        self.name = name
        self.clubName = clubName
        self.golfCourseAPIIds = golfCourseAPIIds
        self.location = location
        self.tees = tees
        self.features = features
        self.subCourses = subCourses
    }
}
