# Code Review Fixes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix all issues identified in the PR #1 code review: bugs, missing tests, DRY violations, stale plans, dead code, and robustness improvements.

**Architecture:** Targeted fixes across models, services, and views. Extract shared utilities to reduce duplication. Add debounced auto-save. Add comprehensive tests for untested logic.

**Tech Stack:** Swift, SwiftUI, XCTest, macOS 14+

**Build & Test:**
```bash
xcodebuild -scheme CourseBuilder -destination 'platform=macOS' build
xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test
```

---

### Task 1: Add `Hole.renumbered(to:)` to eliminate renumbering duplication

Three places manually copy every Hole field just to change the number. Extract a method on Hole.

**Files:**
- Modify: `CourseBuilder/Models/Hole.swift`
- Test: `CourseBuilderTests/Models/HoleTests.swift`

**Step 1: Write the failing test**

Add to `HoleTests.swift`:

```swift
func testRenumbered() {
    let hole = Hole(
        number: 7,
        par: 5,
        maleHandicap: 3,
        femaleHandicap: 5,
        yardages: ["Blue": 545]
    )
    let renumbered = hole.renumbered(to: 1)
    XCTAssertEqual(renumbered.number, 1)
    XCTAssertEqual(renumbered.par, 5)
    XCTAssertEqual(renumbered.maleHandicap, 3)
    XCTAssertEqual(renumbered.femaleHandicap, 5)
    XCTAssertEqual(renumbered.yardages["Blue"], 545)
    XCTAssertNotEqual(renumbered.id, hole.id) // new identity
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test`
Expected: FAIL — `renumbered(to:)` does not exist

**Step 3: Write minimal implementation**

Add to `Hole.swift`:

```swift
func renumbered(to newNumber: Int) -> Hole {
    Hole(
        number: newNumber,
        par: par,
        maleHandicap: maleHandicap,
        femaleHandicap: femaleHandicap,
        yardages: yardages,
        tees: tees,
        green: green,
        features: features
    )
}
```

**Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test`
Expected: PASS

**Step 5: Replace all manual renumbering**

In `GolfCourseAPIClient.swift` lines 321-332, replace:
```swift
let renumberedHoles = group.holes.enumerated().map { (index, hole) in
    Hole(
        number: index + 1,
        par: hole.par,
        maleHandicap: hole.maleHandicap,
        femaleHandicap: hole.femaleHandicap,
        yardages: hole.yardages,
        tees: hole.tees,
        green: hole.green,
        features: hole.features
    )
}
```
with:
```swift
let renumberedHoles = group.holes.enumerated().map { (index, hole) in
    hole.renumbered(to: index + 1)
}
```

In `ScorecardImporter.swift` lines 119-130 and 131-142, replace both `enumerated().map` blocks with the same `hole.renumbered(to: index + 1)` pattern.

**Step 6: Run tests to verify they pass**

**Step 7: Commit**

```
refactor: extract Hole.renumbered(to:) to eliminate duplication
```

---

### Task 2: Extract shared `TeeDefinition.defaultColor(for:)`

Duplicated in `GolfCourseAPIClient` and `ScorecardImporter`. The importer version also misses the "green" case.

**Files:**
- Modify: `CourseBuilder/Models/Course.swift`
- Modify: `CourseBuilder/Services/GolfCourseAPIClient.swift`
- Modify: `CourseBuilder/Services/ScorecardImporter.swift`
- Test: `CourseBuilderTests/Models/CourseTests.swift`

**Step 1: Write the failing test**

Add to `CourseTests.swift`:

```swift
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
```

**Step 2: Run test to verify it fails**

**Step 3: Add static method to `TeeDefinition` in `Course.swift`**

```swift
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
```

**Step 4: Run tests to verify they pass**

**Step 5: Delete `defaultColor` from both `GolfCourseAPIClient.swift` (lines 416-435) and `ScorecardImporter.swift` (lines 159-169). Update all call sites to use `TeeDefinition.defaultColor(for:)`.**

**Step 6: Run tests to verify they pass**

**Step 7: Commit**

```
refactor: extract TeeDefinition.defaultColor(for:) to shared location
```

---

### Task 3: Extract shared hole-splitting utility

Both `GolfCourseAPIClient.convertToCourse` and `ScorecardImporter.buildCourse` split holes at midpoint and renumber. Extract this.

**Files:**
- Modify: `CourseBuilder/Models/Hole.swift`
- Modify: `CourseBuilder/Services/GolfCourseAPIClient.swift`
- Modify: `CourseBuilder/Services/ScorecardImporter.swift`
- Test: `CourseBuilderTests/Models/HoleTests.swift`

**Step 1: Write the failing tests**

Add to `HoleTests.swift`:

```swift
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
    // 9 holes should NOT split — single sub-course
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
    // All holes renumbered 1-9
    XCTAssertEqual(groups[2].holes[0].number, 1)
    XCTAssertEqual(groups[2].holes[8].number, 9)
}
```

**Step 2: Run test to verify it fails**

**Step 3: Add static method to `Hole` in `Hole.swift`**

```swift
/// Split holes into sub-courses by dividing evenly among the given names.
/// If there are fewer holes than names, returns a single group.
/// All holes are renumbered 1-based within each group.
static func splitIntoSubCourses(_ holes: [Hole], names: [String]) -> [(name: String, holes: [Hole])] {
    guard holes.count > 1, names.count >= 2 else {
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
```

**Step 4: Run tests to verify they pass**

**Step 5: Replace splitting logic in `GolfCourseAPIClient.swift` (lines 302-332) and `ScorecardImporter.swift` (lines 113-149) with calls to `Hole.splitIntoSubCourses`.**

In `GolfCourseAPIClient.swift`, replace the midpoint splitting + renumbering block with:
```swift
let holeGroups = Hole.splitIntoSubCourses(allHoles, names: subCourseNames)
```

In `ScorecardImporter.swift`, replace the midpoint splitting + renumbering block with:
```swift
let holeGroups = Hole.splitIntoSubCourses(allHoles, names: ["Front", "Back"])
let subCourses = holeGroups.map { SubCourse(name: $0.name, holes: $0.holes) }
```

**Step 6: Run tests to verify they pass**

**Step 7: Commit**

```
refactor: extract Hole.splitIntoSubCourses to fix 9-hole and 3+ name splitting
```

---

### Task 4: Fix `fatalError` in `convertToCourse` and add HTTP status checking

**Files:**
- Modify: `CourseBuilder/Services/GolfCourseAPIClient.swift`
- Modify: `CourseBuilder/Services/ScorecardScraper.swift`
- Test: `CourseBuilderTests/Services/GolfCourseAPIClientTests.swift`

**Step 1: Write the failing test**

Add to `GolfCourseAPIClientTests.swift`:

```swift
func testConvertToCourseEmptyDetailsThrows() {
    XCTAssertThrowsError(try GolfCourseAPIClient.convertToCourse(details: [])) { error in
        XCTAssertTrue(error is GolfCourseAPIClient.APIError)
    }
}
```

**Step 2: Run test to verify it fails**

**Step 3: Implementation**

In `GolfCourseAPIClient.swift`:

1. Add an error enum:
```swift
enum APIError: LocalizedError {
    case emptyDetails
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .emptyDetails: "convertToCourse requires at least one CourseDetail"
        case .httpError(let code): "HTTP error \(code)"
        }
    }
}
```

2. Change `convertToCourse` signature to `throws` and replace the `fatalError` with `throw APIError.emptyDetails`:
```swift
static func convertToCourse(details: [CourseDetail]) throws -> Course {
    guard let first = details.first else {
        throw APIError.emptyDetails
    }
    // ... rest unchanged
}
```

3. Update `convertToCourse(detail:)` to also be `throws`:
```swift
static func convertToCourse(detail: CourseDetail) throws -> Course {
    return try convertToCourse(details: [detail])
}
```

4. Add HTTP status checking to `search()` and `fetchCourse()`:
```swift
guard let httpResponse = response as? HTTPURLResponse else {
    throw APIError.httpError(0)
}
guard (200...299).contains(httpResponse.statusCode) else {
    throw APIError.httpError(httpResponse.statusCode)
}
```

5. Remove the `print` statement on line 160.

6. In `ScorecardScraper.fetchAndParse`, add HTTP status checking:
```swift
let (data, response) = try await URLSession.shared.data(from: url)
if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
    throw ScraperError.parseError("HTTP \(httpResponse.statusCode)")
}
```

**Step 4: Update all call sites** — `convertToCourse` is called in:
- `ScorecardImporter.importScorecard` (line 49): already in a `do/catch`, add `try`
- `GolfCourseAPIClientTests.swift` (line 102): add `try`
- `CourseListView.swift` `fetchAndAddCourses` (line 352): already in a `do/catch`, add `try`

**Step 5: Run tests to verify they pass**

**Step 6: Commit**

```
fix: replace fatalError with thrown error, add HTTP status checking
```

---

### Task 5: Fix GolfLink slug construction

The slug construction incorrectly strips the `/` between city and course name.

**Files:**
- Modify: `CourseBuilder/Services/ScorecardImporter.swift`
- Test: `CourseBuilderTests/Services/ScorecardImporterTests.swift` (new)

**Step 1: Write the failing test**

Create `CourseBuilderTests/Services/ScorecardImporterTests.swift`:

```swift
import XCTest
@testable import CourseBuilder

final class ScorecardImporterTests: XCTestCase {
    func testBuildCourseFromScorecardData() {
        let holes = (1...18).map { number in
            Hole(number: number, par: number <= 9 ? 4 : 5, yardages: ["Blue": 400])
        }
        let data = ScorecardData(holes: holes, teeNames: ["Blue", "White"])

        let importer = ScorecardImporter(apiKey: nil)
        let course = importer.buildCourseForTesting(from: data, name: "Test", city: "Denver", state: "CO")

        XCTAssertEqual(course.name, "Test")
        XCTAssertEqual(course.subCourses.count, 2)
        XCTAssertEqual(course.subCourses[0].name, "Front")
        XCTAssertEqual(course.subCourses[0].holes.count, 9)
        XCTAssertEqual(course.subCourses[1].name, "Back")
        XCTAssertEqual(course.subCourses[1].holes.count, 9)
        XCTAssertEqual(course.tees.count, 2)
        // Holes renumbered 1-9
        XCTAssertEqual(course.subCourses[1].holes[0].number, 1)
    }

    func testBuildCourse9Holes() {
        let holes = (1...9).map { Hole(number: $0, par: 4) }
        let data = ScorecardData(holes: holes, teeNames: ["Blue"])

        let importer = ScorecardImporter(apiKey: nil)
        let course = importer.buildCourseForTesting(from: data, name: "Nine", city: "Denver", state: "CO")

        XCTAssertEqual(course.subCourses.count, 1)
        XCTAssertEqual(course.subCourses[0].holes.count, 9)
    }
}
```

Note: `buildCourse` is `private`. Either change it to `internal` for testing or add a `@testable` visible wrapper. The simplest approach: change `private` to `internal` on `buildCourse`.

**Step 2: Run test to verify it fails** (method is private)

**Step 3: Fix the slug and change visibility**

1. Change `buildCourse` from `private` to `internal` in `ScorecardImporter.swift`.

2. Fix the GolfLink slug (lines 61-65):
```swift
let citySlug = city
    .lowercased()
    .replacing(/[^a-z0-9\s]/, with: "")
    .replacing(/\s+/, with: "-")
let courseSlug = courseName
    .lowercased()
    .replacing(/[^a-z0-9\s]/, with: "")
    .replacing(/\s+/, with: "-")
let url = URL(string: "https://www.golflink.com/golf-courses/\(state.lowercased())/\(citySlug)/\(courseSlug)")!
```

**Step 4: Run tests to verify they pass**

**Step 5: Commit**

```
fix: correct GolfLink slug construction, add ScorecardImporter tests
```

---

### Task 6: Add `convertToCourse` multi-detail and `extractSubCourseNames` tests

**Files:**
- Test: `CourseBuilderTests/Services/GolfCourseAPIClientTests.swift`

**Step 1: Write the tests**

Add to `GolfCourseAPIClientTests.swift`:

```swift
func testExtractSubCourseNamesWithSlash() throws {
    // Test via convertToCourse with a course named "Vista/Canyon"
    let json = """
    {
        "id": 1,
        "course_name": "Vista/Canyon",
        "club_name": "Test Club",
        "location": { "address": "", "city": "Denver", "state": "CO", "country": "US", "zip_code": "" },
        "tees": {
            "male": [{
                "tee_name": "Blue",
                "course_rating": 72.0, "slope_rating": 130,
                "front_course_rating": 36.0, "front_slope_rating": 128,
                "back_course_rating": 36.0, "back_slope_rating": 132,
                "total_yards": 6800, "par_total": 72,
                "holes": [
                    { "par": 4, "yardage": 400, "handicap": 1 },
                    { "par": 4, "yardage": 410, "handicap": 2 },
                    { "par": 4, "yardage": 420, "handicap": 3 },
                    { "par": 4, "yardage": 430, "handicap": 4 }
                ]
            }],
            "female": []
        }
    }
    """.data(using: .utf8)!

    let detail = try JSONDecoder().decode(GolfCourseAPIClient.CourseDetail.self, from: json)
    let course = try GolfCourseAPIClient.convertToCourse(detail: detail)

    XCTAssertEqual(course.subCourses.count, 2)
    XCTAssertEqual(course.subCourses[0].name, "Vista")
    XCTAssertEqual(course.subCourses[1].name, "Canyon")
}

func testConvertToCourseMultipleDetails() throws {
    let makeDetail: (Int, String) -> GolfCourseAPIClient.CourseDetail = { id, name in
        let json = """
        {
            "id": \(id),
            "course_name": "\(name)",
            "club_name": "Test Club",
            "location": { "address": "", "city": "Denver", "state": "CO", "country": "US", "zip_code": "" },
            "tees": {
                "male": [{
                    "tee_name": "Blue",
                    "course_rating": 36.0, "slope_rating": 130,
                    "front_course_rating": 36.0, "front_slope_rating": 128,
                    "back_course_rating": 36.0, "back_slope_rating": 132,
                    "total_yards": 3400, "par_total": 36,
                    "holes": [
                        { "par": 4, "yardage": 400, "handicap": 1 },
                        { "par": 3, "yardage": 180, "handicap": 9 }
                    ]
                }],
                "female": []
            }
        }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(GolfCourseAPIClient.CourseDetail.self, from: json)
    }

    let details = [makeDetail(1, "Front Nine"), makeDetail(2, "Back Nine")]
    let course = try GolfCourseAPIClient.convertToCourse(details: details)

    // Should have sub-courses from both details
    XCTAssertEqual(course.golfCourseAPIIds, [1, 2])
    XCTAssertFalse(course.subCourses.isEmpty)
}
```

**Step 2: Run tests to verify they pass** (these test existing behavior)

**Step 3: Commit**

```
test: add multi-detail and sub-course name extraction tests
```

---

### Task 7: Add debounced auto-save

**Files:**
- Modify: `CourseBuilder/Views/MapEditorView.swift`
- Modify: `CourseBuilder/Views/ScorecardView.swift`

**Step 1: Add debounce to `ScorecardView.swift`**

Replace line 140-142:
```swift
.onChange(of: course) { _, newValue in
    try? store.save(newValue)
}
```
with:
```swift
.onChange(of: course) { _, _ in
    saveTask?.cancel()
    saveTask = Task {
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        try? store.save(course)
    }
}
```

Add state variable:
```swift
@State private var saveTask: Task<Void, Never>?
```

**Step 2: Add debounce to `MapEditorView.swift`**

Replace lines 92-94:
```swift
.onChange(of: pins) {
    saveCourse()
}
```
with:
```swift
.onChange(of: pins) {
    saveTask?.cancel()
    saveTask = Task {
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        saveCourse()
    }
}
```

Add state variable:
```swift
@State private var saveTask: Task<Void, Never>?
```

**Step 3: Build and verify**

Run: `xcodebuild -scheme CourseBuilder -destination 'platform=macOS' build`

**Step 4: Commit**

```
perf: debounce auto-save to avoid rapid file I/O
```

---

### Task 8: Fix `TeeDefinition.id` collision for unnamed tees

**Files:**
- Modify: `CourseBuilder/Models/Course.swift`
- Test: `CourseBuilderTests/Models/CourseTests.swift`

**Step 1: Write the failing test**

```swift
func testTeeDefinitionUniqueIds() {
    let tee1 = TeeDefinition(name: "", color: "#FFFFFF")
    let tee2 = TeeDefinition(name: "", color: "#000000")
    XCTAssertNotEqual(tee1.id, tee2.id)
}
```

**Step 2: Run test to verify it fails** (both have `id: ""`)

**Step 3: Fix by adding a stored UUID id**

Change `TeeDefinition` to use a stored `id`:

```swift
struct TeeDefinition: Codable, Equatable, Hashable, Identifiable {
    let id: UUID
    var name: String
    var color: String

    init(id: UUID = UUID(), name: String, color: String) {
        self.id = id
        self.name = name
        self.color = color
    }
}
```

**Step 4: Run tests to verify they pass**

**Step 5: Commit**

```
fix: use UUID for TeeDefinition.id to prevent collisions
```

---

### Task 9: Remove dead code

**Files:**
- Modify: `CourseBuilder/Views/PinEditorView.swift`
- Modify: `CourseBuilder/Services/ScorecardImporter.swift`

**Step 1: Remove `ToolMode.defaultPinType`** (lines 20-28 in `PinEditorView.swift`) — unused anywhere.

**Step 2: Remove `@Published var status` and `@Published var isLoading`** from `ScorecardImporter.swift` (lines 27-28) — the class is only used via direct method calls in `ScorecardView.importFromImage()`, never as an `ObservableObject`. Also remove the `ObservableObject` conformance and `@MainActor` annotation since it's only used synchronously. Keep the `ImportError` enum, remove `ImportSource` if unused.

Actually, check: `importScorecard` is `async` and uses `isLoading`/`status`. Keep them if `importScorecard` is used anywhere. Check call sites. If `importScorecard` is not called from the UI, mark it and its properties for future use but leave them. For now, just remove `defaultPinType`.

**Step 3: Build and verify**

**Step 4: Commit**

```
chore: remove unused ToolMode.defaultPinType
```

---

### Task 10: Remove stale `print` statement

**Files:**
- Modify: `CourseBuilder/Services/GolfCourseAPIClient.swift`

**Step 1:** Delete line 160:
```swift
print("[GolfCourseAPI] FetchCourse response body: \(bodyString)")
```
The `logger.debug` on line 159 already logs this.

**Step 2: Build and verify**

**Step 3: Commit**

```
chore: remove debug print statement, use logger instead
```

---

### Task 11: Add guard-let for forced unwraps in URL construction

**Files:**
- Modify: `CourseBuilder/Services/GolfCourseAPIClient.swift`

**Step 1:** Replace forced unwraps on lines 121, 124, and the equivalent in `fetchCourse` with `guard let` and throw `APIError`:

```swift
guard let components = URLComponents(url: baseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false),
      let url = components.url else {
    throw APIError.httpError(0)  // or a new .invalidURL case
}
```

Repeat for `fetchCourse` method.

**Step 2: Build and verify**

**Step 3: Commit**

```
fix: replace forced unwraps with guard-let in URL construction
```

---

### Task 12: Update stale plan documents

**Files:**
- Modify: `plans/2026-03-02-course-data-design.md`
- Modify: `plans/2026-03-04-add-course-dialog-design.md`

**Step 1: Update `2026-03-02-course-data-design.md`:**
- Update JSON example to show `subCourses` structure, `golfCourseAPIIds` (plural array)
- Update tee definitions to show `name` + `color` only (ratings live on `SubCourseTee`)
- Update file structure references from `CourseData/` to `CourseBuilder/`

**Step 2: Update `2026-03-04-add-course-dialog-design.md`:**
- Add Import tab description
- Change `ScorecardImportView` references to `ScorecardView`
- Add 27-hole option to manual entry section

**Step 3: Commit**

```
docs: update plan documents to reflect current code
```

---

### Task 13: Add `CourseStore.loadAll()` test

**Files:**
- Test: `CourseBuilderTests/Services/CourseStoreTests.swift`

**Step 1: Write the test**

```swift
func testLoadAll() throws {
    let store = CourseStore(directory: tempDir)
    let course1 = Course(name: "Course A", location: CourseLocation(address: "", city: "A", state: "CO", country: "US", coordinate: Coordinate(latitude: 0, longitude: 0)))
    let course2 = Course(name: "Course B", location: CourseLocation(address: "", city: "B", state: "CO", country: "US", coordinate: Coordinate(latitude: 0, longitude: 0)))
    try store.save(course1)
    try store.save(course2)

    let store2 = CourseStore(directory: tempDir)
    try store2.loadAll()
    XCTAssertEqual(store2.courses.count, 2)
    XCTAssertTrue(store2.courses.contains(where: { $0.name == "Course A" }))
    XCTAssertTrue(store2.courses.contains(where: { $0.name == "Course B" }))
}

func testDeleteNonExistentCourse() {
    let store = CourseStore(directory: tempDir)
    XCTAssertThrowsError(try store.delete(id: UUID()))
}
```

**Step 2: Run tests to verify they pass**

**Step 3: Commit**

```
test: add CourseStore.loadAll and delete error tests
```

---

## Execution Order

Tasks 1-3 build on each other (Hole utilities → DRY refactors). Task 4 is independent. Tasks 5-6 add test coverage. Task 7-8 are independent fixes. Tasks 9-13 are cleanup.

Recommended order: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11 → 12 → 13
