# Editable Course Info Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make course name, club name, location, tee definitions, and sub-course names editable inline in ScorecardView.

**Architecture:** Replace static Text views with TextFields bound to the course model. Add a tee definitions editing section with add/remove. Replace sub-course name headers with TextFields. All changes are in ScorecardView.swift — the data model already supports mutation.

**Tech Stack:** Swift, SwiftUI, macOS 14+

---

### Task 1: Make course info fields editable in the header

**Files:**
- Modify: `CourseBuilder/Views/ScorecardView.swift`

**Step 1: Replace the header with editable fields**

Replace lines 14-25 (the header HStack) with a new header section. The current header is:

```swift
// Header
HStack {
    Text(course.name)
        .font(.title2.bold())
    Spacer()
    Button("Import Image...") { showImagePicker = true }
    Button("Open Map Editor") {
        openWindow(id: "map-editor", value: course.id)
    }
    .disabled(course.subCourses.isEmpty)
}
.padding()
```

Replace with:

```swift
// Header
VStack(alignment: .leading, spacing: 12) {
    HStack {
        Spacer()
        Button("Import Image...") { showImagePicker = true }
        Button("Open Map Editor") {
            openWindow(id: "map-editor", value: course.id)
        }
        .disabled(course.subCourses.isEmpty)
    }

    HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
            Text("Course Name").font(.caption).foregroundStyle(.secondary)
            TextField("Course Name", text: $course.name)
                .textFieldStyle(.roundedBorder)
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Club Name").font(.caption).foregroundStyle(.secondary)
            TextField("Club Name", text: $course.clubName)
                .textFieldStyle(.roundedBorder)
        }
    }

    VStack(alignment: .leading, spacing: 4) {
        Text("Address").font(.caption).foregroundStyle(.secondary)
        TextField("Address", text: $course.location.address)
            .textFieldStyle(.roundedBorder)
    }

    HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
            Text("City").font(.caption).foregroundStyle(.secondary)
            TextField("City", text: $course.location.city)
                .textFieldStyle(.roundedBorder)
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("State").font(.caption).foregroundStyle(.secondary)
            TextField("State", text: $course.location.state)
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: 100)
        VStack(alignment: .leading, spacing: 4) {
            Text("Country").font(.caption).foregroundStyle(.secondary)
            TextField("Country", text: $course.location.country)
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: 100)
    }
}
.padding()
```

**Step 2: Build and verify**

Run: `cd /Users/bpontarelli/dev/SpotGolf/CourseBuilder && xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' build 2>&1 | grep -E '(error:|BUILD)' | head -20`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add CourseBuilder/Views/ScorecardView.swift
git commit -m "feat: make course name, club name, and location editable inline"
```

---

### Task 2: Add tee definitions editing section

**Files:**
- Modify: `CourseBuilder/Views/ScorecardView.swift`

**Step 1: Add tee editing section below the location fields**

Inside the header VStack (after the City/State/Country HStack, before the closing `}.padding()`), add:

```swift
// Tee definitions
VStack(alignment: .leading, spacing: 4) {
    HStack {
        Text("Tees").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button {
            course.tees.append(TeeDefinition(name: "", color: "#000000"))
        } label: {
            Image(systemName: "plus.circle")
        }
        .buttonStyle(.borderless)
    }

    ForEach(course.tees.indices, id: \.self) { index in
        HStack(spacing: 8) {
            TextField("Tee Name", text: $course.tees[index].name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 150)
            ColorPicker(
                "",
                selection: Binding(
                    get: { Color(hex: course.tees[index].color) ?? .black },
                    set: { course.tees[index] = TeeDefinition(name: course.tees[index].name, color: $0.hexString) }
                ),
                supportsOpacity: false
            )
            .labelsHidden()
            Button {
                course.tees.remove(at: index)
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
    }
}
```

**Step 2: Add Color extension helpers**

The `TeeDefinition.color` is stored as a hex string (e.g. "#FF0000"). We need helpers to convert between `Color` and hex. Add at the bottom of `ScorecardView.swift`:

```swift
// MARK: - Color Hex Helpers

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.hasPrefix("#") ? String(hexSanitized.dropFirst()) : hexSanitized
        guard hexSanitized.count == 6,
              let rgb = UInt64(hexSanitized, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }

    var hexString: String {
        guard let components = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(components.redComponent * 255)
        let g = Int(components.greenComponent * 255)
        let b = Int(components.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
```

Note: `TeeDefinition` has `let name` and `let color`. These need to be changed to `var` to support editing. Update `CourseBuilder/Models/Course.swift` line 36-37:

```swift
// Change from:
let name: String
let color: String
// To:
var name: String
var color: String
```

**Step 3: Build and verify**

Run: `cd /Users/bpontarelli/dev/SpotGolf/CourseBuilder && xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' build 2>&1 | grep -E '(error:|BUILD)' | head -20`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add CourseBuilder/Views/ScorecardView.swift CourseBuilder/Models/Course.swift
git commit -m "feat: add inline tee definitions editing with color picker"
```

---

### Task 3: Make sub-course names editable

**Files:**
- Modify: `CourseBuilder/Views/ScorecardView.swift`

**Step 1: Replace static sub-course name with TextField**

In `ScorecardTableView`, find this line (currently around line 104):

```swift
Text(subCourse.name)
    .font(.headline)
    .padding(.horizontal)
```

Replace with:

```swift
TextField("Sub-course Name", text: $subCourse.name)
    .font(.headline)
    .textFieldStyle(.plain)
    .padding(.horizontal)
```

**Step 2: Build and run tests**

Run: `cd /Users/bpontarelli/dev/SpotGolf/CourseBuilder && xcodegen generate && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' build 2>&1 | grep -E '(error:|BUILD)' | head -20`
Expected: BUILD SUCCEEDED

Run: `cd /Users/bpontarelli/dev/SpotGolf/CourseBuilder && xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test 2>&1 | grep -E '(Executed|FAIL|BUILD)' | tail -5`
Expected: All tests pass

**Step 3: Commit**

```bash
git add CourseBuilder/Views/ScorecardView.swift
git commit -m "feat: make sub-course names editable inline"
```
