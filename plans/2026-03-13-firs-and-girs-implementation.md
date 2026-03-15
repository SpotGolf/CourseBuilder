# Polygon-First Data Model Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the pin-based data model with a polygon-first model where all spatial elements (fairways, greens, tees, bunkers, water, rough) are polygons, enabling FIR/GIR detection in the SpotGolf mobile app.

**Architecture:** Complete rewrite of the data layer (Coordinate, Feature, Hole, Course) with compact `[lat, lon]` JSON encoding, a flat course-level features array referenced by integer ID from holes, and a new Overpass API client for importing OSM polygon data. The map editor shifts from pin placement to polygon drawing and vertex editing.

**Tech Stack:** Swift, SwiftUI, MapKit, Overpass API (OSM), XCTest

---

### Task 1: Compact Coordinate Encoding

Add custom Codable to `Coordinate` so it serializes as `[lat, lon]` instead of `{"latitude": ..., "longitude": ...}`.

**Files:**
- Modify: `CourseBuilder/Models/Coordinate.swift`
- Modify: `CourseBuilderTests/Models/CoordinateTests.swift`

**Step 1: Write the failing test**

Add to `CoordinateTests.swift`:

```swift
func testCompactJSONEncoding() throws {
    let coord = Coordinate(latitude: 39.7879, longitude: -74.9580)
    let data = try JSONEncoder().encode(coord)
    let json = String(data: data, encoding: .utf8)!
    XCTAssertEqual(json, "[39.787900000000001,-74.958000000000013]")
}

func testCompactJSONDecoding() throws {
    let json = "[39.7879, -74.958]"
    let data = json.data(using: .utf8)!
    let coord = try JSONDecoder().decode(Coordinate.self, from: data)
    XCTAssertEqual(coord.latitude, 39.7879, accuracy: 0.0001)
    XCTAssertEqual(coord.longitude, -74.958, accuracy: 0.0001)
}
```

**Step 2: Run tests to verify they fail**

```bash
xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | tail -20
```

Expected: FAIL — default Codable encodes as object, not array.

**Step 3: Implement custom Codable on Coordinate**

Replace the `Codable` conformance in `Coordinate.swift` with custom `encode(to:)` and `init(from:)`:

```swift
struct Coordinate: Equatable, Hashable {
    var latitude: Double
    var longitude: Double

    // ... existing inits and computed properties unchanged ...
}

extension Coordinate: Codable {
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        latitude = try container.decode(Double.self)
        longitude = try container.decode(Double.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(latitude)
        try container.encode(longitude)
    }
}
```

**Step 4: Run tests to verify they pass**

```bash
xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | tail -20
```

Expected: New tests PASS. Existing `testCodableRoundTrip` PASSES. Other tests that encode/decode coordinates in Course/Hole will now produce compact format — some tests may need JSON string updates if they assert on JSON structure. Fix any that break.

**Step 5: Commit**

```bash
git add CourseBuilder/Models/Coordinate.swift CourseBuilderTests/Models/CoordinateTests.swift
git commit -m "feat: compact [lat, lon] array encoding for Coordinate"
```

---

### Task 2: Rewrite Feature Model

Replace the `front`/`back` point-pair model with a polygon model using integer IDs and expanded feature types.

**Files:**
- Modify: `CourseBuilder/Models/Feature.swift`
- Modify: `CourseBuilderTests/Models/HoleTests.swift` (contains FeatureTests)

**Step 1: Write the failing tests**

Replace `FeatureTests` in `HoleTests.swift`:

```swift
final class FeatureTests: XCTestCase {
    func testPolygonFeatureCodableRoundTrip() throws {
        let feature = Feature(
            id: 1,
            type: .fairway,
            polygon: [
                Coordinate(latitude: 39.788, longitude: -74.958),
                Coordinate(latitude: 39.787, longitude: -74.957),
                Coordinate(latitude: 39.786, longitude: -74.956),
                Coordinate(latitude: 39.787, longitude: -74.959)
            ]
        )
        let data = try JSONEncoder().encode(feature)
        let decoded = try JSONDecoder().decode(Feature.self, from: data)
        XCTAssertEqual(feature, decoded)
        XCTAssertEqual(decoded.id, 1)
        XCTAssertEqual(decoded.type, .fairway)
        XCTAssertEqual(decoded.polygon.count, 4)
    }

    func testAllFeatureTypes() throws {
        let types: [FeatureType] = [.fairway, .green, .tee, .bunker, .water, .rough]
        for type in types {
            let feature = Feature(
                id: 1,
                type: type,
                polygon: [Coordinate(latitude: 0, longitude: 0)]
            )
            let data = try JSONEncoder().encode(feature)
            let decoded = try JSONDecoder().decode(Feature.self, from: data)
            XCTAssertEqual(decoded.type, type)
        }
    }

    func testFeatureJSONFormat() throws {
        let feature = Feature(
            id: 42,
            type: .bunker,
            polygon: [
                Coordinate(latitude: 39.0, longitude: -105.0),
                Coordinate(latitude: 39.1, longitude: -105.1)
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(feature)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["id"] as? Int, 42)
        XCTAssertEqual(json["type"] as? String, "bunker")
        let polygon = json["polygon"] as! [[Double]]
        XCTAssertEqual(polygon.count, 2)
        XCTAssertEqual(polygon[0], [39.0, -105.0])
    }
}
```

**Step 2: Run tests to verify they fail**

```bash
xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | tail -20
```

Expected: FAIL — Feature doesn't have `polygon` or integer `id`.

**Step 3: Rewrite Feature.swift**

```swift
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
```

**Step 4: Run tests to verify they pass**

```bash
xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | tail -20
```

Expected: FeatureTests PASS. Other tests (HoleTests, CourseTests, etc.) will FAIL because they still use the old `Feature(type:front:back:)` API. Those are fixed in subsequent tasks.

**Step 5: Commit**

```bash
git add CourseBuilder/Models/Feature.swift CourseBuilderTests/Models/HoleTests.swift
git commit -m "feat: rewrite Feature as polygon with integer ID and expanded types"
```

---

### Task 3: Rewrite Hole Model

Remove embedded `tees`, `green`, and `features` from Hole. Replace with `featureIDs: [Int]` and `centerline: [Coordinate]`.

**Files:**
- Modify: `CourseBuilder/Models/Hole.swift`
- Modify: `CourseBuilderTests/Models/HoleTests.swift`

**Step 1: Write the failing tests**

Replace `HoleTests` in `HoleTests.swift`:

```swift
final class HoleTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let hole = Hole(
            number: 1,
            par: 4,
            maleHandicap: 13,
            yardages: ["Black": 401, "Gold": 378],
            featureIDs: [1, 2, 3],
            centerline: [
                Coordinate(latitude: 39.788, longitude: -74.958),
                Coordinate(latitude: 39.786, longitude: -74.956)
            ]
        )
        let data = try JSONEncoder().encode(hole)
        let decoded = try JSONDecoder().decode(Hole.self, from: data)
        XCTAssertEqual(hole, decoded)
        XCTAssertEqual(decoded.number, 1)
        XCTAssertEqual(decoded.par, 4)
        XCTAssertEqual(decoded.featureIDs, [1, 2, 3])
        XCTAssertEqual(decoded.centerline.count, 2)
    }

    func testRenumbered() {
        let hole = Hole(
            number: 7,
            par: 5,
            maleHandicap: 3,
            femaleHandicap: 5,
            yardages: ["Blue": 545],
            featureIDs: [10, 11],
            centerline: [Coordinate(latitude: 39.0, longitude: -105.0)]
        )
        let renumbered = hole.renumbered(to: 1)
        XCTAssertEqual(renumbered.number, 1)
        XCTAssertEqual(renumbered.par, 5)
        XCTAssertEqual(renumbered.maleHandicap, 3)
        XCTAssertEqual(renumbered.femaleHandicap, 5)
        XCTAssertEqual(renumbered.yardages["Blue"], 545)
        XCTAssertEqual(renumbered.featureIDs, [10, 11])
        XCTAssertEqual(renumbered.centerline.count, 1)
        XCTAssertNotEqual(renumbered.id, hole.id)
    }

    func testEmptyHole() {
        let hole = Hole(number: 5, par: 3, maleHandicap: 7)
        XCTAssertTrue(hole.yardages.isEmpty)
        XCTAssertTrue(hole.featureIDs.isEmpty)
        XCTAssertTrue(hole.centerline.isEmpty)
    }

    func testSplitIntoSubCourses18Holes() {
        let holes = (1...18).map { Hole(number: $0, par: $0 <= 9 ? 4 : 5) }
        let groups = Hole.splitIntoSubCourses(holes, names: ["Front", "Back"])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].name, "Front")
        XCTAssertEqual(groups[0].holes.count, 9)
        XCTAssertEqual(groups[0].holes[0].number, 1)
        XCTAssertEqual(groups[0].holes[0].par, 4)
        XCTAssertEqual(groups[1].name, "Back")
        XCTAssertEqual(groups[1].holes.count, 9)
        XCTAssertEqual(groups[1].holes[0].number, 1)
        XCTAssertEqual(groups[1].holes[0].par, 5)
    }

    func testSplitIntoSubCourses9Holes() {
        let holes = (1...9).map { Hole(number: $0, par: 4) }
        let groups = Hole.splitIntoSubCourses(holes, names: ["Front", "Back"])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "Front")
        XCTAssertEqual(groups[0].holes.count, 9)
    }

    func testSplitIntoSubCourses27HolesThreeNames() {
        let holes = (1...27).map { Hole(number: $0, par: 4) }
        let groups = Hole.splitIntoSubCourses(holes, names: ["Eldorado", "Vista", "Conquistador"])
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].name, "Eldorado")
        XCTAssertEqual(groups[0].holes.count, 9)
        XCTAssertEqual(groups[1].name, "Vista")
        XCTAssertEqual(groups[1].holes.count, 9)
        XCTAssertEqual(groups[2].name, "Conquistador")
        XCTAssertEqual(groups[2].holes.count, 9)
        XCTAssertEqual(groups[2].holes[0].number, 1)
        XCTAssertEqual(groups[2].holes[8].number, 9)
    }

    func testHoleJSONUsesFeatureIDsNotFeatures() throws {
        let hole = Hole(number: 1, par: 4, featureIDs: [1, 2])
        let data = try JSONEncoder().encode(hole)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["featureIDs"])
        XCTAssertNil(json["features"])
        XCTAssertNil(json["tees"])
        XCTAssertNil(json["green"])
    }
}
```

**Step 2: Run tests to verify they fail**

```bash
xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | tail -20
```

**Step 3: Rewrite Hole.swift**

```swift
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
```

Note: The `Green` struct is removed entirely — greens are now polygon features.

**Step 4: Run tests to verify they pass**

```bash
xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | tail -20
```

Expected: HoleTests and FeatureTests PASS. CourseTests and service tests will FAIL (fixed in subsequent tasks).

**Step 5: Commit**

```bash
git add CourseBuilder/Models/Hole.swift CourseBuilderTests/Models/HoleTests.swift
git commit -m "feat: rewrite Hole with featureIDs and centerline, remove Green struct"
```

---

### Task 4: Update Course Model

Add flat `features` array to Course. Remove `id` from TeeDefinition. Update CourseLocation to encode coordinate as `coordinates`.

**Files:**
- Modify: `CourseBuilder/Models/Course.swift`
- Modify: `CourseBuilderTests/Models/CourseTests.swift`

**Step 1: Write the failing tests**

Replace `CourseTests.swift`:

```swift
import XCTest
@testable import CourseBuilder

final class CourseTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let course = Course(
            name: "The Broadlands Golf Course",
            location: CourseLocation(
                address: "4380 W 144th Ave",
                city: "Broomfield",
                state: "CO",
                country: "US",
                coordinate: Coordinate(latitude: 39.9397, longitude: -105.0267)
            ),
            tees: [
                TeeDefinition(name: "Black", color: "#000000"),
                TeeDefinition(name: "Gold", color: "#FFD700")
            ],
            features: [
                Feature(id: 1, type: .tee, polygon: [
                    Coordinate(latitude: 39.9401, longitude: -105.0271),
                    Coordinate(latitude: 39.9402, longitude: -105.0272),
                    Coordinate(latitude: 39.9401, longitude: -105.0273)
                ]),
                Feature(id: 2, type: .fairway, polygon: [
                    Coordinate(latitude: 39.939, longitude: -105.026),
                    Coordinate(latitude: 39.938, longitude: -105.025)
                ])
            ],
            subCourses: [
                SubCourse(
                    name: "Front",
                    holes: [
                        Hole(number: 1, par: 4, maleHandicap: 13,
                             yardages: ["Black": 401],
                             featureIDs: [1, 2])
                    ],
                    tees: ["Black": SubCourseTee(male: TeeInformation(rating: 37.6, slope: 134))]
                )
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(course)
        let decoded = try JSONDecoder().decode(Course.self, from: data)

        XCTAssertEqual(course.id, decoded.id)
        XCTAssertEqual(course.name, decoded.name)
        XCTAssertEqual(course.location.city, "Broomfield")
        XCTAssertEqual(course.tees.count, 2)
        XCTAssertEqual(course.features.count, 2)
        XCTAssertEqual(course.features[0].type, .tee)
        XCTAssertEqual(course.features[1].type, .fairway)
        XCTAssertEqual(course.subCourses.count, 1)
        XCTAssertEqual(course.subCourses[0].holes[0].featureIDs, [1, 2])
        XCTAssertEqual(course.subCourses[0].tees["Black"]?.male?.rating, 37.6)
    }

    func testTeeDefinitionHasNoId() throws {
        let tee = TeeDefinition(name: "Blue", color: "#0000FF")
        let data = try JSONEncoder().encode(tee)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(json["id"])
        XCTAssertEqual(json["name"] as? String, "Blue")
        XCTAssertEqual(json["color"] as? String, "#0000FF")
    }

    func testDefaultTeeColors() {
        XCTAssertEqual(TeeDefinition.defaultColor(for: "Black"), "#000000")
        XCTAssertEqual(TeeDefinition.defaultColor(for: "BLUE"), "#0000FF")
        XCTAssertEqual(TeeDefinition.defaultColor(for: "Red"), "#FF0000")
        XCTAssertEqual(TeeDefinition.defaultColor(for: "White"), "#FFFFFF")
        XCTAssertEqual(TeeDefinition.defaultColor(for: "Gold"), "#FFD700")
        XCTAssertEqual(TeeDefinition.defaultColor(for: "Silver"), "#C0C0C0")
        XCTAssertEqual(TeeDefinition.defaultColor(for: "Green"), "#008000")
        XCTAssertEqual(TeeDefinition.defaultColor(for: "Unknown"), "#808080")
    }

    func testEmptyCourse() {
        let course = Course(
            name: "Test Course",
            location: CourseLocation(
                address: "",
                city: "Denver",
                state: "CO",
                country: "",
                coordinate: Coordinate(latitude: 39.0, longitude: -105.0)
            )
        )
        XCTAssertTrue(course.tees.isEmpty)
        XCTAssertTrue(course.features.isEmpty)
        XCTAssertTrue(course.subCourses.isEmpty)
    }

    func testNextFeatureID() {
        var course = Course(
            name: "Test",
            location: CourseLocation(address: "", city: "", state: "", country: "", coordinate: Coordinate(latitude: 0, longitude: 0)),
            features: [
                Feature(id: 1, type: .fairway, polygon: []),
                Feature(id: 5, type: .green, polygon: []),
                Feature(id: 3, type: .bunker, polygon: [])
            ]
        )
        XCTAssertEqual(course.nextFeatureID, 6)

        course.features = []
        XCTAssertEqual(course.nextFeatureID, 1)
    }
}
```

**Step 2: Run tests to verify they fail**

```bash
xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | tail -20
```

**Step 3: Update Course.swift**

```swift
import Foundation

struct TeeInformation: Codable, Equatable, Hashable {
    var rating: Double?
    var slope: Int?
    var totalYards: Int?
    var parTotal: Int?
}

struct SubCourseTee: Codable, Equatable, Hashable {
    var male: TeeInformation?
    var female: TeeInformation?
}

struct SubCourse: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var holes: [Hole]
    var tees: [String: SubCourseTee]

    init(
        id: UUID = UUID(),
        name: String,
        holes: [Hole] = [],
        tees: [String: SubCourseTee] = [:]
    ) {
        self.id = id
        self.name = name
        self.holes = holes
        self.tees = tees
    }
}

struct TeeDefinition: Codable, Equatable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var color: String

    init(name: String, color: String) {
        self.name = name
        self.color = color
    }

    enum CodingKeys: String, CodingKey {
        case name, color
    }

    static func defaultColor(for teeName: String) -> String {
        switch teeName.lowercased() {
        case "black": "#000000"
        case "gold": "#FFD700"
        case "blue": "#0000FF"
        case "white": "#FFFFFF"
        case "silver": "#C0C0C0"
        case "red": "#FF0000"
        case "green": "#008000"
        default: "#808080"
        }
    }
}

struct CourseLocation: Codable, Equatable, Hashable {
    var address: String
    var city: String
    var state: String
    var country: String
    var coordinate: Coordinate

    enum CodingKeys: String, CodingKey {
        case address, city, state, country
        case coordinate = "coordinates"
    }
}

struct Course: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var clubName: String
    var golfCourseAPIIds: [Int]
    var location: CourseLocation
    var tees: [TeeDefinition]
    var features: [Feature]
    var subCourses: [SubCourse]

    var nextFeatureID: Int {
        (features.map(\.id).max() ?? 0) + 1
    }

    init(
        id: UUID = UUID(),
        name: String,
        clubName: String = "",
        golfCourseAPIIds: [Int] = [],
        location: CourseLocation,
        tees: [TeeDefinition] = [],
        features: [Feature] = [],
        subCourses: [SubCourse] = []
    ) {
        self.id = id
        self.name = name
        self.clubName = clubName
        self.golfCourseAPIIds = golfCourseAPIIds
        self.location = location
        self.tees = tees
        self.features = features
        self.subCourses = subCourses
    }
}
```

**Step 4: Run tests to verify they pass**

```bash
xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | tail -20
```

Expected: CourseTests PASS. Service tests may still fail (fixed in Task 5-6).

**Step 5: Commit**

```bash
git add CourseBuilder/Models/Course.swift CourseBuilderTests/Models/CourseTests.swift
git commit -m "feat: add features array to Course, remove ID from TeeDefinition"
```

---

### Task 5: Update CourseStore and Tests

CourseStore itself should work as-is since it uses generic Codable encoding. Update tests that create courses to use the new model.

**Files:**
- Modify: `CourseBuilderTests/Services/CourseStoreTests.swift`

**Step 1: Update CourseStoreTests to use new model**

The `makeCourse` helper already creates a minimal course, but verify it still works with the new `features` field. The test should pass without changes, but verify the JSON output uses the new format.

Add a test:

```swift
func testSavedJSONUsesCompactCoordinates() throws {
    let course = Course(
        id: idA,
        name: "Test",
        location: CourseLocation(
            address: "",
            city: "Denver",
            state: "CO",
            country: "",
            coordinate: Coordinate(latitude: 39.0, longitude: -105.0)
        ),
        features: [
            Feature(id: 1, type: .fairway, polygon: [
                Coordinate(latitude: 39.0, longitude: -105.0),
                Coordinate(latitude: 39.1, longitude: -105.1)
            ])
        ]
    )
    try store.save(course)
    let fileURL = tempDir.appendingPathComponent("\(idA).json")
    let data = try Data(contentsOf: fileURL)
    let json = String(data: data, encoding: .utf8)!
    // Coordinates should be arrays, not objects
    XCTAssertFalse(json.contains("\"latitude\""))
    XCTAssertFalse(json.contains("\"longitude\""))
    // Should use "coordinates" key for location
    XCTAssertTrue(json.contains("\"coordinates\""))
    // Should contain features array
    XCTAssertTrue(json.contains("\"features\""))
}
```

**Step 2: Run tests**

```bash
xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | tail -20
```

**Step 3: Fix any failures**

If the existing `testTeeDefinitionUniqueIds` test exists separately, remove it — TeeDefinition no longer has a UUID id.

**Step 4: Commit**

```bash
git add CourseBuilderTests/Services/CourseStoreTests.swift
git commit -m "test: update CourseStore tests for new data model"
```

---

### Task 6: Update GolfCourseAPIClient

Update `convertToCourse` to produce the new model. GolfCourseAPI doesn't provide polygon data, so courses created from it will have empty `features` arrays and no centerlines — those come from OSM import later.

**Files:**
- Modify: `CourseBuilder/Services/GolfCourseAPIClient.swift`
- Modify: `CourseBuilderTests/Services/GolfCourseAPIClientTests.swift`

**Step 1: Update convertToCourse**

The main changes:
- Remove `TeeDefinition(id:name:color:)` calls — use `TeeDefinition(name:color:)`
- Holes no longer have `tees`/`green`/`features` fields — just `featureIDs` and `centerline` (both empty from API)
- Course gets empty `features: []`

In `GolfCourseAPIClient.swift`, the `Hole(...)` constructor calls at line 320-326 should be updated. The change is minimal since the old constructor used defaults for `tees`, `green`, and `features` — now those params simply don't exist and `featureIDs`/`centerline` default to empty.

The `TeeDefinition` calls at lines 252-254 and 286-289 need the `id:` parameter removed (it no longer exists).

**Step 2: Update tests**

Update `GolfCourseAPIClientTests.swift` to match the new model. Any assertions on `hole.tees` or `hole.green` should be changed to assert on `hole.featureIDs` (empty) and `hole.centerline` (empty).

**Step 3: Run tests**

```bash
xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | tail -20
```

**Step 4: Commit**

```bash
git add CourseBuilder/Services/GolfCourseAPIClient.swift CourseBuilderTests/Services/GolfCourseAPIClientTests.swift
git commit -m "feat: update GolfCourseAPIClient for polygon data model"
```

---

### Task 7: Update ScorecardImporter

Same changes as Task 6 — update for the new model shape.

**Files:**
- Modify: `CourseBuilder/Services/ScorecardImporter.swift`
- Modify: `CourseBuilderTests/Services/ScorecardImporterTests.swift`

**Step 1: Update ScorecardImporter**

The `buildCourse` method (line 109) and `createManualCourse` method (line 88) need the `TeeDefinition` constructor call updated (remove `id:`). The Hole constructors should already work since `featureIDs` and `centerline` have defaults.

**Step 2: Update tests**

Update assertions that reference `hole.tees`, `hole.green`, or `hole.features` to use the new field names.

**Step 3: Run tests**

```bash
xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | tail -20
```

**Step 4: Commit**

```bash
git add CourseBuilder/Services/ScorecardImporter.swift CourseBuilderTests/Services/ScorecardImporterTests.swift
git commit -m "feat: update ScorecardImporter for polygon data model"
```

---

### Task 8: Update ScorecardView

Update validation logic and export for the new model. The scorecard editing UI (par, handicap, yardages) is unchanged since those fields are the same.

**Files:**
- Modify: `CourseBuilder/Views/ScorecardView.swift`

**Step 1: Update validateCourse()**

The current validation checks for missing tee pins and green pins per hole. With the new model, validation should check for missing features by type:

```swift
private func validateCourse() -> [String] {
    var warnings: [String] = []
    var holeOffset = 0

    for subCourse in course.subCourses {
        for hole in subCourse.holes {
            let holeLabel = "Hole \(holeOffset + hole.number)"
            let holeFeatures = hole.featureIDs.compactMap { id in
                course.features.first { $0.id == id }
            }

            if !holeFeatures.contains(where: { $0.type == .green }) {
                warnings.append("\(holeLabel): missing green polygon")
            }

            if hole.par > 3 && !holeFeatures.contains(where: { $0.type == .fairway }) {
                warnings.append("\(holeLabel): missing fairway polygon")
            }

            if !holeFeatures.contains(where: { $0.type == .tee }) {
                warnings.append("\(holeLabel): missing tee polygon")
            }

            if hole.centerline.isEmpty {
                warnings.append("\(holeLabel): missing centerline")
            }
        }
        holeOffset += subCourse.holes.count
    }

    return warnings
}
```

**Step 2: Update TeeDefinition usage**

The tee definitions section in the view creates `TeeDefinition(name: "", color: "#FFFFFF")` at line 87. Remove the `id:` parameter if it was being passed (it wasn't in this case, but verify after model change).

**Step 3: Build and verify**

```bash
xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' build 2>&1 | tail -20
```

**Step 4: Commit**

```bash
git add CourseBuilder/Views/ScorecardView.swift
git commit -m "feat: update ScorecardView validation for polygon model"
```

---

### Task 9: Polygon Geometry Utilities

Add computed properties and utility functions for polygon geometry: centroid, area, front/back relative to direction.

**Files:**
- Create: `CourseBuilder/Models/PolygonGeometry.swift`
- Create: `CourseBuilderTests/Models/PolygonGeometryTests.swift`

**Step 1: Write the failing tests**

```swift
import XCTest
@testable import CourseBuilder

final class PolygonGeometryTests: XCTestCase {
    func testCentroidOfSquare() {
        let polygon = [
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 0, longitude: 2),
            Coordinate(latitude: 2, longitude: 2),
            Coordinate(latitude: 2, longitude: 0)
        ]
        let centroid = PolygonGeometry.centroid(of: polygon)
        XCTAssertEqual(centroid.latitude, 1.0, accuracy: 0.001)
        XCTAssertEqual(centroid.longitude, 1.0, accuracy: 0.001)
    }

    func testCentroidOfTriangle() {
        let polygon = [
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 0, longitude: 6),
            Coordinate(latitude: 3, longitude: 3)
        ]
        let centroid = PolygonGeometry.centroid(of: polygon)
        XCTAssertEqual(centroid.latitude, 1.0, accuracy: 0.001)
        XCTAssertEqual(centroid.longitude, 3.0, accuracy: 0.001)
    }

    func testAreaOfSquare() {
        // 2x2 degree square (approximate, not geodesic)
        let polygon = [
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 0, longitude: 2),
            Coordinate(latitude: 2, longitude: 2),
            Coordinate(latitude: 2, longitude: 0)
        ]
        let area = PolygonGeometry.area(of: polygon)
        XCTAssertEqual(area, 4.0, accuracy: 0.001)
    }

    func testFrontAndBackFromDirection() {
        // Green polygon: a simple rectangle
        let polygon = [
            Coordinate(latitude: 39.786, longitude: -74.956),
            Coordinate(latitude: 39.786, longitude: -74.954),
            Coordinate(latitude: 39.788, longitude: -74.954),
            Coordinate(latitude: 39.788, longitude: -74.956)
        ]
        // Approach from south (lower latitude)
        let approachFrom = Coordinate(latitude: 39.780, longitude: -74.955)
        let front = PolygonGeometry.nearestPoint(on: polygon, to: approachFrom)
        let back = PolygonGeometry.farthestPoint(on: polygon, to: approachFrom)

        // Front should be the southern edge (lower latitude)
        XCTAssertEqual(front.latitude, 39.786, accuracy: 0.001)
        // Back should be the northern edge (higher latitude)
        XCTAssertEqual(back.latitude, 39.788, accuracy: 0.001)
    }

    func testCentroidOfEmptyPolygon() {
        let centroid = PolygonGeometry.centroid(of: [])
        XCTAssertEqual(centroid.latitude, 0)
        XCTAssertEqual(centroid.longitude, 0)
    }

    func testCentroidOfSinglePoint() {
        let polygon = [Coordinate(latitude: 39.0, longitude: -105.0)]
        let centroid = PolygonGeometry.centroid(of: polygon)
        XCTAssertEqual(centroid.latitude, 39.0)
        XCTAssertEqual(centroid.longitude, -105.0)
    }
}
```

**Step 2: Run tests to verify they fail**

```bash
xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | tail -20
```

**Step 3: Implement PolygonGeometry**

```swift
import Foundation
import CoreLocation

enum PolygonGeometry {
    /// Centroid of a polygon using the signed-area formula.
    static func centroid(of polygon: [Coordinate]) -> Coordinate {
        guard !polygon.isEmpty else {
            return Coordinate(latitude: 0, longitude: 0)
        }
        guard polygon.count > 1 else {
            return polygon[0]
        }

        var cx = 0.0, cy = 0.0, area = 0.0
        let n = polygon.count
        for i in 0..<n {
            let j = (i + 1) % n
            let cross = polygon[i].latitude * polygon[j].longitude - polygon[j].latitude * polygon[i].longitude
            area += cross
            cx += (polygon[i].latitude + polygon[j].latitude) * cross
            cy += (polygon[i].longitude + polygon[j].longitude) * cross
        }
        area /= 2.0
        guard abs(area) > 1e-10 else {
            // Degenerate polygon — use simple average
            let lat = polygon.map(\.latitude).reduce(0, +) / Double(n)
            let lon = polygon.map(\.longitude).reduce(0, +) / Double(n)
            return Coordinate(latitude: lat, longitude: lon)
        }
        cx /= (6.0 * area)
        cy /= (6.0 * area)
        return Coordinate(latitude: cx, longitude: cy)
    }

    /// Signed area of a polygon (in coordinate-space units squared).
    static func area(of polygon: [Coordinate]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        var area = 0.0
        let n = polygon.count
        for i in 0..<n {
            let j = (i + 1) % n
            area += polygon[i].latitude * polygon[j].longitude
            area -= polygon[j].latitude * polygon[i].longitude
        }
        return abs(area / 2.0)
    }

    /// Nearest vertex on polygon to a reference point.
    static func nearestPoint(on polygon: [Coordinate], to reference: Coordinate) -> Coordinate {
        guard !polygon.isEmpty else {
            return Coordinate(latitude: 0, longitude: 0)
        }
        let refLocation = reference.clLocation
        return polygon.min(by: {
            $0.clLocation.distance(from: refLocation) < $1.clLocation.distance(from: refLocation)
        })!
    }

    /// Farthest vertex on polygon from a reference point.
    static func farthestPoint(on polygon: [Coordinate], to reference: Coordinate) -> Coordinate {
        guard !polygon.isEmpty else {
            return Coordinate(latitude: 0, longitude: 0)
        }
        let refLocation = reference.clLocation
        return polygon.max(by: {
            $0.clLocation.distance(from: refLocation) < $1.clLocation.distance(from: refLocation)
        })!
    }

    /// Check if a coordinate is inside a polygon using ray casting.
    static func contains(_ point: Coordinate, in polygon: [Coordinate]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        let n = polygon.count
        var j = n - 1
        for i in 0..<n {
            let yi = polygon[i].latitude, xi = polygon[i].longitude
            let yj = polygon[j].latitude, xj = polygon[j].longitude
            if ((yi > point.latitude) != (yj > point.latitude)) &&
                (point.longitude < (xj - xi) * (point.latitude - yi) / (yj - yi) + xi) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
```

**Step 4: Run tests to verify they pass**

```bash
xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | tail -20
```

**Step 5: Commit**

```bash
git add CourseBuilder/Models/PolygonGeometry.swift CourseBuilderTests/Models/PolygonGeometryTests.swift
git commit -m "feat: add polygon geometry utilities (centroid, area, containment)"
```

---

### Task 10: Overpass API Client

Create a service to query OpenStreetMap's Overpass API for golf course features.

**Files:**
- Create: `CourseBuilder/Services/OverpassAPIClient.swift`
- Create: `CourseBuilderTests/Services/OverpassAPIClientTests.swift`

**Step 1: Write the failing tests**

Test the Overpass query builder and response parser (not the network call itself):

```swift
import XCTest
@testable import CourseBuilder

final class OverpassAPIClientTests: XCTestCase {
    func testBuildQuery() {
        let bbox = OverpassAPIClient.BoundingBox(
            south: 39.78, west: -74.96, north: 39.80, east: -74.94
        )
        let query = OverpassAPIClient.buildQuery(bbox: bbox)
        XCTAssertTrue(query.contains("golf"))
        XCTAssertTrue(query.contains("39.78"))
        XCTAssertTrue(query.contains("-74.96"))
        XCTAssertTrue(query.contains("39.80"))
        XCTAssertTrue(query.contains("-74.94"))
    }

    func testParseFeaturesFromJSON() throws {
        let json = """
        {
          "elements": [
            {
              "type": "way",
              "id": 12345,
              "tags": { "golf": "fairway" },
              "geometry": [
                { "lat": 39.788, "lon": -74.958 },
                { "lat": 39.787, "lon": -74.957 },
                { "lat": 39.786, "lon": -74.956 }
              ]
            },
            {
              "type": "way",
              "id": 12346,
              "tags": { "golf": "green" },
              "geometry": [
                { "lat": 39.785, "lon": -74.955 },
                { "lat": 39.784, "lon": -74.954 }
              ]
            },
            {
              "type": "way",
              "id": 12347,
              "tags": { "golf": "hole", "ref": "1" },
              "geometry": [
                { "lat": 39.790, "lon": -74.960 },
                { "lat": 39.785, "lon": -74.955 }
              ]
            }
          ]
        }
        """
        let data = json.data(using: .utf8)!
        let result = try OverpassAPIClient.parseResponse(data: data)

        XCTAssertEqual(result.features.count, 2)
        XCTAssertEqual(result.features[0].type, .fairway)
        XCTAssertEqual(result.features[0].polygon.count, 3)
        XCTAssertEqual(result.features[1].type, .green)

        XCTAssertEqual(result.centerlines.count, 1)
        XCTAssertEqual(result.centerlines[0].holeNumber, 1)
        XCTAssertEqual(result.centerlines[0].coordinates.count, 2)
    }

    func testParseWaterHazardTypes() throws {
        let json = """
        {
          "elements": [
            {
              "type": "way",
              "id": 1,
              "tags": { "golf": "water_hazard" },
              "geometry": [{ "lat": 39.0, "lon": -105.0 }]
            },
            {
              "type": "way",
              "id": 2,
              "tags": { "golf": "lateral_water_hazard" },
              "geometry": [{ "lat": 39.0, "lon": -105.0 }]
            }
          ]
        }
        """
        let data = json.data(using: .utf8)!
        let result = try OverpassAPIClient.parseResponse(data: data)
        XCTAssertEqual(result.features.count, 2)
        XCTAssertTrue(result.features.allSatisfy { $0.type == .water })
    }

    func testBoundingBoxFromCoordinateWithPadding() {
        let center = Coordinate(latitude: 39.7879, longitude: -74.9580)
        let bbox = OverpassAPIClient.boundingBox(around: center, radiusMeters: 1000)
        // 1km radius should produce a box roughly 0.009 degrees lat and wider in lon
        XCTAssertLessThan(bbox.south, 39.7879)
        XCTAssertGreaterThan(bbox.north, 39.7879)
        XCTAssertLessThan(bbox.west, -74.9580)
        XCTAssertGreaterThan(bbox.east, -74.9580)
    }

    func testPadBoundingBox() {
        let bbox = OverpassAPIClient.BoundingBox(south: 39.78, west: -74.96, north: 39.80, east: -74.94)
        let padded = bbox.padded(by: 0.25)
        // 25% padding on each side
        let latSpan = 39.80 - 39.78 // 0.02
        let lonSpan = -74.94 - (-74.96) // 0.02
        XCTAssertEqual(padded.south, 39.78 - latSpan * 0.25, accuracy: 0.0001)
        XCTAssertEqual(padded.north, 39.80 + latSpan * 0.25, accuracy: 0.0001)
        XCTAssertEqual(padded.west, -74.96 - lonSpan * 0.25, accuracy: 0.0001)
        XCTAssertEqual(padded.east, -74.94 + lonSpan * 0.25, accuracy: 0.0001)
    }
}
```

**Step 2: Run tests to verify they fail**

```bash
xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | tail -20
```

**Step 3: Implement OverpassAPIClient**

```swift
import Foundation
import os

private let logger = Logger(subsystem: "golf.spot.CourseBuilder", category: "OverpassAPI")

actor OverpassAPIClient {
    struct BoundingBox {
        let south: Double
        let west: Double
        let north: Double
        let east: Double

        func padded(by fraction: Double) -> BoundingBox {
            let latSpan = north - south
            let lonSpan = east - west
            return BoundingBox(
                south: south - latSpan * fraction,
                west: west - lonSpan * fraction,
                north: north + latSpan * fraction,
                east: east + lonSpan * fraction
            )
        }
    }

    struct ParsedCenterline {
        let holeNumber: Int?
        let coordinates: [Coordinate]
    }

    struct ParsedResult {
        let features: [ParsedFeature]
        let centerlines: [ParsedCenterline]
        let courseBoundary: [Coordinate]?
    }

    struct ParsedFeature {
        let type: FeatureType
        let polygon: [Coordinate]
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Query Building

    static func buildQuery(bbox: BoundingBox) -> String {
        let b = "\(bbox.south),\(bbox.west),\(bbox.north),\(bbox.east)"
        return """
        [out:json][timeout:30];
        (
          way["golf"="fairway"](\(b));
          way["golf"="green"](\(b));
          way["golf"="tee"](\(b));
          way["golf"="bunker"](\(b));
          way["golf"="water_hazard"](\(b));
          way["golf"="lateral_water_hazard"](\(b));
          way["golf"="rough"](\(b));
          way["golf"="hole"](\(b));
          way["leisure"="golf_course"](\(b));
        );
        out geom;
        """
    }

    // MARK: - Bounding Box Helpers

    static func boundingBox(around center: Coordinate, radiusMeters: Double) -> BoundingBox {
        let latDelta = radiusMeters / 111_320.0
        let lonDelta = radiusMeters / (111_320.0 * cos(center.latitude * .pi / 180))
        return BoundingBox(
            south: center.latitude - latDelta,
            west: center.longitude - lonDelta,
            north: center.latitude + latDelta,
            east: center.longitude + lonDelta
        )
    }

    // MARK: - Network

    func fetchFeatures(bbox: BoundingBox) async throws -> ParsedResult {
        let query = Self.buildQuery(bbox: bbox)
        var request = URLRequest(url: URL(string: "https://overpass-api.de/api/interpreter")!)
        request.httpMethod = "POST"
        request.httpBody = query.data(using: .utf8)

        logger.debug("Overpass query for bbox: \(bbox.south),\(bbox.west),\(bbox.north),\(bbox.east)")

        let (data, _) = try await session.data(for: request)
        return try Self.parseResponse(data: data)
    }

    // MARK: - Response Parsing

    static func parseResponse(data: Data) throws -> ParsedResult {
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let elements = json["elements"] as? [[String: Any]] ?? []

        var features: [ParsedFeature] = []
        var centerlines: [ParsedCenterline] = []
        var courseBoundary: [Coordinate]?

        for element in elements {
            guard let tags = element["tags"] as? [String: String],
                  let geometry = element["geometry"] as? [[String: Double]] else {
                continue
            }

            let coords = geometry.compactMap { point -> Coordinate? in
                guard let lat = point["lat"], let lon = point["lon"] else { return nil }
                return Coordinate(latitude: lat, longitude: lon)
            }

            if let golfTag = tags["golf"] {
                switch golfTag {
                case "fairway":
                    features.append(ParsedFeature(type: .fairway, polygon: coords))
                case "green":
                    features.append(ParsedFeature(type: .green, polygon: coords))
                case "tee":
                    features.append(ParsedFeature(type: .tee, polygon: coords))
                case "bunker":
                    features.append(ParsedFeature(type: .bunker, polygon: coords))
                case "water_hazard", "lateral_water_hazard":
                    features.append(ParsedFeature(type: .water, polygon: coords))
                case "rough":
                    features.append(ParsedFeature(type: .rough, polygon: coords))
                case "hole":
                    let ref = tags["ref"]
                    let holeNumber = ref.flatMap { Int($0) }
                    centerlines.append(ParsedCenterline(holeNumber: holeNumber, coordinates: coords))
                default:
                    break
                }
            }

            if tags["leisure"] == "golf_course" {
                courseBoundary = coords
            }
        }

        return ParsedResult(
            features: features,
            centerlines: centerlines,
            courseBoundary: courseBoundary
        )
    }
}
```

**Step 4: Run tests to verify they pass**

```bash
xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | tail -20
```

**Step 5: Commit**

```bash
git add CourseBuilder/Services/OverpassAPIClient.swift CourseBuilderTests/Services/OverpassAPIClientTests.swift
git commit -m "feat: add OverpassAPIClient for OSM golf feature import"
```

---

### Task 11: OSM Feature-to-Hole Association

Build the logic that takes raw OSM features and centerlines and produces a fully associated Course with features assigned to holes.

**Files:**
- Create: `CourseBuilder/Services/OSMImporter.swift`
- Create: `CourseBuilderTests/Services/OSMImporterTests.swift`

**Step 1: Write the failing tests**

```swift
import XCTest
@testable import CourseBuilder

final class OSMImporterTests: XCTestCase {
    func testAssociateFeaturesViaCenterlines() {
        // A fairway polygon that the centerline passes through
        let fairway = OverpassAPIClient.ParsedFeature(
            type: .fairway,
            polygon: [
                Coordinate(latitude: 39.786, longitude: -74.958),
                Coordinate(latitude: 39.786, longitude: -74.956),
                Coordinate(latitude: 39.788, longitude: -74.956),
                Coordinate(latitude: 39.788, longitude: -74.958)
            ]
        )
        // A green polygon near the end of the centerline
        let green = OverpassAPIClient.ParsedFeature(
            type: .green,
            polygon: [
                Coordinate(latitude: 39.784, longitude: -74.955),
                Coordinate(latitude: 39.784, longitude: -74.953),
                Coordinate(latitude: 39.785, longitude: -74.953),
                Coordinate(latitude: 39.785, longitude: -74.955)
            ]
        )
        let centerline = OverpassAPIClient.ParsedCenterline(
            holeNumber: 1,
            coordinates: [
                Coordinate(latitude: 39.790, longitude: -74.960),
                Coordinate(latitude: 39.787, longitude: -74.957),
                Coordinate(latitude: 39.7845, longitude: -74.954)
            ]
        )

        let parsed = OverpassAPIClient.ParsedResult(
            features: [fairway, green],
            centerlines: [centerline],
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

        XCTAssertEqual(course.features.count, 2)
        XCTAssertFalse(course.subCourses[0].holes[0].featureIDs.isEmpty)
        XCTAssertFalse(course.subCourses[0].holes[0].centerline.isEmpty)
    }

    func testGeneratesCenterlinesWhenMissing() {
        let tee = OverpassAPIClient.ParsedFeature(
            type: .tee,
            polygon: [
                Coordinate(latitude: 39.790, longitude: -74.960),
                Coordinate(latitude: 39.791, longitude: -74.960),
                Coordinate(latitude: 39.791, longitude: -74.959),
                Coordinate(latitude: 39.790, longitude: -74.959)
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

        let parsed = OverpassAPIClient.ParsedResult(
            features: [tee, green],
            centerlines: [],
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

        // Should have generated a centerline from tee centroid to green centroid
        XCTAssertFalse(course.subCourses[0].holes[0].centerline.isEmpty)
    }
}
```

**Step 2: Run tests to verify they fail**

```bash
xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | tail -20
```

**Step 3: Implement OSMImporter**

```swift
import Foundation

enum OSMImporter {
    /// Apply parsed OSM data to a course: assign feature IDs, associate features with holes,
    /// and set centerlines.
    static func applyParsedResult(_ result: OverpassAPIClient.ParsedResult, to course: inout Course) {
        // Create Feature objects with auto-incremented IDs
        var nextID = course.nextFeatureID
        var features: [Feature] = []
        for parsed in result.features {
            features.append(Feature(id: nextID, type: parsed.type, polygon: parsed.polygon))
            nextID += 1
        }
        course.features.append(contentsOf: features)

        // If we have centerlines from OSM, use them to associate features
        if !result.centerlines.isEmpty {
            associateViaCenterlines(result.centerlines, features: features, course: &course)
        } else {
            associateViaProximity(features: features, course: &course)
        }
    }

    private static func associateViaCenterlines(
        _ centerlines: [OverpassAPIClient.ParsedCenterline],
        features: [Feature],
        course: inout Course
    ) {
        for subIdx in course.subCourses.indices {
            for holeIdx in course.subCourses[subIdx].holes.indices {
                let hole = course.subCourses[subIdx].holes[holeIdx]
                let globalHoleNumber = holeIdx + 1 + subIdx * course.subCourses[subIdx].holes.count

                // Find matching centerline
                if let cl = centerlines.first(where: { $0.holeNumber == globalHoleNumber })
                    ?? centerlines.first(where: { $0.holeNumber == hole.number && subIdx == 0 }) {
                    course.subCourses[subIdx].holes[holeIdx].centerline = cl.coordinates

                    // Associate features whose centroid is near the centerline
                    for feature in features {
                        let centroid = PolygonGeometry.centroid(of: feature.polygon)
                        if isNearCenterline(point: centroid, centerline: cl.coordinates, thresholdDegrees: 0.001) {
                            if !course.subCourses[subIdx].holes[holeIdx].featureIDs.contains(feature.id) {
                                course.subCourses[subIdx].holes[holeIdx].featureIDs.append(feature.id)
                            }
                        }
                    }
                }
            }
        }
    }

    private static func associateViaProximity(features: [Feature], course: inout Course) {
        // Group features by type to find tees and greens
        let tees = features.filter { $0.type == .tee }
        let greens = features.filter { $0.type == .green }

        for subIdx in course.subCourses.indices {
            for holeIdx in course.subCourses[subIdx].holes.indices {
                // Simple heuristic: assign closest unassigned tee and green
                let allAssigned = course.subCourses.flatMap(\.holes).flatMap(\.featureIDs)

                if let nearestTee = tees.first(where: { !allAssigned.contains($0.id) }) {
                    course.subCourses[subIdx].holes[holeIdx].featureIDs.append(nearestTee.id)
                }
                if let nearestGreen = greens.first(where: { !allAssigned.contains($0.id) }) {
                    course.subCourses[subIdx].holes[holeIdx].featureIDs.append(nearestGreen.id)
                }

                // Generate centerline from tee to green centroids
                let holeFeatureIDs = course.subCourses[subIdx].holes[holeIdx].featureIDs
                let holeFeatures = holeFeatureIDs.compactMap { id in features.first { $0.id == id } }
                let teeCentroid = holeFeatures.first { $0.type == .tee }.map { PolygonGeometry.centroid(of: $0.polygon) }
                let greenCentroid = holeFeatures.first { $0.type == .green }.map { PolygonGeometry.centroid(of: $0.polygon) }

                var centerline: [Coordinate] = []
                if let t = teeCentroid { centerline.append(t) }
                if let g = greenCentroid { centerline.append(g) }
                course.subCourses[subIdx].holes[holeIdx].centerline = centerline
            }
        }
    }

    private static func isNearCenterline(point: Coordinate, centerline: [Coordinate], thresholdDegrees: Double) -> Bool {
        for coord in centerline {
            let dlat = abs(point.latitude - coord.latitude)
            let dlon = abs(point.longitude - coord.longitude)
            if dlat < thresholdDegrees && dlon < thresholdDegrees {
                return true
            }
        }
        // Also check midpoints between centerline segments
        for i in 0..<(centerline.count - 1) {
            let mid = Coordinate(
                latitude: (centerline[i].latitude + centerline[i+1].latitude) / 2,
                longitude: (centerline[i].longitude + centerline[i+1].longitude) / 2
            )
            let dlat = abs(point.latitude - mid.latitude)
            let dlon = abs(point.longitude - mid.longitude)
            if dlat < thresholdDegrees && dlon < thresholdDegrees {
                return true
            }
        }
        return false
    }
}
```

**Step 4: Run tests to verify they pass**

```bash
xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | tail -20
```

**Step 5: Commit**

```bash
git add CourseBuilder/Services/OSMImporter.swift CourseBuilderTests/Services/OSMImporterTests.swift
git commit -m "feat: add OSMImporter for feature-to-hole association"
```

---

### Task 12: Rewrite MapEditorView — Data Layer

Replace the pin-based `EditablePin` system with a polygon/feature-based editing model. This task handles the data layer and state management; the next task handles the UI.

**Files:**
- Modify: `CourseBuilder/Views/PinEditorView.swift`
- Modify: `CourseBuilder/Views/MapEditorView.swift`

**Step 1: Replace EditablePin and PinType with new editing types**

Rewrite `PinEditorView.swift` with the new types and editor:

```swift
import SwiftUI

enum ToolMode: String, CaseIterable {
    case select = "Select"
    case drawPolygon = "Polygon"
    case drawCenterline = "Centerline"

    var shortcutKey: Character {
        switch self {
        case .select: "s"
        case .drawPolygon: "p"
        case .drawCenterline: "c"
        }
    }

    var systemImage: String {
        switch self {
        case .select: "cursorarrow"
        case .drawPolygon: "pentagon"
        case .drawCenterline: "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
}

struct FeatureEditorView: View {
    @Binding var feature: Feature
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Type", selection: $feature.type) {
                ForEach(FeatureType.allCases, id: \.self) { type in
                    Text(type.rawValue.capitalized).tag(type)
                }
            }

            Text("\(feature.polygon.count) vertices")
                .font(.caption)
                .foregroundStyle(.secondary)

            let centroid = PolygonGeometry.centroid(of: feature.polygon)
            Text("Center: \(centroid.latitude, specifier: "%.6f"), \(centroid.longitude, specifier: "%.6f")")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Text("Vertices")
                .font(.caption.bold())

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(feature.polygon.indices, id: \.self) { i in
                        HStack {
                            Text("\(i + 1)")
                                .font(.caption2)
                                .frame(width: 20)
                            TextField("Lat", value: $feature.polygon[i].latitude, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                            TextField("Lon", value: $feature.polygon[i].longitude, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                        }
                    }
                }
            }
            .frame(maxHeight: 200)

            Button("Delete Feature", role: .destructive, action: onDelete)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

**Step 2: Rewrite MapEditorView state and data flow**

Replace the pin-based state in `MapEditorView.swift` with feature/polygon state. The key changes:

- `@State private var pins: [EditablePin] = []` → removed entirely
- Selected feature tracked by `@State private var selectedFeatureID: Int?`
- Selected vertex tracked by `@State private var selectedVertexIndex: Int?`
- Drawing state: `@State private var drawingVertices: [Coordinate] = []`
- `loadPinsFromCourse()` / `applyPinsToCourse()` → no longer needed; features are directly on the course object

The full MapEditorView rewrite is extensive. Key sections:

1. **Map rendering**: Use `MapPolygon` and `MapPolyline` to render features and centerlines instead of `Annotation` pins
2. **Polygon drawing**: Click to add vertices, double-click to close and create Feature
3. **Vertex editing**: Select a feature, drag its vertices
4. **Sidebar**: List features per hole, show unassociated features
5. **Inspector**: Show FeatureEditorView for selected feature

This is the largest single task. Implement the core map rendering and interaction first, then iterate.

**Step 3: Build and verify**

```bash
xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' build 2>&1 | tail -20
```

**Step 4: Commit**

```bash
git add CourseBuilder/Views/PinEditorView.swift CourseBuilder/Views/MapEditorView.swift
git commit -m "feat: rewrite map editor for polygon drawing and feature editing"
```

---

### Task 13: MapEditorView — Polygon Rendering

Render feature polygons and centerlines on the map using MapKit overlays.

**Files:**
- Modify: `CourseBuilder/Views/MapEditorView.swift`

**Step 1: Add polygon and centerline rendering**

In the `Map { }` content builder, replace the pin `Annotation` loop with polygon/polyline overlays:

```swift
// Render feature polygons for current hole
ForEach(featuresForCurrentHole, id: \.id) { feature in
    MapPolygon(coordinates: feature.polygon.map(\.clCoordinate))
        .foregroundStyle(colorForFeatureType(feature.type).opacity(0.3))
        .stroke(
            selectedFeatureID == feature.id ? Color.white : colorForFeatureType(feature.type),
            lineWidth: selectedFeatureID == feature.id ? 3 : 1.5
        )
}

// Render centerline for current hole
if let hole = currentHole, !hole.centerline.isEmpty {
    MapPolyline(coordinates: hole.centerline.map(\.clCoordinate))
        .stroke(.white, lineWidth: 2)
}

// Render vertices of selected feature as draggable points
if let featureID = selectedFeatureID,
   let feature = course.features.first(where: { $0.id == featureID }) {
    ForEach(Array(feature.polygon.enumerated()), id: \.offset) { index, coord in
        Annotation("", coordinate: coord.clCoordinate) {
            Circle()
                .fill(selectedVertexIndex == index ? Color.white : Color.accentColor)
                .frame(width: 10, height: 10)
                .onTapGesture { selectedVertexIndex = index }
        }
    }
}

// Drawing in-progress polygon
if !drawingVertices.isEmpty {
    MapPolyline(coordinates: drawingVertices.map(\.clCoordinate))
        .stroke(.yellow, lineWidth: 2)
    ForEach(Array(drawingVertices.enumerated()), id: \.offset) { _, coord in
        Annotation("", coordinate: coord.clCoordinate) {
            Circle().fill(.yellow).frame(width: 8, height: 8)
        }
    }
}
```

**Step 2: Add feature type colors**

```swift
private func colorForFeatureType(_ type: FeatureType) -> Color {
    switch type {
    case .fairway: .green
    case .green: .mint
    case .tee: .blue
    case .bunker: .yellow
    case .water: .cyan
    case .rough: .brown
    }
}
```

**Step 3: Build and verify**

```bash
xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' build 2>&1 | tail -20
```

**Step 4: Commit**

```bash
git add CourseBuilder/Views/MapEditorView.swift
git commit -m "feat: add polygon and centerline rendering to map editor"
```

---

### Task 14: MapEditorView — Drawing and Interaction

Implement polygon drawing (click to place vertices, double-click to close), centerline drawing, and feature-to-hole association.

**Files:**
- Modify: `CourseBuilder/Views/MapEditorView.swift`

**Step 1: Implement polygon drawing interaction**

Handle map taps based on active tool:

```swift
.simultaneousGesture(
    SpatialTapGesture()
        .onEnded { tap in
            guard let coord = proxy.convert(tap.location, from: .local) else { return }
            let coordinate = Coordinate(coord)

            switch activeTool {
            case .select:
                // Try to select a feature by tap location
                selectFeatureAt(coordinate)
            case .drawPolygon:
                drawingVertices.append(coordinate)
            case .drawCenterline:
                drawingVertices.append(coordinate)
            }
        }
)
```

**Step 2: Implement double-click to close polygon**

Use `.onTapGesture(count: 2)` or track timing to detect double-click:

```swift
private func finishDrawing() {
    guard drawingVertices.count >= 3 || (activeTool == .drawCenterline && drawingVertices.count >= 2) else {
        drawingVertices = []
        return
    }

    if activeTool == .drawPolygon {
        let feature = Feature(
            id: course.nextFeatureID,
            type: pendingFeatureType,
            polygon: drawingVertices
        )
        course.features.append(feature)
        // Associate with current hole
        if selectedSubCourseIndex < course.subCourses.count {
            let holeIdx = course.subCourses[selectedSubCourseIndex].holes.firstIndex { $0.number == selectedHole }
            if let idx = holeIdx {
                course.subCourses[selectedSubCourseIndex].holes[idx].featureIDs.append(feature.id)
            }
        }
        selectedFeatureID = feature.id
    } else if activeTool == .drawCenterline {
        if selectedSubCourseIndex < course.subCourses.count,
           let idx = course.subCourses[selectedSubCourseIndex].holes.firstIndex(where: { $0.number == selectedHole }) {
            course.subCourses[selectedSubCourseIndex].holes[idx].centerline = drawingVertices
        }
    }

    drawingVertices = []
    activeTool = .select
}
```

**Step 3: Add feature type picker for new polygons**

Add a `@State private var pendingFeatureType: FeatureType = .fairway` and show a picker in the toolbar or as a popover when drawing.

**Step 4: Update sidebar for feature association**

Replace the pin list with a feature list per hole, showing feature type and ID. Add an "Unassociated" section for features not assigned to any hole.

**Step 5: Build and verify**

```bash
xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' build 2>&1 | tail -20
```

**Step 6: Commit**

```bash
git add CourseBuilder/Views/MapEditorView.swift
git commit -m "feat: add polygon drawing, centerline drawing, and feature association"
```

---

### Task 15: OSM Import UI Flow

Add an "Import from OSM" button to the map editor that triggers the Overpass API import pipeline.

**Files:**
- Modify: `CourseBuilder/Views/MapEditorView.swift`

**Step 1: Add import state and button**

```swift
@State private var isImportingOSM = false
@State private var osmImportStatus = ""
```

Add to the toolbar:

```swift
Button {
    Task { await importFromOSM() }
} label: {
    Label("Import OSM", systemImage: "square.and.arrow.down")
}
.disabled(isImportingOSM)
```

**Step 2: Implement importFromOSM()**

```swift
private func importFromOSM() async {
    isImportingOSM = true
    osmImportStatus = "Querying OpenStreetMap..."

    let client = OverpassAPIClient()

    // Determine bounding box
    let clubhouseCoord = course.location.coordinate
    var bbox: OverpassAPIClient.BoundingBox

    // First try to get the course boundary
    let searchBBox = OverpassAPIClient.boundingBox(around: clubhouseCoord, radiusMeters: 1000)

    do {
        let result = try await client.fetchFeatures(bbox: searchBBox)

        if let boundary = result.courseBoundary, boundary.count >= 3 {
            // Use boundary bbox padded by 25%
            let lats = boundary.map(\.latitude)
            let lons = boundary.map(\.longitude)
            bbox = OverpassAPIClient.BoundingBox(
                south: lats.min()!, west: lons.min()!,
                north: lats.max()!, east: lons.max()!
            ).padded(by: 0.25)
        } else {
            bbox = searchBBox
        }

        osmImportStatus = "Processing \(result.features.count) features..."
        OSMImporter.applyParsedResult(result, to: &course)

        osmImportStatus = "Imported \(result.features.count) features"
        try? store.save(course)
    } catch {
        osmImportStatus = "Import failed: \(error.localizedDescription)"
    }

    isImportingOSM = false
}
```

**Step 3: Build and verify**

```bash
xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' build 2>&1 | tail -20
```

**Step 4: Commit**

```bash
git add CourseBuilder/Views/MapEditorView.swift
git commit -m "feat: add OSM import button and flow to map editor"
```

---

### Task 16: Delete Old Unused Code

Remove any remaining dead code from the pin-based system that wasn't already removed.

**Files:**
- Audit: all files for references to `Green`, `EditablePin`, `PinType`, old `FeatureType` cases
- Modify: any files with dead references

**Step 1: Search for dead references**

```bash
grep -r "EditablePin\|PinType\|\.greenFront\|\.greenMiddle\|\.greenBack\|\.bunkerFront\|\.bunkerBack\|\.waterFront\|\.waterBack" CourseBuilder/
```

**Step 2: Remove any found references**

**Step 3: Run full test suite**

```bash
xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | tail -20
```

**Step 4: Commit**

```bash
git add -A
git commit -m "chore: remove dead pin-based editing code"
```

---

### Task 17: Final Integration Test

Run the full build and test suite, fix any remaining issues.

**Step 1: Clean build**

```bash
xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' clean build 2>&1 | tail -30
```

**Step 2: Run all tests**

```bash
xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | tail -30
```

**Step 3: Fix any failures**

**Step 4: Final commit if needed**

```bash
git add -A
git commit -m "fix: resolve integration issues from polygon model rewrite"
```
