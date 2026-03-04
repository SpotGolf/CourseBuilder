# Add Course Dialog Design

**Date:** 2026-03-04

## Overview

Replace the current `NewCourseSheet` (name, city, state) with an `AddCourseSheet` that has two tabs: "Search" (GolfCourseAPI lookup) and "Manual Entry" (form input). Both tabs share Add and Cancel buttons at the bottom.

## Dialog Layout

```
┌─────────────────────────────────┐
│  ┌──────────┐ ┌──────────────┐  │
│  │  Search   │ │ Manual Entry │  │
│  └──────────┘ └──────────────┘  │
│ ┌─────────────────────────────┐ │
│ │                             │ │
│ │   Tab content area          │ │
│ │   (search results or form)  │ │
│ │                             │ │
│ └─────────────────────────────┘ │
│                                 │
│            [Cancel]  [Add]      │
└─────────────────────────────────┘
```

SwiftUI `TabView` with shared button bar below.

## Search Tab

- Horizontal row: text field + "Search" button
- Below: scrollable `List` of search results
  - Each row: course name (primary), city/state (secondary)
  - Single selection (clicking highlights)
- Loading: `ProgressView` spinner during search
- Errors: inline text if search fails or no API key configured
  - No API key: "Configure API key in Settings (Cmd+,)"
  - Network error: error message below results
  - Empty results: "No courses found"
- "Add" button enabled only when a result is selected

## Manual Entry Tab

- Form fields: Club Name, Course Name, Address, City, State, Country
- Hole count: segmented picker for 9 or 18 (default 18)
- "Add" button enabled when Course Name, City, and State are non-empty

## Data Flow

### Search Tab → Add

1. Fetch full course detail via `GolfCourseAPIClient.fetchCourse(id:)`
2. Convert to `Course` via `GolfCourseAPIClient.convertToCourse(detail:)`
3. `CourseStore.save(course)`
4. Set as selected course, dismiss sheet
5. Navigate to `ScorecardImportView`

### Manual Entry Tab → Add

1. Create `Course` with user-provided fields (club name, name, address, city, state, country)
2. Pre-populate with 9 or 18 default holes (par 4, handicap 0)
3. Coordinates set to (0, 0)
4. Save, select, dismiss, navigate to `ScorecardImportView`

## Error Handling

- Fetch failure on Add (search tab): show alert, don't dismiss dialog
- No API key: show inline message with Settings shortcut hint
- Network/search errors: inline text below search field

## Files Changed

- `CourseBuilder/Views/CourseListView.swift` — Replace `NewCourseSheet` with `AddCourseSheet`, update sheet presentation
- No new files needed; the new sheet replaces the existing one in the same file
