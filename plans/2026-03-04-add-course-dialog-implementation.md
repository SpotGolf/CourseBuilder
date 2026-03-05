# Add Course Dialog Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace `NewCourseSheet` with a tabbed `AddCourseSheet` that supports both GolfCourseAPI search and manual entry for creating new courses.

**Architecture:** A single `AddCourseSheet` SwiftUI view with a `TabView` containing "Search" and "Manual Entry" tabs. Shared Add/Cancel buttons below the tab content. The search tab uses `GolfCourseAPIClient` to search and fetch full course data. Both paths save via `CourseStore` and navigate to `ScorecardImportView`.

**Tech Stack:** Swift, SwiftUI, `@AppStorage` for API key, existing `GolfCourseAPIClient` actor, existing `CourseStore`.

---

### Task 1: Create AddCourseSheet with Manual Entry tab

Replace the existing `NewCourseSheet` in `CourseListView.swift` with the new `AddCourseSheet`. Start with just the Manual Entry tab to preserve existing functionality with the expanded form fields.

**Files:**
- Modify: `CourseBuilder/Views/CourseListView.swift:45-96`

**Step 1: Replace NewCourseSheet with AddCourseSheet**

Replace the entire `NewCourseSheet` struct (lines 58-96) and update the sheet presentation (lines 45-51) in `CourseListView`. The new `AddCourseSheet` has:

- An `enum Tab` with `.search` and `.manualEntry` cases
- `@State` for the selected tab
- Manual entry fields: `clubName`, `name`, `address`, `city`, `state`, `country`
- `@State var holeCount = 18` with a segmented picker (9 or 18)
- `TabView` with two `Tab` labels (Search tab content will be placeholder text for now)
- Shared Cancel and Add buttons below the `TabView`
- Add button validation: on Manual Entry tab, requires `name`, `city`, and `state` non-empty
- `onCreate` callback receiving a `Course`, same pattern as before

```swift
struct AddCourseSheet: View {
    let onCreate: (Course) -> Void

    enum Tab: Hashable {
        case search, manualEntry
    }

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: Tab = .search

    // Manual entry fields
    @State private var clubName = ""
    @State private var name = ""
    @State private var address = ""
    @State private var city = ""
    @State private var state = ""
    @State private var country = ""
    @State private var holeCount = 18

    private var canAddManual: Bool {
        !name.isEmpty && !city.isEmpty && !state.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                Text("Search coming soon")
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag(Tab.search)

                manualEntryTab
                    .tabItem { Label("Manual Entry", systemImage: "square.and.pencil") }
                    .tag(Tab.manualEntry)
            }
            .frame(width: 450, height: 350)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") { addCourse() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedTab == .manualEntry && !canAddManual)
            }
            .padding()
        }
    }

    private var manualEntryTab: some View {
        Form {
            TextField("Club Name", text: $clubName)
            TextField("Course Name", text: $name)
            TextField("Address", text: $address)
            TextField("City", text: $city)
            TextField("State", text: $state)
            TextField("Country", text: $country)
            Picker("Holes", selection: $holeCount) {
                Text("9").tag(9)
                Text("18").tag(18)
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
        .padding()
    }

    private func addCourse() {
        guard selectedTab == .manualEntry else { return }
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
            holes: (1...holeCount).map { Hole(number: $0, par: 4) }
        )
        onCreate(course)
    }
}
```

Also update `CourseListView` to reference `AddCourseSheet` instead of `NewCourseSheet`:

```swift
// Line 45-51: change NewCourseSheet to AddCourseSheet
.sheet(isPresented: $showNewCourse) {
    AddCourseSheet { course in
        try? store.save(course)
        selectedCourse = course
        showNewCourse = false
    }
}
```

**Step 2: Build and verify**

Run: `cd /Users/bpontarelli/dev/SpotGolf/CourseBuilder && xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add CourseBuilder/Views/CourseListView.swift
git commit -m "feat: replace NewCourseSheet with AddCourseSheet with manual entry tab"
```

---

### Task 2: Add Search tab with API search functionality

Implement the Search tab content with search field, results list, and selection.

**Files:**
- Modify: `CourseBuilder/Views/CourseListView.swift` (AddCourseSheet struct)

**Step 1: Add search state and UI**

Add these `@State` properties to `AddCourseSheet`:

```swift
// Search fields
@AppStorage("golfCourseAPIKey") private var apiKey: String = ""
@State private var searchQuery = ""
@State private var searchResults: [GolfCourseAPIClient.CourseSearchResult] = []
@State private var selectedResult: GolfCourseAPIClient.CourseSearchResult?
@State private var isSearching = false
@State private var searchError = ""
```

Replace the placeholder `Text("Search coming soon")` with the search tab view:

```swift
private var searchTab: some View {
    VStack(spacing: 12) {
        HStack {
            TextField("Search courses...", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit { searchCourses() }
            Button("Search") { searchCourses() }
                .disabled(searchQuery.isEmpty || isSearching)
        }
        .padding(.horizontal)
        .padding(.top, 8)

        if apiKey.isEmpty {
            Spacer()
            Text("Configure your GolfCourseAPI key in Settings (⌘,)")
                .foregroundStyle(.secondary)
                .font(.callout)
            Spacer()
        } else if isSearching {
            Spacer()
            ProgressView("Searching...")
            Spacer()
        } else if !searchError.isEmpty {
            Spacer()
            Text(searchError)
                .foregroundStyle(.red)
                .font(.callout)
            Spacer()
        } else if searchResults.isEmpty && !searchQuery.isEmpty {
            Spacer()
            Text("No courses found")
                .foregroundStyle(.secondary)
            Spacer()
        } else {
            List(searchResults, id: \.id, selection: $selectedResult) { result in
                VStack(alignment: .leading) {
                    Text(result.courseName)
                        .font(.headline)
                    Text("\(result.location.city), \(result.location.state)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(result)
            }
        }
    }
}
```

Note: `CourseSearchResult` needs to conform to `Hashable` for List selection. Add this conformance.

**Step 2: Make CourseSearchResult Hashable**

In `CourseBuilder/Services/GolfCourseAPIClient.swift`, update `CourseSearchResult` (line 25):

```swift
// Change from:
struct CourseSearchResult: Codable {
// To:
struct CourseSearchResult: Codable, Hashable {
```

Also make `APILocation` conform to `Hashable` (line 41):

```swift
// Change from:
struct APILocation: Codable {
// To:
struct APILocation: Codable, Hashable {
```

**Step 3: Add search function**

Add this method to `AddCourseSheet`:

```swift
private func searchCourses() {
    guard !apiKey.isEmpty, !searchQuery.isEmpty else { return }
    isSearching = true
    searchError = ""
    searchResults = []
    selectedResult = nil
    Task {
        do {
            let client = GolfCourseAPIClient(apiKey: apiKey)
            let response = try await client.search(query: searchQuery)
            searchResults = response.courses
        } catch {
            searchError = "Search failed: \(error.localizedDescription)"
        }
        isSearching = false
    }
}
```

**Step 4: Update Add button for search tab**

Update `canAdd` logic and `addCourse()` to handle both tabs:

```swift
private var canAdd: Bool {
    switch selectedTab {
    case .search:
        return selectedResult != nil
    case .manualEntry:
        return !name.isEmpty && !city.isEmpty && !state.isEmpty
    }
}
```

Update the Add button disabled state:
```swift
Button("Add") { addCourse() }
    .keyboardShortcut(.defaultAction)
    .disabled(!canAdd)
```

Update `addCourse()`:

```swift
private func addCourse() {
    switch selectedTab {
    case .search:
        guard let result = selectedResult else { return }
        fetchAndAddCourse(result)
    case .manualEntry:
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
            holes: (1...holeCount).map { Hole(number: $0, par: 4) }
        )
        onCreate(course)
    }
}
```

**Step 5: Add fetch-and-add function**

Add state for fetch errors and the fetch function:

```swift
@State private var isFetching = false
@State private var showFetchError = false
@State private var fetchErrorMessage = ""
```

```swift
private func fetchAndAddCourse(_ result: GolfCourseAPIClient.CourseSearchResult) {
    isFetching = true
    Task {
        do {
            let client = GolfCourseAPIClient(apiKey: apiKey)
            let detail = try await client.fetchCourse(id: result.id)
            let course = GolfCourseAPIClient.convertToCourse(detail: detail)
            onCreate(course)
        } catch {
            fetchErrorMessage = "Failed to fetch course: \(error.localizedDescription)"
            showFetchError = true
        }
        isFetching = false
    }
}
```

Add an alert for fetch errors on the `VStack`:

```swift
.alert("Error", isPresented: $showFetchError) {
    Button("OK", role: .cancel) {}
} message: {
    Text(fetchErrorMessage)
}
```

Also disable the Add button while fetching:

```swift
Button("Add") { addCourse() }
    .keyboardShortcut(.defaultAction)
    .disabled(!canAdd || isFetching)
```

And show a progress indicator when fetching:

```swift
HStack {
    Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
    Spacer()
    if isFetching {
        ProgressView()
            .scaleEffect(0.7)
    }
    Button("Add") { addCourse() }
        .keyboardShortcut(.defaultAction)
        .disabled(!canAdd || isFetching)
}
.padding()
```

**Step 6: Build and verify**

Run: `cd /Users/bpontarelli/dev/SpotGolf/CourseBuilder && xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 7: Run existing tests**

Run: `cd /Users/bpontarelli/dev/SpotGolf/CourseBuilder && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | tail -10`
Expected: All tests pass

**Step 8: Commit**

```bash
git add CourseBuilder/Views/CourseListView.swift CourseBuilder/Services/GolfCourseAPIClient.swift
git commit -m "feat: add search tab with GolfCourseAPI search and full course import"
```

---

### Task 3: Clean up and final verification

**Files:**
- Review: `CourseBuilder/Views/CourseListView.swift`

**Step 1: Remove dead code**

Verify that `NewCourseSheet` has been fully removed (no leftover references). Search for `NewCourseSheet` across the codebase.

**Step 2: Full build and test**

Run: `cd /Users/bpontarelli/dev/SpotGolf/CourseBuilder && xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

Run: `cd /Users/bpontarelli/dev/SpotGolf/CourseBuilder && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | tail -10`
Expected: All tests pass

**Step 3: Commit if any cleanup was needed**

```bash
git add -u
git commit -m "chore: clean up dead code from NewCourseSheet removal"
```
