# Sub-Courses Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Restructure the data model so every Course contains SubCourses (e.g. Front/Back for standard 18-hole, or Eldorado/Vista/Conquistador for multi-9 facilities), and update all views, services, and tests accordingly.

**Architecture:** Add `SubCourse` and `SubCourseTee` types. Move `holes` from `Course` into `SubCourse`. Move tee ratings from `TeeDefinition` into `SubCourse.tees` (a `[String: SubCourseTee]` dictionary). Update `convertToCourse` to split API holes into Front/Back sub-courses. Update all views to iterate sub-courses. Not backward compatible — existing stored JSON files must be deleted.

**Tech Stack:** Swift, SwiftUI, macOS 14+, XCTest

---

### Task 1: Update data model types

**Files:**
- Modify: `CourseBuilder/Models/Course.swift`

**Step 1: Rewrite Course.swift with new types**

Replace the entire file with:

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
    let name: String
    let color: String
}

struct CourseLocation: Codable, Equatable, Hashable {
    var address: String
    var city: String
    var state: String
    var country: String
    var coordinate: Coordinate
}

struct Course: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var clubName: String
    var golfCourseAPIIds: [Int]
    var location: CourseLocation
    var tees: [TeeDefinition]
    var subCourses: [SubCourse]

    init(
        id: UUID = UUID(),
        name: String,
        clubName: String = "",
        golfCourseAPIIds: [Int] = [],
        location: CourseLocation,
        tees: [TeeDefinition] = [],
        subCourses: [SubCourse] = []
    ) {
        self.id = id
        self.name = name
        self.clubName = clubName
        self.golfCourseAPIIds = golfCourseAPIIds
        self.location = location
        self.tees = tees
        self.subCourses = subCourses
    }
}
```

Key changes from old model:
- `TeeInformation`: `courseRating` → `rating`, `slopeRating` → `slope`, removed front/back splits
- `TeeDefinition`: removed `male`/`female` TeeInformation (ratings now live on SubCourseTee)
- `Course`: `golfCourseAPIId: Int?` → `golfCourseAPIIds: [Int]`, `holes: [Hole]` → `subCourses: [SubCourse]`
- New types: `SubCourse`, `SubCourseTee`

**Step 2: Attempt build to see all compilation errors**

Run: `cd /Users/bpontarelli/dev/SpotGolf/CourseBuilder && xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' build 2>&1 | grep "error:" | head -30`

This will fail — that's expected. The errors show every file that needs updating (Tasks 2-6).

**Step 3: Commit the model change alone**

```bash
git add CourseBuilder/Models/Course.swift
git commit -m "feat: restructure data model with SubCourse, SubCourseTee, and revised TeeInformation"
```

---

### Task 2: Update GolfCourseAPIClient.convertToCourse

**Files:**
- Modify: `CourseBuilder/Services/GolfCourseAPIClient.swift:173-297`

**Step 1: Rewrite convertToCourse**

Replace the `convertToCourse` method (lines 173-297) with a new version that:
- Splits API holes into "Front" (1-9) and "Back" (10-18) sub-courses, renumbering back holes to 1-9
- Maps `frontCourseRating`/`frontSlopeRating` to the Front sub-course's tees
- Maps `backCourseRating`/`backSlopeRating` to the Back sub-course's tees
- Builds `TeeDefinition` array (name + color only, no ratings)
- Returns `Course` with `golfCourseAPIIds` array and `subCourses` instead of `holes`

```swift
static func convertToCourse(details: [CourseDetail]) -> Course {
    guard let first = details.first else {
        fatalError("convertToCourse called with empty details array")
    }

    let location = CourseLocation(
        address: first.location.address ?? "",
        city: first.location.city,
        state: first.location.state,
        country: first.location.country ?? "",
        coordinate: Coordinate(
            latitude: first.location.latitude ?? 0,
            longitude: first.location.longitude ?? 0
        )
    )

    let apiIds = details.compactMap { $0.id }

    // Collect all unique tee names and build TeeDefinitions
    var teeNames: Set<String> = []
    for detail in details {
        for teeSet in (detail.tees.male ?? []) + (detail.tees.female ?? []) {
            teeNames.insert(teeSet.teeName)
        }
    }
    let teeDefinitions = teeNames.sorted().map { name in
        TeeDefinition(name: name, color: defaultColor(for: name))
    }

    // Extract sub-courses from each detail
    var subCourseMap: [String: SubCourse] = [:]
    var subCourseOrder: [String] = []

    for detail in details {
        let names = extractSubCourseNames(from: detail.courseName)

        // Build hole data from male tees (primary source for par/handicap)
        var holeDataMap: [Int: (par: Int, maleHandicap: Int, femaleHandicap: Int, yardages: [String: Int])] = [:]

        if let maleTees = detail.tees.male {
            for teeSet in maleTees {
                for (index, hole) in teeSet.holes.enumerated() {
                    let holeNumber = index + 1
                    if var existing = holeDataMap[holeNumber] {
                        existing.yardages[teeSet.teeName] = hole.yardage
                        existing.maleHandicap = hole.handicap
                        holeDataMap[holeNumber] = existing
                    } else {
                        holeDataMap[holeNumber] = (
                            par: hole.par,
                            maleHandicap: hole.handicap,
                            femaleHandicap: 0,
                            yardages: [teeSet.teeName: hole.yardage]
                        )
                    }
                }
            }
        }
        if let femaleTees = detail.tees.female {
            for teeSet in femaleTees {
                for (index, hole) in teeSet.holes.enumerated() {
                    let holeNumber = index + 1
                    if var existing = holeDataMap[holeNumber] {
                        existing.yardages[teeSet.teeName] = hole.yardage
                        existing.femaleHandicap = hole.handicap
                        holeDataMap[holeNumber] = existing
                    } else {
                        holeDataMap[holeNumber] = (
                            par: hole.par,
                            maleHandicap: 0,
                            femaleHandicap: hole.handicap,
                            yardages: [teeSet.teeName: hole.yardage]
                        )
                    }
                }
            }
        }

        let totalHoles = holeDataMap.count
        let midpoint = totalHoles / 2

        // Build sub-course tee ratings
        func buildSubCourseTees(isFront: Bool) -> [String: SubCourseTee] {
            var result: [String: SubCourseTee] = [:]
            if let maleTees = detail.tees.male {
                for teeSet in maleTees {
                    let rating = isFront ? teeSet.frontCourseRating : teeSet.backCourseRating
                    let slope = isFront ? teeSet.frontSlopeRating : teeSet.backSlopeRating
                    let frontYards = teeSet.holes.prefix(midpoint).reduce(0) { $0 + $1.yardage }
                    let backYards = teeSet.holes.suffix(from: midpoint).reduce(0) { $0 + $1.yardage }
                    let yards = isFront ? frontYards : backYards
                    let frontPar = teeSet.holes.prefix(midpoint).reduce(0) { $0 + $1.par }
                    let backPar = teeSet.holes.suffix(from: midpoint).reduce(0) { $0 + $1.par }
                    let par = isFront ? frontPar : backPar
                    let info = TeeInformation(rating: rating, slope: slope, totalYards: yards, parTotal: par)
                    if var existing = result[teeSet.teeName] {
                        existing.male = info
                        result[teeSet.teeName] = existing
                    } else {
                        result[teeSet.teeName] = SubCourseTee(male: info)
                    }
                }
            }
            if let femaleTees = detail.tees.female {
                for teeSet in femaleTees {
                    let rating = isFront ? teeSet.frontCourseRating : teeSet.backCourseRating
                    let slope = isFront ? teeSet.frontSlopeRating : teeSet.backSlopeRating
                    let frontYards = teeSet.holes.prefix(midpoint).reduce(0) { $0 + $1.yardage }
                    let backYards = teeSet.holes.suffix(from: midpoint).reduce(0) { $0 + $1.yardage }
                    let yards = isFront ? frontYards : backYards
                    let frontPar = teeSet.holes.prefix(midpoint).reduce(0) { $0 + $1.par }
                    let backPar = teeSet.holes.suffix(from: midpoint).reduce(0) { $0 + $1.par }
                    let par = isFront ? frontPar : backPar
                    let info = TeeInformation(rating: rating, slope: slope, totalYards: yards, parTotal: par)
                    if var existing = result[teeSet.teeName] {
                        existing.female = info
                        result[teeSet.teeName] = existing
                    } else {
                        result[teeSet.teeName] = SubCourseTee(female: info)
                    }
                }
            }
            return result
        }

        // Build holes for each sub-course
        let sortedHoles = holeDataMap.keys.sorted()
        let frontHoleNumbers = Array(sortedHoles.prefix(midpoint))
        let backHoleNumbers = Array(sortedHoles.suffix(from: midpoint))

        func buildHoles(from holeNumbers: [Int]) -> [Hole] {
            holeNumbers.enumerated().map { (newIndex, oldNumber) in
                let data = holeDataMap[oldNumber]!
                return Hole(
                    number: newIndex + 1,
                    par: data.par,
                    maleHandicap: data.maleHandicap,
                    femaleHandicap: data.femaleHandicap,
                    yardages: data.yardages
                )
            }
        }

        let firstName = names.count >= 1 ? names[0] : "Front"
        let secondName = names.count >= 2 ? names[1] : "Back"

        // Only add sub-courses not already seen (deduplication for multi-detail imports)
        if subCourseMap[firstName] == nil {
            subCourseMap[firstName] = SubCourse(
                name: firstName,
                holes: buildHoles(from: frontHoleNumbers),
                tees: buildSubCourseTees(isFront: true)
            )
            subCourseOrder.append(firstName)
        }
        if subCourseMap[secondName] == nil {
            subCourseMap[secondName] = SubCourse(
                name: secondName,
                holes: buildHoles(from: backHoleNumbers),
                tees: buildSubCourseTees(isFront: false)
            )
            subCourseOrder.append(secondName)
        }
    }

    let subCourses = subCourseOrder.compactMap { subCourseMap[$0] }

    return Course(
        name: first.courseName,
        clubName: first.clubName,
        golfCourseAPIIds: apiIds,
        location: location,
        tees: teeDefinitions,
        subCourses: subCourses
    )
}

/// Extract sub-course names from an API course name.
/// "Eldorado/Vista" → ["Eldorado", "Vista"]
/// "Broadlands Golf Course" → ["Front", "Back"]
private static func extractSubCourseNames(from courseName: String) -> [String] {
    let parts = courseName.split(separator: "/").map { String($0).trimmingCharacters(in: .whitespaces) }
    if parts.count >= 2 {
        return parts
    }
    return ["Front", "Back"]
}
```

Also update the old single-detail convenience to call the new multi-detail version:

```swift
static func convertToCourse(detail: CourseDetail) -> Course {
    convertToCourse(details: [detail])
}
```

**Step 2: Build and verify**

Run: `cd /Users/bpontarelli/dev/SpotGolf/CourseBuilder && xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' build 2>&1 | grep "error:" | head -20`

This may still fail due to other files referencing `course.holes`. That's fine — we fix those in the next tasks.

**Step 3: Commit**

```bash
git add CourseBuilder/Services/GolfCourseAPIClient.swift
git commit -m "feat: update convertToCourse to produce SubCourses with Front/Back split"
```

---

### Task 3: Update ScorecardImporter

**Files:**
- Modify: `CourseBuilder/Services/ScorecardImporter.swift`

**Step 1: Update all methods to use subCourses instead of holes**

The `buildCourse` method needs to wrap holes into a single "Front"/"Back" sub-course structure. The `createManualCourse` method needs to do the same. The `importFromImage` method returns whatever `buildCourse` returns.

Update `buildCourse`:

```swift
private func buildCourse(from data: ScorecardData, name: String, city: String, state: String) -> Course {
    let tees = data.teeNames.map { teeName in
        TeeDefinition(
            name: teeName,
            color: defaultColor(for: teeName)
        )
    }
    let midpoint = data.holes.count / 2
    let frontHoles = data.holes.prefix(midpoint).enumerated().map { (i, hole) in
        Hole(number: i + 1, par: hole.par, maleHandicap: hole.maleHandicap, femaleHandicap: hole.femaleHandicap, yardages: hole.yardages)
    }
    let backHoles = data.holes.suffix(from: midpoint).enumerated().map { (i, hole) in
        Hole(number: i + 1, par: hole.par, maleHandicap: hole.maleHandicap, femaleHandicap: hole.femaleHandicap, yardages: hole.yardages)
    }
    return Course(
        name: name,
        location: CourseLocation(address: "", city: city, state: state, country: "", coordinate: Coordinate(latitude: 0, longitude: 0)),
        tees: tees,
        subCourses: [
            SubCourse(name: "Front", holes: frontHoles),
            SubCourse(name: "Back", holes: backHoles)
        ]
    )
}
```

Update `createManualCourse`:

```swift
func createManualCourse(name: String, city: String, state: String, holeCount: Int = 18) -> Course {
    let holesPerSub = holeCount / 2
    let remainder = holeCount % 2
    let frontHoles = (1...holesPerSub).map { Hole(number: $0, par: 4) }
    let backCount = holesPerSub + remainder
    let backHoles = (1...backCount).map { Hole(number: $0, par: 4) }
    var subCourses = [SubCourse(name: "Front", holes: frontHoles)]
    if holeCount > holesPerSub {
        subCourses.append(SubCourse(name: "Back", holes: backHoles))
    }
    return Course(
        name: name,
        location: CourseLocation(address: "", city: city, state: state, country: "", coordinate: Coordinate(latitude: 0, longitude: 0)),
        subCourses: subCourses
    )
}
```

Update `importScorecard` — line 49 calls `convertToCourse` which now returns the new model, so no changes needed there.

**Step 2: Commit**

```bash
git add CourseBuilder/Services/ScorecardImporter.swift
git commit -m "feat: update ScorecardImporter to produce SubCourses"
```

---

### Task 4: Update CourseListView and AddCourseSheet

**Files:**
- Modify: `CourseBuilder/Views/CourseListView.swift`

**Step 1: Update CourseListView hole count display**

Line 18 currently shows `course.holes.count`. Change to show total holes across all sub-courses:

```swift
// Replace:
Text("\(course.holes.count) holes")
// With:
Text("\(course.subCourses.reduce(0) { $0 + $1.holes.count }) holes")
```

**Step 2: Update AddCourseSheet manual entry to create sub-courses**

In `addCourse()` (line 206-220), the manual entry case currently creates a Course with `holes:`. Change it to create sub-courses:

```swift
case .manualEntry:
    let holesPerSub = holeCount / 2
    let remainder = holeCount % 2
    let frontHoles = (1...(holeCount == 9 ? holeCount : holesPerSub)).map { Hole(number: $0, par: 4) }
    var subCourses = [SubCourse(name: "Front", holes: frontHoles)]
    if holeCount > 9 {
        let backCount = holesPerSub + remainder
        let backHoles = (1...backCount).map { Hole(number: $0, par: 4) }
        subCourses.append(SubCourse(name: "Back", holes: backHoles))
    }
    let course = Course(
        name: name,
        clubName: clubName,
        location: CourseLocation(
            address: address,
            city: city,
            state: state,
            country: country,
            coordinate: Coordinate(latitude: 0, longitude: 0)
        ),
        subCourses: subCourses
    )
    onCreate(course)
```

**Step 3: Update search tab to support multi-select**

Change `selectedResult` from single to a `Set`:

```swift
// Replace:
@State private var selectedResult: GolfCourseAPIClient.CourseSearchResult?
// With:
@State private var selectedResults: Set<GolfCourseAPIClient.CourseSearchResult> = []
```

Update `canAdd` for search tab:

```swift
case .search:
    return !selectedResults.isEmpty
```

Update the List to use multi-selection:

```swift
List(searchResults, id: \.id, selection: $selectedResults) { result in
    VStack(alignment: .leading) {
        Text(result.courseName)
            .font(.headline)
        Text("\(result.location.city), \(result.location.state)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    .tag(result)
}
```

Update `addCourse()` search case:

```swift
case .search:
    guard !selectedResults.isEmpty else { return }
    fetchAndAddCourses(Array(selectedResults))
```

Rename `fetchAndAddCourse` to `fetchAndAddCourses` and update to fetch multiple details:

```swift
private func fetchAndAddCourses(_ results: [GolfCourseAPIClient.CourseSearchResult]) {
    isFetching = true
    Task {
        do {
            let client = GolfCourseAPIClient(apiKey: apiKey)
            var details: [GolfCourseAPIClient.CourseDetail] = []
            for result in results {
                let detail = try await client.fetchCourse(id: result.id)
                details.append(detail)
            }
            let course = GolfCourseAPIClient.convertToCourse(details: details)
            onCreate(course)
        } catch {
            fetchErrorMessage = "Failed to fetch course: \(error.localizedDescription)"
            showFetchError = true
        }
        isFetching = false
    }
}
```

Update `searchCourses` to clear the set:

```swift
selectedResults = []
// (was: selectedResult = nil)
```

**Step 4: Commit**

```bash
git add CourseBuilder/Views/CourseListView.swift
git commit -m "feat: update CourseListView and AddCourseSheet for sub-courses and multi-select"
```

---

### Task 5: Update ScorecardView and ScorecardTableView

**Files:**
- Modify: `CourseBuilder/Views/ScorecardView.swift`

**Step 1: Update ScorecardView**

The "Open Map Editor" disabled check currently references `course.holes.isEmpty`. Update to check sub-courses:

```swift
// Replace:
.disabled(course.holes.isEmpty)
// With:
.disabled(course.subCourses.isEmpty)
```

The OCR import currently sets `course.tees` and `course.holes`. Update to set `course.subCourses`:

```swift
// Replace:
course.tees = imported.tees
course.holes = imported.holes
statusMessage = "OCR imported \(imported.holes.count) holes"
// With:
course.tees = imported.tees
course.subCourses = imported.subCourses
let totalHoles = imported.subCourses.reduce(0) { $0 + $1.holes.count }
statusMessage = "OCR imported \(totalHoles) holes"
```

**Step 2: Rewrite ScorecardTableView to show sub-courses**

The table needs to iterate sub-courses, showing a section header for each sub-course with its holes below. Replace the entire `ScorecardTableView` struct:

```swift
struct ScorecardTableView: View {
    @Binding var course: Course

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach($course.subCourses) { $subCourse in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(subCourse.name)
                            .font(.headline)
                            .padding(.horizontal)

                        Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 2) {
                            GridRow {
                                Text("Hole").bold().frame(width: 50)
                                Text("Par").bold().frame(width: 40)
                                Text("M Hcp").bold().frame(width: 45)
                                Text("F Hcp").bold().frame(width: 45)
                                ForEach(course.tees) { tee in
                                    Text(tee.name).bold().frame(width: 60)
                                }
                            }
                            Divider()

                            ForEach($subCourse.holes) { $hole in
                                GridRow {
                                    Text("\(hole.number)").frame(width: 50)
                                    TextField("", value: $hole.par, format: .number)
                                        .frame(width: 40)
                                        .textFieldStyle(.roundedBorder)
                                    TextField("", value: $hole.maleHandicap, format: .number)
                                        .frame(width: 45)
                                        .textFieldStyle(.roundedBorder)
                                    TextField("", value: $hole.femaleHandicap, format: .number)
                                        .frame(width: 45)
                                        .textFieldStyle(.roundedBorder)
                                    ForEach(course.tees) { tee in
                                        let binding = Binding(
                                            get: { hole.yardages[tee.name] ?? 0 },
                                            set: { hole.yardages[tee.name] = $0 }
                                        )
                                        TextField("", value: binding, format: .number)
                                            .frame(width: 60)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }
}
```

**Step 3: Commit**

```bash
git add CourseBuilder/Views/ScorecardView.swift
git commit -m "feat: update ScorecardView and ScorecardTableView for sub-courses"
```

---

### Task 6: Update MapEditorView

**Files:**
- Modify: `CourseBuilder/Views/MapEditorView.swift`

**Step 1: Update hole sidebar and pin loading**

The map editor needs to navigate by sub-course. Add a `@State private var selectedSubCourseIndex: Int = 0` and update the sidebar to show sub-courses with their holes.

Key changes:
- `selectedHole` becomes relative to the selected sub-course
- `holeSidebar` shows sub-course sections with holes nested under each
- `loadPinsFromCourse()` iterates `course.subCourses` instead of `course.holes`, storing the sub-course index on each pin
- `applyPinsToCourse()` writes back to `course.subCourses[subIdx].holes[holeIdx]`
- `distanceReadout` looks up yardage from the correct sub-course's hole
- `EditablePin` gains a `subCourseIndex: Int` property (update in `PinEditorView.swift`)

Update `EditablePin` in `PinEditorView.swift`:

```swift
struct EditablePin: Identifiable, Equatable {
    let id: UUID
    var pinType: PinType
    var coordinate: Coordinate
    var teeName: String?
    var featureIndex: Int?
    var subCourseIndex: Int
    var holeNumber: Int

    static func == (lhs: EditablePin, rhs: EditablePin) -> Bool {
        lhs.id == rhs.id
            && lhs.pinType == rhs.pinType
            && lhs.coordinate == rhs.coordinate
            && lhs.teeName == rhs.teeName
            && lhs.subCourseIndex == rhs.subCourseIndex
            && lhs.holeNumber == rhs.holeNumber
    }
}
```

In `MapEditorView`, replace `loadPinsFromCourse`:

```swift
private func loadPinsFromCourse() {
    pins = []
    for (subIdx, subCourse) in course.subCourses.enumerated() {
        for hole in subCourse.holes {
            // Tee pins
            for (teeName, coord) in hole.tees {
                pins.append(EditablePin(
                    id: UUID(), pinType: .tee, coordinate: coord,
                    teeName: teeName, subCourseIndex: subIdx, holeNumber: hole.number
                ))
            }
            // Green pins
            if let green = hole.green {
                pins.append(EditablePin(id: UUID(), pinType: .greenFront, coordinate: green.front, subCourseIndex: subIdx, holeNumber: hole.number))
                pins.append(EditablePin(id: UUID(), pinType: .greenMiddle, coordinate: green.middle, subCourseIndex: subIdx, holeNumber: hole.number))
                pins.append(EditablePin(id: UUID(), pinType: .greenBack, coordinate: green.back, subCourseIndex: subIdx, holeNumber: hole.number))
            }
            // Feature pins
            for (featureIdx, feature) in hole.features.enumerated() {
                let frontType: PinType = feature.type == .bunker ? .bunkerFront : .waterFront
                let backType: PinType = feature.type == .bunker ? .bunkerBack : .waterBack
                pins.append(EditablePin(id: UUID(), pinType: frontType, coordinate: feature.front, featureIndex: featureIdx, subCourseIndex: subIdx, holeNumber: hole.number))
                pins.append(EditablePin(id: UUID(), pinType: backType, coordinate: feature.back, featureIndex: featureIdx, subCourseIndex: subIdx, holeNumber: hole.number))
            }
        }
    }
}
```

Replace `applyPinsToCourse`:

```swift
private func applyPinsToCourse() {
    for subIdx in course.subCourses.indices {
        for holeIdx in course.subCourses[subIdx].holes.indices {
            let holeNumber = course.subCourses[subIdx].holes[holeIdx].number
            let holePins = pins.filter { $0.subCourseIndex == subIdx && $0.holeNumber == holeNumber }

            var tees: [String: Coordinate] = [:]
            for pin in holePins where pin.pinType == .tee {
                if let teeName = pin.teeName { tees[teeName] = pin.coordinate }
            }
            course.subCourses[subIdx].holes[holeIdx].tees = tees

            let greenFront = holePins.first { $0.pinType == .greenFront }
            let greenMiddle = holePins.first { $0.pinType == .greenMiddle }
            let greenBack = holePins.first { $0.pinType == .greenBack }
            if let front = greenFront, let middle = greenMiddle, let back = greenBack {
                course.subCourses[subIdx].holes[holeIdx].green = Green(front: front.coordinate, middle: middle.coordinate, back: back.coordinate)
            } else {
                course.subCourses[subIdx].holes[holeIdx].green = nil
            }

            var features: [Feature] = []
            let bunkerFronts = holePins.filter { $0.pinType == .bunkerFront }
            let bunkerBacks = holePins.filter { $0.pinType == .bunkerBack }
            for (front, back) in zip(bunkerFronts, bunkerBacks) {
                features.append(Feature(type: .bunker, front: front.coordinate, back: back.coordinate))
            }
            let waterFronts = holePins.filter { $0.pinType == .waterFront }
            let waterBacks = holePins.filter { $0.pinType == .waterBack }
            for (front, back) in zip(waterFronts, waterBacks) {
                features.append(Feature(type: .water, front: front.coordinate, back: back.coordinate))
            }
            course.subCourses[subIdx].holes[holeIdx].features = features
        }
    }
}
```

Update `holeSidebar` to show sub-courses:

```swift
private var holeSidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
        Text("Holes")
            .font(.headline)
            .padding()

        List {
            ForEach(Array(course.subCourses.enumerated()), id: \.offset) { subIdx, subCourse in
                Section(subCourse.name) {
                    ForEach(subCourse.holes) { hole in
                        Button {
                            selectedSubCourseIndex = subIdx
                            selectedHole = hole.number
                            selectedPinID = nil
                        } label: {
                            HStack {
                                Text("Hole \(hole.number)")
                                    .fontWeight(selectedSubCourseIndex == subIdx && selectedHole == hole.number ? .bold : .regular)
                                Spacer()
                                let count = pins.filter { $0.subCourseIndex == subIdx && $0.holeNumber == hole.number }.count
                                Text("\(count) pins")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }

        // ... pin list section stays similar but filters by subCourseIndex too
    }
}
```

Update `pinsForCurrentHole`:

```swift
private var pinsForCurrentHole: [EditablePin] {
    pins.filter { $0.subCourseIndex == selectedSubCourseIndex && $0.holeNumber == selectedHole }
}
```

Update `placePin` to set `subCourseIndex`:

```swift
let pin = EditablePin(
    id: UUID(),
    pinType: pinType,
    coordinate: coordinate,
    teeName: pinType == .tee ? course.tees.first?.name : nil,
    subCourseIndex: selectedSubCourseIndex,
    holeNumber: selectedHole
)
```

Update `distanceReadout` to look up yardage from the correct sub-course:

```swift
let scorecardYardage = course.subCourses[safe: selectedSubCourseIndex]?
    .holes.first(where: { $0.number == selectedHole })?
    .yardages.values.first ?? 0
```

(Add a safe subscript extension or use bounds checking.)

Update the pin list section in the sidebar to filter by `subCourseIndex`:

```swift
let holePins = pins.filter { $0.subCourseIndex == selectedSubCourseIndex && $0.holeNumber == selectedHole }
```

**Step 2: Commit**

```bash
git add CourseBuilder/Views/MapEditorView.swift CourseBuilder/Views/PinEditorView.swift
git commit -m "feat: update MapEditorView for sub-course navigation"
```

---

### Task 7: Update tests

**Files:**
- Modify: `CourseBuilderTests/Models/CourseTests.swift`
- Modify: `CourseBuilderTests/Services/GolfCourseAPIClientTests.swift`

**Step 1: Rewrite CourseTests**

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
            subCourses: [
                SubCourse(
                    name: "Front",
                    holes: [
                        Hole(number: 1, par: 4, maleHandicap: 13,
                             yardages: ["Black": 401],
                             tees: ["Black": Coordinate(latitude: 39.9401, longitude: -105.0271)])
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
        XCTAssertEqual(course.subCourses.count, 1)
        XCTAssertEqual(course.subCourses[0].name, "Front")
        XCTAssertEqual(course.subCourses[0].holes.count, 1)
        XCTAssertEqual(course.subCourses[0].tees["Black"]?.male?.rating, 37.6)
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
        XCTAssertTrue(course.subCourses.isEmpty)
    }
}
```

**Step 2: Update GolfCourseAPIClientTests**

Update `testParseCourseDetailResponse` to check sub-courses instead of `course.holes`:

```swift
func testParseCourseDetailResponse() throws {
    let json = """
    {
        "id": 12345,
        "course_name": "Broadlands Golf Course",
        "club_name": "The Broadlands Golf Club",
        "location": {
            "address": "4380 W 144th Ave",
            "city": "Broomfield",
            "state": "CO",
            "country": "US",
            "zip_code": "80023"
        },
        "tees": {
            "male": [
                {
                    "tee_name": "Black",
                    "course_rating": 73.5,
                    "slope_rating": 137,
                    "front_course_rating": 37.6,
                    "front_slope_rating": 134,
                    "back_course_rating": 35.9,
                    "back_slope_rating": 140,
                    "total_yards": 7289,
                    "par_total": 72,
                    "holes": [
                        { "par": 4, "yardage": 401, "handicap": 13 },
                        { "par": 5, "yardage": 545, "handicap": 3 }
                    ]
                }
            ],
            "female": [
                {
                    "tee_name": "Red",
                    "course_rating": 69.1,
                    "slope_rating": 121,
                    "front_course_rating": 34.2,
                    "front_slope_rating": 118,
                    "back_course_rating": 34.9,
                    "back_slope_rating": 124,
                    "total_yards": 5200,
                    "par_total": 72,
                    "holes": [
                        { "par": 4, "yardage": 298, "handicap": 13 },
                        { "par": 5, "yardage": 430, "handicap": 3 }
                    ]
                }
            ]
        }
    }
    """.data(using: .utf8)!

    let detail = try JSONDecoder().decode(GolfCourseAPIClient.CourseDetail.self, from: json)
    let course = GolfCourseAPIClient.convertToCourse(detail: detail)

    XCTAssertEqual(course.name, "Broadlands Golf Course")
    XCTAssertEqual(course.clubName, "The Broadlands Golf Club")
    XCTAssertEqual(course.golfCourseAPIIds, [12345])
    XCTAssertEqual(course.location.city, "Broomfield")
    XCTAssertEqual(course.tees.count, 2)

    // Should have Front and Back sub-courses
    XCTAssertEqual(course.subCourses.count, 2)
    XCTAssertEqual(course.subCourses[0].name, "Front")
    XCTAssertEqual(course.subCourses[1].name, "Back")

    // Front sub-course gets hole 1 (renumbered to 1)
    XCTAssertEqual(course.subCourses[0].holes.count, 1)
    XCTAssertEqual(course.subCourses[0].holes[0].par, 4)
    XCTAssertEqual(course.subCourses[0].holes[0].yardages["Black"], 401)
    XCTAssertEqual(course.subCourses[0].holes[0].yardages["Red"], 298)

    // Back sub-course gets hole 2 (renumbered to 1)
    XCTAssertEqual(course.subCourses[1].holes.count, 1)
    XCTAssertEqual(course.subCourses[1].holes[0].number, 1)
    XCTAssertEqual(course.subCourses[1].holes[0].par, 5)

    // Front sub-course tee ratings from front_course_rating
    let frontBlack = course.subCourses[0].tees["Black"]
    XCTAssertEqual(frontBlack?.male?.rating, 37.6)
    XCTAssertEqual(frontBlack?.male?.slope, 134)

    // Back sub-course tee ratings from back_course_rating
    let backBlack = course.subCourses[1].tees["Black"]
    XCTAssertEqual(backBlack?.male?.rating, 35.9)
    XCTAssertEqual(backBlack?.male?.slope, 140)

    // Female tee ratings
    let frontRed = course.subCourses[0].tees["Red"]
    XCTAssertEqual(frontRed?.female?.rating, 34.2)
    XCTAssertEqual(frontRed?.female?.slope, 118)
}
```

Update `testLiveFetchCourse` to check sub-courses:

```swift
func testLiveFetchCourse() async throws {
    let apiKey = try loadAPIKey()
    let client = GolfCourseAPIClient(apiKey: apiKey)

    let response = try await client.search(query: "Broadlands")
    let firstResult = try XCTUnwrap(response.courses.first)

    let detail = try await client.fetchCourse(id: firstResult.id)
    let course = GolfCourseAPIClient.convertToCourse(detail: detail)

    XCTAssertFalse(course.name.isEmpty)
    XCTAssertFalse(course.subCourses.isEmpty, "Expected sub-courses")
    XCTAssertFalse(course.tees.isEmpty, "Expected tees")

    print("Converted: \(course.name), \(course.subCourses.count) sub-courses, \(course.tees.count) tees")
    for sub in course.subCourses {
        print("  \(sub.name): \(sub.holes.count) holes")
    }
}
```

**Step 3: Build and run all tests**

Run: `cd /Users/bpontarelli/dev/SpotGolf/CourseBuilder && xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | grep -E '(Test Case|FAIL|Executed|BUILD)'`
Expected: BUILD SUCCEEDED, all tests pass

**Step 4: Commit**

```bash
git add CourseBuilderTests/
git commit -m "test: update all tests for sub-course data model"
```

---

### Task 8: Full build, test, and cleanup

**Step 1: Delete existing stored course JSON files**

The old format is incompatible. Delete any stored courses:

```bash
rm -rf ~/Library/Application\ Support/CourseBuilder/courses/*.json
```

**Step 2: Full clean build and test**

Run: `cd /Users/bpontarelli/dev/SpotGolf/CourseBuilder && xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' clean build 2>&1 | tail -5`

Run: `cd /Users/bpontarelli/dev/SpotGolf/CourseBuilder && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | tail -10`

Expected: BUILD SUCCEEDED, all tests pass

**Step 3: Commit any remaining cleanup**

```bash
git add -u
git commit -m "chore: final cleanup for sub-course migration"
```
