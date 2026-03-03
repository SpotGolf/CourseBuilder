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
        guard url.startAccessingSecurityScopedResource() else {
            statusMessage = "Could not access file"
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let image = NSImage(contentsOf: url) else {
            statusMessage = "Could not load image"
            return
        }
        do {
            let importer = ScorecardImporter(apiKey: nil)
            let imported = try importer.importFromImage(
                image,
                name: course.name,
                city: course.location.city,
                state: course.location.state
            )
            course.tees = imported.tees
            course.holes = imported.holes
            statusMessage = "OCR imported \(imported.holes.count) holes"
        } catch {
            statusMessage = "OCR failed: \(error.localizedDescription)"
        }
    }

    private var apiKey: String? {
        ProcessInfo.processInfo.environment["GOLF_COURSE_API_KEY"]
    }
}

// MARK: - ScorecardTableView

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
