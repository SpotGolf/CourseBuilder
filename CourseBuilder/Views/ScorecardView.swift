import SwiftUI
import UniformTypeIdentifiers
import CourseDataSwift

struct ScorecardView: View {
    @Binding var course: Course
    @State private var isImporting = false
    @State private var statusMessage = ""
    @State private var showImagePicker = false
    @State private var exportWarnings: [String]?
    @State private var cleanupActions: [String]?
    @State private var cleanupError: String?
    @State private var isCleaningUp = false
    @State private var showUpdateInfoConfirmation = false
    @State private var isUpdatingInfo = false
    @State private var comboTeeName: String?
    @State private var teeToDelete: String?
    @AppStorage("golfCourseAPIKey") private var apiKey: String = ""
    /// The CourseData repository chosen for the last export.
    @AppStorage("courseDataDirectory") private var courseDataDirectory: String = ""
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                // Section heading and action buttons
                HStack {
                    sectionHeading("Course Info")
                    Spacer()
                    Button("Update course info...") { showUpdateInfoConfirmation = true }
                        .disabled(course.golfCourseAPIIds.isEmpty || apiKey.isEmpty || isUpdatingInfo)
                        .help(updateInfoHelp)
                    Button {
                        runCleanup()
                    } label: {
                        HStack(spacing: 4) {
                            if isCleaningUp {
                                ProgressView()
                                    .scaleEffect(0.6)
                            }
                            Text("Cleanup")
                        }
                    }
                    .disabled(isCleaningUp)
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
                        TextField("Latitude", value: $course.location.coordinate.lat, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 120)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Longitude").font(.caption).foregroundStyle(.secondary)
                        TextField("Longitude", value: $course.location.coordinate.lon, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 120)
                    }
                }

                Divider()
                    .padding(.vertical, 12)

                sectionHeading("Tees")

                // Tee definitions, with combo tees to the right
                HStack(alignment: .top, spacing: 32) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Main Tees").font(.caption).foregroundStyle(.secondary)
                            Button(action: {
                                course.tees.append(TeeDefinition(name: "", color: "#FFFFFF"))
                            }) {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.borderless)
                        }

                        ForEach(course.tees.indices, id: \.self) { index in
                            HStack(spacing: 8) {
                                Button {
                                    guard index > 0 else { return }
                                    course.tees.swapAt(index, index - 1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == 0)

                                Button {
                                    guard index < course.tees.count - 1 else { return }
                                    course.tees.swapAt(index, index + 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == course.tees.count - 1)

                                TeeNameField(index: index, course: $course)
                                ColorPicker(
                                    "",
                                    selection: Binding(
                                        get: { Color(hex: course.tees[index].color) ?? .white },
                                        set: { course.tees[index].color = $0.hexString }
                                    )
                                )
                                .labelsHidden()
                                Button("Make combo tee...") {
                                    comboTeeName = course.tees[index].name
                                }
                                .disabled(course.tees.count < 3)
                                Button(action: {
                                    let teeName = course.tees[index].name
                                    if CourseIntegrity.usage(ofTeeNamed: teeName, in: course).isInUse {
                                        teeToDelete = teeName
                                    } else {
                                        CourseIntegrity.removeTee(at: index, from: &course)
                                    }
                                }) {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }

                    if !course.comboTees.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Combo Tees").font(.caption).foregroundStyle(.secondary)
                            ForEach(course.comboTees) { combo in
                                HStack(spacing: 8) {
                                    Text("\(combo.name): \(combo.tees.joined(separator: " + "))")
                                    Button("Edit...") {
                                        comboTeeName = combo.name
                                    }
                                    Button(action: {
                                        ComboTeeBuilder.delete(comboNamed: combo.name, from: &course)
                                    }) {
                                        Image(systemName: "xmark")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
            }
            .padding()

            Divider()

            sectionHeading("Yardages")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top])

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
        .focusedSceneValue(\.courseActions, courseActions)
        .confirmationDialog(
            "Update \(course.name) from GolfCourseAPI?",
            isPresented: $showUpdateInfoConfirmation,
            titleVisibility: .visible
        ) {
            Button("Update") { updateCourseInfo() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Names, address, tees, ratings, slopes, par, handicaps, and yardages are replaced. Map features and centerlines are kept.")
        }
        .sheet(
            isPresented: Binding(
                get: { comboTeeName != nil },
                set: { if !$0 { comboTeeName = nil } }
            )
        ) {
            if let comboTeeName {
                ComboTeeSheet(course: $course, teeName: comboTeeName) {
                    self.comboTeeName = nil
                }
            }
        }
        .alert(
            "Delete tee \"\(teeToDelete ?? "")\"?",
            isPresented: Binding(
                get: { teeToDelete != nil },
                set: { if !$0 { teeToDelete = nil } }
            ),
            presenting: teeToDelete
        ) { teeName in
            Button("Delete", role: .destructive) {
                if let index = course.tees.firstIndex(where: { $0.name == teeName }) {
                    CourseIntegrity.removeTee(at: index, from: &course)
                }
                teeToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                teeToDelete = nil
            }
        } message: { teeName in
            Text(teeInUseMessage(for: teeName))
        }
        .fileImporter(isPresented: $showImagePicker, allowedContentTypes: [.image, .pdf]) { result in
            if case .success(let url) = result {
                importFromImage(url: url)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { exportWarnings != nil },
                set: { if !$0 { exportWarnings = nil } }
            )
        ) {
            ExportWarningsSheet(warnings: exportWarnings ?? []) {
                exportWarnings = nil
            } onCleanup: {
                exportWarnings = nil
                runCleanup()
            } onExportAnyway: {
                exportWarnings = nil
                showSavePanelAndExport()
            }
        }
        .sheet(
            isPresented: Binding(
                get: { cleanupActions != nil },
                set: { if !$0 { cleanupActions = nil } }
            )
        ) {
            CleanupResultsSheet(actions: cleanupActions ?? [], errorMessage: cleanupError) {
                cleanupActions = nil
                cleanupError = nil
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
            // The imported holes have no combo tees, so any old combo tees would point at nothing.
            course.comboTees = []
            course.subCourses = imported.subCourses
            let totalHoles = imported.subCourses.reduce(0) { $0 + $1.holes.count }
            statusMessage = "OCR imported \(totalHoles) holes"
        } catch {
            statusMessage = "OCR failed: \(error.localizedDescription)"
        }
    }

    private func teeInUseMessage(for teeName: String) -> String {
        let usage = CourseIntegrity.usage(ofTeeNamed: teeName, in: course)
        var lines = ["This tee is in use. Deleting it also deletes:"]
        if !usage.comboTees.isEmpty {
            lines.append("• Combo \(usage.comboTees.count == 1 ? "tee" : "tees") \(usage.comboTees.map { "\"\($0)\"" }.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    /// The header buttons, for the menus. A disabled button's action is nil.
    private var courseActions: CourseActions {
        CourseActions(
            updateCourseInfo: course.golfCourseAPIIds.isEmpty || apiKey.isEmpty || isUpdatingInfo
                ? nil : { showUpdateInfoConfirmation = true },
            export: { exportJSON() },
            cleanup: isCleaningUp ? nil : { runCleanup() },
            importImage: { showImagePicker = true },
            openMapEditor: course.subCourses.isEmpty
                ? nil : { openWindow(id: "map-editor", value: course.id) }
        )
    }

    private var updateInfoHelp: String {
        if course.golfCourseAPIIds.isEmpty {
            "This course was not imported from GolfCourseAPI"
        } else if apiKey.isEmpty {
            "Set the GolfCourseAPI key in Settings"
        } else {
            "Reload the scorecard data from GolfCourseAPI"
        }
    }

    private func updateCourseInfo() {
        let ids = course.golfCourseAPIIds
        isUpdatingInfo = true
        statusMessage = "Updating course info..."
        Task {
            do {
                let client = GolfCourseAPIClient(apiKey: apiKey)
                var details: [GolfCourseAPIClient.CourseDetail] = []
                for id in ids {
                    details.append(try await client.fetchCourse(id: id))
                }
                let fetched = try GolfCourseAPIClient.convertToCourse(details: details)
                course = CourseInfoUpdater.merge(course, with: fetched)
                statusMessage = "Updated course info from GolfCourseAPI"
            } catch {
                statusMessage = "Update failed: \(error.localizedDescription)"
            }
            isUpdatingInfo = false
        }
    }

    private func exportJSON() {
        let warnings = CourseIntegrity.validateCourse(course)
        if warnings.isEmpty {
            showSavePanelAndExport()
        } else {
            exportWarnings = warnings
        }
    }

    /// Looks up missing elevations, then repairs the course data. If the elevation lookup fails,
    /// the rest of the cleanup still runs and the results sheet shows the error.
    private func runCleanup() {
        guard !isCleaningUp else { return }
        isCleaningUp = true
        Task {
            var elevationActions: [String] = []
            var elevationError: String?
            let missing = ElevationUpdater.missingCoordinates(in: course).count
            if missing > 0 {
                statusMessage = "Looking up elevations for \(missing) point(s)..."
                do {
                    let lookup = try await ElevationUpdater.lookUpMissingElevations(in: course)
                    ElevationUpdater.apply(lookup.elevations, to: &course)
                    let found = lookup.elevations.count - lookup.seaLevelPoints
                    if found > 0 {
                        elevationActions.append("Looked up elevations for \(found) point(s)")
                    }
                    if lookup.seaLevelPoints > 0 {
                        elevationActions.append("Set \(lookup.seaLevelPoints) point(s) to sea level because USGS has no elevation data for them")
                    }
                } catch {
                    elevationError = "Could not look up elevations. \(error.localizedDescription)"
                }
                statusMessage = ""
            }

            let report = CourseIntegrity.cleanup(&course)
            cleanupError = elevationError
            cleanupActions = elevationActions + report.actions
            isCleaningUp = false
        }
    }

    /// Asks for the CourseData repository and saves the course into it, in the folder and with
    /// the file name CourseData's naming rules give.
    private func showSavePanelAndExport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose your CourseData folder. The course is saved under Data/ in its country, state, and city folders."
        if !courseDataDirectory.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: courseDataDirectory)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        courseDataDirectory = url.path
        writeExport(toCourseData: url)
    }

    private func writeExport(toCourseData directory: URL) {
        do {
            let saved = try CourseExporter.write(course, toCourseData: directory)
            let ratio = Int((1.0 - Double(saved.gzipSize) / Double(saved.jsonSize)) * 100)
            let path = saved.url.path.replacingOccurrences(of: directory.path + "/", with: "")
            statusMessage = "Exported to \(path) (\(ratio)% smaller)"
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

}

// MARK: - ExportWarningsSheet

struct ExportWarningsSheet: View {
    let warnings: [String]
    let onCancel: () -> Void
    let onCleanup: () -> Void
    let onExportAnyway: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Warnings")
                .font(.headline)

            Text("The following issues were found:")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            List(Array(warnings.enumerated()), id: \.offset) { _, warning in
                Text(warning)
                    .font(.body)
            }
            .frame(height: 280)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Cleanup", action: onCleanup)
                Button("Export Anyway", action: onExportAnyway)
            }
        }
        .padding()
        .frame(width: 450)
    }
}

// MARK: - CleanupResultsSheet

struct CleanupResultsSheet: View {
    let actions: [String]
    var errorMessage: String?
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(errorMessage == nil ? "Cleanup Complete" : "Cleanup Incomplete")
                .font(.headline)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if actions.isEmpty && errorMessage == nil {
                Text("No cleanup was needed.")
                    .foregroundStyle(.secondary)
            } else if !actions.isEmpty {
                Text("The following cleanup actions were performed:")
                    .foregroundStyle(.secondary)

                List(Array(actions.enumerated()), id: \.offset) { _, action in
                    Text(action)
                }
                .frame(height: 280)
            }

            HStack {
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 500)
    }
}

// MARK: - ScorecardTableView

/// A heading for a section of the scorecard, slightly larger than the field labels.
private func sectionHeading(_ title: String) -> some View {
    Text(title).font(.headline)
}

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
