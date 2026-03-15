# OSM Importer Redesign Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite `OSMImporter.applyParsedResult` to use type-aware, directional feature association with exclusive green anchoring and yardage-clustered tee name assignment.

**Architecture:** The importer runs in four phases: (1) anchor greens 1:1 to holes via centerline endpoint proximity, (2) anchor tee polygons to holes — tees must be within 35 yards laterally of the centerline AND forward of the start (using the directional filter), which allows tees spread along the hole's length (e.g., junior tees 200 yards ahead) while excluding tees from adjacent holes, (3) associate remaining features via nearest-centerline with the same directional filter, (4) assign tee names per-hole using only that hole's features — distance-rank zipping (equal counts) or yardage gap clustering (unequal counts). A shared `isForwardOfStart` helper enforces the directional constraint by computing the dot product of the feature's position relative to the centerline start against the centerline's overall direction vector (start → end).

**Tech Stack:** Swift, CoreLocation, XCTest

---

## Chunk 1: Core Rewrite

### Task 1: Add `isForwardOfStart` helper

The directional filter. Given a point and a centerline, returns true if the point is not behind the centerline's start. Computes the dot product of `(point - start)` with the direction vector `(end - start)`. A dot product >= 0 means the point is forward of (or at) the start.

**Files:**
- Modify: `CourseBuilder/Services/OSMImporter.swift`
- Modify: `CourseBuilderTests/Services/OSMImporterTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// In OSMImporterTests.swift, add new MARK section:

// MARK: - Directional Filter

func testPointForwardOfCenterlineStart() {
    // Centerline goes south-east: (39.790, -74.960) → (39.784, -74.954)
    let centerline = [
        Coordinate(latitude: 39.790, longitude: -74.960),
        Coordinate(latitude: 39.784, longitude: -74.954)
    ]
    // Point along the centerline direction (south-east of start)
    let forward = Coordinate(latitude: 39.788, longitude: -74.958)
    XCTAssertTrue(OSMImporter.isForwardOfStart(point: forward, centerline: centerline))
}

func testPointBehindCenterlineStart() {
    let centerline = [
        Coordinate(latitude: 39.790, longitude: -74.960),
        Coordinate(latitude: 39.784, longitude: -74.954)
    ]
    // Point behind start (north-west of start, opposite to centerline direction)
    let behind = Coordinate(latitude: 39.792, longitude: -74.962)
    XCTAssertFalse(OSMImporter.isForwardOfStart(point: behind, centerline: centerline))
}

func testPointPerpendicularToCenterline() {
    let centerline = [
        Coordinate(latitude: 39.790, longitude: -74.960),
        Coordinate(latitude: 39.784, longitude: -74.954)
    ]
    // Point perpendicular to centerline at start — should be forward (dot ≈ 0, we allow it)
    // Move perpendicular: direction is (-0.006, +0.006), perpendicular is (+0.006, +0.006)
    let perp = Coordinate(latitude: 39.791, longitude: -74.959)
    XCTAssertTrue(OSMImporter.isForwardOfStart(point: perp, centerline: centerline))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | grep -E "isForwardOfStart|error:"`
Expected: Compilation error — `isForwardOfStart` does not exist.

- [ ] **Step 3: Implement `isForwardOfStart`**

Add to `OSMImporter` (inside the `enum OSMImporter` block, as a `static` method):

```swift
/// Returns true if `point` is not behind the centerline's start.
/// Uses the dot product of (point - start) against the centerline direction (start → end).
/// Points at or forward of the start (dot product >= 0) return true.
/// Returns true if the centerline has fewer than 2 points (no direction to check).
static func isForwardOfStart(point: Coordinate, centerline: [Coordinate]) -> Bool {
    guard centerline.count >= 2 else { return true }
    let start = centerline.first!
    let end = centerline.last!
    // Direction vector (in lat/lon space)
    let dx = end.longitude - start.longitude
    let dy = end.latitude - start.latitude
    // Vector from start to point
    let px = point.longitude - start.longitude
    let py = point.latitude - start.latitude
    // Dot product
    return (px * dx + py * dy) >= 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | grep -E "testPoint|Executed"`
Expected: All 3 new tests PASS.

- [ ] **Step 5: Commit**

```bash
git add CourseBuilder/Services/OSMImporter.swift CourseBuilderTests/Services/OSMImporterTests.swift
git commit -m "feat: add isForwardOfStart directional filter for OSM import"
```

---

### Task 2: Rewrite `applyParsedResult` — Phase 1 (anchor greens) and Phase 2 (anchor tees)

Replace the current monolithic feature association with type-specific phases. Phase 1 anchors one green per hole using the centerline endpoint. Phase 2 finds tee polygons near the centerline start.

**Files:**
- Modify: `CourseBuilder/Services/OSMImporter.swift`
- Modify: `CourseBuilderTests/Services/OSMImporterTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// MARK: - Phase-Based Association

func testGreenAnchoredToClosestCenterlineEnd() {
    // Two holes, two greens. Each green is near one hole's centerline end.
    let green1 = OverpassAPIClient.ParsedFeature(
        type: .green,
        polygon: [
            Coordinate(latitude: 39.784, longitude: -74.955),
            Coordinate(latitude: 39.784, longitude: -74.953),
            Coordinate(latitude: 39.785, longitude: -74.953),
            Coordinate(latitude: 39.785, longitude: -74.955)
        ]
    )
    let green2 = OverpassAPIClient.ParsedFeature(
        type: .green,
        polygon: [
            Coordinate(latitude: 39.790, longitude: -74.945),
            Coordinate(latitude: 39.790, longitude: -74.943),
            Coordinate(latitude: 39.791, longitude: -74.943),
            Coordinate(latitude: 39.791, longitude: -74.945)
        ]
    )
    let cl1 = OverpassAPIClient.ParsedCenterline(
        holeNumber: 1,
        coordinates: [
            Coordinate(latitude: 39.790, longitude: -74.960),
            Coordinate(latitude: 39.7845, longitude: -74.954)
        ]
    )
    let cl2 = OverpassAPIClient.ParsedCenterline(
        holeNumber: 2,
        coordinates: [
            Coordinate(latitude: 39.784, longitude: -74.950),
            Coordinate(latitude: 39.7905, longitude: -74.944)
        ]
    )

    let parsed = OverpassAPIClient.ParsedResult(
        features: [green1, green2],
        centerlines: [cl1, cl2],
        courseBoundary: nil
    )

    var course = Course(
        name: "Test",
        location: CourseLocation(address: "", city: "", state: "", country: "",
                                 coordinate: Coordinate(latitude: 39.787, longitude: -74.950)),
        subCourses: [
            SubCourse(name: "Front", holes: [Hole(number: 1, par: 4), Hole(number: 2, par: 4)])
        ]
    )

    OSMImporter.applyParsedResult(parsed, to: &course)

    let hole1 = course.subCourses[0].holes[0]
    let hole2 = course.subCourses[0].holes[1]
    let green1ID = course.features.first(where: {
        $0.type == .green && $0.polygon[0].latitude < 39.786
    })!.id
    let green2ID = course.features.first(where: {
        $0.type == .green && $0.polygon[0].latitude > 39.789
    })!.id

    // Green 1 (near 39.784) should anchor to hole 1 (centerline ends at 39.7845)
    XCTAssertTrue(hole1.features.contains(green1ID))
    XCTAssertFalse(hole1.features.contains(green2ID))
    // Green 2 (near 39.790) should anchor to hole 2 (centerline ends at 39.7905)
    XCTAssertTrue(hole2.features.contains(green2ID))
    XCTAssertFalse(hole2.features.contains(green1ID))
}

func testTeesAnchoredAlongCenterline() {
    // Three tee polygons: two near the start, one far forward along the centerline
    // (simulating a junior tee 200+ yards ahead), and one far away laterally (different hole).
    // Centerline goes SE: (39.790, -74.960) → (39.787, -74.957) → (39.7845, -74.954)
    let teeAtStart1 = OverpassAPIClient.ParsedFeature(
        type: .tee,
        polygon: [
            Coordinate(latitude: 39.7898, longitude: -74.9602),
            Coordinate(latitude: 39.7898, longitude: -74.9598),
            Coordinate(latitude: 39.7902, longitude: -74.9598),
            Coordinate(latitude: 39.7902, longitude: -74.9602)
        ]
    )
    let teeAtStart2 = OverpassAPIClient.ParsedFeature(
        type: .tee,
        polygon: [
            Coordinate(latitude: 39.7895, longitude: -74.9604),
            Coordinate(latitude: 39.7895, longitude: -74.9600),
            Coordinate(latitude: 39.7899, longitude: -74.9600),
            Coordinate(latitude: 39.7899, longitude: -74.9604)
        ]
    )
    // Junior tee: far forward along the centerline, near the midpoint (39.787, -74.957)
    // Within 35 yards laterally of the centerline, forward of start
    let teeJunior = OverpassAPIClient.ParsedFeature(
        type: .tee,
        polygon: [
            Coordinate(latitude: 39.7868, longitude: -74.9572),
            Coordinate(latitude: 39.7868, longitude: -74.9568),
            Coordinate(latitude: 39.7872, longitude: -74.9568),
            Coordinate(latitude: 39.7872, longitude: -74.9572)
        ]
    )
    // Tee from a different hole — laterally far from this centerline
    let teeDifferentHole = OverpassAPIClient.ParsedFeature(
        type: .tee,
        polygon: [
            Coordinate(latitude: 39.780, longitude: -74.950),
            Coordinate(latitude: 39.780, longitude: -74.949),
            Coordinate(latitude: 39.781, longitude: -74.949),
            Coordinate(latitude: 39.781, longitude: -74.950)
        ]
    )
    let green = OverpassAPIClient.ParsedFeature(
        type: .green,
        polygon: [
            Coordinate(latitude: 39.784, longitude: -74.955),
            Coordinate(latitude: 39.784, longitude: -74.953),
            Coordinate(latitude: 39.785, longitude: -74.953),
            Coordinate(latitude: 39.785, longitude: -74.955)
        ]
    )
    let cl = OverpassAPIClient.ParsedCenterline(
        holeNumber: 1,
        coordinates: [
            Coordinate(latitude: 39.790, longitude: -74.960),
            Coordinate(latitude: 39.787, longitude: -74.957),
            Coordinate(latitude: 39.7845, longitude: -74.954)
        ]
    )

    let parsed = OverpassAPIClient.ParsedResult(
        features: [teeAtStart1, teeAtStart2, teeJunior, teeDifferentHole, green],
        centerlines: [cl],
        courseBoundary: nil
    )

    var course = Course(
        name: "Test",
        location: CourseLocation(address: "", city: "", state: "", country: "",
                                 coordinate: Coordinate(latitude: 39.787, longitude: -74.957)),
        subCourses: [
            SubCourse(name: "Front", holes: [Hole(number: 1, par: 4)])
        ]
    )

    OSMImporter.applyParsedResult(parsed, to: &course)

    let hole = course.subCourses[0].holes[0]
    let differentHoleTeeID = course.features.first(where: {
        $0.type == .tee && $0.polygon[0].latitude < 39.785
    })!.id

    // Three tees along the centerline should be on hole 1, the far lateral one should not
    let holeTeeIDs = hole.features.filter { id in
        course.features.first { $0.id == id }?.type == .tee
    }
    XCTAssertEqual(holeTeeIDs.count, 3)
    XCTAssertFalse(holeTeeIDs.contains(differentHoleTeeID))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | grep -E "testGreen|testTees|error:"`
Expected: FAIL — current association logic doesn't match the expected behavior.

- [ ] **Step 3: Rewrite `applyParsedResult` with Phases 1 and 2**

Replace the entire body of `applyParsedResult` and remove `assignTeeNames` and `associateViaProximity`. The full rewritten `OSMImporter` is below. Note: `shouldAssociate`, `distanceToPolyline`, `distanceToSegment`, and `isForwardOfStart` remain unchanged.

```swift
static func applyParsedResult(_ result: OverpassAPIClient.ParsedResult, to course: inout Course) {
    // Create Feature objects with auto-incremented IDs
    var nextID = course.nextFeatureID
    var features: [Feature] = []
    for parsed in result.features {
        features.append(Feature(id: nextID, type: parsed.type, polygon: parsed.polygon))
        nextID += 1
    }
    course.features.append(contentsOf: features)

    // Build a flat list of (subCourseIndex, holeIndex, globalHoleNumber) for all holes
    var holeSlots: [(sub: Int, hole: Int, global: Int)] = []
    var globalNumber = 0
    for subIdx in course.subCourses.indices {
        for holeIdx in course.subCourses[subIdx].holes.indices {
            globalNumber += 1
            holeSlots.append((subIdx, holeIdx, globalNumber))
        }
    }

    // Assign centerlines to holes by matching OSM hole numbers to global numbers
    for slot in holeSlots {
        if let cl = result.centerlines.first(where: { $0.holeNumber == slot.global }) {
            course.subCourses[slot.sub].holes[slot.hole].centerline = cl.coordinates
        }
    }

    let holesWithCenterlines = holeSlots.filter { slot in
        !course.subCourses[slot.sub].holes[slot.hole].centerline.isEmpty
    }

    guard !holesWithCenterlines.isEmpty else {
        associateViaProximity(features: features, course: &course, holeSlots: holeSlots)
        return
    }

    let metersPerYard = 0.9144
    let thresholdMeters = 35.0 * metersPerYard

    // Phase 1: Anchor greens — each green goes to the hole whose centerline
    // endpoint is closest. Greedy 1:1 assignment (one green per hole).
    let greenFeatures = features.filter { $0.type == .green }
    var assignedGreenIDs: Set<Int> = []

    // Build (slot, centerlineEnd) pairs for holes with centerlines
    var holeCenterlineEnds: [(slot: (sub: Int, hole: Int, global: Int), end: Coordinate)] = []
    for slot in holesWithCenterlines {
        let cl = course.subCourses[slot.sub].holes[slot.hole].centerline
        if let end = cl.last {
            holeCenterlineEnds.append((slot, end))
        }
    }

    // For each hole, find the closest unassigned green to its centerline end
    for holeEnd in holeCenterlineEnds {
        var bestGreen: Feature?
        var bestDist = Double.greatestFiniteMagnitude
        for green in greenFeatures where !assignedGreenIDs.contains(green.id) {
            let centroid = PolygonGeometry.centroid(of: green.polygon)
            let dist = centroid.clLocation.distance(from: holeEnd.end.clLocation)
            if dist < bestDist {
                bestDist = dist
                bestGreen = green
            }
        }
        if let green = bestGreen {
            course.subCourses[holeEnd.slot.sub].holes[holeEnd.slot.hole].features.append(green.id)
            assignedGreenIDs.insert(green.id)
        }
    }

    // Phase 2: Anchor tees — find tee polygons along each hole's centerline.
    // A tee must be within 35 yards laterally of the centerline AND forward of its start.
    // This allows tees spread along the hole (e.g., junior tees 200 yards forward)
    // while excluding tees from adjacent holes.
    let teeFeatures = features.filter { $0.type == .tee }
    var assignedTeeIDs: Set<Int> = []

    for slot in holesWithCenterlines {
        let cl = course.subCourses[slot.sub].holes[slot.hole].centerline

        for tee in teeFeatures where !assignedTeeIDs.contains(tee.id) {
            let centroid = PolygonGeometry.centroid(of: tee.polygon)
            guard isForwardOfStart(point: centroid, centerline: cl) else { continue }
            let lateralDist = distanceToPolyline(from: centroid, polyline: cl)
            if lateralDist <= thresholdMeters {
                course.subCourses[slot.sub].holes[slot.hole].features.append(tee.id)
                assignedTeeIDs.insert(tee.id)
            }
        }
    }

    // Phase 3: Associate remaining features (fairways, bunkers, water, rough)
    // with the nearest hole's centerline, filtered by the directional check.
    let remainingFeatures = features.filter {
        !assignedGreenIDs.contains($0.id) && !assignedTeeIDs.contains($0.id)
    }
    associateRemainingFeatures(
        remainingFeatures,
        course: &course,
        holesWithCenterlines: holesWithCenterlines,
        threshold: thresholdMeters
    )

    // Phase 4: Assign tee names
    assignTeeNames(course: &course, holeSlots: holeSlots)
}
```

- [ ] **Step 4: Add `associateRemainingFeatures` method**

```swift
/// Phase 3: Associate non-anchor features with the nearest hole whose centerline
/// is within the threshold, excluding features behind the centerline start.
private static func associateRemainingFeatures(
    _ features: [Feature],
    course: inout Course,
    holesWithCenterlines: [(sub: Int, hole: Int, global: Int)],
    threshold: Double
) {
    for feature in features {
        let centroid = PolygonGeometry.centroid(of: feature.polygon)
        var bestSlot: (sub: Int, hole: Int, global: Int)?
        var bestDist = Double.greatestFiniteMagnitude

        for slot in holesWithCenterlines {
            let cl = course.subCourses[slot.sub].holes[slot.hole].centerline

            // Directional filter: skip if feature is behind this hole's start
            guard isForwardOfStart(point: centroid, centerline: cl) else { continue }

            if shouldAssociate(feature: feature, withCenterline: cl, threshold: threshold) {
                let dist = distanceToPolyline(from: centroid, polyline: cl)
                if dist < bestDist {
                    bestDist = dist
                    bestSlot = slot
                }
            }
        }

        if let slot = bestSlot {
            course.subCourses[slot.sub].holes[slot.hole].features.append(feature.id)
        }
    }
}
```

- [ ] **Step 5: Rewrite `assignTeeNames` — no longer searches for tees (uses hole.features directly)**

Since Phase 2 already correctly anchored tees, `assignTeeNames` just reads from `hole.features`. Remove the `features` parameter.

```swift
/// Phase 4: Assign tee names to tee features on a per-hole basis.
/// Only uses features already in `hole.features` (populated by Phase 2).
///
/// When the number of tee polygons equals the number of tee names, both lists are sorted by
/// distance/yardage and zipped directly. When they differ, tee names are clustered by yardage
/// proximity into N groups (where N = polygon count), then each cluster is assigned to the
/// matching-rank polygon.
private static func assignTeeNames(
    course: inout Course,
    holeSlots: [(sub: Int, hole: Int, global: Int)]
) {
    let metersPerYard = 0.9144

    for slot in holeSlots {
        let hole = course.subCourses[slot.sub].holes[slot.hole]
        guard !hole.yardages.isEmpty else { continue }

        // Find green centroid for this hole
        let greenIDs = hole.features.filter { id in
            course.features.first { $0.id == id }?.type == .green
        }
        guard let greenID = greenIDs.first,
              let green = course.features.first(where: { $0.id == greenID }) else { continue }
        let greenCentroid = PolygonGeometry.centroid(of: green.polygon)

        // Get tee features already associated with this hole
        let teeIDs = hole.features.filter { id in
            course.features.first { $0.id == id }?.type == .tee
        }
        guard !teeIDs.isEmpty else { continue }

        // Compute distance from each tee to the green centroid
        var teeDistances: [(featureID: Int, yards: Double)] = []
        for teeID in teeIDs {
            guard let feature = course.features.first(where: { $0.id == teeID }) else { continue }
            let teeCentroid = PolygonGeometry.centroid(of: feature.polygon)
            let distMeters = teeCentroid.clLocation.distance(from: greenCentroid.clLocation)
            teeDistances.append((teeID, distMeters / metersPerYard))
        }

        // Sort tees by distance descending (longest first) and yardages descending
        teeDistances.sort { $0.yards > $1.yards }
        let sortedYardages = hole.yardages.sorted { $0.value > $1.value }

        if teeDistances.count == sortedYardages.count {
            // Equal counts: zip by rank order — longest tee polygon gets highest yardage name
            for (tee, entry) in zip(teeDistances, sortedYardages) {
                course.subCourses[slot.sub].holes[slot.hole].tees[entry.key] = tee.featureID
            }
        } else if teeDistances.count < sortedYardages.count {
            // More tee names than polygons: cluster yardages into N groups (N = polygon count)
            // by splitting at the largest gaps, then assign each cluster to the matching polygon.
            let clusters = clusterYardages(sortedYardages, into: teeDistances.count)
            for (i, cluster) in clusters.enumerated() {
                for (name, _) in cluster {
                    course.subCourses[slot.sub].holes[slot.hole].tees[name] = teeDistances[i].featureID
                }
            }
        } else {
            // More polygons than tee names (unusual): assign each name to the closest polygon
            for (name, yards) in sortedYardages {
                var bestFeatureID: Int?
                var bestDiff = Double.greatestFiniteMagnitude
                for tee in teeDistances {
                    let diff = abs(tee.yards - Double(yards))
                    if diff < bestDiff {
                        bestDiff = diff
                        bestFeatureID = tee.featureID
                    }
                }
                if let featureID = bestFeatureID {
                    course.subCourses[slot.sub].holes[slot.hole].tees[name] = featureID
                }
            }
        }
    }
}

/// Cluster a sorted (descending) array of yardage entries into `n` groups by splitting
/// at the largest gaps between consecutive yardages.
private static func clusterYardages(
    _ sortedYardages: [(key: String, value: Int)],
    into n: Int
) -> [[(key: String, value: Int)]] {
    guard n > 0, !sortedYardages.isEmpty else { return [] }
    guard n < sortedYardages.count else {
        // Each yardage is its own cluster
        return sortedYardages.map { [$0] }
    }

    // Find the (n-1) largest gaps between consecutive yardage values
    var gaps: [(index: Int, gap: Int)] = []
    for i in 0..<(sortedYardages.count - 1) {
        let gap = sortedYardages[i].value - sortedYardages[i + 1].value
        gaps.append((i, gap))
    }
    gaps.sort { $0.gap > $1.gap }
    let splitIndices = gaps.prefix(n - 1).map(\.index).sorted()

    // Split at the gap positions
    var clusters: [[(key: String, value: Int)]] = []
    var start = 0
    for splitIndex in splitIndices {
        clusters.append(Array(sortedYardages[start...(splitIndex)]))
        start = splitIndex + 1
    }
    clusters.append(Array(sortedYardages[start...]))
    return clusters
}
```

- [ ] **Step 6: Run all tests**

Run: `xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | grep -E "error:|Executed"`
Expected: Some existing tests may fail due to the new association logic. Note which ones fail — we'll fix them in Task 3.

- [ ] **Step 7: Commit work in progress**

```bash
git add CourseBuilder/Services/OSMImporter.swift CourseBuilderTests/Services/OSMImporterTests.swift
git commit -m "feat: rewrite OSMImporter with phased type-aware feature association"
```

---

### Task 3: Update existing tests to match new behavior

The redesign changes several behaviors:
- Greens are anchored 1:1 (not threshold-based)
- Tees are anchored to centerline start (not full polyline proximity)
- Remaining features use directional filtering and nearest-hole assignment
- Features behind the centerline start are excluded

Review each existing test and update assertions as needed. Some tests may pass unchanged (e.g., `testFeatureBeyondThresholdNotAssigned`). Others may need coordinate or assertion adjustments.

**Files:**
- Modify: `CourseBuilderTests/Services/OSMImporterTests.swift`

- [ ] **Step 1: Run all tests and catalog failures**

Run: `xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | grep -E "error:|passed|failed"`
Catalog each failure and its cause.

- [ ] **Step 2: Fix failing tests one at a time**

For each failing test, determine if:
- (a) The test's coordinates need updating to work with the new logic, or
- (b) The test's assertions need updating to reflect correct new behavior, or
- (c) The test should be removed and replaced by the new tests from Task 2

Apply fixes. Common adjustments:
- `testAssociateFeaturesViaCenterlines`: The fairway is along the centerline (forward of start) and the green is near the endpoint — should still pass.
- `testAssignsFeatureToCorrectHole`: Green association now uses endpoint proximity instead of threshold — verify the coordinates still work.
- `testCenterlinePassesThroughPolygon`: Fairway is forward of start and centerline passes through it — should still pass.
- `testFeatureOffsetFromCenterline`: Bunker is offset but forward of start — should still pass.
- `testAssignsTeeNamesWhenCountsMatch`: Tees need to be near the centerline start (within 35 yards) to get associated. Adjust tee polygon coordinates to cluster near `(39.791, -74.960)`.
- `testAssignsTeeNamesWhenFewerPolygonsThanNames`: Same — cluster tee polygons near centerline start. Also now uses yardage clustering instead of distance matching.

- [ ] **Step 3: Run all tests to verify they pass**

Run: `xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | grep -E "error:|Executed"`
Expected: All tests PASS.

- [ ] **Step 4: Commit**

```bash
git add CourseBuilderTests/Services/OSMImporterTests.swift
git commit -m "test: update OSMImporter tests for phased association redesign"
```

---

### Task 4: Add directional filter test for feature association

Verify that features behind the centerline start are not associated with the hole.

**Files:**
- Modify: `CourseBuilderTests/Services/OSMImporterTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// MARK: - Directional Filtering

func testFeatureBehindCenterlineStartNotAssociated() {
    // Bunker is behind the start of hole 1's centerline (north-west of start,
    // opposite to the tee-to-green direction)
    let bunkerBehind = OverpassAPIClient.ParsedFeature(
        type: .bunker,
        polygon: [
            Coordinate(latitude: 39.792, longitude: -74.962),
            Coordinate(latitude: 39.792, longitude: -74.961),
            Coordinate(latitude: 39.793, longitude: -74.961),
            Coordinate(latitude: 39.793, longitude: -74.962)
        ]
    )
    let green = OverpassAPIClient.ParsedFeature(
        type: .green,
        polygon: [
            Coordinate(latitude: 39.784, longitude: -74.955),
            Coordinate(latitude: 39.784, longitude: -74.953),
            Coordinate(latitude: 39.785, longitude: -74.953),
            Coordinate(latitude: 39.785, longitude: -74.955)
        ]
    )
    // Centerline goes SE: (39.790, -74.960) → (39.7845, -74.954)
    let cl = OverpassAPIClient.ParsedCenterline(
        holeNumber: 1,
        coordinates: [
            Coordinate(latitude: 39.790, longitude: -74.960),
            Coordinate(latitude: 39.787, longitude: -74.957),
            Coordinate(latitude: 39.7845, longitude: -74.954)
        ]
    )

    let parsed = OverpassAPIClient.ParsedResult(
        features: [bunkerBehind, green],
        centerlines: [cl],
        courseBoundary: nil
    )

    var course = Course(
        name: "Test",
        location: CourseLocation(address: "", city: "", state: "", country: "",
                                 coordinate: Coordinate(latitude: 39.787, longitude: -74.957)),
        subCourses: [
            SubCourse(name: "Front", holes: [Hole(number: 1, par: 4)])
        ]
    )

    OSMImporter.applyParsedResult(parsed, to: &course)

    let hole = course.subCourses[0].holes[0]
    // Green should be associated (it's the anchor), bunker should NOT (it's behind start)
    let bunkerID = course.features.first(where: { $0.type == .bunker })!.id
    XCTAssertFalse(hole.features.contains(bunkerID))
    XCTAssertEqual(hole.features.count, 1) // only the green
}
```

- [ ] **Step 2: Run test to verify it passes (should pass with new logic)**

Run: `xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | grep "testFeatureBehind"`
Expected: PASS — the directional filter is already implemented.

- [ ] **Step 3: Commit**

```bash
git add CourseBuilderTests/Services/OSMImporterTests.swift
git commit -m "test: add directional filter test for features behind centerline start"
```

---

### Task 5: Add yardage clustering test

Verify that when there are fewer tee polygons than tee names, names are clustered by yardage gap analysis.

**Files:**
- Modify: `CourseBuilderTests/Services/OSMImporterTests.swift`

- [ ] **Step 1: Write the test**

```swift
// MARK: - Yardage Clustering

func testTeeNameClusteringWithUnequalCounts() {
    // 4 tee names, 2 tee polygons.
    // Yardages: Black=420, Blue=400, White=310, Red=290
    // The largest gap is between Blue(400) and White(310) = 90 yards.
    // Cluster 1: [Black, Blue] → back polygon
    // Cluster 2: [White, Red] → front polygon
    let green = OverpassAPIClient.ParsedFeature(
        type: .green,
        polygon: [
            Coordinate(latitude: 39.7840, longitude: -74.9540),
            Coordinate(latitude: 39.7840, longitude: -74.9538),
            Coordinate(latitude: 39.7842, longitude: -74.9538),
            Coordinate(latitude: 39.7842, longitude: -74.9540)
        ]
    )
    // Back tee box — near centerline start
    let teeBack = OverpassAPIClient.ParsedFeature(
        type: .tee,
        polygon: [
            Coordinate(latitude: 39.7899, longitude: -74.9601),
            Coordinate(latitude: 39.7899, longitude: -74.9599),
            Coordinate(latitude: 39.7901, longitude: -74.9599),
            Coordinate(latitude: 39.7901, longitude: -74.9601)
        ]
    )
    // Front tee box — also near centerline start but slightly closer to green
    let teeFront = OverpassAPIClient.ParsedFeature(
        type: .tee,
        polygon: [
            Coordinate(latitude: 39.7896, longitude: -74.9601),
            Coordinate(latitude: 39.7896, longitude: -74.9599),
            Coordinate(latitude: 39.7898, longitude: -74.9599),
            Coordinate(latitude: 39.7898, longitude: -74.9601)
        ]
    )
    let cl = OverpassAPIClient.ParsedCenterline(
        holeNumber: 1,
        coordinates: [
            Coordinate(latitude: 39.790, longitude: -74.960),
            Coordinate(latitude: 39.787, longitude: -74.957),
            Coordinate(latitude: 39.7841, longitude: -74.9539)
        ]
    )

    let parsed = OverpassAPIClient.ParsedResult(
        features: [green, teeBack, teeFront],
        centerlines: [cl],
        courseBoundary: nil
    )

    var course = Course(
        name: "Test",
        location: CourseLocation(address: "", city: "", state: "", country: "",
                                 coordinate: Coordinate(latitude: 39.787, longitude: -74.957)),
        tees: [
            TeeDefinition(name: "Black", color: "#000000"),
            TeeDefinition(name: "Blue", color: "#0000FF"),
            TeeDefinition(name: "White", color: "#FFFFFF"),
            TeeDefinition(name: "Red", color: "#FF0000")
        ],
        subCourses: [
            SubCourse(name: "Front", holes: [Hole(number: 1, par: 4)])
        ]
    )
    course.subCourses[0].holes[0].yardages = ["Black": 420, "Blue": 400, "White": 310, "Red": 290]

    OSMImporter.applyParsedResult(parsed, to: &course)

    let hole = course.subCourses[0].holes[0]
    let teeFeatures = course.features.filter { $0.type == .tee }
    let backID = teeFeatures.first(where: { $0.polygon[0].latitude > 39.7898 })!.id
    let frontID = teeFeatures.first(where: { $0.polygon[0].latitude < 39.7898 })!.id

    // Black & Blue clustered → back polygon
    XCTAssertEqual(hole.tees["Black"], backID)
    XCTAssertEqual(hole.tees["Blue"], backID)
    // White & Red clustered → front polygon
    XCTAssertEqual(hole.tees["White"], frontID)
    XCTAssertEqual(hole.tees["Red"], frontID)
    XCTAssertEqual(hole.tees.count, 4)
}
```

- [ ] **Step 2: Run test to verify it passes**

Run: `xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | grep "testTeeNameClustering"`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add CourseBuilderTests/Services/OSMImporterTests.swift
git commit -m "test: add yardage clustering test for tee name assignment"
```

---

### Task 6: Clean up stale doc comment and verify build

**Files:**
- Modify: `CourseBuilder/Services/OSMImporter.swift`

- [ ] **Step 1: Review and update doc comments**

The `assignTeeNames` doc comment still references "100-yard radius from the centerline start" — update to reflect the new phased approach. Remove any stale comments referencing the old logic.

- [ ] **Step 2: Run full build and test suite**

Run: `xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | grep "Executed"`
Expected: All tests PASS, build succeeds.

- [ ] **Step 3: Commit**

```bash
git add CourseBuilder/Services/OSMImporter.swift
git commit -m "chore: clean up stale comments in OSMImporter"
```
