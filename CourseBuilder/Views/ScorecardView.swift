import SwiftUI
import UniformTypeIdentifiers

struct ScorecardView: View {
    @EnvironmentObject var store: CourseStore
    @State var course: Course
    @State private var isImporting = false
    @State private var statusMessage = ""
    @State private var showImagePicker = false
    @State private var saveTask: Task<Void, Never>?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                // Action buttons
                HStack {
                    Spacer()
                    Button("Export JSON...") { exportJSON() }
                    Button("Import Image...") { showImagePicker = true }
                    Button("Open Map Editor") {
                        openWindow(id: "map-editor", value: course.id)
                    }
                    .disabled(course.subCourses.isEmpty)
                }

                // Course Name and Club Name
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Course Name").font(.caption).foregroundStyle(.secondary)
                        TextField("Course Name", text: $course.name)
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Club Name").font(.caption).foregroundStyle(.secondary)
                        TextField("Club Name", text: $course.clubName)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                // Address
                VStack(alignment: .leading, spacing: 2) {
                    Text("Address").font(.caption).foregroundStyle(.secondary)
                    TextField("Address", text: $course.location.address)
                        .textFieldStyle(.roundedBorder)
                }

                // City, State, Country, Lat/Lng
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("City").font(.caption).foregroundStyle(.secondary)
                        TextField("City", text: $course.location.city)
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("State").font(.caption).foregroundStyle(.secondary)
                        TextField("State", text: $course.location.state)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 100)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Country").font(.caption).foregroundStyle(.secondary)
                        TextField("Country", text: $course.location.country)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 100)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Latitude").font(.caption).foregroundStyle(.secondary)
                        TextField("Latitude", value: $course.location.coordinate.latitude, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 120)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Longitude").font(.caption).foregroundStyle(.secondary)
                        TextField("Longitude", value: $course.location.coordinate.longitude, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 120)
                    }
                }

                // Tee definitions
                HStack {
                    Text("Tees").font(.caption).foregroundStyle(.secondary)
                    Button(action: {
                        course.tees.append(TeeDefinition(name: "", color: "#FFFFFF"))
                    }) {
                        Image(systemName: "plus")
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
                                get: { Color(hex: course.tees[index].color) ?? .white },
                                set: { course.tees[index].color = $0.hexString }
                            )
                        )
                        .labelsHidden()
                        Button(action: {
                            course.tees.remove(at: index)
                        }) {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                    }
                }
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
        .onChange(of: course) { _, _ in
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                try? store.save(course)
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

    private func exportJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let fileName = course.name
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { $0.capitalized }
            .joined(separator: "-")
        panel.nameFieldStringValue = "\(fileName).json"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(course)
            try data.write(to: url)
            statusMessage = "Exported to \(url.lastPathComponent)"
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

}

// MARK: - ScorecardTableView

struct ScorecardTableView: View {
    @Binding var course: Course
    @State private var subCourseToDelete: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(Array(course.subCourses.enumerated()), id: \.element.id) { index, _ in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Sub-course Name").font(.caption).foregroundStyle(.secondary)
                                TextField("Sub-course Name", text: $course.subCourses[index].name)
                                    .textFieldStyle(.roundedBorder)
                            }
                            Button {
                                subCourseToDelete = index
                            } label: {
                                Image(systemName: "xmark")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }

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

                            ForEach($course.subCourses[index].holes) { $hole in
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

                Button {
                    let holes = (1...9).map { Hole(number: $0, par: 4) }
                    course.subCourses.append(SubCourse(name: "New", holes: holes))
                } label: {
                    Label("Add Sub-course", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal)
            }
            .padding()
        }
        .confirmationDialog(
            "Delete \(subCourseToDelete.flatMap { course.subCourses.indices.contains($0) ? course.subCourses[$0].name : nil } ?? "this sub-course")?",
            isPresented: Binding(
                get: { subCourseToDelete != nil },
                set: { if !$0 { subCourseToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let index = subCourseToDelete {
                    course.subCourses.remove(at: index)
                    subCourseToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                subCourseToDelete = nil
            }
        } message: {
            Text("This will remove all holes in this sub-course.")
        }
    }
}

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
