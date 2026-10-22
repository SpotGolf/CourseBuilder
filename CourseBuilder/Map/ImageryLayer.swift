import Foundation

/// The imagery the map editor can show under the course.
///
/// Every layer must be licensed for tracing into OpenStreetMap. Esri gives OSM explicit
/// permission (https://wiki.openstreetmap.org/wiki/Esri). NAIP is public domain.
enum ImageryLayer: String, CaseIterable, Identifiable {
    case esri
    case naip

    var id: String { rawValue }

    var name: String {
        switch self {
        case .esri: "Esri World Imagery"
        case .naip: "USDA NAIP"
        }
    }

    var shortName: String {
        switch self {
        case .esri: "esri"
        case .naip: "naip"
        }
    }

    /// Lowest tile zoom the layer is drawn at.
    var minZoom: Int {
        switch self {
        case .esri: 0
        // NAIP is registered per area, so zoomed-out views would register too many areas.
        case .naip: 14
        }
    }

    /// Highest tile zoom requested. Above it, tiles are scaled up.
    var maxZoom: Int {
        switch self {
        case .esri: 22
        case .naip: 19
        }
    }

    /// The credit the layer's terms require on the map.
    var attribution: String {
        switch self {
        case .esri: "Powered by Esri · Source: Esri, Vantor, Earthstar Geographics, and the GIS User Community"
        case .naip: "Imagery: U.S. Department of Agriculture (NAIP)"
        }
    }

    var termsURL: URL {
        switch self {
        case .esri: URL(string: "https://wiki.openstreetmap.org/wiki/Esri")!
        case .naip: URL(string: "https://naip-usdaonline.hub.arcgis.com/")!
        }
    }

    var termsLabel: String {
        switch self {
        case .esri: "Terms & Feedback"
        case .naip: "About NAIP"
        }
    }

    var next: ImageryLayer {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    /// Esri tile URL. `blankTile=false` makes the server answer 404 instead of sending a
    /// "Map data not yet available" image where it has no imagery at that zoom.
    static func esriTileURL(zoom: Int, x: Int, y: Int) -> URL {
        URL(string: "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/\(zoom)/\(y)/\(x)?blankTile=false")!
    }
}
