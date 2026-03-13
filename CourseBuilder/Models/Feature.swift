import Foundation

enum FeatureType: String, Codable, CaseIterable, Hashable {
    case fairway
    case green
    case tee
    case bunker
    case water
    case rough
}

struct Feature: Identifiable, Codable, Equatable, Hashable {
    let id: Int
    let type: FeatureType
    var polygon: [Coordinate]

    init(id: Int, type: FeatureType, polygon: [Coordinate]) {
        self.id = id
        self.type = type
        self.polygon = polygon
    }
}
