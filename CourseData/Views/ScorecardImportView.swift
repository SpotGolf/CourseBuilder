import SwiftUI
import UniformTypeIdentifiers

struct ScorecardImportView: View {
    @EnvironmentObject var store: CourseStore
    @State var course: Course
    @State private var searchQuery = ""
    @State private var isImporting = false
    @State private var statusMessage = ""
    @State private var showImagePicker = false
    @State private var showAPIKeyAlert = false
    @Environment(\.openWindow) private var openWindow
    @State private var searchResults: [GolfCourseAPIClient.CourseSearchResult] = []
    @AppStorage("golfCourseAPIKey") private var apiKey: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(course.name)
                    .font(.title2.bold())
                Spacer()
                Button("Open Map Editor") {
                    openWindow(id: "map-editor", value: course.id)
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

            if !searchResults.isEmpty {
                List(searchResults, id: \.id) { result in
                    Button {
                        selectSearchResult(result)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(result.courseName)
                                .font(.headline)
                            Text("\(result.clubName) — \(result.location.city), \(result.location.state)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxHeight: 150)
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
        .alert("API Key Required", isPresented: $showAPIKeyAlert) {
            SettingsLink {
                Text("Open Settings")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Please add your GolfCourseAPI key in Settings (⌘,) before searching.")
        }
        .onAppear {
            if let latest = store.courses.first(where: { $0.id == course.id }) {
                course = latest
            }
        }
    }

    private func importFromAPI() {
        guard !apiKey.isEmpty else {
            showAPIKeyAlert = true
            return
        }
        isImporting = true
        statusMessage = "Searching..."
        searchResults = []
        Task {
            do {
                let client = GolfCourseAPIClient(apiKey: apiKey)
                let response = try await client.search(query: searchQuery.isEmpty ? course.name : searchQuery)
                searchResults = response.courses
                statusMessage = "Found \(response.courses.count) result(s)"
            } catch {
                statusMessage = "Search failed: \(error.localizedDescription)"
            }
            isImporting = false
        }
    }

    private func selectSearchResult(_ result: GolfCourseAPIClient.CourseSearchResult) {
        isImporting = true
        statusMessage = "Fetching scorecard data..."
        Task {
            do {
                let client = GolfCourseAPIClient(apiKey: apiKey)
                let detail = try await client.fetchCourse(id: result.id)
                let imported = GolfCourseAPIClient.convertToCourse(detail: detail)
                course.tees = imported.tees
                course.holes = imported.holes
                course.location = imported.location
                course.clubName = imported.clubName
                course.golfCourseAPIId = imported.golfCourseAPIId
                try? store.save(course)
                searchResults = []
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
                    Text("M Hcp").bold().frame(width: 45)
                    Text("F Hcp").bold().frame(width: 45)
                    ForEach(course.tees) { tee in
                        VStack(spacing: 2) {
                            Text(tee.name).bold()
                            Button {
                                deleteTee(id: tee.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(width: 60)
                    }
                }
                Divider()

                ForEach($course.holes) { $hole in
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
            .padding()
        }
    }

    private func deleteTee(id: String) {
        course.tees.removeAll { $0.id == id }
        for i in course.holes.indices {
            course.holes[i].yardages.removeValue(forKey: id)
        }
    }
}
