import SwiftUI
import UniformTypeIdentifiers
import CourseDataSwift

struct ScorecardView: View {
    @Binding var course: Course
    /// Whether the Course Details tab is showing. The menus only act on it while it is.
    var isActive = true
    @State private var isImporting = false
    @State private var showImagePicker = false
    @State private var exportWarnings: [String]?
    /// The outcome of the last export, course info update, or image import, shown in a dialog
    /// until the user closes it.
    @State private var actionResult: ActionResult?
    /// Whether to export when the warnings sheet has closed, because the user chose to export anyway.
    @State private var exportsAfterWarnings = false
    @State private var cleanupActions: [String]?
    @State private var isCleaningUp = false
    @State private var elevationRequest: ElevationFetchRequest?
    /// What the Cleanup fetch did. Set when the fetch is done, and shown once its dialog closes.
    @State private var fetchedElevationActions: [String]?
    @State private var showUpdateInfoConfirmation = false
    @State private var isUpdatingInfo = false
    @State private var comboTeeName: String?
    @State private var teeToDelete: String?
    @AppStorage("golfCourseAPIKey") private var apiKey: String = ""
    /// The CourseData repository chosen for the last export.
    @AppStorage("courseDataDirectory") private var courseDataDirectory: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: sectionSpacing) {
                VStack(alignment: .leading, spacing: 8) {
                    // Section heading and action buttons
                    HStack {
                        sectionHeading("Course Info")
                        Spacer()
                        Button {
                            showUpdateInfoConfirmation = true
                        } label: {
                            HStack(spacing: 4) {
                                if isUpdatingInfo {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                }
                                Text("Update course info...")
                            }
                        }
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
                    }
                    .padding(.bottom, headingBottomPadding)

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

                }
                .sectionCard()

                VStack(alignment: .leading, spacing: 8) {
                    sectionHeading("Tees")
                        .padding(.bottom, headingBottomPadding)

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
                .sectionCard()

                // Scorecard table
                ScorecardTableView(course: $course)
            }
            .padding(sectionSpacing)
        }
        .background(DetailsBackground())
        .focusedSceneValue(\.courseActions, isActive ? courseActions : nil)
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
        .alert(
            actionResult?.title ?? "",
            isPresented: Binding(
                get: { actionResult != nil },
                set: { if !$0 { actionResult = nil } }
            ),
            presenting: actionResult
        ) { _ in
            Button("OK") { actionResult = nil }
        } message: { result in
            Text(result.message)
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
            ),
            onDismiss: {
                // Export once the sheet has closed, so the result dialog can open.
                if exportsAfterWarnings {
                    exportsAfterWarnings = false
                    showSavePanelAndExport()
                }
            }
        ) {
            ExportWarningsSheet(warnings: exportWarnings ?? []) {
                exportWarnings = nil
            } onCleanup: {
                exportWarnings = nil
                runCleanup()
            } onExportAnyway: {
                exportsAfterWarnings = true
                exportWarnings = nil
            }
        }
        .sheet(
            isPresented: Binding(
                get: { cleanupActions != nil },
                set: { if !$0 { cleanupActions = nil } }
            )
        ) {
            CleanupResultsSheet(actions: cleanupActions ?? []) {
                cleanupActions = nil
            }
        }
        .elevationFetchDialog($elevationRequest)
        .onChange(of: elevationRequest?.id) {
            // The fetch dialog has closed. The results sheet opens after it.
            guard elevationRequest == nil, let actions = fetchedElevationActions else { return }
            fetchedElevationActions = nil
            finishCleanup(elevationActions: actions)
        }
    }

    private func importFromImage(url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            actionResult = ActionResult(title: "Import Failed", message: "Could not access the file.")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let image = NSImage(contentsOf: url) else {
            actionResult = ActionResult(title: "Import Failed", message: "Could not load the image.")
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
            actionResult = ActionResult(title: "Import Complete", message: "Imported \(totalHoles) holes from the image.")
        } catch {
            actionResult = ActionResult(title: "Import Failed", message: error.localizedDescription)
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
            importImage: { showImagePicker = true }
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
        Task {
            do {
                let client = GolfCourseAPIClient(apiKey: apiKey)
                var details: [GolfCourseAPIClient.CourseDetail] = []
                for id in ids {
                    details.append(try await client.fetchCourse(id: id))
                }
                let fetched = try GolfCourseAPIClient.convertToCourse(details: details)
                course = CourseInfoUpdater.merge(course, with: fetched)
                actionResult = ActionResult(title: "Update Complete", message: "Course info was updated from GolfCourseAPI.")
            } catch {
                actionResult = ActionResult(title: "Update Failed", message: error.localizedDescription)
            }
            isUpdatingInfo = false
        }
    }

    private func exportJSON() {
        let warnings = CourseIntegrity.validateCourse(course, elevationStatus: ElevationStatusStore().load(courseID: course.id))
        if warnings.isEmpty {
            showSavePanelAndExport()
        } else {
            exportWarnings = warnings
        }
    }

    /// Fetches missing elevations and green surfaces in a dialog, then repairs the course data.
    /// If the user cancels the fetch, nothing is repaired.
    private func runCleanup() {
        guard !isCleaningUp else { return }
        let statusStore = ElevationStatusStore()
        let savedStatus = statusStore.load(courseID: course.id)
        guard CourseElevationFetch.isNeeded(for: course, status: savedStatus) else {
            finishCleanup(elevationActions: [])
            return
        }

        isCleaningUp = true
        let pointsBefore = ElevationUpdater.missingCoordinates(in: course).count
        let greensBefore = GreenSurfaceUpdater.greensMissingSurface(in: course).count
        elevationRequest = ElevationFetchRequest(
            course: course,
            status: savedStatus,
            onFinished: { updated, status in
                try statusStore.save(status, courseID: updated.id)
                course = updated
                var actions: [String] = []
                let points = pointsBefore - ElevationUpdater.missingCoordinates(in: updated).count
                if points > 0 {
                    actions.append("Fetched elevations for \(points) point(s)")
                }
                let greens = greensBefore - GreenSurfaceUpdater.greensMissingSurface(in: updated).count
                if greens > 0 {
                    actions.append("Built the surface of \(greens) green(s)")
                }
                if let noData = CourseElevationFetch.noDataMessage(from: savedStatus, to: status) {
                    actions.append(noData)
                }
                fetchedElevationActions = actions
            },
            onCancelled: { isCleaningUp = false }
        )
    }

    /// Repairs the course data and shows what was done.
    private func finishCleanup(elevationActions: [String]) {
        let report = CourseIntegrity.cleanup(&course)
        cleanupActions = elevationActions + report.actions
        isCleaningUp = false
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
            actionResult = ActionResult(title: "Export Complete", message: "Saved to \(path) (\(ratio)% smaller).")
        } catch {
            actionResult = ActionResult(title: "Export Failed", message: error.localizedDescription)
        }
    }

}

// MARK: - ActionResult

/// What an export, a course info update, or an image import did, for the dialog that is shown
/// when it ends.
private struct ActionResult {
    let title: String
    let message: String
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
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cleanup Complete")
                .font(.headline)

            if actions.isEmpty {
                Text("No cleanup was needed.")
                    .foregroundStyle(.secondary)
            } else {
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

/// The extra space under a section's heading, before the section's content.
private let headingBottomPadding: CGFloat = 8

/// The space between the sections of the course details, and around them.
private let sectionSpacing: CGFloat = 16

/// The background of the course details: the window's color, darkened so the sections stand out.
private struct DetailsBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay(Color.black.opacity(colorScheme == .dark ? 0.35 : 0.1))
    }
}

/// The background of a section of the course details: the window's color, lightened, with
/// rounded corners.
private struct SectionCardBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .windowBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(colorScheme == .dark ? 0.05 : 0.6)))
    }
}

private extension View {
    /// Shows a section of the course details as a card: padded, as wide as the details, and on a
    /// lighter background with rounded corners.
    func sectionCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SectionCardBackground())
    }
}

struct ScorecardTableView: View {
    @Binding var course: Course
    @State private var subCourseToDelete: Int?
    /// The round whose handicaps are shown as the scorecard prints them, or `nil` to show each
    /// sub-course's stored handicaps.
    @State private var selectedHandicapRound: [Int]?

    /// The rounds a scorecard prints for the course.
    private var rounds: [[Int]] {
        ScorecardRounds.rounds(in: course)
    }

    /// The rounds of more than one sub-course when the course has more than one such round. With
    /// these, a hole's printed handicap depends on the round, so the user picks one.
    private var handicapRounds: [[Int]] {
        let rounds = rounds.filter { $0.count > 1 }
        return rounds.count > 1 ? rounds : []
    }

    /// ``selectedHandicapRound``, or `nil` when the course no longer has that round.
    private var handicapRound: [Int]? {
        selectedHandicapRound.flatMap { handicapRounds.contains($0) ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeading("Ratings")
                    .padding(.bottom, headingBottomPadding)
                ratingsTable
            }
            .sectionCard()

            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    // The sub-course tables below already keep their distance from the heading.
                    sectionHeading("Yardages")
                        .padding(.bottom, handicapRounds.isEmpty ? 0 : headingBottomPadding)
                    if !handicapRounds.isEmpty {
                        Picker("Show handicaps for", selection: $selectedHandicapRound) {
                            Text("Each sub-course alone").tag([Int]?.none)
                            ForEach(handicapRounds, id: \.self) { round in
                                Text(ScorecardRounds.name(of: round, in: course)).tag([Int]?.some(round))
                            }
                        }
                        .fixedSize()
                    }
                }

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
                                    handicapField(subCourse: index, holeNumber: hole.number, gender: .male)
                                    handicapField(subCourse: index, holeNumber: hole.number, gender: .female)
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
            }
            .sectionCard()
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

    // MARK: - Ratings

    /// The rating and slope of each round from each tee, as a scorecard prints them.
    @ViewBuilder
    private var ratingsTable: some View {
        let teeNames = course.tees.map(\.name) + course.comboTees.map(\.name)
        if rounds.isEmpty || teeNames.isEmpty {
            Text("Add a tee and a sub-course to enter ratings and slopes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 2) {
                GridRow {
                    Text("Round").bold()
                    Text("Tee").bold()
                    Text("M Rating").bold().frame(width: 70)
                    Text("M Slope").bold().frame(width: 60)
                    Text("F Rating").bold().frame(width: 70)
                    Text("F Slope").bold().frame(width: 60)
                }

                ForEach(rounds, id: \.self) { round in
                    Divider()
                    ForEach(Array(teeNames.enumerated()), id: \.element) { teeIndex, tee in
                        GridRow {
                            Text(teeIndex == 0 ? ScorecardRounds.name(of: round, in: course) : "")
                                .padding(.trailing, 8)
                            Text(tee)
                                .padding(.trailing, 8)
                            ForEach(Gender.allCases, id: \.self) { gender in
                                TextField("", value: ratingBinding(round: round, tee: tee, gender: gender), format: .number.precision(.fractionLength(0...2)))
                                    .frame(width: 70)
                                    .textFieldStyle(.roundedBorder)
                                TextField("", value: slopeBinding(round: round, tee: tee, gender: gender), format: .number)
                                    .frame(width: 60)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                }
            }
        }
    }

    private func ratingBinding(round: [Int], tee: String, gender: Gender) -> Binding<Double?> {
        Binding(
            get: { ScorecardRounds.rating(in: course, round: round, tee: tee, gender: gender) },
            set: { ScorecardRounds.setRating($0, in: &course, round: round, tee: tee, gender: gender) }
        )
    }

    private func slopeBinding(round: [Int], tee: String, gender: Gender) -> Binding<Int?> {
        Binding(
            get: { ScorecardRounds.slope(in: course, round: round, tee: tee, gender: gender) },
            set: { ScorecardRounds.setSlope($0, in: &course, round: round, tee: tee, gender: gender) }
        )
    }

    // MARK: - Handicaps

    /// A field for one hole's handicap. It shows the handicap as the scorecard prints it for the
    /// picked round. When a round is picked that does not have the sub-course, the field shows
    /// the stored handicap and cannot be changed.
    private func handicapField(subCourse: Int, holeNumber: Int, gender: Gender) -> some View {
        let binding = Binding<Int>(
            get: {
                guard let hole = course.subCourses[subCourse].holes.firstIndex(where: { $0.number == holeNumber }) else { return 0 }
                return ScorecardRounds.handicaps(in: course, round: handicapRound, subCourse: subCourse, gender: gender)[hole]
            },
            set: { handicap in
                guard let hole = course.subCourses[subCourse].holes.firstIndex(where: { $0.number == holeNumber }) else { return }
                ScorecardRounds.setHandicap(handicap, in: &course, round: handicapRound, subCourse: subCourse, hole: hole, gender: gender)
            }
        )
        return TextField("", value: binding, format: .number)
            .frame(width: 45)
            .textFieldStyle(.roundedBorder)
            .disabled(handicapRound.map { !$0.contains(subCourse) } ?? false)
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
