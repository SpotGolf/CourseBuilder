import SwiftUI
import UniformTypeIdentifiers

struct ScorecardView: View {
    @EnvironmentObject var store: CourseStore
    @State var course: Course
    @State private var isImporting = false
    @State private var statusMessage = ""
    @State private var showImagePicker = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
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

            Divider()

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 4)
            }

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
        .onAppear {
            if let latest = store.courses.first(where: { $0.id == course.id }) {
                course = latest
            }
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
            course.subCourses = imported.subCourses
            let totalHoles = imported.subCourses.reduce(0) { $0 + $1.holes.count }
            statusMessage = "OCR imported \(totalHoles) holes"
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
