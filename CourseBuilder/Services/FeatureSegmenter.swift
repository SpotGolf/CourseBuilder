import CoreGraphics
import Foundation
import CourseDataSwift

/// Detection settings for each feature type. See the auto polygon design doc.
struct SegmentationProfile {
    /// Default color distance for a pixel to join the region.
    let tolerance: Double
    /// Largest distance from the click the auto tool searches.
    let maxRadiusMeters: Double
    /// How far past the old outline Fit to Imagery searches.
    let fitMarginMeters: Double
    /// Largest distance between the simplified outline and the traced edge.
    let errorLimitMeters: Double
    /// Smallest distance between outline points.
    let minSpacingMeters: Double
    /// Point count above which the result is flagged.
    let safetyLimit: Int
    /// Fit to Imagery starts from the old outline and tells the feature apart from the band of
    /// ground just outside it (see `FeatureSegmenter.refine`), instead of growing from its colors.
    var refinesFit = false
    /// The auto tool splits each grown area into its two main color groups and keeps the one
    /// clicked (see `FeatureSegmenter.splitFromSurroundings`).
    var splitsGrownRegion = false
    /// Type rule every pixel must pass, given its NDVI and CIELAB lightness (0–100).
    let accepts: @Sendable (_ ndvi: Float, _ lightness: Float) -> Bool
}

/// Type rules come from NAIP pixels measured inside each feature type at Colorado National
/// (2023, 30 cm): median NDVI bunker 0.02, water 0.19, green 0.32, tee 0.39, fairway 0.44,
/// rough 0.46; median lightness green 51, tee 47, fairway 41, rough 40, water 32.
extension FeatureType {
    var segmentationProfile: SegmentationProfile {
        switch self {
        case .bunker:
            SegmentationProfile(tolerance: 3.0, maxRadiusMeters: 40, fitMarginMeters: 5,
                                errorLimitMeters: 0.3, minSpacingMeters: 0.75, safetyLimit: 80,
                                accepts: { ndvi, _ in ndvi < 0.15 })
        case .water:
            SegmentationProfile(tolerance: 3.0, maxRadiusMeters: 300, fitMarginMeters: 15,
                                errorLimitMeters: 1.0, minSpacingMeters: 2, safetyLimit: 120,
                                accepts: { ndvi, lightness in ndvi < 0.3 && lightness < 45 })
        case .green:
            SegmentationProfile(tolerance: 2.0, maxRadiusMeters: 60, fitMarginMeters: 5,
                                errorLimitMeters: 0.3, minSpacingMeters: 1, safetyLimit: 80, refinesFit: true,
                                accepts: { ndvi, lightness in ndvi > 0.2 && ndvi < 0.42 && lightness > 42 })
        case .tee:
            SegmentationProfile(tolerance: 2.5, maxRadiusMeters: 40, fitMarginMeters: 5,
                                errorLimitMeters: 0.3, minSpacingMeters: 1, safetyLimit: 30, refinesFit: true,
                                accepts: { ndvi, lightness in ndvi > 0.2 && lightness > 40 })
        case .fairway:
            SegmentationProfile(tolerance: 2.0, maxRadiusMeters: 400, fitMarginMeters: 15,
                                errorLimitMeters: 1.0, minSpacingMeters: 3, safetyLimit: 150,
                                refinesFit: true, splitsGrownRegion: true,
                                accepts: { ndvi, _ in ndvi > 0.25 })
        case .rough:
            SegmentationProfile(tolerance: 3.0, maxRadiusMeters: 400, fitMarginMeters: 15,
                                errorLimitMeters: 1.5, minSpacingMeters: 3, safetyLimit: 150,
                                refinesFit: true, splitsGrownRegion: true,
                                accepts: { ndvi, _ in ndvi > 0.2 })
        }
    }
}

/// A rectangle of patch pixels that detection works in.
struct PixelWindow: Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    /// The window covering the given patch-pixel rectangle, clipped to the patch.
    init(covering rect: CGRect, in patch: ImagePatch) {
        let minX = max(0, Int(rect.minX.rounded(.down)))
        let minY = max(0, Int(rect.minY.rounded(.down)))
        let maxX = min(patch.width, Int(rect.maxX.rounded(.up)))
        let maxY = min(patch.height, Int(rect.maxY.rounded(.up)))
        self.init(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A grid of on/off pixels, the same size as a `PixelWindow`.
struct BinaryMask: Equatable {
    let width: Int
    let height: Int
    var bits: [Bool]

    init(width: Int, height: Int, bits: [Bool]? = nil) {
        self.width = width
        self.height = height
        self.bits = bits ?? Array(repeating: false, count: width * height)
    }

    subscript(x: Int, y: Int) -> Bool {
        get { x >= 0 && y >= 0 && x < width && y < height && bits[y * width + x] }
        set { bits[y * width + x] = newValue }
    }

    var count: Int { bits.reduce(0) { $0 + ($1 ? 1 : 0) } }
    var isEmpty: Bool { !bits.contains(true) }

    /// Pixels whose centers are within `radius` pixels of `center`.
    static func circle(width: Int, height: Int, center: CGPoint, radius: Double) -> BinaryMask {
        var mask = BinaryMask(width: width, height: height)
        let r2 = radius * radius
        for y in 0..<height {
            let dy = Double(y) + 0.5 - Double(center.y)
            for x in 0..<width {
                let dx = Double(x) + 0.5 - Double(center.x)
                if dx * dx + dy * dy <= r2 { mask[x, y] = true }
            }
        }
        return mask
    }

    /// Pixels whose centers are inside the polygon (even-odd rule, scanline fill).
    static func polygon(width: Int, height: Int, points: [CGPoint]) -> BinaryMask {
        var mask = BinaryMask(width: width, height: height)
        guard points.count >= 3 else { return mask }
        for y in 0..<height {
            let sy = Double(y) + 0.5
            var crossings: [Double] = []
            for i in points.indices {
                let a = points[i], b = points[(i + 1) % points.count]
                let ay = Double(a.y), by = Double(b.y)
                if (ay <= sy && by > sy) || (by <= sy && ay > sy) {
                    let t = (sy - ay) / (by - ay)
                    crossings.append(Double(a.x) + t * (Double(b.x) - Double(a.x)))
                }
            }
            crossings.sort()
            var i = 0
            while i + 1 < crossings.count {
                let start = max(0, Int((crossings[i] - 0.5).rounded(.up)))
                let end = min(width - 1, Int((crossings[i + 1] - 0.5).rounded(.down)))
                if start <= end {
                    for x in start...end { mask[x, y] = true }
                }
                i += 2
            }
        }
        return mask
    }

    func union(_ other: BinaryMask) -> BinaryMask {
        BinaryMask(width: width, height: height, bits: zip(bits, other.bits).map { $0 || $1 })
    }

    func subtracting(_ other: BinaryMask) -> BinaryMask {
        BinaryMask(width: width, height: height, bits: zip(bits, other.bits).map { $0 && !$1 })
    }

    func intersection(_ other: BinaryMask) -> BinaryMask {
        BinaryMask(width: width, height: height, bits: zip(bits, other.bits).map { $0 && $1 })
    }

    /// Approximate distance in pixels from every pixel to the nearest pixel whose bit equals
    /// `target` (two-pass chamfer with steps of 1 and √2).
    func distance(to target: Bool) -> [Float] {
        let far = Float(width + height) * 2
        var d = bits.map { $0 == target ? Float(0) : far }
        let diagonal = Float(2).squareRoot()
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                var v = d[i]
                if x > 0 { v = min(v, d[i - 1] + 1) }
                if y > 0 {
                    v = min(v, d[i - width] + 1)
                    if x > 0 { v = min(v, d[i - width - 1] + diagonal) }
                    if x < width - 1 { v = min(v, d[i - width + 1] + diagonal) }
                }
                d[i] = v
            }
        }
        for y in stride(from: height - 1, through: 0, by: -1) {
            for x in stride(from: width - 1, through: 0, by: -1) {
                let i = y * width + x
                var v = d[i]
                if x < width - 1 { v = min(v, d[i + 1] + 1) }
                if y < height - 1 {
                    v = min(v, d[i + width] + 1)
                    if x < width - 1 { v = min(v, d[i + width + 1] + diagonal) }
                    if x > 0 { v = min(v, d[i + width - 1] + diagonal) }
                }
                d[i] = v
            }
        }
        return d
    }

    func dilated(by radius: Double) -> BinaryMask {
        guard radius > 0 else { return self }
        let d = distance(to: true)
        return BinaryMask(width: width, height: height, bits: d.map { Double($0) <= radius })
    }

    func eroded(by radius: Double) -> BinaryMask {
        guard radius > 0 else { return self }
        let d = distance(to: false)
        return BinaryMask(width: width, height: height, bits: d.map { Double($0) > radius })
    }

    /// Closes gaps narrower than about twice the radius.
    func closed(by radius: Double) -> BinaryMask {
        dilated(by: radius).eroded(by: radius)
    }

    /// Removes spurs and specks narrower than about twice the radius.
    func opened(by radius: Double) -> BinaryMask {
        eroded(by: radius).dilated(by: radius)
    }

    /// Turns on every off pixel that is not connected to the window's edge.
    func filledHoles() -> BinaryMask {
        var outside = BinaryMask(width: width, height: height)
        var stack: [Int] = []
        func push(_ x: Int, _ y: Int) {
            let i = y * width + x
            if !bits[i] && !outside.bits[i] {
                outside.bits[i] = true
                stack.append(i)
            }
        }
        for x in 0..<width {
            push(x, 0)
            push(x, height - 1)
        }
        for y in 0..<height {
            push(0, y)
            push(width - 1, y)
        }
        while let i = stack.popLast() {
            let x = i % width, y = i / width
            if x > 0 { push(x - 1, y) }
            if x < width - 1 { push(x + 1, y) }
            if y > 0 { push(x, y - 1) }
            if y < height - 1 { push(x, y + 1) }
        }
        return BinaryMask(width: width, height: height, bits: outside.bits.map { !$0 })
    }

    /// The 4-connected piece containing `start`.
    func component(containing start: Int) -> BinaryMask {
        var result = BinaryMask(width: width, height: height)
        guard bits.indices.contains(start), bits[start] else { return result }
        var stack = [start]
        result.bits[start] = true
        while let i = stack.popLast() {
            let x = i % width, y = i / width
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            where nx >= 0 && ny >= 0 && nx < width && ny < height {
                let n = ny * width + nx
                if bits[n] && !result.bits[n] {
                    result.bits[n] = true
                    stack.append(n)
                }
            }
        }
        return result
    }

    /// The largest connected piece that contains any of the seed pixels.
    func largestComponent(containingAnyOf seeds: [Int]) -> BinaryMask {
        var best = BinaryMask(width: width, height: height)
        var bestCount = 0
        var covered = BinaryMask(width: width, height: height)
        for seed in seeds where bits.indices.contains(seed) && bits[seed] && !covered.bits[seed] {
            let piece = component(containing: seed)
            covered = covered.union(piece)
            let count = piece.count
            if count > bestCount {
                best = piece
                bestCount = count
            }
        }
        return best
    }
}

/// Per-pixel values used for detection, for one window of a patch.
struct PixelValues {
    let window: PixelWindow
    /// CIELAB lightness, 0–100.
    var lightness: [Float]
    var a: [Float]
    var b: [Float]
    /// (NIR − red) / (NIR + red), −1–1.
    var ndvi: [Float]
    var valid: [Bool]

    init(patch: ImagePatch, window: PixelWindow) {
        self.window = window
        let count = window.width * window.height
        lightness = Array(repeating: 0, count: count)
        a = Array(repeating: 0, count: count)
        b = Array(repeating: 0, count: count)
        ndvi = Array(repeating: 0, count: count)
        valid = Array(repeating: false, count: count)
        for wy in 0..<window.height {
            for wx in 0..<window.width {
                let source = patch.index(window.x + wx, window.y + wy)
                let target = wy * window.width + wx
                guard patch.valid[source] else { continue }
                let lab = Self.lab(r: patch.red[source], g: patch.green[source], b: patch.blue[source])
                lightness[target] = lab.l
                a[target] = lab.a
                b[target] = lab.b
                let red = Float(patch.red[source]), nir = Float(patch.nir[source])
                ndvi[target] = red + nir > 0 ? (nir - red) / (nir + red) : 0
                valid[target] = true
            }
        }
    }

    func channels(at i: Int) -> [Float] {
        [lightness[i], a[i], b[i], ndvi[i]]
    }

    /// Each value averaged over the square of `radius` pixels around it (valid pixels only).
    func blurred(radius: Int) -> PixelValues {
        guard radius > 0 else { return self }
        var copy = self
        let w = window.width, h = window.height
        func boxMean(_ x: [Float]) -> [Float] {
            var sum = [Double](repeating: 0, count: (w + 1) * (h + 1))
            var count = [Int](repeating: 0, count: (w + 1) * (h + 1))
            for y in 0..<h {
                var rowSum = 0.0, rowCount = 0
                for col in 0..<w {
                    let i = y * w + col
                    if valid[i] { rowSum += Double(x[i]); rowCount += 1 }
                    let k = (y + 1) * (w + 1) + col + 1
                    sum[k] = sum[k - w - 1] + rowSum
                    count[k] = count[k - w - 1] + rowCount
                }
            }
            var out = x
            for y in 0..<h {
                for col in 0..<w where valid[y * w + col] {
                    let x0 = max(0, col - radius), x1 = min(w, col + radius + 1)
                    let y0 = max(0, y - radius), y1 = min(h, y + radius + 1)
                    let a = y1 * (w + 1) + x1, b = y0 * (w + 1) + x1, c = y1 * (w + 1) + x0, d = y0 * (w + 1) + x0
                    let n = count[a] - count[b] - count[c] + count[d]
                    if n > 0 { out[y * w + col] = Float((sum[a] - sum[b] - sum[c] + sum[d]) / Double(n)) }
                }
            }
            return out
        }
        copy.lightness = boxMean(lightness)
        copy.a = boxMean(a)
        copy.b = boxMean(b)
        copy.ndvi = boxMean(ndvi)
        return copy
    }

    /// sRGB bytes to CIELAB (D65 white).
    /// sRGB byte to linear light.
    private static let linearTable: [Float] = (0...255).map { v in
        let c = Float(v) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func lab(r: UInt8, g: UInt8, b: UInt8) -> (l: Float, a: Float, b: Float) {
        let lr = linearTable[Int(r)], lg = linearTable[Int(g)], lb = linearTable[Int(b)]
        let x = (0.4124 * lr + 0.3576 * lg + 0.1805 * lb) / 0.95047
        let y = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb
        let z = (0.0193 * lr + 0.1192 * lg + 0.9505 * lb) / 1.08883
        func f(_ t: Float) -> Float {
            t > 0.008856 ? cbrtf(t) : 7.787 * t + 16.0 / 116.0
        }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
}

/// Median and spread of the seed pixels' values, used to judge which pixels match.
struct SeedStatistics: Equatable {
    /// Smallest spread per channel (L, a, b, NDVI), so a flat seed does not reject everything.
    static let minimumSpread: [Float] = [3, 2, 2, 0.04]

    let median: [Float]
    let spread: [Float]

    init(median: [Float], spread: [Float]) {
        self.median = median
        self.spread = spread
    }

    init?(values: PixelValues, pixels: [Int]) {
        let usable = pixels.filter { values.valid.indices.contains($0) && values.valid[$0] }
        guard !usable.isEmpty else { return nil }
        var median: [Float] = []
        var spread: [Float] = []
        for channel in [values.lightness, values.a, values.b, values.ndvi].enumerated() {
            let samples = usable.map { channel.element[$0] }
            let m = Self.median(samples)
            let mad = Self.median(samples.map { abs($0 - m) })
            median.append(m)
            // 1.4826 × MAD estimates the standard deviation for normal data.
            spread.append(max(mad * 1.4826, Self.minimumSpread[channel.offset]))
        }
        self.init(median: median, spread: spread)
    }

    /// Root-mean-square of the per-channel distances in spread units.
    func distance(_ channels: [Float]) -> Float {
        var sum: Float = 0
        for c in 0..<4 {
            let z = (channels[c] - median[c]) / spread[c]
            sum += z * z
        }
        return (sum / 4).squareRoot()
    }

    /// Same as `distance(_:)` for one pixel of `values`, without building an array.
    func distance(values: PixelValues, at i: Int) -> Float {
        let zl = (values.lightness[i] - median[0]) / spread[0]
        let za = (values.a[i] - median[1]) / spread[1]
        let zb = (values.b[i] - median[2]) / spread[2]
        let zn = (values.ndvi[i] - median[3]) / spread[3]
        return ((zl * zl + za * za + zb * zb + zn * zn) / 4).squareRoot()
    }

    static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

/// Mean and variance of each value (L, a, b, NDVI) over a set of pixels.
struct PixelGaussian {
    let mean: [Float]
    let variance: [Float]

    init?(values: PixelValues, mask: BinaryMask) {
        var sum = [Double](repeating: 0, count: 4), sumSquares = [Double](repeating: 0, count: 4)
        var n = 0
        for i in mask.bits.indices where mask.bits[i] && values.valid[i] {
            let v = [values.lightness[i], values.a[i], values.b[i], values.ndvi[i]]
            for c in 0..<4 {
                sum[c] += Double(v[c])
                sumSquares[c] += Double(v[c] * v[c])
            }
            n += 1
        }
        guard n >= 20 else { return nil }
        mean = (0..<4).map { Float(sum[$0] / Double(n)) }
        variance = (0..<4).map { c in
            let m = sum[c] / Double(n)
            let floor = Double(SeedStatistics.minimumSpread[c] * SeedStatistics.minimumSpread[c]) / 4
            return Float(max(sumSquares[c] / Double(n) - m * m, floor))
        }
    }

    func logLikelihood(values: PixelValues, at i: Int) -> Float {
        let v = [values.lightness[i], values.a[i], values.b[i], values.ndvi[i]]
        var total: Float = 0
        for c in 0..<4 {
            let d = v[c] - mean[c]
            total -= d * d / (2 * variance[c]) + 0.5 * log(variance[c])
        }
        return total
    }
}

enum FeatureSegmenter {
    /// Splits a grown region into its two main color groups and keeps the group holding the
    /// seeds. Region growing often takes in nearby grass of a slightly different color (rough
    /// around a fairway, fairway around a green). The split is skipped when the region has no
    /// clear second group, so a uniform feature such as a bunker is left alone. A positive
    /// `bias` keeps more pixels in the feature.
    static func splitFromSurroundings(
        values: PixelValues,
        mask: BinaryMask,
        seeds: [Int],
        metersPerPixel: Double,
        bias: Float = 0,
        minimumSeparation: Float = 2.0,
        minimumOtherFraction: Double = 0.15
    ) -> BinaryMask {
        let smoothed = values.blurred(radius: max(1, Int((0.5 / metersPerPixel).rounded())))
        var seedBits = BinaryMask(width: mask.width, height: mask.height)
        for seed in seeds where seedBits.bits.indices.contains(seed) && mask.bits[seed] { seedBits.bits[seed] = true }
        guard var feature = PixelGaussian(values: smoothed, mask: seedBits) ?? PixelGaussian(values: smoothed, mask: mask) else {
            return mask
        }
        let pixels = mask.bits.indices.filter { mask.bits[$0] && values.valid[$0] }
        guard pixels.count >= 100 else { return mask }

        // Start the second group from the 30% of pixels least like the seeds.
        let ranked = pixels.sorted { feature.logLikelihood(values: smoothed, at: $0) < feature.logLikelihood(values: smoothed, at: $1) }
        var otherBits = BinaryMask(width: mask.width, height: mask.height)
        for i in ranked.prefix(max(20, ranked.count * 3 / 10)) { otherBits.bits[i] = true }
        guard var other = PixelGaussian(values: smoothed, mask: otherBits) else { return mask }

        var featureBits = mask
        for _ in 0..<6 {
            featureBits = BinaryMask(width: mask.width, height: mask.height)
            otherBits = BinaryMask(width: mask.width, height: mask.height)
            for i in pixels {
                if feature.logLikelihood(values: smoothed, at: i) + bias >= other.logLikelihood(values: smoothed, at: i) {
                    featureBits.bits[i] = true
                } else {
                    otherBits.bits[i] = true
                }
            }
            guard let f = PixelGaussian(values: smoothed, mask: featureBits),
                  let o = PixelGaussian(values: smoothed, mask: otherBits) else { return mask }
            feature = f
            other = o
        }

        let separation = (0..<4).reduce(Float(0)) { total, c in
            let d = feature.mean[c] - other.mean[c]
            return total + d * d / (feature.variance[c] + other.variance[c])
        }
        let otherFraction = Double(otherBits.count) / Double(pixels.count)
        guard separation >= minimumSeparation, otherFraction >= minimumOtherFraction else { return mask }
        let split = cleanUp(featureBits, metersPerPixel: metersPerPixel, seeds: seeds)
        return split.isEmpty ? mask : split
    }

    /// Re-labels pixels by whether they look more like the feature than like the ground just
    /// outside it, and repeats as the outline settles. Colors alone cannot tell fairway from
    /// rough (they differ by less than the tolerance), but each pixel is still closer to one
    /// group than the other. A positive `bias` keeps more pixels in the feature.
    static func refine(
        values: PixelValues,
        mask: BinaryMask,
        allowed: BinaryMask,
        seeds: [Int],
        profile: SegmentationProfile,
        metersPerPixel: Double,
        bias: Float = 0,
        iterations: Int = 4
    ) -> BinaryMask {
        let smoothed = values.blurred(radius: max(1, Int((0.5 / metersPerPixel).rounded())))
        var current = mask
        for _ in 0..<iterations {
            let inner = current.eroded(by: 1 / metersPerPixel)
            let core = inner.count >= 20 ? inner : current
            let band = current.dilated(by: 8 / metersPerPixel).subtracting(current.dilated(by: 1 / metersPerPixel))
            guard let feature = PixelGaussian(values: smoothed, mask: core),
                  let surroundings = PixelGaussian(values: smoothed, mask: band) else { break }
            var next = BinaryMask(width: mask.width, height: mask.height)
            for i in next.bits.indices
            where allowed.bits[i] && values.valid[i]
                && profile.accepts(values.ndvi[i], values.lightness[i])
                && feature.logLikelihood(values: smoothed, at: i) + bias > surroundings.logLikelihood(values: smoothed, at: i) {
                next.bits[i] = true
            }
            next = cleanUp(next, metersPerPixel: metersPerPixel, seeds: seeds)
            guard !next.isEmpty else { break }
            if next == current { break }
            current = next
        }
        return current
    }

    /// Flood fill (4 neighbors) from the seed pixels. A pixel joins when it is valid, inside
    /// `allowed`, passes the type rule, and is within `tolerance` of the seed statistics.
    static func grow(
        values: PixelValues,
        seeds: [Int],
        statistics: SeedStatistics,
        tolerance: Double,
        allowed: BinaryMask,
        profile: SegmentationProfile
    ) -> BinaryMask {
        let width = values.window.width, height = values.window.height
        var mask = BinaryMask(width: width, height: height)
        var visited = BinaryMask(width: width, height: height)
        let limit = Float(tolerance)

        func accepts(_ i: Int) -> Bool {
            values.valid[i] && allowed.bits[i]
                && profile.accepts(values.ndvi[i], values.lightness[i])
                && statistics.distance(values: values, at: i) <= limit
        }

        var stack: [Int] = []
        for seed in seeds where mask.bits.indices.contains(seed) && !visited.bits[seed] {
            visited.bits[seed] = true
            if accepts(seed) {
                mask.bits[seed] = true
                stack.append(seed)
            }
        }
        while let i = stack.popLast() {
            let x = i % width, y = i / width
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            where nx >= 0 && ny >= 0 && nx < width && ny < height {
                let n = ny * width + nx
                guard !visited.bits[n] else { continue }
                visited.bits[n] = true
                if accepts(n) {
                    mask.bits[n] = true
                    stack.append(n)
                }
            }
        }
        return mask
    }

    /// Closes small gaps, removes thin spurs, fills holes, and keeps the largest piece holding a seed.
    static func cleanUp(_ mask: BinaryMask, metersPerPixel: Double, seeds: [Int]) -> BinaryMask {
        let radius = 0.6 / metersPerPixel
        let closed = mask.closed(by: radius).opened(by: radius).filledHoles()
        // Closing can shift a thin seed area; fall back to the unclosed mask's seeds.
        let kept = closed.largestComponent(containingAnyOf: seeds)
        return kept.isEmpty ? mask.filledHoles().largestComponent(containingAnyOf: seeds) : kept
    }
}
