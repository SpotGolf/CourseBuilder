# Add Course Dialog Design

**Date:** 2026-03-04

## Overview

Replace the current `NewCourseSheet` (name, city, state) with an `AddCourseSheet` that has three tabs: "Search" (GolfCourseAPI lookup), "Manual Entry" (form input), and "Import" (load an existing CourseBuilder JSON file). Both Search and Manual Entry tabs share Add and Cancel buttons at the bottom; the Import tab has a file chooser.

## Dialog Layout

```
┌─────────────────────────────────┐
│  ┌────────┐ ┌──────────┐ ┌────────┐ │
│  │ Search │ │  Manual  │ │ Import │ │
│  └────────┘ └──────────┘ └────────┘ │
│ ┌─────────────────────────────┐ │
│ │                             │ │
│ │   Tab content area          │ │
│ │   (search results, form,   │ │
│ │    or file chooser)        │ │
│ │                             │ │
│ └─────────────────────────────┘ │
│                                 │
│            [Cancel]  [Add]      │
└─────────────────────────────────┘
```

SwiftUI `TabView` with shared button bar below.

## Search Tab

- Horizontal row: text field + "Search" button
- Below: scrollable `List` of search results grouped by club name
  - Each club group is an expandable row showing the club name and location
  - Clicking a club group expands/collapses it and selects all its courses
  - Individual courses listed under each club with course name and hole count
  - Checkbox selection allows adding multiple courses at once
- Loading: `ProgressView` spinner during search
- Errors: inline text if search fails or no API key configured
  - No API key: "Configure API key in Settings (Cmd+,)"
  - Network error: error message below results
  - Empty results: "No courses found"
- "Add" button enabled only when at least one result is selected

## Manual Entry Tab

- Form fields: Club Name, Course Name, Address, City, State, Country
- Hole count: segmented picker for 9, 18, or 27 (default 18)
- "Add" button enabled when Course Name, City, and State are non-empty

## Import Tab

- "Choose File..." button opens a file picker filtered to JSON files
- Displays the selected file path after choosing
- Loads and imports an existing CourseBuilder JSON file directly into the course store

## Data Flow

### Search Tab -> Add

1. Fetch full course detail via `GolfCourseAPIClient.fetchCourse(id:)` for each selected result
2. Convert to `Course` via `GolfCourseAPIClient.convertToCourse(detail:)`
3. `CourseStore.save(course)` for each
4. Set as selected course, dismiss sheet
5. Navigate to `ScorecardView`

### Manual Entry Tab -> Add

1. Create `Course` with user-provided fields (club name, name, address, city, state, country)
2. Pre-populate with 9, 18, or 27 default holes (par 4, handicap 0)
3. Coordinates set to (0, 0)
4. Save, select, dismiss, navigate to `ScorecardView`

### Import Tab -> Choose File

1. User selects a CourseBuilder JSON file via NSOpenPanel
2. File is decoded into a `Course` object
3. `CourseStore.save(course)`
4. Set as selected course, dismiss sheet

## Error Handling

- Fetch failure on Add (search tab): show alert, don't dismiss dialog
- No API key: show inline message with Settings shortcut hint
- Network/search errors: inline text below search field

## Files Changed

- `CourseBuilder/Views/CourseListView.swift` -- Replace `NewCourseSheet` with `AddCourseSheet`, update sheet presentation
- No new files needed; the new sheet replaces the existing one in the same file
