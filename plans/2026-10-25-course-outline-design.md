# Course Outline

## Problem

The OSM wiki says the `leisure=golf_course` element should be the area of the whole course. Many courses have it on the wrong element:

| Case                | Example                                                                                                   |
|---------------------|-----------------------------------------------------------------------------------------------------------|
| A node              | A point dropped on the course with `leisure=golf_course` and the course's name.                           |
| A way or relation   | Bear Dance: way `w237236029` is the clubhouse building with `building=yes`, `golf=clubhouse`, and `leisure=golf_course`, plus the course's name, phone, website, and hours. |

The app should let the user fix this. It builds an outline around the course and publishes it as a new way with the course tags.

## Decisions

| Topic              | Decision                                                                                                                                                                         |
|--------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| When it is offered | The import finds a `leisure=golf_course` element that is not a usable course outline, and no usable outline exists. Courses imported before this change are checked once when they are opened. |
| Node               | Converted. The new way gets all of the node's tags, and the node is deleted (`if-unused`, so a node that is part of another way stays).                                          |
| Way or relation    | Kept. The new way gets the tags the user picks, and they are removed from the old element. The old element can also get `golf=clubhouse`.                                        |
| Outline shape      | Starts as a padded convex hull around every course feature. The user edits its points on the map like any polygon before publishing.                                           |
| Storage            | In the OSM baseline, like pending multipolygons. The course file does not change.                                                                                               |
| Tags               | The user picks them from a list of the old element's tags, with course tags checked to start.                                                                                   |
| Publish            | One more change in the normal publish: create the outline way, then modify or delete the old element. Same changeset as everything else.                                        |

## Finding the wrong element

The Overpass query adds `node["leisure"="golf_course"]`. The parser already skips elements that are not a usable outline (`isCourseBoundary`, `minimumBoundarySpanMeters`). Those skipped elements are now returned too.

| Element                                                         | Result                                         |
|-----------------------------------------------------------------|------------------------------------------------|
| Way or relation that passes `isCourseBoundary` and the span test | The course outline. Nothing is offered.        |
| Node with `leisure=golf_course`                                 | Wrong element, kind `node`.                    |
| Way or relation that fails `isCourseBoundary` or the span test  | Wrong element, kind `way` or `relation`.       |

When the result has a usable outline, wrong elements are ignored.

`ParsedResult` gets every wrong element. The parser does not know the course location, so it keeps them all:

```swift
/// The `leisure=golf_course` elements that are not a usable course outline. Empty when the
/// result has a usable outline.
var misplacedCourseElements: [MisplacedCourseElement] = []
```

```swift
struct MisplacedCourseElement: Codable, Hashable {
    /// Such as `n123`, `w123`, or `r123`.
    var osmID: String
    var version: Int?
    var tags: [String: String]
    /// The middle of the element's bounding box, used to pick the one nearest the course.
    var center: Coordinate
}
```

When the result is saved, `CourseOutline.nearest(_:to:)` picks the element whose `center` is nearest the course location. Import saves it in the baseline (`misplacedCourseElement`). A later import that finds a usable outline clears it.

### Courses imported before this change

"Import OSM" is off once a course has features, so these courses would never be checked. When such a course is opened, the editor asks Overpass for its `leisure=golf_course` elements:

| Step  | Detail                                                                                                                                       |
|-------|----------------------------------------------------------------------------------------------------------------------------------------------|
| When  | The course is opened, the baseline has entries, and `checkedCourseElement` is false. Runs after the baseline's missing tags are filled in. |
| Query | `nwr["leisure"="golf_course"]` in the bounding box of every course feature, padded by 25%, with `out geom meta`.                            |
| Parse | The same parser, so a usable outline in the area means nothing is misplaced.                                                                |
| Save  | The nearest misplaced element, if any, and `checkedCourseElement = true`. A failed query saves nothing, so it is tried again on the next open. |

Import also sets `checkedCourseElement = true`.

## Flow

```
Import OSM, or opening a course not yet checked
   │ misplaced elements found, no usable outline
   ▼
nearest one saved as baseline.misplacedCourseElement
   │
   ▼
"Fix Course Outline…" in the map editor toolbar
   │
   ▼
Sheet: what is wrong, tag list with checkboxes, "Tag old element golf=clubhouse"
   │ Create Outline
   ▼
Padded hull built → baseline.pendingCourseOutline saved → outline shown on the map, selected for editing
   │ user moves, adds, or removes points
   ▼
Publish to OSM: "Course outline" listed with the other changes
   │
   ▼
osmChange: create outline way + nodes; modify old way/relation, or delete old node
   │ success
   ▼
pendingCourseOutline and misplacedCourseElement removed from the baseline
```

## Outline shape

`CourseOutline.hull(for course: Course, marginMeters: Double = 30) -> [Coordinate]`

1. Take every point of every feature and centerline, except water. A lake next to the course can be far larger than it (same rule as `grownBoundingBox`).
2. Replace each point with 8 points on a circle of `marginMeters` around it.
3. Take the convex hull (monotone chain). The result is a closed outline about 30 m outside the outermost features, with rounded corners.

Returns an empty list when the course has fewer than 3 points.

## Tags

The sheet lists the old element's tags, sorted by key. Each has a checkbox: checked tags go to the new way.

| Element kind      | Starts checked                                                                                                     | Can uncheck |
|-------------------|--------------------------------------------------------------------------------------------------------------------|-------------|
| Node              | All tags.                                                                                                          | No. The node is deleted, so every tag moves. |
| Way or relation   | `leisure`, `name`, `name:*`, `alt_name`, `website`, `phone`, `email`, `operator`, `opening_hours`, `payment:*`, `access`, `golf:par`, `holes`, `par`. | Yes, except `leisure`. |

Below the list, for a way or relation only: "Tag old element golf=clubhouse". Shown when the old element's `golf` tag is not `clubhouse`. Checked to start when it has a `building` tag.

For Bear Dance the sheet starts with these checked: `access`, `leisure`, `name`, `opening_hours`, `operator`, `payment:cash`, `payment:credit_cards`, `payment:debit_cards`, `phone`, `website`. The clubhouse keeps `building`, `building:levels`, `golf=clubhouse`, `addr:*`, `check_date`, `internet_access*`, and `wheelchair`.

## Baseline

```swift
struct PendingCourseOutline: Codable, Equatable {
    /// The outline's points, open (the first point is not repeated).
    var points: [[Double]]
    /// The tags the new way gets.
    var tags: [String: String]
    /// Whether the old way or relation gets `golf=clubhouse`.
    var tagsOldElementClubhouse: Bool
}
```

`OSMBaseline` gets `misplacedCourseElement: MisplacedCourseElement?`, `pendingCourseOutline: PendingCourseOutline?`, and `checkedCourseElement: Bool` (false by default). All three are decoded with `decodeIfPresent`, so older baselines still load.

## Map editor

| Part      | Behavior                                                                                                                                                                      |
|-----------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Toolbar   | "Fix Course Outline…" next to "Publish to OSM". Shown when the baseline has a misplaced element and no pending outline.                                                          |
| Map       | The pending outline is drawn as a dashed white line with no fill, under every feature. Clicking its line selects it. Clicking inside it does not, so features stay clickable. |
| Editing   | Same vertex tools as features: drag, add on an edge, delete. Uses the existing editor code through a reserved feature ID (`CourseOutline.featureID = -1`) that is never written to the course. Each edit saves the baseline. Undo works the same way. |
| Inspector | For the selected outline: point count, the tags it will get, "Edit Tags…" (reopens the sheet), and "Cancel Course Outline" (removes the pending outline).                       |

## Publish

`OSMChangeDetector` adds one change, action `courseOutline`, when the baseline has a pending outline and a misplaced element. It sorts after `multipolygon` and before `create`. The publish dialog shows it as "Course outline" with the old element's ID.

`OSMAPIClient.fetchElements` fetches the old element: `GET /node/{id}`, `/way/{id}`, or `/relation/{id}`. The conflict check compares its version to `misplacedCourseElement.version`.

`OSMChangeBuilder` writes:

| Section   | Content                                                                                                                                         |
|-----------|-------------------------------------------------------------------------------------------------------------------------------------------------|
| `create`  | One new node per outline point, and a closed way with the pending tags.                                                                          |
| `modify`  | Way or relation: the old element with the moved tags removed, plus `golf=clubhouse` when chosen. Its nodes or members do not change.             |
| `delete`  | Node: the old node, inside the existing `if-unused` block.                                                                                       |

After a successful upload, `apply` removes `pendingCourseOutline` and `misplacedCourseElement` from the baseline. The outline is not kept as a baseline entry, since it is not a course feature. The next import finds it as the course outline.

## New code

| File                                       | Contents                                                                                       |
|--------------------------------------------|------------------------------------------------------------------------------------------------|
| `Services/CourseOutline.swift`             | `MisplacedCourseElement`, `PendingCourseOutline`, `hull(for:marginMeters:)`, default tag rule.  |
| `Views/CourseOutlineSheet.swift`           | The tag list sheet.                                                                             |
| Changes                                    | `OverpassAPIClient` (query, parser), `OSMBaseline`, `OSMChangeDetector`, `OSMAPIClient`, `OSMChangeBuilder`, `MapEditorView`, `MapOverlays`, `PublishToOSMSheet`. |

## Tests

| Area                | Test                                                                                                       |
|---------------------|------------------------------------------------------------------------------------------------------------|
| Parser              | Node with `leisure=golf_course` → misplaced, kind node.                                                     |
| Parser              | Clubhouse way like Bear Dance → misplaced, kind way. Usable outline present → no misplaced element.         |
| Nearest             | Of several misplaced elements, the one whose center is nearest the course location is picked.               |
| Hull                | Contains every non-water point, stays about `marginMeters` outside, is convex.                              |
| Tag rule            | Bear Dance tags → the checked list above. Node → every tag.                                                 |
| Detector            | Pending outline + misplaced element → one `courseOutline` change.                                           |
| Builder, node       | Creates nodes and a closed way with all tags; deletes the node.                                             |
| Builder, way        | Creates the way with the picked tags; modifies the old way with them removed and `golf=clubhouse` added.    |
| Conflict            | Old element version changed → conflict, nothing sent.                                                       |
| Apply               | Removes the pending outline and misplaced element.                                                          |
| Baseline            | Old baseline without the new fields still loads. The new fields survive saving and loading.                 |

## Not in this version

- Courses with no `leisure=golf_course` element at all.
- Reshaping an existing usable course outline.
- Choosing between several misplaced elements. The nearest one is used.
