import Foundation

struct Green: Codable, Equatable, Hashable {
    var front: Coordinate
    var middle: Coordinate
    var back: Coordinate
}

struct Hole: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let number: Int
    var par: Int
    var maleHandicap: Int
    var femaleHandicap: Int
    var yardages: [String: Int]
    var tees: [String: Coordinate]
    var green: Green?
    var features: [Feature]

    init(
        id: UUID = UUID(),
        number: Int,
        par: Int,
        maleHandicap: Int = 0,
        femaleHandicap: Int = 0,
        yardages: [String: Int] = [:],
        tees: [String: Coordinate] = [:],
        green: Green? = nil,
        features: [Feature] = []
    ) {
        self.id = id
        self.number = number
        self.par = par
        self.maleHandicap = maleHandicap
        self.femaleHandicap = femaleHandicap
        self.yardages = yardages
        self.tees = tees
        self.green = green
        self.features = features
    }
}
