# Sub-Courses Design

**Date:** 2026-03-04

## Overview

Restructure the Course data model so that every course contains sub-courses. A standard 18-hole course has two sub-courses ("Front" and "Back"). Facilities with multiple 9-hole layouts (e.g. Eldorado, Vista, Conquistador) have three or more sub-courses that players combine into 18-hole rounds.

## Data Model

### Course

```swift
struct Course: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var clubName: String
    var golfCourseAPIIds: [Int]       // multiple API results may contribute
    var location: CourseLocation
    var tees: [TeeDefinition]         // name + color only
    var subCourses: [SubCourse]       // always populated, min 1
}
```

- `golfCourseAPIId: Int?` becomes `golfCourseAPIIds: [Int]` since a course may be built from multiple API results.
- `holes: [Hole]` is removed from Course — holes live inside SubCourse.

### SubCourse

```swift
struct SubCourse: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String                  // "Front", "Back", "Eldorado", "Vista"
    var holes: [Hole]                 // numbered 1-N within each sub-course
    var tees: [String: SubCourseTee]  // keyed by tee name, matches TeeDefinition.name
}
```

### SubCourseTee

```swift
struct SubCourseTee: Codable, Equatable, Hashable {
    var male: TeeInformation?
    var female: TeeInformation?
}
```

### TeeDefinition (revised)

```swift
struct TeeDefinition: Codable, Equatable, Hashable, Identifiable {
    var id: String { name }
    let name: String
    let color: String
    // ratings removed — they live on SubCourse.tees
}
```

### TeeInformation (revised)

```swift
struct TeeInformation: Codable, Equatable, Hashable {
    var rating: Double?               // was courseRating
    var slope: Int?                    // was slopeRating
    var totalYards: Int?
    var parTotal: Int?
    // frontCourseRating, frontSlopeRating, backCourseRating, backSlopeRating removed
    // — sub-course structure handles front/back splits
}
```

### Hole, Green, Feature, Coordinate

Unchanged. Hole numbers are always 1-N within each sub-course.

## Import Workflow

### Single API result selected

A single GolfCourseAPI result (e.g. "The Broadlands Golf Course") produces a course with two sub-courses:

1. Split the API's 18 holes: holes 1-9 → "Front" sub-course (renumbered 1-9), holes 10-18 → "Back" sub-course (renumbered 1-9).
2. Map `frontCourseRating`/`frontSlopeRating` from the API to the "Front" sub-course's tee ratings.
3. Map `backCourseRating`/`backSlopeRating` to the "Back" sub-course's tee ratings.
4. `golfCourseAPIIds` contains the single API ID.

### Multiple API results selected (multi-sub-course facility)

When multiple results are selected (e.g. "Eldorado/Vista" and "Vista/Conquistador"):

1. For each selected result, split the course name by "/" to get the ordered sub-course names.
   - "Eldorado/Vista" → `["Eldorado", "Vista"]`
   - "Vista/Conquistador" → `["Vista", "Conquistador"]`
2. The first sub-course name gets holes 1-9 from that API result (renumbered 1-9), with front tee ratings.
3. The second sub-course name gets holes 10-18 (renumbered 1-9), with back tee ratings.
4. Deduplicate: if a sub-course name was already extracted from a previous result, skip it.
5. All API IDs go into `golfCourseAPIIds`.
6. If name splitting doesn't produce clean results (no "/" separator), present a dialog letting the user name each sub-course and assign hole ranges.

### Search tab changes

The search results list in AddCourseSheet becomes multi-select to support selecting multiple API results for a single facility.

## JSON Output Example

```json
{
  "id": "A5F3B2C1-1234-4567-89AB-CDEF01234567",
  "name": "Champions Course",
  "clubName": "Omni La Costa Resort",
  "golfCourseAPIIds": [12345, 12346],
  "location": {
    "address": "2100 Costa Del Mar Rd",
    "city": "Carlsbad",
    "state": "CA",
    "country": "US",
    "coordinate": { "latitude": 33.09, "longitude": -117.28 }
  },
  "tees": [
    { "name": "Blue", "color": "#0000FF" },
    { "name": "White", "color": "#FFFFFF" }
  ],
  "subCourses": [
    {
      "id": "B1234567-...",
      "name": "Eldorado",
      "tees": {
        "Blue": {
          "male": { "rating": 36.2, "slope": 134, "totalYards": 3450, "parTotal": 36 }
        },
        "White": {
          "male": { "rating": 34.8, "slope": 128, "totalYards": 3200, "parTotal": 36 }
        }
      },
      "holes": [
        {
          "number": 1,
          "par": 4,
          "maleHandicap": 5,
          "femaleHandicap": 7,
          "yardages": { "Blue": 410, "White": 385 },
          "tees": {
            "Blue": { "latitude": 33.091, "longitude": -117.281 }
          },
          "green": {
            "front": { "latitude": 33.090, "longitude": -117.280 },
            "middle": { "latitude": 33.0899, "longitude": -117.2799 },
            "back": { "latitude": 33.0898, "longitude": -117.2798 }
          },
          "features": []
        }
      ]
    },
    {
      "id": "C2345678-...",
      "name": "Vista",
      "tees": {
        "Blue": {
          "male": { "rating": 35.9, "slope": 131, "totalYards": 3380, "parTotal": 36 }
        }
      },
      "holes": []
    }
  ]
}
```

## Scope of Changes

- `Course.swift` — restructure Course, add SubCourse, SubCourseTee; revise TeeDefinition, TeeInformation
- `Hole.swift` — unchanged
- `GolfCourseAPIClient.swift` — update `convertToCourse` to produce sub-courses; handle multi-result merging
- `CourseListView.swift` / `AddCourseSheet` — multi-select search results
- `ScorecardView.swift` — update table to show sub-courses
- `MapEditorView.swift` — navigate by sub-course + hole
- `CourseStore.swift` — no structural changes (still one JSON file per course)
- All existing tests — update for new model structure
- Delete existing stored course JSON files (not backward compatible)
