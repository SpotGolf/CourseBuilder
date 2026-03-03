import Foundation
import MapKit
import AppKit

struct DetectedFeature {
    enum Kind {
        case green
        case teeBox
    }

    let kind: Kind
    let coordinate: Coordinate
    let confidence: Double
}

class FeatureDetector {

    // MARK: - Public

    func detect(in region: MKCoordinateRegion) async throws -> [DetectedFeature] {
        let snapshot = try await captureSnapshot(region: region)

        guard let cgImage = snapshot.image.cgImage(
            forProposedRect: nil, context: nil, hints: nil
        ) else {
            return []
        }

        let width = cgImage.width
        let height = cgImage.height

        guard let pixelData = extractPixelData(from: cgImage, width: width, height: height) else {
            return []
        }

        let greenPixels = scanForGreenPixels(pixelData: pixelData, width: width, height: height)
        let darkGreenPixels = greenPixels.filter { $0.kind == .green }
        let lightGreenPixels = greenPixels.filter { $0.kind == .teeBox }

        let greenClusters = clusterPixels(darkGreenPixels.map { $0.point }, minClusterSize: 200, maxGap: 20)
        let teeClusters = clusterPixels(lightGreenPixels.map { $0.point }, minClusterSize: 80, maxGap: 15)

        var features: [DetectedFeature] = []

        for cluster in greenClusters {
            let centroid = clusterCentroid(cluster)
            let coord = pixelToCoordinate(
                pixelX: centroid.x, pixelY: centroid.y,
                imageWidth: Double(width), imageHeight: Double(height),
                region: region
            )
            let confidence = min(Double(cluster.count) / 1000.0, 1.0)
            features.append(DetectedFeature(kind: .green, coordinate: coord, confidence: confidence))
        }

        for cluster in teeClusters {
            let centroid = clusterCentroid(cluster)
            let coord = pixelToCoordinate(
                pixelX: centroid.x, pixelY: centroid.y,
                imageWidth: Double(width), imageHeight: Double(height),
                region: region
            )
            let confidence = min(Double(cluster.count) / 500.0, 1.0)
            features.append(DetectedFeature(kind: .teeBox, coordinate: coord, confidence: confidence))
        }

        return features
    }

    // MARK: - Snapshot Capture

    private func captureSnapshot(region: MKCoordinateRegion) async throws -> MKMapSnapshotter.Snapshot {
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = CGSize(width: 1024, height: 1024)
        options.mapType = .satellite
        // scale is set automatically by the system based on display

        let snapshotter = MKMapSnapshotter(options: options)
        return try await snapshotter.start()
    }

    // MARK: - Pixel Extraction

    private func extractPixelData(from cgImage: CGImage, width: Int, height: Int) -> [UInt8]? {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = height * bytesPerRow

        var pixelData = [UInt8](repeating: 0, count: totalBytes)

        guard let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &pixelData,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelData
    }

    // MARK: - Color Scanning

    private struct ClassifiedPixel {
        let point: PixelPoint
        let kind: DetectedFeature.Kind
    }

    private struct PixelPoint: Hashable {
        let x: Int
        let y: Int
    }

    private func scanForGreenPixels(pixelData: [UInt8], width: Int, height: Int) -> [ClassifiedPixel] {
        var results: [ClassifiedPixel] = []
        let bytesPerPixel = 4

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * bytesPerPixel
                let r = CGFloat(pixelData[offset]) / 255.0
                let g = CGFloat(pixelData[offset + 1]) / 255.0
                let b = CGFloat(pixelData[offset + 2]) / 255.0

                let color = NSColor(red: r, green: g, blue: b, alpha: 1.0)
                var hue: CGFloat = 0
                var saturation: CGFloat = 0
                var brightness: CGFloat = 0
                color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)

                let hueDegrees = hue * 360.0
                let point = PixelPoint(x: x, y: y)

                // Dark green pixels (golf greens): hue 80-160, saturation > 0.3, brightness 0.3-0.7
                if hueDegrees >= 80 && hueDegrees <= 160
                    && saturation > 0.3
                    && brightness >= 0.3 && brightness <= 0.7 {
                    results.append(ClassifiedPixel(point: point, kind: .green))
                }
                // Light green pixels (tee boxes): hue 80-160, saturation > 0.2, brightness 0.5-0.85
                else if hueDegrees >= 80 && hueDegrees <= 160
                    && saturation > 0.2
                    && brightness >= 0.5 && brightness <= 0.85 {
                    results.append(ClassifiedPixel(point: point, kind: .teeBox))
                }
            }
        }

        return results
    }

    // MARK: - Clustering

    private func clusterPixels(_ pixels: [PixelPoint], minClusterSize: Int, maxGap: Int) -> [[PixelPoint]] {
        guard !pixels.isEmpty else { return [] }

        // Build spatial hash map: divide image into cells of size maxGap
        var grid: [PixelPoint: [PixelPoint]] = [:]
        for pixel in pixels {
            let cellKey = PixelPoint(x: pixel.x / maxGap, y: pixel.y / maxGap)
            grid[cellKey, default: []].append(pixel)
        }

        var visited = Set<PixelPoint>()
        var clusters: [[PixelPoint]] = []
        let searchRadius = maxGap * 2

        for pixel in pixels {
            guard !visited.contains(pixel) else { continue }

            // BFS from this pixel
            var cluster: [PixelPoint] = []
            var queue: [PixelPoint] = [pixel]
            visited.insert(pixel)

            while !queue.isEmpty {
                let current = queue.removeFirst()
                cluster.append(current)

                // Check neighboring cells within search radius
                let minCellX = (current.x - searchRadius) / maxGap
                let maxCellX = (current.x + searchRadius) / maxGap
                let minCellY = (current.y - searchRadius) / maxGap
                let maxCellY = (current.y + searchRadius) / maxGap

                for cellY in minCellY...maxCellY {
                    for cellX in minCellX...maxCellX {
                        let cellKey = PixelPoint(x: cellX, y: cellY)
                        guard let cellPixels = grid[cellKey] else { continue }

                        for neighbor in cellPixels {
                            guard !visited.contains(neighbor) else { continue }

                            // Manhattan distance check
                            let dx = abs(neighbor.x - current.x)
                            let dy = abs(neighbor.y - current.y)
                            if dx + dy <= searchRadius {
                                visited.insert(neighbor)
                                queue.append(neighbor)
                            }
                        }
                    }
                }
            }

            if cluster.count >= minClusterSize {
                clusters.append(cluster)
            }
        }

        return clusters
    }

    private func clusterCentroid(_ cluster: [PixelPoint]) -> (x: Double, y: Double) {
        let sumX = cluster.reduce(0) { $0 + $1.x }
        let sumY = cluster.reduce(0) { $0 + $1.y }
        let count = Double(cluster.count)
        return (Double(sumX) / count, Double(sumY) / count)
    }

    // MARK: - Coordinate Conversion

    private func pixelToCoordinate(
        pixelX: Double,
        pixelY: Double,
        imageWidth: Double,
        imageHeight: Double,
        region: MKCoordinateRegion
    ) -> Coordinate {
        let lat = region.center.latitude + region.span.latitudeDelta * (0.5 - pixelY / imageHeight)
        let lon = region.center.longitude + region.span.longitudeDelta * (pixelX / imageWidth - 0.5)
        return Coordinate(latitude: lat, longitude: lon)
    }
}
