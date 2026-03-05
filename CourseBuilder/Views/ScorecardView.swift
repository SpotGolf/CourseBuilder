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
            VStack(alignment: .leading, spacing: 8) {
                // Action buttons
                HStack {
                    Spacer()
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

                // City, State, Country
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
        .onChange(of: course) { _, newValue in
            try? store.save(newValue)
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
                        TextField("Sub-course Name", text: $subCourse.name)
                            .font(.headline)
                            .textFieldStyle(.plain)
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
