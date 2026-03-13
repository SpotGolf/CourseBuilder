import Foundation

struct Hole: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let number: Int
    var par: Int
    var maleHandicap: Int
    var femaleHandicap: Int
    var yardages: [String: Int]
    var featureIDs: [Int]
    var centerline: [Coordinate]

    init(
        id: UUID = UUID(),
        number: Int,
        par: Int,
        maleHandicap: Int = 0,
        femaleHandicap: Int = 0,
        yardages: [String: Int] = [:],
        featureIDs: [Int] = [],
        centerline: [Coordinate] = []
    ) {
        self.id = id
        self.number = number
        self.par = par
        self.maleHandicap = maleHandicap
        self.femaleHandicap = femaleHandicap
        self.yardages = yardages
        self.featureIDs = featureIDs
        self.centerline = centerline
    }

    func renumbered(to newNumber: Int) -> Hole {
        Hole(
            number: newNumber,
            par: par,
            maleHandicap: maleHandicap,
            femaleHandicap: femaleHandicap,
            yardages: yardages,
            featureIDs: featureIDs,
            centerline: centerline
        )
    }

    /// Split holes into sub-courses by dividing evenly among the given names.
    /// If there are fewer holes than names, returns a single group.
    /// All holes are renumbered 1-based within each group.
    static func splitIntoSubCourses(_ holes: [Hole], names: [String]) -> [(name: String, holes: [Hole])] {
        guard holes.count > 1, names.count >= 2, holes.count % names.count == 0 else {
            let renumbered = holes.enumerated().map { $1.renumbered(to: $0 + 1) }
            return [(names.first ?? "Front", renumbered)]
        }

        let groupSize = holes.count / names.count
        guard groupSize > 0 else {
            let renumbered = holes.enumerated().map { $1.renumbered(to: $0 + 1) }
            return [(names.first ?? "Front", renumbered)]
        }

        var groups: [(name: String, holes: [Hole])] = []
        for (i, name) in names.enumerated() {
            let start = i * groupSize
            let end = (i == names.count - 1) ? holes.count : start + groupSize
            let slice = Array(holes[start..<end])
            let renumbered = slice.enumerated().map { $1.renumbered(to: $0 + 1) }
            groups.append((name, renumbered))
        }
        return groups
    }
}
