# Auto-Sequenced Tee Placement Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Auto-sequence tee placement in the map editor by yardage order, and sort scorecard tee columns by descending total yardage.

**Architecture:** Add a computed method to MapEditorView that determines the next tee to place based on the current hole's yardages and already-placed pins. Sort `course.tees` by descending total yardage at both import paths (API and scraper/OCR).

**Tech Stack:** Swift, SwiftUI, MapKit

---

### Task 1: Sort tees by descending yardage in ScorecardImporter.buildCourse

**Files:**
- Modify: `CourseBuilder/Services/ScorecardImporter.swift:109-126`
- Test: `CourseBuilderTests/ScorecardImporterTests.swift`

**Step 1: Write the failing test**

```swift
func testBuildCourseSortsTeesByDescendingTotalYardage() throws {
    let importer = ScorecardImporter(apiKey: nil)
    let data = ScorecardData(
        holes: [
            Hole(number: 1, par: 4, yardages: ["Blue": 350, "Black": 400, "Red": 280]),
            Hole(number: 2, par: 3, yardages: ["Blue": 150, "Black": 180, "Red": 120]),
        ],
        teeNames: ["Blue", "Black", "Red"]
    )

    let course = importer.buildCourse(from: data, name: "Test", city: "City", state: "ST")

    XCTAssertEqual(course.tees.map(\.name), ["Black", "Blue", "Red"])
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | grep -E '(Test Case|PASS|FAIL|error:)'`
Expected: FAIL — tees are in input order ["Blue", "Black", "Red"] not sorted order

**Step 3: Write minimal implementation**

In `ScorecardImporter.swift`, modify `buildCourse` (line 109-126). After creating `tees` and `subCourses`, sort `tees` by descending total yardage before returning:

```swift
func buildCourse(from data: ScorecardData, name: String, city: String, state: String) -> Course {
    let tees = data.teeNames.map { teeName in
        TeeDefinition(
            name: teeName,
            color: TeeDefinition.defaultColor(for: teeName)
        )
    }

    let holeGroups = Hole.splitIntoSubCourses(data.holes, names: ["Front", "Back"])
    let subCourses = holeGroups.map { SubCourse(name: $0.name, holes: $0.holes) }

    let allHoles = data.holes
    let sortedTees = tees.sorted { a, b in
        let aTotal = allHoles.compactMap { $0.yardages[a.name] }.reduce(0, +)
        let bTotal = allHoles.compactMap { $0.yardages[b.name] }.reduce(0, +)
        return aTotal > bTotal
    }

    return Course(
        name: name,
        location: CourseLocation(address: "", city: city, state: state, country: "", coordinate: Coordinate(latitude: 0, longitude: 0)),
        tees: sortedTees,
        subCourses: subCourses
    )
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | grep -E '(Test Case|PASS|FAIL|error:)'`
Expected: PASS

**Step 5: Commit**

```bash
git add CourseBuilder/Services/ScorecardImporter.swift CourseBuilderTests/ScorecardImporterTests.swift
git commit -m "feat: sort tees by descending yardage in ScorecardImporter.buildCourse"
```

---

### Task 2: Sort tees by descending yardage in GolfCourseAPIClient.convertToCourse

**Files:**
- Modify: `CourseBuilder/Services/GolfCourseAPIClient.swift:397-406`
- Test: `CourseBuilderTests/GolfCourseAPIClientTests.swift`

**Step 1: Write the failing test**

```swift
func testConvertToCourseSortsTeesByDescendingTotalYardage() throws {
    let detail = GolfCourseAPIClient.CourseDetail(
        id: 1,
        courseName: "Test Course",
        clubName: "Test Club",
        location: GolfCourseAPIClient.APILocation(
            address: "123 Main", city: "City", state: "ST",
            country: "US", zipCode: nil, latitude: 40.0, longitude: -80.0
        ),
        tees: GolfCourseAPIClient.TeeSets(
            male: [
                GolfCourseAPIClient.TeeSet(
                    teeName: "Blue", courseRating: nil, slopeRating: nil,
                    totalYards: nil, parTotal: nil,
                    frontCourseRating: nil, frontSlopeRating: nil,
                    backCourseRating: nil, backSlopeRating: nil,
                    holes: [
                        GolfCourseAPIClient.APIHole(number: 1, par: 4, yardage: 350, handicap: 1),
                        GolfCourseAPIClient.APIHole(number: 2, par: 3, yardage: 150, handicap: 3),
                    ]
                ),
                GolfCourseAPIClient.TeeSet(
                    teeName: "Black", courseRating: nil, slopeRating: nil,
                    totalYards: nil, parTotal: nil,
                    frontCourseRating: nil, frontSlopeRating: nil,
                    backCourseRating: nil, backSlopeRating: nil,
                    holes: [
                        GolfCourseAPIClient.APIHole(number: 1, par: 4, yardage: 400, handicap: 1),
                        GolfCourseAPIClient.APIHole(number: 2, par: 3, yardage: 180, handicap: 3),
                    ]
                ),
            ],
            female: nil
        )
    )

    let course = try GolfCourseAPIClient.convertToCourse(detail: detail)

    XCTAssertEqual(course.tees.map(\.name), ["Black", "Blue"])
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | grep -E '(Test Case|PASS|FAIL|error:)'`
Expected: FAIL — `allTeeDefinitions.values` gives dictionary-order (unpredictable), not sorted

**Step 3: Write minimal implementation**

In `GolfCourseAPIClient.swift`, modify the return block at lines 397-406. Replace `Array(allTeeDefinitions.values)` with a sorted version. After building `allSubCourses`, compute total yardage per tee from all holes across all sub-courses:

```swift
// Sort tee definitions by descending total yardage
let allHoles = allSubCourses.flatMap(\.holes)
let sortedTees = Array(allTeeDefinitions.values).sorted { a, b in
    let aTotal = allHoles.compactMap { $0.yardages[a.name] }.reduce(0, +)
    let bTotal = allHoles.compactMap { $0.yardages[b.name] }.reduce(0, +)
    return aTotal > bTotal
}

return Course(
    name: first.courseName,
    clubName: first.clubName,
    golfCourseAPIIds: golfCourseAPIIds,
    location: location,
    tees: sortedTees,
    subCourses: allSubCourses
)
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | grep -E '(Test Case|PASS|FAIL|error:)'`
Expected: PASS

**Step 5: Commit**

```bash
git add CourseBuilder/Services/GolfCourseAPIClient.swift CourseBuilderTests/GolfCourseAPIClientTests.swift
git commit -m "feat: sort tees by descending yardage in GolfCourseAPIClient.convertToCourse"
```

---

### Task 3: Add remainingTeesForCurrentHole method to MapEditorView

This is the core sequencing logic. It computes which tees still need placement for the current hole, ordered by descending yardage.

**Files:**
- Modify: `CourseBuilder/Views/MapEditorView.swift`

**Step 1: Add the method**

Add this method in the `// MARK: - Pin Management` section (after line 509):

```swift
/// Returns tees still needing placement for the current hole, ordered by descending yardage.
/// Tees with yardage data come first (sorted by yards desc), then tees without yardage (in course.tees order).
private func remainingTeesForCurrentHole() -> [(name: String, yards: Int?)] {
    let currentHole: Hole? = {
        guard selectedSubCourseIndex < course.subCourses.count else { return nil }
        return course.subCourses[selectedSubCourseIndex].holes.first { $0.number == selectedHole }
    }()

    // Find tee names already placed for this hole
    let placedTeeNames = Set(
        pinsForCurrentHole
            .filter { $0.pinType == .tee }
            .compactMap(\.teeName)
    )

    // Split into tees with yardage and tees without
    var withYardage: [(name: String, yards: Int)] = []
    var withoutYardage: [String] = []

    for tee in course.tees {
        guard !placedTeeNames.contains(tee.name) else { continue }
        if let yards = currentHole?.yardages[tee.name], yards > 0 {
            withYardage.append((name: tee.name, yards: yards))
        } else {
            withoutYardage.append(tee.name)
        }
    }

    // Sort tees with yardage by descending yards
    withYardage.sort { $0.yards > $1.yards }

    // Combine: yardage tees first, then no-yardage tees in definition order
    return withYardage.map { (name: $0.name, yards: Optional($0.yards)) }
         + withoutYardage.map { (name: $0, yards: nil) }
}
```

**Step 2: Verify build**

Run: `xcodebuild -scheme CourseBuilder -destination 'platform=macOS' build 2>&1 | grep -E '(BUILD|error:)'`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add CourseBuilder/Views/MapEditorView.swift
git commit -m "feat: add remainingTeesForCurrentHole computed method"
```

---

### Task 4: Wire tee sequencing into placePin and tool hint

**Files:**
- Modify: `CourseBuilder/Views/MapEditorView.swift:487-509` (placePin method)
- Modify: `CourseBuilder/Views/MapEditorView.swift:453-468` (toolHint computed property)

**Step 1: Modify placePin to use the sequence**

Replace the tee assignment at line 493 and the click reset logic at lines 501-509:

```swift
private func placePin(at coordinate: Coordinate) {
    let pinType = pinTypeForCurrentClick()

    // For tee tool, determine the tee name from the sequence
    let teeName: String? = {
        if pinType == .tee {
            return remainingTeesForCurrentHole().first?.name
        }
        return nil
    }()

    // If tee tool but no remaining tees, do nothing
    if activeTool == .tee && teeName == nil {
        return
    }

    let pin = EditablePin(
        id: UUID(),
        pinType: pinType,
        coordinate: coordinate,
        teeName: teeName,
        subCourseIndex: selectedSubCourseIndex,
        holeNumber: selectedHole
    )
    pins.append(pin)
    selectedPinID = pin.id
    toolClickIndex += 1

    // Reset click index or auto-switch when sequence is complete
    switch activeTool {
    case .tee:
        if remainingTeesForCurrentHole().isEmpty {
            activeTool = .select
            toolClickIndex = 0
            statusMessage = "All tees placed"
        }
    case .green:
        if toolClickIndex >= 3 { toolClickIndex = 0 }
    case .bunker, .water:
        if toolClickIndex >= 2 { toolClickIndex = 0 }
    default:
        toolClickIndex = 0
    }
}
```

**Step 2: Update toolHint for dynamic tee hints**

Replace the `.tee` case in the `toolHint` computed property (line 456):

```swift
private var toolHint: String {
    switch activeTool {
    case .select: "Click pin to select | Hold+drag to move | Esc to deselect | Del to remove"
    case .tee:
        if let next = remainingTeesForCurrentHole().first {
            if let yards = next.yards {
                "Click to place \(next.name) tee (\(yards) yds)"
            } else {
                "Click to place \(next.name) tee"
            }
        } else {
            "All tees placed for this hole"
        }
    case .green:
        switch toolClickIndex {
        case 0: "Click map: green front"
        case 1: "Click map: green middle"
        default: "Click map: green back"
        }
    case .bunker:
        toolClickIndex == 0 ? "Click map: bunker front" : "Click map: bunker back"
    case .water:
        toolClickIndex == 0 ? "Click map: water front" : "Click map: water back"
    }
}
```

**Step 3: Verify build**

Run: `xcodebuild -scheme CourseBuilder -destination 'platform=macOS' build 2>&1 | grep -E '(BUILD|error:)'`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add CourseBuilder/Views/MapEditorView.swift
git commit -m "feat: wire tee sequencing into placePin and tool hints"
```

---

### Task 5: Manual verification

**Step 1: Launch the app and verify scorecard column ordering**

1. Open an existing course or import a new one via API/scraping
2. Verify the scorecard table shows tee columns ordered by descending total yardage (longest left, shortest right)

**Step 2: Verify tee tool auto-sequencing**

1. Open the map editor for a course with scorecard data
2. Select a hole and press `t` to activate the tee tool
3. Verify the status bar shows the longest tee name and yardage (e.g., "Click to place Black tee (450 yds)")
4. Click the map — verify the pin is created with the correct tee name
5. Verify the hint updates to the next tee in descending yardage order
6. Continue clicking until all tees are placed
7. Verify the tool auto-switches to select and shows "All tees placed"

**Step 3: Verify resume behavior**

1. Activate the tee tool, place 2 of 4 tees
2. Press `s` to switch to select tool
3. Press `t` to switch back to tee tool
4. Verify the hint shows the 3rd tee (not the 1st)

**Step 4: Commit**

```bash
git commit --allow-empty -m "chore: manual verification of auto-tee-placement complete"
```
