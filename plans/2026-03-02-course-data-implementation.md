# CourseData Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

> **Note (2026-03-04):** The data model has been updated since this plan was written. Code snippets below reflect the original model. Key changes:
> - `Course.id` is now `UUID` (was `String` from `generateID()`); `generateID()` removed
> - `Course` gained `clubName: String` and `golfCourseAPIId: Int?`
> - `CourseLocation` gained `address: String` and `country: String`
> - `TeeDefinition` now uses `male: TeeInformation?` and `female: TeeInformation?` instead of flat `maleRating/maleSlope/femaleRating/femaleSlope`
> - `TeeInformation` struct contains: `courseRating`, `slopeRating`, `frontCourseRating`, `frontSlopeRating`, `backCourseRating`, `backSlopeRating`, `totalYards`, `parTotal`
> - See `plans/2026-03-02-course-data-design.md` for the current JSON schema

**Goal:** Build a macOS SwiftUI app that creates golf course GPS data files (tees, greens, hazards) by combining scorecard APIs, satellite imagery analysis, and a manual map editor.

**Architecture:** Native macOS 14+ SwiftUI app using MapKit for satellite display and pin editing, CoreImage for green/tee detection from satellite snapshots, Vision for scorecard OCR, and URLSession for API/scraping. Data persisted as one JSON file per course.

**Tech Stack:** Swift, SwiftUI, MapKit, CoreImage, Vision, CoreLocation, URLSession, xcodegen

---

### Task 1: Project scaffold with xcodegen

**Files:**
- Create: `project.yml`
- Create: `CourseData/App/CourseDataApp.swift`
- Create: `CourseData/Views/ContentView.swift`
- Create: `CourseData/Resources/CourseData.entitlements`

**Step 1: Create project.yml**

```yaml
name: CourseData
options:
  bundleIdPrefix: com.spotgolf
  deploymentTarget:
    macOS: "14.0"
  xcodeVersion: "15.0"
  minimumXcodeGenVersion: "2.38.0"
settings:
  base:
    SWIFT_VERSION: "5.9"
targets:
  CourseData:
    type: application
    platform: macOS
    sources:
      - CourseData
    settings:
      base:
        CODE_SIGN_ENTITLEMENTS: CourseData/Resources/CourseData.entitlements
        INFOPLIST_KEY_NSLocationUsageDescription: "CourseData uses your location for testing course distances"
    scheme:
      testTargets:
        - CourseDataTests
  CourseDataTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - CourseDataTests
    dependencies:
      - target: CourseData
```

**Step 2: Create entitlements file**

`CourseData/Resources/CourseData.entitlements`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
</dict>
</plist>
```

**Step 3: Create minimal app entry point**

`CourseData/App/CourseDataApp.swift`:
```swift
import SwiftUI

@main
struct CourseDataApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

`CourseData/Views/ContentView.swift`:
```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        Text("CourseData")
            .frame(minWidth: 800, minHeight: 600)
    }
}
```

**Step 4: Create a placeholder test**

`CourseDataTests/PlaceholderTests.swift`:
```swift
import XCTest

final class PlaceholderTests: XCTestCase {
    func testPlaceholder() {
        XCTAssertTrue(true)
    }
}
```

**Step 5: Generate the Xcode project and verify it builds**

```bash
cd /Users/bpontarelli/dev/SpotGolf/CourseData
xcodegen generate
xcodebuild -scheme CourseData -destination 'platform=macOS' build
```

Expected: BUILD SUCCEEDED

**Step 6: Run tests**

```bash
xcodebuild -scheme CourseData -destination 'platform=macOS' test
```

Expected: Test suite passes (1 test)

**Step 7: Commit**

```bash
git init
git add -A
git commit -m "feat: scaffold macOS app with xcodegen"
```

---

### Task 2: Data models — Coordinate, Feature, Hole

**Files:**
- Create: `CourseData/Models/Coordinate.swift`
- Create: `CourseData/Models/Feature.swift`
- Create: `CourseData/Models/Hole.swift`
- Create: `CourseDataTests/Models/CoordinateTests.swift`
- Create: `CourseDataTests/Models/HoleTests.swift`

**Step 1: Write Coordinate tests**

`CourseDataTests/Models/CoordinateTests.swift`:
```swift
import XCTest
import CoreLocation
@testable import CourseData

final class CoordinateTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let coord = Coordinate(latitude: 39.9397, longitude: -105.0267)
        let data = try JSONEncoder().encode(coord)
        let decoded = try JSONDecoder().decode(Coordinate.self, from: data)
        XCTAssertEqual(coord, decoded)
    }

    func testCLLocationCoordinate2D() {
        let coord = Coordinate(latitude: 39.9397, longitude: -105.0267)
        let cl = coord.clCoordinate
        XCTAssertEqual(cl.latitude, 39.9397)
        XCTAssertEqual(cl.longitude, -105.0267)
    }

    func testCLLocation() {
        let coord = Coordinate(latitude: 39.9397, longitude: -105.0267)
        let loc = coord.clLocation
        XCTAssertEqual(loc.coordinate.latitude, 39.9397)
        XCTAssertEqual(loc.coordinate.longitude, -105.0267)
    }

    func testInitFromCLLocationCoordinate2D() {
        let cl = CLLocationCoordinate2D(latitude: 39.9397, longitude: -105.0267)
        let coord = Coordinate(cl)
        XCTAssertEqual(coord.latitude, 39.9397)
        XCTAssertEqual(coord.longitude, -105.0267)
    }
}
```

**Step 2: Run tests — verify they fail**

```bash
xcodebuild -scheme CourseData -destination 'platform=macOS' test 2>&1 | grep -E "(FAIL|error:.*Coordinate)"
```

Expected: compilation errors (Coordinate not defined)

**Step 3: Implement Coordinate**

`CourseData/Models/Coordinate.swift`:
```swift
import Foundation
import CoreLocation

struct Coordinate: Codable, Equatable, Hashable {
    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ clCoordinate: CLLocationCoordinate2D) {
        self.latitude = clCoordinate.latitude
        self.longitude = clCoordinate.longitude
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var clLocation: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
}
```

**Step 4: Run tests — verify they pass**

```bash
xcodebuild -scheme CourseData -destination 'platform=macOS' test 2>&1 | tail -5
```

Expected: all CoordinateTests pass

**Step 5: Write Feature and Hole tests**

`CourseDataTests/Models/HoleTests.swift`:
```swift
import XCTest
@testable import CourseData

final class FeatureTests: XCTestCase {
    func testBunkerCodableRoundTrip() throws {
        let bunker = Feature(
            type: .bunker,
            front: Coordinate(latitude: 39.9387, longitude: -105.0249),
            back: Coordinate(latitude: 39.9388, longitude: -105.0248)
        )
        let data = try JSONEncoder().encode(bunker)
        let decoded = try JSONDecoder().decode(Feature.self, from: data)
        XCTAssertEqual(bunker, decoded)
        XCTAssertEqual(decoded.type, .bunker)
    }

    func testWaterCodableRoundTrip() throws {
        let water = Feature(
            type: .water,
            front: Coordinate(latitude: 39.9394, longitude: -105.0261),
            back: Coordinate(latitude: 39.9392, longitude: -105.0259)
        )
        let data = try JSONEncoder().encode(water)
        let decoded = try JSONDecoder().decode(Feature.self, from: data)
        XCTAssertEqual(water, decoded)
    }
}

final class HoleTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let hole = Hole(
            number: 1,
            par: 4,
            handicap: 13,
            yardages: ["Black": 401, "Gold": 378],
            tees: [
                "Black": Coordinate(latitude: 39.9401, longitude: -105.0271),
                "Gold": Coordinate(latitude: 39.9400, longitude: -105.0270)
            ],
            green: Green(
                front: Coordinate(latitude: 39.9386, longitude: -105.0246),
                middle: Coordinate(latitude: 39.9385, longitude: -105.0245),
                back: Coordinate(latitude: 39.9384, longitude: -105.0244)
            ),
            features: [
                Feature(
                    type: .bunker,
                    front: Coordinate(latitude: 39.9387, longitude: -105.0249),
                    back: Coordinate(latitude: 39.9388, longitude: -105.0248)
                )
            ]
        )
        let data = try JSONEncoder().encode(hole)
        let decoded = try JSONDecoder().decode(Hole.self, from: data)
        XCTAssertEqual(hole, decoded)
        XCTAssertEqual(decoded.number, 1)
        XCTAssertEqual(decoded.par, 4)
        XCTAssertEqual(decoded.tees.count, 2)
        XCTAssertEqual(decoded.green.front.latitude, 39.9386)
        XCTAssertEqual(decoded.features.count, 1)
    }

    func testEmptyHole() {
        let hole = Hole(number: 5, par: 3, handicap: 7)
        XCTAssertTrue(hole.yardages.isEmpty)
        XCTAssertTrue(hole.tees.isEmpty)
        XCTAssertNil(hole.green)
        XCTAssertTrue(hole.features.isEmpty)
    }
}
```

**Step 6: Run tests — verify they fail**

```bash
xcodebuild -scheme CourseData -destination 'platform=macOS' test 2>&1 | grep -E "error:"
```

Expected: compilation errors (Feature, Hole, Green not defined)

**Step 7: Implement Feature and Hole**

`CourseData/Models/Feature.swift`:
```swift
import Foundation

enum FeatureType: String, Codable, CaseIterable {
    case bunker
    case water
}

struct Feature: Identifiable, Codable, Equatable {
    let id: UUID
    let type: FeatureType
    var front: Coordinate
    var back: Coordinate

    init(id: UUID = UUID(), type: FeatureType, front: Coordinate, back: Coordinate) {
        self.id = id
        self.type = type
        self.front = front
        self.back = back
    }
}
```

`CourseData/Models/Hole.swift`:
```swift
import Foundation

struct Green: Codable, Equatable {
    var front: Coordinate
    var middle: Coordinate
    var back: Coordinate
}

struct Hole: Identifiable, Codable, Equatable {
    let id: UUID
    let number: Int
    var par: Int
    var handicap: Int
    var yardages: [String: Int]
    var tees: [String: Coordinate]
    var green: Green?
    var features: [Feature]

    init(
        id: UUID = UUID(),
        number: Int,
        par: Int,
        handicap: Int,
        yardages: [String: Int] = [:],
        tees: [String: Coordinate] = [:],
        green: Green? = nil,
        features: [Feature] = []
    ) {
        self.id = id
        self.number = number
        self.par = par
        self.handicap = handicap
        self.yardages = yardages
        self.tees = tees
        self.green = green
        self.features = features
    }
}
```

**Step 8: Run tests — verify they pass**

```bash
xcodebuild -scheme CourseData -destination 'platform=macOS' test 2>&1 | tail -5
```

Expected: all tests pass

**Step 9: Commit**

```bash
git add CourseData/Models/ CourseDataTests/Models/
git commit -m "feat: add Coordinate, Feature, Green, and Hole models"
```

---

### Task 3: Data model — Course, TeeDefinition

**Files:**
- Create: `CourseData/Models/Course.swift`
- Create: `CourseDataTests/Models/CourseTests.swift`

**Step 1: Write Course tests**

`CourseDataTests/Models/CourseTests.swift`:
```swift
import XCTest
@testable import CourseData

final class CourseTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let course = Course(
            id: "broadlands-gc-broomfield-co",
            name: "The Broadlands Golf Course",
            location: CourseLocation(
                city: "Broomfield",
                state: "CO",
                coordinate: Coordinate(latitude: 39.9397, longitude: -105.0267)
            ),
            tees: [
                TeeDefinition(name: "Black", color: "#000000", gender: .male, rating: 73.5, slope: 137),
                TeeDefinition(name: "Gold", color: "#FFD700", gender: .male, rating: 71.2, slope: 131)
            ],
            holes: [
                Hole(number: 1, par: 4, handicap: 13,
                     yardages: ["Black": 401],
                     tees: ["Black": Coordinate(latitude: 39.9401, longitude: -105.0271)])
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
        XCTAssertEqual(course.holes.count, 1)
    }

    func testEmptyCourse() {
        let course = Course(
            id: "test",
            name: "Test Course",
            location: CourseLocation(
                city: "Denver",
                state: "CO",
                coordinate: Coordinate(latitude: 39.0, longitude: -105.0)
            )
        )
        XCTAssertTrue(course.tees.isEmpty)
        XCTAssertTrue(course.holes.isEmpty)
    }

    func testGenerateID() {
        let id = Course.generateID(name: "The Broadlands Golf Course", city: "Broomfield", state: "CO")
        XCTAssertEqual(id, "the-broadlands-golf-course-broomfield-co")
    }
}
```

**Step 2: Run tests — verify they fail**

```bash
xcodebuild -scheme CourseData -destination 'platform=macOS' test 2>&1 | grep -E "error:"
```

Expected: compilation errors

**Step 3: Implement Course**

`CourseData/Models/Course.swift`:
```swift
import Foundation

enum Gender: String, Codable {
    case male
    case female
}

struct TeeDefinition: Codable, Equatable, Identifiable {
    var id: String { name }
    let name: String
    let color: String
    let gender: Gender
    var rating: Double?
    var slope: Int?
}

struct CourseLocation: Codable, Equatable {
    var city: String
    var state: String
    var coordinate: Coordinate
}

struct Course: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var location: CourseLocation
    var tees: [TeeDefinition]
    var holes: [Hole]

    init(
        id: String,
        name: String,
        location: CourseLocation,
        tees: [TeeDefinition] = [],
        holes: [Hole] = []
    ) {
        self.id = id
        self.name = name
        self.location = location
        self.tees = tees
        self.holes = holes
    }

    static func generateID(name: String, city: String, state: String) -> String {
        "\(name)-\(city)-\(state)"
            .lowercased()
            .replacing(/[^a-z0-9\s-]/, with: "")
            .replacing(/\s+/, with: "-")
    }
}
```

**Step 4: Run tests — verify they pass**

```bash
xcodebuild -scheme CourseData -destination 'platform=macOS' test 2>&1 | tail -5
```

Expected: all tests pass

**Step 5: Commit**

```bash
git add CourseData/Models/Course.swift CourseDataTests/Models/CourseTests.swift
git commit -m "feat: add Course, TeeDefinition, and CourseLocation models"
```

---

### Task 4: CourseStore — JSON persistence

**Files:**
- Create: `CourseData/Services/CourseStore.swift`
- Create: `CourseDataTests/Services/CourseStoreTests.swift`

**Step 1: Write CourseStore tests**

`CourseDataTests/Services/CourseStoreTests.swift`:
```swift
import XCTest
@testable import CourseData

final class CourseStoreTests: XCTestCase {
    var tempDir: URL!
    var store: CourseStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = CourseStore(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testSaveAndLoad() throws {
        let course = makeCourse(id: "test-course")
        try store.save(course)

        let loaded = try store.load(id: "test-course")
        XCTAssertEqual(loaded?.name, course.name)
        XCTAssertEqual(loaded?.id, "test-course")
    }

    func testListCourses() throws {
        try store.save(makeCourse(id: "course-a"))
        try store.save(makeCourse(id: "course-b"))

        let list = try store.listCourses()
        XCTAssertEqual(list.count, 2)
        XCTAssertTrue(list.contains(where: { $0.id == "course-a" }))
        XCTAssertTrue(list.contains(where: { $0.id == "course-b" }))
    }

    func testDeleteCourse() throws {
        try store.save(makeCourse(id: "to-delete"))
        XCTAssertNotNil(try store.load(id: "to-delete"))

        try store.delete(id: "to-delete")
        XCTAssertNil(try store.load(id: "to-delete"))
    }

    func testOverwriteExisting() throws {
        var course = makeCourse(id: "overwrite-me")
        try store.save(course)

        course.name = "Updated Name"
        try store.save(course)

        let loaded = try store.load(id: "overwrite-me")
        XCTAssertEqual(loaded?.name, "Updated Name")
    }

    func testLoadNonexistent() throws {
        let loaded = try store.load(id: "does-not-exist")
        XCTAssertNil(loaded)
    }

    private func makeCourse(id: String) -> Course {
        Course(
            id: id,
            name: "Test Course",
            location: CourseLocation(
                city: "Denver",
                state: "CO",
                coordinate: Coordinate(latitude: 39.0, longitude: -105.0)
            )
        )
    }
}
```

**Step 2: Run tests — verify they fail**

```bash
xcodebuild -scheme CourseData -destination 'platform=macOS' test 2>&1 | grep -E "error:.*CourseStore"
```

Expected: CourseStore not defined

**Step 3: Implement CourseStore**

`CourseData/Services/CourseStore.swift`:
```swift
import Foundation

class CourseStore: ObservableObject {
    @Published var courses: [Course] = []

    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = appSupport.appendingPathComponent("CourseData/courses", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func save(_ course: Course) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(course)
        let fileURL = directory.appendingPathComponent("\(course.id).json")
        try data.write(to: fileURL)

        if let index = courses.firstIndex(where: { $0.id == course.id }) {
            courses[index] = course
        } else {
            courses.append(course)
        }
    }

    func load(id: String) throws -> Course? {
        let fileURL = directory.appendingPathComponent("\(id).json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(Course.self, from: data)
    }

    func listCourses() throws -> [Course] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        return try files.map { url in
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Course.self, from: data)
        }
    }

    func delete(id: String) throws {
        let fileURL = directory.appendingPathComponent("\(id).json")
        try FileManager.default.removeItem(at: fileURL)
        courses.removeAll { $0.id == id }
    }

    func loadAll() throws {
        courses = try listCourses()
    }
}
```

**Step 4: Run tests — verify they pass**

```bash
xcodebuild -scheme CourseData -destination 'platform=macOS' test 2>&1 | tail -5
```

Expected: all tests pass

**Step 5: Commit**

```bash
git add CourseData/Services/CourseStore.swift CourseDataTests/Services/CourseStoreTests.swift
git commit -m "feat: add CourseStore for JSON persistence"
```

---

### Task 5: GolfCourseAPIClient

**Files:**
- Create: `CourseData/Services/GolfCourseAPIClient.swift`
- Create: `CourseDataTests/Services/GolfCourseAPIClientTests.swift`

The GolfCourseAPI.com returns JSON. We parse it into our Course model. The API key should be stored in a config/environment since it requires signup. For now, use a placeholder mechanism.

**Step 1: Write parsing tests using mock JSON**

`CourseDataTests/Services/GolfCourseAPIClientTests.swift`:
```swift
import XCTest
@testable import CourseData

final class GolfCourseAPIClientTests: XCTestCase {
    func testParseCourseSearchResponse() throws {
        let json = """
        {
            "courses": [
                {
                    "id": 12345,
                    "club_name": "The Broadlands Golf Club",
                    "course_name": "Broadlands Golf Course",
                    "location": {
                        "address": "4380 W 144th Ave",
                        "city": "Broomfield",
                        "state": "CO",
                        "country": "US",
                        "zip_code": "80023"
                    },
                    "holes": 18
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(GolfCourseAPIClient.SearchResponse.self, from: json)
        XCTAssertEqual(response.courses.count, 1)
        XCTAssertEqual(response.courses[0].courseName, "Broadlands Golf Course")
        XCTAssertEqual(response.courses[0].location.city, "Broomfield")
    }

    func testParseCourseDetailResponse() throws {
        let json = """
        {
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
                        "total_yards": 7289,
                        "par_total": 72,
                        "holes": [
                            { "hole_number": 1, "par": 4, "yardage": 401, "handicap": 13 },
                            { "hole_number": 2, "par": 5, "yardage": 545, "handicap": 3 }
                        ]
                    }
                ],
                "female": [
                    {
                        "tee_name": "Red",
                        "course_rating": 69.1,
                        "slope_rating": 121,
                        "total_yards": 5200,
                        "par_total": 72,
                        "holes": [
                            { "hole_number": 1, "par": 4, "yardage": 298, "handicap": 13 },
                            { "hole_number": 2, "par": 5, "yardage": 430, "handicap": 3 }
                        ]
                    }
                ]
            }
        }
        """.data(using: .utf8)!

        let detail = try JSONDecoder().decode(GolfCourseAPIClient.CourseDetail.self, from: json)
        let course = GolfCourseAPIClient.convertToCourse(detail: detail)

        XCTAssertEqual(course.name, "Broadlands Golf Course")
        XCTAssertEqual(course.location.city, "Broomfield")
        XCTAssertEqual(course.location.state, "CO")
        XCTAssertEqual(course.tees.count, 2)
        XCTAssertEqual(course.tees[0].name, "Black")
        XCTAssertEqual(course.tees[0].gender, .male)
        XCTAssertEqual(course.tees[0].rating, 73.5)
        XCTAssertEqual(course.tees[0].slope, 137)
        XCTAssertEqual(course.holes.count, 2)
        XCTAssertEqual(course.holes[0].par, 4)
        XCTAssertEqual(course.holes[0].yardages["Black"], 401)
        XCTAssertEqual(course.holes[0].yardages["Red"], 298)
        XCTAssertEqual(course.holes[1].handicap, 3)
    }
}
```

**Step 2: Run tests — verify they fail**

```bash
xcodebuild -scheme CourseData -destination 'platform=macOS' test 2>&1 | grep -E "error:"
```

Expected: GolfCourseAPIClient not defined

**Step 3: Implement GolfCourseAPIClient**

`CourseData/Services/GolfCourseAPIClient.swift`:
```swift
import Foundation

actor GolfCourseAPIClient {
    private let apiKey: String
    private let baseURL = "https://api.golfcourseapi.com/v1"
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: - API Response Types

    struct SearchResponse: Codable {
        let courses: [CourseSearchResult]
    }

    struct CourseSearchResult: Codable {
        let id: Int
        let clubName: String
        let courseName: String
        let location: APILocation
        let holes: Int

        enum CodingKeys: String, CodingKey {
            case id
            case clubName = "club_name"
            case courseName = "course_name"
            case location
            case holes
        }
    }

    struct APILocation: Codable {
        let address: String?
        let city: String
        let state: String
        let country: String?
        let zipCode: String?

        enum CodingKeys: String, CodingKey {
            case address, city, state, country
            case zipCode = "zip_code"
        }
    }

    struct CourseDetail: Codable {
        let courseName: String
        let clubName: String
        let location: APILocation
        let tees: TeeSets

        enum CodingKeys: String, CodingKey {
            case courseName = "course_name"
            case clubName = "club_name"
            case location, tees
        }
    }

    struct TeeSets: Codable {
        let male: [TeeSet]?
        let female: [TeeSet]?
    }

    struct TeeSet: Codable {
        let teeName: String
        let courseRating: Double?
        let slopeRating: Int?
        let totalYards: Int?
        let parTotal: Int?
        let holes: [APIHole]

        enum CodingKeys: String, CodingKey {
            case teeName = "tee_name"
            case courseRating = "course_rating"
            case slopeRating = "slope_rating"
            case totalYards = "total_yards"
            case parTotal = "par_total"
            case holes
        }
    }

    struct APIHole: Codable {
        let holeNumber: Int
        let par: Int
        let yardage: Int
        let handicap: Int

        enum CodingKeys: String, CodingKey {
            case holeNumber = "hole_number"
            case par, yardage, handicap
        }
    }

    // MARK: - Network Methods

    func search(query: String) async throws -> [CourseSearchResult] {
        var components = URLComponents(string: "\(baseURL)/search")!
        components.queryItems = [URLQueryItem(name: "search_query", value: query)]
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        return response.courses
    }

    func fetchCourse(id: Int) async throws -> CourseDetail {
        let url = URL(string: "\(baseURL)/courses/\(id)")!
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(CourseDetail.self, from: data)
    }

    // MARK: - Conversion

    static func convertToCourse(detail: CourseDetail) -> Course {
        var teeDefinitions: [TeeDefinition] = []
        var holeMap: [Int: Hole] = [:]

        func processTeeSet(_ teeSet: TeeSet, gender: Gender) {
            let color = defaultColor(for: teeSet.teeName)
            teeDefinitions.append(TeeDefinition(
                name: teeSet.teeName,
                color: color,
                gender: gender,
                rating: teeSet.courseRating,
                slope: teeSet.slopeRating
            ))

            for apiHole in teeSet.holes {
                if var hole = holeMap[apiHole.holeNumber] {
                    hole.yardages[teeSet.teeName] = apiHole.yardage
                    holeMap[apiHole.holeNumber] = hole
                } else {
                    holeMap[apiHole.holeNumber] = Hole(
                        number: apiHole.holeNumber,
                        par: apiHole.par,
                        handicap: apiHole.handicap,
                        yardages: [teeSet.teeName: apiHole.yardage]
                    )
                }
            }
        }

        for teeSet in detail.tees.male ?? [] {
            processTeeSet(teeSet, gender: .male)
        }
        for teeSet in detail.tees.female ?? [] {
            processTeeSet(teeSet, gender: .female)
        }

        let holes = holeMap.values.sorted { $0.number < $1.number }

        let courseID = Course.generateID(
            name: detail.courseName,
            city: detail.location.city,
            state: detail.location.state
        )

        return Course(
            id: courseID,
            name: detail.courseName,
            location: CourseLocation(
                city: detail.location.city,
                state: detail.location.state,
                coordinate: Coordinate(latitude: 0, longitude: 0) // Set later via MapKit search
            ),
            tees: teeDefinitions,
            holes: holes
        )
    }

    private static func defaultColor(for teeName: String) -> String {
        switch teeName.lowercased() {
        case "black": return "#000000"
        case "gold": return "#FFD700"
        case "blue": return "#0000FF"
        case "white": return "#FFFFFF"
        case "silver": return "#C0C0C0"
        case "red": return "#FF0000"
        case "green": return "#008000"
        default: return "#808080"
        }
    }
}
```

**Step 4: Run tests — verify they pass**

```bash
xcodebuild -scheme CourseData -destination 'platform=macOS' test 2>&1 | tail -5
```

Expected: all tests pass

**Step 5: Commit**

```bash
git add CourseData/Services/GolfCourseAPIClient.swift CourseDataTests/Services/GolfCourseAPIClientTests.swift
git commit -m "feat: add GolfCourseAPIClient with JSON parsing"
```

---

### Task 6: CourseSearchService

**Files:**
- Create: `CourseData/Services/CourseSearchService.swift`

This wraps MKLocalSearch with `.golf` POI filtering. It requires MapKit which is hard to unit test (needs a running app context). We'll create the service and verify it compiles.

**Step 1: Implement CourseSearchService**

`CourseData/Services/CourseSearchService.swift`:
```swift
import Foundation
import MapKit

struct CourseSearchResult: Identifiable {
    let id = UUID()
    let name: String
    let coordinate: Coordinate
    let region: MKCoordinateRegion
    let mapItem: MKMapItem
}

class CourseSearchService {
    func search(query: String) async throws -> [CourseSearchResult] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.golf])

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
            return CourseSearchResult(
                name: name,
                coordinate: Coordinate(coord),
                region: region,
                mapItem: item
            )
        }
    }
}
```

**Step 2: Verify it compiles**

```bash
xcodebuild -scheme CourseData -destination 'platform=macOS' build 2>&1 | tail -3
```

Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add CourseData/Services/CourseSearchService.swift
git commit -m "feat: add CourseSearchService with MKLocalSearch"
```

---

### Task 7: ScorecardScraper — HTML parsing for GolfLink/GolfPass

**Files:**
- Create: `CourseData/Services/ScorecardScraper.swift`
- Create: `CourseDataTests/Services/ScorecardScraperTests.swift`

We'll use `XMLDocument` with `.documentTidyHTML` option to parse HTML. Tests will use inline HTML fixtures.

**Step 1: Write scraper tests with HTML fixture**

`CourseDataTests/Services/ScorecardScraperTests.swift`:
```swift
import XCTest
@testable import CourseData

final class ScorecardScraperTests: XCTestCase {
    func testParseGolfLinkHTML() throws {
        // Minimal GolfLink-style scorecard HTML
        let html = """
        <div class="scorecard-table-container">
        <table>
          <tr><th></th><th>1</th><th>2</th><th>3</th><th>Out</th></tr>
          <tr><td>Black</td><td>401</td><td>545</td><td>185</td><td>1131</td></tr>
          <tr><td>Gold</td><td>378</td><td>520</td><td>165</td><td>1063</td></tr>
          <tr><td>Par</td><td>4</td><td>5</td><td>3</td><td>12</td></tr>
          <tr><td>Handicap</td><td>13</td><td>3</td><td>17</td><td></td></tr>
        </table>
        </div>
        """

        let result = try ScorecardScraper.parseGolfLink(html: html)
        XCTAssertEqual(result.holes.count, 3)
        XCTAssertEqual(result.holes[0].par, 4)
        XCTAssertEqual(result.holes[0].handicap, 13)
        XCTAssertEqual(result.holes[0].yardages["Black"], 401)
        XCTAssertEqual(result.holes[0].yardages["Gold"], 378)
        XCTAssertEqual(result.holes[1].par, 5)
        XCTAssertEqual(result.holes[2].yardages["Black"], 185)
        XCTAssertEqual(result.teeNames, ["Black", "Gold"])
    }
}
```

**Step 2: Run tests — verify they fail**

```bash
xcodebuild -scheme CourseData -destination 'platform=macOS' test 2>&1 | grep -E "error:"
```

Expected: ScorecardScraper not defined

**Step 3: Implement ScorecardScraper**

`CourseData/Services/ScorecardScraper.swift`:
```swift
import Foundation

struct ScorecardData {
    var holes: [Hole]
    var teeNames: [String]
}

enum ScorecardScraper {
    static func parseGolfLink(html: String) throws -> ScorecardData {
        let doc = try XMLDocument(xmlString: html, options: [.documentTidyHTML])
        guard let root = doc.rootElement() else {
            throw ScraperError.parseError("No root element")
        }

        // Find the scorecard table
        let tables = try root.nodes(forXPath: "//table")
        guard let table = tables.first as? XMLElement else {
            throw ScraperError.parseError("No table found")
        }

        let rows = table.elements(forName: "tr")
        guard rows.count >= 2 else {
            throw ScraperError.parseError("Not enough rows in table")
        }

        // First row is headers — extract hole numbers
        let headerCells = cellTexts(from: rows[0])
        let holeColumns = headerCells.enumerated().compactMap { index, text -> (Int, Int)? in
            guard let num = Int(text) else { return nil }
            return (index, num)
        }

        // Parse each subsequent row
        var teeYardages: [(name: String, yardages: [Int: Int])] = []
        var parRow: [Int: Int] = [:]
        var handicapRow: [Int: Int] = [:]

        for row in rows.dropFirst() {
            let cells = cellTexts(from: row)
            guard let label = cells.first else { continue }

            let trimmed = label.trimmingCharacters(in: .whitespaces)

            if trimmed.lowercased() == "par" {
                for (colIndex, holeNum) in holeColumns {
                    if colIndex < cells.count, let par = Int(cells[colIndex]) {
                        parRow[holeNum] = par
                    }
                }
            } else if trimmed.lowercased() == "handicap" || trimmed.lowercased() == "hdcp" {
                for (colIndex, holeNum) in holeColumns {
                    if colIndex < cells.count, let hcp = Int(cells[colIndex]) {
                        handicapRow[holeNum] = hcp
                    }
                }
            } else if trimmed.lowercased() != "out" && trimmed.lowercased() != "in"
                        && trimmed.lowercased() != "tot" && trimmed.lowercased() != "total" {
                // Assume it's a tee name
                var yardages: [Int: Int] = [:]
                for (colIndex, holeNum) in holeColumns {
                    if colIndex < cells.count, let yards = Int(cells[colIndex]) {
                        yardages[holeNum] = yards
                    }
                }
                if !yardages.isEmpty {
                    teeYardages.append((name: trimmed, yardages: yardages))
                }
            }
        }

        let teeNames = teeYardages.map(\.name)
        let holeNumbers = holeColumns.map(\.1).sorted()

        let holes = holeNumbers.map { num in
            var yardageDict: [String: Int] = [:]
            for tee in teeYardages {
                if let y = tee.yardages[num] {
                    yardageDict[tee.name] = y
                }
            }
            return Hole(
                number: num,
                par: parRow[num] ?? 0,
                handicap: handicapRow[num] ?? 0,
                yardages: yardageDict
            )
        }

        return ScorecardData(holes: holes, teeNames: teeNames)
    }

    private static func cellTexts(from row: XMLElement) -> [String] {
        let cells = row.elements(forName: "td") + row.elements(forName: "th")
        return cells.map { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    }

    static func fetchAndParse(url: URL) async throws -> ScorecardData {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let html = String(data: data, encoding: .utf8) else {
            throw ScraperError.parseError("Could not decode HTML as UTF-8")
        }
        return try parseGolfLink(html: html)
    }

    enum ScraperError: LocalizedError {
        case parseError(String)

        var errorDescription: String? {
            switch self {
            case .parseError(let msg): return "Scraper error: \(msg)"
            }
        }
    }
}
```

**Step 4: Run tests — verify they pass**

```bash
xcodebuild -scheme CourseData -destination 'platform=macOS' test 2>&1 | tail -5
```

Expected: all tests pass

**Step 5: Commit**

```bash
git add CourseData/Services/ScorecardScraper.swift CourseDataTests/Services/ScorecardScraperTests.swift
git commit -m "feat: add ScorecardScraper for GolfLink HTML parsing"
```

---

### Task 8: ScorecardOCR — Vision framework text extraction

**Files:**
- Create: `CourseData/Services/ScorecardOCR.swift`

Vision OCR requires an actual image so we'll skip unit tests and write this as a straightforward service. We can integration-test it later with a real scorecard image.

**Step 1: Implement ScorecardOCR**

`CourseData/Services/ScorecardOCR.swift`:
```swift
import AppKit
import Vision

enum ScorecardOCR {
    struct TextBlock {
        let text: String
        let boundingBox: CGRect // normalized, origin at bottom-left
    }

    /// Extract all text blocks from an image, sorted top-to-bottom then left-to-right
    static func extractText(from image: NSImage) throws -> [TextBlock] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw OCRError.invalidImage
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.customWords = ["Par", "Handicap", "Hdcp", "Out", "In", "Tot", "Slope", "Rating"]

        try handler.perform([request])

        guard let observations = request.results else { return [] }

        let blocks = observations.compactMap { obs -> TextBlock? in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            return TextBlock(text: candidate.string, boundingBox: obs.boundingBox)
        }

        // Sort top-to-bottom (descending Y since Vision uses bottom-left origin), then left-to-right
        return blocks.sorted { a, b in
            let rowA = Int(a.boundingBox.midY * 100)
            let rowB = Int(b.boundingBox.midY * 100)
            if abs(rowA - rowB) > 2 { // same row tolerance
                return rowA > rowB // top-to-bottom
            }
            return a.boundingBox.minX < b.boundingBox.minX // left-to-right
        }
    }

    /// Attempt to parse extracted text blocks into scorecard data
    static func parseScorecard(from image: NSImage) throws -> ScorecardData {
        let blocks = try extractText(from: image)

        // Group into rows by Y position
        var rows: [[TextBlock]] = []
        var currentRow: [TextBlock] = []
        var lastY: CGFloat = -1

        for block in blocks {
            let y = block.boundingBox.midY
            if lastY < 0 || abs(y - lastY) < 0.02 {
                currentRow.append(block)
            } else {
                if !currentRow.isEmpty { rows.append(currentRow) }
                currentRow = [block]
            }
            lastY = y
        }
        if !currentRow.isEmpty { rows.append(currentRow) }

        // Convert rows to text arrays and reuse the table parser logic
        var teeYardages: [(name: String, yardages: [Int: Int])] = []
        var parValues: [Int: Int] = [:]
        var handicapValues: [Int: Int] = [:]
        let holeCount = 9 // assume 9 holes per side; caller handles front/back

        for row in rows {
            let texts = row.map(\.text)
            guard let label = texts.first else { continue }
            let numbers = texts.dropFirst().compactMap { Int($0) }

            if label.lowercased().contains("par") {
                for (i, val) in numbers.enumerated() {
                    parValues[i + 1] = val
                }
            } else if label.lowercased().contains("handicap") || label.lowercased().contains("hdcp") {
                for (i, val) in numbers.enumerated() {
                    handicapValues[i + 1] = val
                }
            } else if numbers.count >= 3 {
                var yardages: [Int: Int] = [:]
                for (i, val) in numbers.prefix(holeCount).enumerated() {
                    yardages[i + 1] = val
                }
                teeYardages.append((name: label, yardages: yardages))
            }
        }

        let holeNumbers = Set(parValues.keys).union(teeYardages.flatMap(\.yardages.keys)).sorted()

        let holes = holeNumbers.map { num in
            var yardageDict: [String: Int] = [:]
            for tee in teeYardages {
                if let y = tee.yardages[num] {
                    yardageDict[tee.name] = y
                }
            }
            return Hole(
                number: num,
                par: parValues[num] ?? 0,
                handicap: handicapValues[num] ?? 0,
                yardages: yardageDict
            )
        }

        return ScorecardData(holes: holes, teeNames: teeYardages.map(\.name))
    }

    enum OCRError: LocalizedError {
        case invalidImage

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "Could not convert image to CGImage"
            }
        }
    }
}
```

**Step 2: Verify it compiles**

```bash
xcodebuild -scheme CourseData -destination 'platform=macOS' build 2>&1 | tail -3
```

Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add CourseData/Services/ScorecardOCR.swift
git commit -m "feat: add ScorecardOCR using Vision framework"
```

---

### Task 9: ScorecardImporter — orchestrates the fallback chain

**Files:**
- Create: `CourseData/Services/ScorecardImporter.swift`

**Step 1: Implement ScorecardImporter**

`CourseData/Services/ScorecardImporter.swift`:
```swift
import AppKit
import Foundation

@MainActor
class ScorecardImporter: ObservableObject {
    enum ImportSource {
        case api
        case scraped(URL)
        case ocr(NSImage)
        case manual
    }

    enum ImportError: LocalizedError {
        case apiKeyMissing
        case courseNotFound
        case allSourcesFailed(String)

        var errorDescription: String? {
            switch self {
            case .apiKeyMissing: return "Golf Course API key not configured"
            case .courseNotFound: return "Course not found in any data source"
            case .allSourcesFailed(let detail): return "All import sources failed: \(detail)"
            }
        }
    }

    @Published var status: String = ""
    @Published var isLoading = false

    private let apiClient: GolfCourseAPIClient?

    init(apiKey: String?) {
        self.apiClient = apiKey.map { GolfCourseAPIClient(apiKey: $0) }
    }

    /// Try API first, then scraping, return partial Course (no GPS coords yet)
    func importScorecard(courseName: String, city: String, state: String) async throws -> Course {
        isLoading = true
        defer { isLoading = false }

        // Try API
        if let apiClient {
            do {
                status = "Searching GolfCourseAPI.com..."
                let results = try await apiClient.search(query: "\(courseName) \(city) \(state)")
                if let match = results.first {
                    status = "Fetching scorecard data..."
                    let detail = try await apiClient.fetchCourse(id: match.id)
                    let course = GolfCourseAPIClient.convertToCourse(detail: detail)
                    status = "Imported from API"
                    return course
                }
            } catch {
                status = "API failed: \(error.localizedDescription)"
            }
        }

        // Try scraping GolfLink
        do {
            status = "Trying GolfLink..."
            let slug = "\(city)/\(courseName)"
                .lowercased()
                .replacing(/[^a-z0-9\s]/, with: "")
                .replacing(/\s+/, with: "-")
            let url = URL(string: "https://www.golflink.com/golf-courses/\(state.lowercased())/\(slug)")!
            let data = try await ScorecardScraper.fetchAndParse(url: url)
            let course = buildCourse(from: data, name: courseName, city: city, state: state)
            status = "Imported from GolfLink"
            return course
        } catch {
            status = "GolfLink failed: \(error.localizedDescription)"
        }

        throw ImportError.courseNotFound
    }

    /// Import from a scorecard image using OCR
    func importFromImage(_ image: NSImage, name: String, city: String, state: String) throws -> Course {
        let data = try ScorecardOCR.parseScorecard(from: image)
        return buildCourse(from: data, name: name, city: city, state: state)
    }

    /// Create an empty course shell for manual entry
    func createManualCourse(name: String, city: String, state: String, holeCount: Int = 18) -> Course {
        let holes = (1...holeCount).map { Hole(number: $0, par: 4, handicap: $0) }
        return Course(
            id: Course.generateID(name: name, city: city, state: state),
            name: name,
            location: CourseLocation(city: city, state: state, coordinate: Coordinate(latitude: 0, longitude: 0)),
            holes: holes
        )
    }

    private func buildCourse(from data: ScorecardData, name: String, city: String, state: String) -> Course {
        let tees = data.teeNames.map { teeName in
            TeeDefinition(
                name: teeName,
                color: defaultColor(for: teeName),
                gender: .male
            )
        }
        return Course(
            id: Course.generateID(name: name, city: city, state: state),
            name: name,
            location: CourseLocation(city: city, state: state, coordinate: Coordinate(latitude: 0, longitude: 0)),
            tees: tees,
            holes: data.holes
        )
    }

    private func defaultColor(for teeName: String) -> String {
        switch teeName.lowercased() {
        case "black": return "#000000"
        case "gold": return "#FFD700"
        case "blue": return "#0000FF"
        case "white": return "#FFFFFF"
        case "silver": return "#C0C0C0"
        case "red": return "#FF0000"
        default: return "#808080"
        }
    }
}
```

**Step 2: Verify it compiles**

```bash
xcodebuild -scheme CourseData -destination 'platform=macOS' build 2>&1 | tail -3
```

Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add CourseData/Services/ScorecardImporter.swift
git commit -m "feat: add ScorecardImporter with API/scraping/OCR fallback chain"
```

---

### Task 10: FeatureDetector — satellite imagery analysis

**Files:**
- Create: `CourseData/Services/FeatureDetector.swift`

Uses MKMapSnapshotter to capture satellite imagery, then CoreImage HSB filtering to detect greens and tee boxes.

**Step 1: Implement FeatureDetector**

`CourseData/Services/FeatureDetector.swift`:
```swift
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import MapKit

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
    /// Capture satellite imagery for a region and detect golf features
    func detect(in region: MKCoordinateRegion) async throws -> [DetectedFeature] {
        let snapshot = try await captureSnapshot(region: region)
        guard let cgImage = snapshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }

        let width = cgImage.width
        let height = cgImage.height

        // Get raw pixel data
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let pixelData = context.data else { return [] }
        let data = pixelData.bindMemory(to: UInt8.self, capacity: width * height * 4)

        // Scan for green regions (golf greens are dark, saturated green)
        var greenPixels: [(x: Int, y: Int)] = []
        var lightGreenPixels: [(x: Int, y: Int)] = [] // tee boxes are lighter green

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let r = CGFloat(data[offset]) / 255.0
                let g = CGFloat(data[offset + 1]) / 255.0
                let b = CGFloat(data[offset + 2]) / 255.0

                var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0
                NSColor(red: r, green: g, blue: b, alpha: 1.0).getHue(&h, saturation: &s, brightness: &br, alpha: nil)

                let hueDeg = h * 360

                // Dark green (golf greens): hue 80-160, high saturation, medium brightness
                if hueDeg > 80 && hueDeg < 160 && s > 0.3 && br > 0.3 && br < 0.7 {
                    greenPixels.append((x, y))
                }
                // Light green (tee boxes): hue 80-160, moderate saturation, higher brightness
                else if hueDeg > 80 && hueDeg < 160 && s > 0.2 && br > 0.5 && br < 0.85 {
                    lightGreenPixels.append((x, y))
                }
            }
        }

        var features: [DetectedFeature] = []

        // Cluster green pixels and find centroids
        let greenClusters = clusterPixels(greenPixels, minClusterSize: 50, maxGap: 10)
        for cluster in greenClusters {
            let centroid = clusterCentroid(cluster)
            let point = CGPoint(x: centroid.x, y: centroid.y)
            let coord = snapshot.point(for: coordinateFrom(point: point, snapshot: snapshot, imageSize: CGSize(width: width, height: height)))
            // Convert back — snapshot.point gives us the screen point for a coordinate
            // We need the reverse: image point to coordinate
            let mapCoord = coordinateFrom(point: point, snapshot: snapshot, imageSize: CGSize(width: width, height: height))
            features.append(DetectedFeature(kind: .green, coordinate: Coordinate(mapCoord), confidence: 0.6))
        }

        return features
    }

    private func captureSnapshot(region: MKCoordinateRegion) async throws -> MKMapSnapshotter.Snapshot {
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = CGSize(width: 1024, height: 1024)
        options.mapType = .satellite

        let snapshotter = MKMapSnapshotter(options: options)
        return try await snapshotter.start()
    }

    /// Simple grid-based clustering
    private func clusterPixels(_ pixels: [(x: Int, y: Int)], minClusterSize: Int, maxGap: Int) -> [[(x: Int, y: Int)]] {
        guard !pixels.isEmpty else { return [] }

        var visited = Set<Int>()
        var clusters: [[(x: Int, y: Int)]] = []

        // Build a spatial index
        var grid: [Int: [(x: Int, y: Int)]] = [:]
        for p in pixels {
            let key = (p.y / maxGap) * 100000 + (p.x / maxGap)
            grid[key, default: []].append(p)
        }

        for (i, pixel) in pixels.enumerated() {
            guard !visited.contains(i) else { continue }
            visited.insert(i)

            var cluster = [pixel]
            var queue = [pixel]

            while !queue.isEmpty {
                let current = queue.removeFirst()
                // Check neighboring grid cells
                let cellX = current.x / maxGap
                let cellY = current.y / maxGap
                for dy in -1...1 {
                    for dx in -1...1 {
                        let key = (cellY + dy) * 100000 + (cellX + dx)
                        if let neighbors = grid[key] {
                            for neighbor in neighbors {
                                let ni = pixels.firstIndex(where: { $0.x == neighbor.x && $0.y == neighbor.y })
                                if let ni, !visited.contains(ni) {
                                    let dist = abs(neighbor.x - current.x) + abs(neighbor.y - current.y)
                                    if dist <= maxGap * 2 {
                                        visited.insert(ni)
                                        cluster.append(neighbor)
                                        queue.append(neighbor)
                                    }
                                }
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

    private func clusterCentroid(_ cluster: [(x: Int, y: Int)]) -> (x: Double, y: Double) {
        let sumX = cluster.reduce(0.0) { $0 + Double($1.x) }
        let sumY = cluster.reduce(0.0) { $0 + Double($1.y) }
        return (sumX / Double(cluster.count), sumY / Double(cluster.count))
    }

    /// Convert an image pixel point to a map coordinate using the snapshot's coordinate mapping
    private func coordinateFrom(point: CGPoint, snapshot: MKMapSnapshotter.Snapshot, imageSize: CGSize) -> CLLocationCoordinate2D {
        // The snapshot maps coordinates to points. We need the inverse.
        // snapshot.point(for:) gives screen point for a coordinate.
        // We approximate the inverse by using the region bounds.
        let region = snapshot.snapshotProperties.region
        let lat = region.center.latitude + region.span.latitudeDelta * (0.5 - Double(point.y / imageSize.height))
        let lon = region.center.longitude + region.span.longitudeDelta * (Double(point.x / imageSize.width) - 0.5)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
```

**Step 2: Verify it compiles**

Note: `snapshot.snapshotProperties` may not exist — the region is on the options, not the snapshot. We'll need to pass the region through. This will likely need adjustment during implementation. The key API calls are correct (`MKMapSnapshotter`, pixel analysis, coordinate conversion). The implementer should verify the exact `MKMapSnapshotter.Snapshot` API and adjust the `coordinateFrom` method accordingly — the region used for the snapshot options should be passed alongside the snapshot result.

```bash
xcodebuild -scheme CourseData -destination 'platform=macOS' build 2>&1 | tail -3
```

Expected: BUILD SUCCEEDED (may need to fix `snapshotProperties` — replace with passing region as parameter)

**Step 3: Commit**

```bash
git add CourseData/Services/FeatureDetector.swift
git commit -m "feat: add FeatureDetector with CoreImage HSB analysis"
```

---

### Task 11: CourseListView

**Files:**
- Modify: `CourseData/App/CourseDataApp.swift`
- Create: `CourseData/Views/CourseListView.swift`
- Modify: `CourseData/Views/ContentView.swift`

**Step 1: Implement CourseListView**

`CourseData/Views/CourseListView.swift`:
```swift
import SwiftUI

struct CourseListView: View {
    @EnvironmentObject var store: CourseStore
    @State private var showNewCourse = false
    @State private var selectedCourse: Course?

    var body: some View {
        NavigationSplitView {
            List(store.courses, selection: $selectedCourse) { course in
                NavigationLink(value: course) {
                    VStack(alignment: .leading) {
                        Text(course.name)
                            .font(.headline)
                        Text("\(course.location.city), \(course.location.state)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(course.holes.count) holes")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .navigationTitle("Courses")
            .toolbar {
                Button("New Course") {
                    showNewCourse = true
                }
            }
        } detail: {
            if let course = selectedCourse {
                ScorecardImportView(course: course)
            } else {
                Text("Select a course or create a new one")
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showNewCourse) {
            NewCourseSheet { course in
                try? store.save(course)
                selectedCourse = course
                showNewCourse = false
            }
        }
        .onAppear {
            try? store.loadAll()
        }
    }
}

struct NewCourseSheet: View {
    let onCreate: (Course) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var city = ""
    @State private var state = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("New Course").font(.title2)
            TextField("Course Name", text: $name)
            TextField("City", text: $city)
            TextField("State (abbreviation)", text: $state)
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let course = Course(
                        id: Course.generateID(name: name, city: city, state: state),
                        name: name,
                        location: CourseLocation(
                            city: city,
                            state: state,
                            coordinate: Coordinate(latitude: 0, longitude: 0)
                        ),
                        holes: (1...18).map { Hole(number: $0, par: 4, handicap: $0) }
                    )
                    onCreate(course)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || city.isEmpty || state.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 350)
    }
}
```

**Step 2: Update ContentView and App entry point**

`CourseData/Views/ContentView.swift`:
```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        CourseListView()
            .frame(minWidth: 900, minHeight: 600)
    }
}
```

`CourseData/App/CourseDataApp.swift`:
```swift
import SwiftUI

@main
struct CourseDataApp: App {
    @StateObject private var store = CourseStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
```

**Step 3: Verify it compiles**

Note: `ScorecardImportView` doesn't exist yet — use a placeholder `Text(course.name)` in the detail view for now. Replace the `ScorecardImportView(course: course)` line with `Text(course.name)` and update it in Task 12.

```bash
xcodebuild -scheme CourseData -destination 'platform=macOS' build 2>&1 | tail -3
```

Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add CourseData/App/ CourseData/Views/
git commit -m "feat: add CourseListView with new course creation"
```

---

### Task 12: ScorecardImportView

**Files:**
- Create: `CourseData/Views/ScorecardImportView.swift`
- Modify: `CourseData/Views/CourseListView.swift` (replace placeholder in detail)

**Step 1: Implement ScorecardImportView**

`CourseData/Views/ScorecardImportView.swift`:
```swift
import SwiftUI
import UniformTypeIdentifiers

struct ScorecardImportView: View {
    @EnvironmentObject var store: CourseStore
    @State var course: Course
    @State private var searchQuery = ""
    @State private var isImporting = false
    @State private var statusMessage = ""
    @State private var showImagePicker = false
    @State private var navigateToMap = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(course.name)
                    .font(.title2.bold())
                Spacer()
                Button("Open Map Editor") {
                    navigateToMap = true
                }
                .disabled(course.holes.isEmpty)
            }
            .padding()

            Divider()

            // Import controls
            HStack(spacing: 12) {
                TextField("Search GolfCourseAPI...", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { importFromAPI() }
                Button("Search API") { importFromAPI() }
                    .disabled(searchQuery.isEmpty || isImporting)
                Button("Import Image...") { showImagePicker = true }
                if isImporting {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            Divider()

            // Scorecard table
            ScorecardTableView(course: $course)

            Divider()

            // Save bar
            HStack {
                Spacer()
                Button("Save") {
                    try? store.save(course)
                    statusMessage = "Saved"
                }
            }
            .padding()
        }
        .fileImporter(isPresented: $showImagePicker, allowedContentTypes: [.image, .pdf]) { result in
            if case .success(let url) = result {
                importFromImage(url: url)
            }
        }
        .navigationDestination(isPresented: $navigateToMap) {
            MapEditorView(course: $course)
        }
    }

    private func importFromAPI() {
        isImporting = true
        statusMessage = "Searching..."
        Task {
            do {
                let importer = ScorecardImporter(apiKey: apiKey)
                let imported = try await importer.importScorecard(
                    courseName: searchQuery.isEmpty ? course.name : searchQuery,
                    city: course.location.city,
                    state: course.location.state
                )
                course.tees = imported.tees
                course.holes = imported.holes
                statusMessage = "Imported \(imported.holes.count) holes with \(imported.tees.count) tee sets"
            } catch {
                statusMessage = "Import failed: \(error.localizedDescription)"
            }
            isImporting = false
        }
    }

    private func importFromImage(url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            statusMessage = "Could not load image"
            return
        }
        do {
            let data = try ScorecardOCR.parseScorecard(from: image)
            for (i, hole) in data.holes.enumerated() where i < course.holes.count {
                course.holes[i].par = hole.par
                course.holes[i].handicap = hole.handicap
                course.holes[i].yardages.merge(hole.yardages) { _, new in new }
            }
            statusMessage = "OCR imported \(data.holes.count) holes"
        } catch {
            statusMessage = "OCR failed: \(error.localizedDescription)"
        }
    }

    private var apiKey: String? {
        ProcessInfo.processInfo.environment["GOLF_COURSE_API_KEY"]
    }
}

struct ScorecardTableView: View {
    @Binding var course: Course

    var body: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 2) {
                // Header row
                GridRow {
                    Text("Hole").bold().frame(width: 50)
                    Text("Par").bold().frame(width: 40)
                    Text("Hdcp").bold().frame(width: 40)
                    ForEach(course.tees) { tee in
                        Text(tee.name).bold().frame(width: 60)
                    }
                }
                Divider()

                ForEach($course.holes) { $hole in
                    GridRow {
                        Text("\(hole.number)").frame(width: 50)
                        TextField("", value: $hole.par, format: .number)
                            .frame(width: 40)
                            .textFieldStyle(.roundedBorder)
                        TextField("", value: $hole.handicap, format: .number)
                            .frame(width: 40)
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
            .padding()
        }
    }
}
```

**Step 2: Update CourseListView detail to use ScorecardImportView**

Replace the placeholder `Text(course.name)` in CourseListView's detail with `ScorecardImportView(course: course)`.

**Step 3: Verify it compiles**

Note: `MapEditorView` doesn't exist yet. Use a placeholder `Text("Map Editor")` view temporarily or create a stub. Replace with the real implementation in Task 13.

```bash
xcodebuild -scheme CourseData -destination 'platform=macOS' build 2>&1 | tail -3
```

Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add CourseData/Views/ScorecardImportView.swift CourseData/Views/CourseListView.swift
git commit -m "feat: add ScorecardImportView with API/OCR import and editable table"
```

---

### Task 13: MapEditorView — satellite map with pin editing

This is the largest task. It includes the satellite map, pin display, click-to-edit, double-click-to-add, and drag-to-move interactions.

**Files:**
- Create: `CourseData/Views/MapEditorView.swift`
- Create: `CourseData/Views/PinEditorView.swift`

**Step 1: Implement PinEditorView (the popover for editing a pin)**

`CourseData/Views/PinEditorView.swift`:
```swift
import SwiftUI

enum PinType: String, CaseIterable {
    case tee = "Tee"
    case greenFront = "Green (Front)"
    case greenMiddle = "Green (Middle)"
    case greenBack = "Green (Back)"
    case bunkerFront = "Bunker (Front)"
    case bunkerBack = "Bunker (Back)"
    case waterFront = "Water (Front)"
    case waterBack = "Water (Back)"
}

struct EditablePin: Identifiable, Equatable {
    let id: UUID
    var pinType: PinType
    var coordinate: Coordinate
    var teeName: String? // only for tee type
    var featureIndex: Int? // index into hole.features for bunker/water
    var holeNumber: Int

    static func == (lhs: EditablePin, rhs: EditablePin) -> Bool {
        lhs.id == rhs.id
    }
}

struct PinEditorView: View {
    @Binding var pin: EditablePin
    let teeNames: [String]
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hole \(pin.holeNumber)").font(.headline)

            Picker("Type", selection: $pin.pinType) {
                ForEach(PinType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }

            if pin.pinType == .tee {
                Picker("Tee", selection: Binding(
                    get: { pin.teeName ?? "" },
                    set: { pin.teeName = $0 }
                )) {
                    ForEach(teeNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            }

            HStack {
                Text("Lat:")
                TextField("Latitude", value: $pin.coordinate.latitude, format: .number)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Lon:")
                TextField("Longitude", value: $pin.coordinate.longitude, format: .number)
                    .textFieldStyle(.roundedBorder)
            }

            Button("Delete", role: .destructive, action: onDelete)
        }
        .padding()
        .frame(width: 250)
    }
}

extension Coordinate {
    var latitude: Double {
        get { self._latitude }
        set { self = Coordinate(latitude: newValue, longitude: self.longitude) }
    }

    var longitude: Double {
        get { self._longitude }
        set { self = Coordinate(latitude: self.latitude, longitude: newValue) }
    }
}
```

Note: The `Coordinate` extension with mutable latitude/longitude will need adjustment since `Coordinate` uses `let` properties. The implementer should change `Coordinate` to use `var` properties instead of `let`, or create a mutable binding wrapper. The simplest fix is changing `Coordinate.swift` to use `var latitude` and `var longitude`.

**Step 2: Implement MapEditorView**

`CourseData/Views/MapEditorView.swift`:
```swift
import SwiftUI
import MapKit

struct MapEditorView: View {
    @Binding var course: Course
    @EnvironmentObject var store: CourseStore

    @State private var selectedHole: Int = 1
    @State private var pins: [EditablePin] = []
    @State private var selectedPin: EditablePin?
    @State private var showPinEditor = false
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var isDetecting = false

    private let featureDetector = FeatureDetector()

    var body: some View {
        HSplitView {
            // Left sidebar — hole list
            VStack {
                Text("Holes").font(.headline).padding(.top)
                List(1...max(course.holes.count, 1), id: \.self, selection: $selectedHole) { num in
                    HStack {
                        Text("Hole \(num)")
                        Spacer()
                        let hole = course.holes.first(where: { $0.number == num })
                        if let hole {
                            Text("Par \(hole.par)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(width: 150)

            // Main map area
            VStack(spacing: 0) {
                // Toolbar
                HStack {
                    Text("Hole \(selectedHole)")
                        .font(.title3.bold())

                    if let hole = currentHole {
                        let teeCoord = hole.tees.values.first
                        let greenCoord = hole.green?.middle
                        if let tc = teeCoord, let gc = greenCoord {
                            let dist = Int(tc.clLocation.distance(from: gc.clLocation) * 1.09361)
                            Text("\(dist) yds (GPS)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let expectedYards = hole.yardages.values.first {
                                Text("/ \(expectedYards) yds (card)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Spacer()

                    Button("Auto-Detect") {
                        Task { await runDetection() }
                    }
                    .disabled(isDetecting)

                    Button("Save") {
                        applyPinsToCourse()
                        try? store.save(course)
                    }

                    Button("Export JSON") {
                        exportJSON()
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                // Map
                MapReader { proxy in
                    Map(position: $mapPosition) {
                        ForEach(pinsForCurrentHole) { pin in
                            Annotation(pin.pinType.rawValue, coordinate: pin.coordinate.clCoordinate) {
                                pinMarker(for: pin)
                                    .onTapGesture {
                                        selectedPin = pin
                                        showPinEditor = true
                                    }
                            }
                            .annotationTitles(.hidden)
                        }
                    }
                    .mapStyle(.imagery(elevation: .realistic))
                    .onTapGesture(count: 2) { position in
                        if let coord = proxy.convert(position, from: .local) {
                            addPin(at: Coordinate(coord))
                        }
                    }
                }
                .popover(isPresented: $showPinEditor) {
                    if let selected = selectedPin,
                       let index = pins.firstIndex(where: { $0.id == selected.id }) {
                        PinEditorView(
                            pin: $pins[index],
                            teeNames: course.tees.map(\.name),
                            onDelete: {
                                pins.remove(at: index)
                                showPinEditor = false
                                selectedPin = nil
                            }
                        )
                    }
                }
            }
        }
        .onAppear {
            loadPinsFromCourse()
            centerOnCourse()
        }
        .onChange(of: selectedHole) {
            centerOnHole(selectedHole)
        }
    }

    // MARK: - Pin Rendering

    @ViewBuilder
    private func pinMarker(for pin: EditablePin) -> some View {
        Circle()
            .fill(pinColor(for: pin))
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(.white, lineWidth: 2))
    }

    private func pinColor(for pin: EditablePin) -> Color {
        switch pin.pinType {
        case .tee: return .blue
        case .greenFront, .greenMiddle, .greenBack: return .green
        case .bunkerFront, .bunkerBack: return .yellow
        case .waterFront, .waterBack: return .cyan
        }
    }

    // MARK: - Pin Management

    private var currentHole: Hole? {
        course.holes.first(where: { $0.number == selectedHole })
    }

    private var pinsForCurrentHole: [EditablePin] {
        pins.filter { $0.holeNumber == selectedHole }
    }

    private func addPin(at coordinate: Coordinate) {
        let pin = EditablePin(
            id: UUID(),
            pinType: .tee,
            coordinate: coordinate,
            teeName: course.tees.first?.name,
            holeNumber: selectedHole
        )
        pins.append(pin)
        selectedPin = pin
        showPinEditor = true
    }

    // MARK: - Course <-> Pin Conversion

    private func loadPinsFromCourse() {
        pins = []
        for hole in course.holes {
            for (teeName, coord) in hole.tees {
                pins.append(EditablePin(
                    id: UUID(), pinType: .tee, coordinate: coord,
                    teeName: teeName, holeNumber: hole.number
                ))
            }
            if let green = hole.green {
                pins.append(EditablePin(id: UUID(), pinType: .greenFront, coordinate: green.front, holeNumber: hole.number))
                pins.append(EditablePin(id: UUID(), pinType: .greenMiddle, coordinate: green.middle, holeNumber: hole.number))
                pins.append(EditablePin(id: UUID(), pinType: .greenBack, coordinate: green.back, holeNumber: hole.number))
            }
            for (i, feature) in hole.features.enumerated() {
                switch feature.type {
                case .bunker:
                    pins.append(EditablePin(id: UUID(), pinType: .bunkerFront, coordinate: feature.front, featureIndex: i, holeNumber: hole.number))
                    pins.append(EditablePin(id: UUID(), pinType: .bunkerBack, coordinate: feature.back, featureIndex: i, holeNumber: hole.number))
                case .water:
                    pins.append(EditablePin(id: UUID(), pinType: .waterFront, coordinate: feature.front, featureIndex: i, holeNumber: hole.number))
                    pins.append(EditablePin(id: UUID(), pinType: .waterBack, coordinate: feature.back, featureIndex: i, holeNumber: hole.number))
                }
            }
        }
    }

    private func applyPinsToCourse() {
        for i in course.holes.indices {
            let holeNum = course.holes[i].number
            let holePins = pins.filter { $0.holeNumber == holeNum }

            // Tees
            course.holes[i].tees = [:]
            for pin in holePins where pin.pinType == .tee {
                if let name = pin.teeName {
                    course.holes[i].tees[name] = pin.coordinate
                }
            }

            // Green
            let greenFront = holePins.first(where: { $0.pinType == .greenFront })
            let greenMiddle = holePins.first(where: { $0.pinType == .greenMiddle })
            let greenBack = holePins.first(where: { $0.pinType == .greenBack })
            if let f = greenFront, let m = greenMiddle, let b = greenBack {
                course.holes[i].green = Green(front: f.coordinate, middle: m.coordinate, back: b.coordinate)
            }

            // Features (bunkers, water)
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
            course.holes[i].features = features
        }
    }

    // MARK: - Map Navigation

    private func centerOnCourse() {
        let coord = course.location.coordinate
        if coord.latitude != 0 && coord.longitude != 0 {
            mapPosition = .region(MKCoordinateRegion(
                center: coord.clCoordinate,
                latitudinalMeters: 2000,
                longitudinalMeters: 2000
            ))
        }
    }

    private func centerOnHole(_ holeNumber: Int) {
        guard let hole = course.holes.first(where: { $0.number == holeNumber }) else { return }
        // Center on the first tee or green if available
        if let teeCoord = hole.tees.values.first {
            mapPosition = .region(MKCoordinateRegion(
                center: teeCoord.clCoordinate,
                latitudinalMeters: 500,
                longitudinalMeters: 500
            ))
        }
    }

    // MARK: - Auto-Detection

    private func runDetection() async {
        isDetecting = true
        defer { isDetecting = false }

        let region = MKCoordinateRegion(
            center: course.location.coordinate.clCoordinate,
            latitudinalMeters: 2000,
            longitudinalMeters: 2000
        )

        do {
            let detected = try await featureDetector.detect(in: region)
            for feature in detected {
                let pin = EditablePin(
                    id: UUID(),
                    pinType: feature.kind == .green ? .greenMiddle : .tee,
                    coordinate: feature.coordinate,
                    holeNumber: selectedHole
                )
                pins.append(pin)
            }
        } catch {
            print("Detection failed: \(error)")
        }
    }

    // MARK: - Export

    private func exportJSON() {
        applyPinsToCourse()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(course.id).json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(course)
                try data.write(to: url)
            } catch {
                print("Export failed: \(error)")
            }
        }
    }
}
```

**Step 3: Verify it compiles**

```bash
xcodebuild -scheme CourseData -destination 'platform=macOS' build 2>&1 | tail -3
```

Expected: BUILD SUCCEEDED (may need minor fixes — the implementer should resolve any compilation issues with MapKit APIs, Coordinate mutability, etc.)

**Step 4: Commit**

```bash
git add CourseData/Views/MapEditorView.swift CourseData/Views/PinEditorView.swift
git commit -m "feat: add MapEditorView with satellite view, pin editing, and auto-detection"
```

---

### Task 14: Polish and integration

**Files:**
- Modify: `CourseData/Models/Coordinate.swift` — change `let` to `var` if needed for bindings
- Delete: `CourseDataTests/PlaceholderTests.swift`
- Modify: various views for navigation wiring

**Step 1: Fix Coordinate mutability**

Change `Coordinate.swift` to use `var` instead of `let` for latitude/longitude so SwiftUI bindings work. Remove the extension in PinEditorView.swift that tried to add setters.

**Step 2: Wire up full navigation flow**

Ensure CourseListView -> ScorecardImportView -> MapEditorView navigation works end to end. The implementer should verify:
- Clicking a course in the list opens ScorecardImportView
- "Open Map Editor" button navigates to MapEditorView
- Saving in MapEditorView writes the JSON to disk
- Export produces a valid JSON file matching the design schema

**Step 3: Build and run manually**

```bash
xcodebuild -scheme CourseData -destination 'platform=macOS' build
```

Then open the app in the Simulator or run directly to test the full flow.

**Step 4: Run all tests**

```bash
xcodebuild -scheme CourseData -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: All tests pass

**Step 5: Delete placeholder test and commit**

```bash
rm CourseDataTests/PlaceholderTests.swift
git add -A
git commit -m "feat: wire up navigation and fix Coordinate mutability"
```

---

### Task 15: Final commit — CLAUDE.md and .gitignore

**Files:**
- Create: `CLAUDE.md`
- Create: `.gitignore`

**Step 1: Create .gitignore**

```
# Xcode
*.xcodeproj/xcuserdata/
*.xcodeproj/project.xcworkspace/xcuserdata/
DerivedData/
build/

# macOS
.DS_Store

# Course data output (don't track generated course JSON in git)
output/
```

**Step 2: Create CLAUDE.md**

```markdown
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

CourseData — a macOS SwiftUI desktop app for creating golf course GPS data files. Part of the SpotGolf project. Produces JSON files with tee, green, and hazard coordinates for each hole.

## Build & Test

Requires xcodegen (`brew install xcodegen`).

```bash
xcodegen generate
xcodebuild -scheme CourseData -destination 'platform=macOS' build
xcodebuild -scheme CourseData -destination 'platform=macOS' test
```

## Architecture

- macOS 14+ (Sonoma), Swift, SwiftUI, no external packages
- MapKit for satellite map display and course search
- CoreImage for satellite imagery color analysis (green/tee detection)
- Vision framework for scorecard image OCR
- GolfCourseAPI.com (free tier) for structured scorecard data

## Key Data Flow

Course search (MapKit) -> Scorecard import (API/scraping/OCR) -> Feature detection (satellite analysis) -> Manual pin editing (map UI) -> JSON export

## Data Model

One JSON file per course. Holes contain: tees (keyed by name), green (front/middle/back), features (bunker/water with front/back). See `plans/2026-03-02-course-data-design.md` for full schema.

## Environment

Set `GOLF_COURSE_API_KEY` environment variable for GolfCourseAPI.com access.
```

**Step 3: Commit**

```bash
git add CLAUDE.md .gitignore
git commit -m "docs: add CLAUDE.md and .gitignore"
```
