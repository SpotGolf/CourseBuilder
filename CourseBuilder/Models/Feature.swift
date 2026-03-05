import Foundation

enum FeatureType: String, Codable, CaseIterable, Hashable {
    case bunker
    case water
}

struct Feature: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let type: FeatureType
    var front: Coordinate
    var back: Coordinate

    init(id: UUID = UUID(), type: FeatureType, front: Coordinate, back: Coordinate) {
        self.id = id
        self.type = type
        self.front = front
        self.back = back
    }
}
