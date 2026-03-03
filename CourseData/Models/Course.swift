import Foundation

enum Gender: String, Codable {
    case male
    case female
}

struct TeeDefinition: Codable, Equatable, Identifiable {
    var id: String { name }
    let name: String
    let color: String
    let gender: Gender
    var rating: Double?
    var slope: Int?
}

struct CourseLocation: Codable, Equatable {
    var city: String
    var state: String
    var coordinate: Coordinate
}

struct Course: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var location: CourseLocation
    var tees: [TeeDefinition]
    var holes: [Hole]

    init(
        id: String,
        name: String,
        location: CourseLocation,
        tees: [TeeDefinition] = [],
        holes: [Hole] = []
    ) {
        self.id = id
        self.name = name
        self.location = location
        self.tees = tees
        self.holes = holes
    }

    static func generateID(name: String, city: String, state: String) -> String {
        "\(name)-\(city)-\(state)"
            .lowercased()
            .replacing(/[^a-z0-9\s-]/, with: "")
            .replacing(/\s+/, with: "-")
    }
}
