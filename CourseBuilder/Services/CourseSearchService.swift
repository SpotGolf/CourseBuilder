import Foundation
import MapKit

struct MapSearchResult: Identifiable {
    let id = UUID()
    let name: String
    let coordinate: Coordinate
    let region: MKCoordinateRegion
    let mapItem: MKMapItem
}

class CourseSearchService {
    func search(query: String) async throws -> [MapSearchResult] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if #available(macOS 15.0, *) {
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.golf])
        }

        let search = MKLocalSearch(request: request)
        let response = try await search.start()

        return response.mapItems.compactMap { item in
            guard let name = item.name else { return nil }
            let coord = item.placemark.coordinate
            let region = MKCoordinateRegion(
                center: coord,
                latitudinalMeters: 2000,
                longitudinalMeters: 2000
            )
            return MapSearchResult(
                name: name,
                coordinate: Coordinate(coord),
                region: region,
                mapItem: item
            )
        }
    }
}
