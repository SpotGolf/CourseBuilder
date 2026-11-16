import CoreLocation
import MapKit
import SwiftUI
import UniformTypeIdentifiers
import CourseDataSwift

struct CourseListView: View {
    @EnvironmentObject var store: CourseStore
    @State private var showNewCourse = false
    @State private var showDeleteConfirmation = false
    @State private var selectedCourse: Course?
    @State private var elevationRequest: ElevationFetchRequest?

    var body: some View {
        NavigationSplitView {
            List(store.courses, selection: Binding(get: { selectedCourse }, set: { select($0) })) { course in
                NavigationLink(value: course) {
                    VStack(alignment: .leading) {
                        Text(course.name)
                            .font(.headline)
                        Text(course.location.cityStateDisplay)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(course.subCourses.reduce(0) { $0 + $1.holes.count }) holes")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .navigationTitle("Courses")
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 0) {
                    Button {
                        showNewCourse = true
                    } label: {
                        Image(systemName: "plus")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderless)

                    Divider().frame(height: 20)

                    Button {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "minus")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedCourse == nil)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        } detail: {
            if let course = selectedCourse, let binding = store.binding(for: course.id) {
                CourseTabsView(course: binding)
                    .id(course.id)
            } else {
                Text("Select a course or create a new one")
                    .foregroundStyle(.secondary)
            }
        }
        .focusedSceneValue(\.courseListActions, CourseListActions(
            newCourse: { showNewCourse = true },
            deleteCourse: selectedCourse == nil ? nil : { showDeleteConfirmation = true }
        ))
        .sheet(isPresented: $showNewCourse) {
            AddCourseSheet { course in
                try? store.save(course)
                selectedCourse = course
                showNewCourse = false
            }
        }
        .confirmationDialog(
            "Delete \(selectedCourse?.name ?? "this course")?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let course = selectedCourse {
                    try? store.delete(id: course.id)
                    // An empty status removes the course's status file.
                    try? ElevationStatusStore().save(ElevationStatus(), courseID: course.id)
                    selectedCourse = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
        .elevationFetchDialog($elevationRequest)
        .onAppear {
            try? store.loadAll()
        }
    }

    /// Selects a course. A course that is missing elevations, green surfaces, or part of its
    /// OpenStreetMap record has them fetched first, and is only selected once that is done.
    private func select(_ course: Course?) {
        guard let course else {
            selectedCourse = nil
            return
        }
        let statusStore = ElevationStatusStore()
        let status = statusStore.load(courseID: course.id)
        let baselineStore = OSMBaselineStore()
        let baseline = try? baselineStore.loadOrCreate(for: course)
        let needsOSM = baseline.map { OSMBaselineFetch.isNeeded(for: $0, course: course) } ?? false
        guard needsOSM || CourseElevationFetch.isNeeded(for: course, status: status) else {
            selectedCourse = course
            return
        }
        elevationRequest = ElevationFetchRequest(
            course: course,
            status: status,
            osmBaseline: baseline,
            onOSMBaselineFetched: { try baselineStore.save($0, courseID: course.id) },
            onFinished: { updated, status in
                try statusStore.save(status, courseID: updated.id)
                try store.save(updated)
                selectedCourse = updated
            }
        )
    }
}

struct AddCourseSheet: View {
    let onCreate: (Course) -> Void

    enum Tab: Hashable {
        case search, manualEntry, importFile
    }

    /// Where the dialog is on the way to adding a course.
    enum Step: Equatable {
        /// The user is filling in a tab.
        case form
        /// Looking for the course in OpenStreetMap.
        case lookingUp
        /// The OpenStreetMap lookup failed, with why.
        case lookupFailed(String)
        /// The user is assigning the OpenStreetMap holes to sub-courses.
        case assigning
        /// Fetching what the course still needs: what its OpenStreetMap record lacks, then
        /// its elevations from USGS.
        case fetchingElevations
        /// The elevation fetch failed, with why.
        case elevationsFailed(String)
        /// The elevations were fetched, with what to tell the user. The course is added a moment later.
        case elevationsDone(String)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: Tab = .search
    @State private var step: Step = .form

    // OpenStreetMap lookup. The course is only added once this is done.
    /// The course being added, before any OpenStreetMap data.
    @State private var pendingCourse: Course?
    @State private var osmResult: OverpassAPIClient.ParsedResult?
    @State private var centerlineGroups: [CenterlineGroup] = []
    @State private var lookupStatus = ""
    @State private var lookupTask: Task<Void, Never>?

    // Elevations. They are fetched last, and the course is only added once this is done.
    /// The course with its OpenStreetMap data, and the elevations fetched so far.
    @State private var elevationCourse: Course?
    /// What OpenStreetMap had. Nil when the course is not in OpenStreetMap.
    @State private var importedBaseline: OSMBaseline?
    @State private var elevationStatus = ElevationStatus()
    @State private var elevationProgress: CourseElevationFetch.Progress?
    /// Set while the OpenStreetMap record of an imported file is being fetched.
    @State private var osmRecordProgress: OSMBaselineFetch.Progress?
    @State private var elevationTask: Task<Void, Never>?

    // Search fields
    @AppStorage("golfCourseAPIKey") private var apiKey: String = ""
    @State private var searchQuery = ""
    @State private var searchResults: [GolfCourseAPIClient.CourseSearchResult] = []
    @State private var selectedResultIDs: Set<String> = []
    @State private var isSearching = false
    @State private var searchError = ""
    @State private var isFetching = false
    @State private var showFetchError = false
    @State private var fetchErrorMessage = ""

    // Import fields
    @State private var importedCourse: Course?
    @State private var importError = ""

    // Manual entry fields
    @State private var clubName = ""
    @State private var name = ""
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var holeCount = 18
    @State private var isGeocodingManual = false

    /// The club name, plus the course name when a club has more than one course (e.g. "South/East").
    private func displayName(_ result: GolfCourseAPIClient.CourseSearchResult) -> String {
        result.courseName.isEmpty || result.courseName == result.clubName
            ? result.clubName
            : "\(result.clubName) – \(result.courseName)"
    }

    private var canAdd: Bool {
        switch selectedTab {
        case .search:
            return !selectedResultIDs.isEmpty
        case .manualEntry:
            guard !name.isEmpty,
                  let lat = Double(latitude), (-90...90).contains(lat),
                  let lon = Double(longitude), (-180...180).contains(lon) else { return false }
            return true
        case .importFile:
            return importedCourse != nil
        }
    }

    /// The size the dialog opens the sub-course assignment step at. The user can resize it.
    private static let assignmentSize = CGSize(width: 1000, height: 700)

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .form:
                form
            case .lookingUp:
                lookupProgress
                    .frame(width: 450, height: 418)
            case .lookupFailed(let message):
                lookupFailure(message)
                    .frame(width: 450, height: 418)
            case .fetchingElevations:
                Group {
                    if let osmRecordProgress {
                        FetchProgressView(title: "Fetching OpenStreetMap data", detail: osmRecordProgress.message)
                    } else {
                        ElevationFetchProgressView(progress: elevationProgress)
                    }
                }
                .padding(24)
                .frame(width: 450, height: 418)
            case .elevationsFailed(let message):
                elevationFailure(message)
                    .frame(width: 450, height: 418)
            case .elevationsDone(let message):
                ElevationFetchDoneView(message: message)
                    .padding(24)
                    .frame(width: 450, height: 418)
            case .assigning:
                SubCourseAssignmentView(
                    subCourseNames: pendingCourse?.subCourses.map(\.name) ?? [],
                    groups: $centerlineGroups
                )
                .frame(minWidth: 700, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
            }

            Divider()

            HStack {
                Button("Cancel") {
                    lookupTask?.cancel()
                    elevationTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if isFetching || isGeocodingManual {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                switch step {
                case .form, .lookingUp, .fetchingElevations, .elevationsDone:
                    Button("Add") { addCourse() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(step != .form || !canAdd || isFetching || isGeocodingManual)
                case .lookupFailed:
                    Button("Retry") {
                        if let pendingCourse { lookUpOSM(for: pendingCourse) }
                    }
                    .keyboardShortcut(.defaultAction)
                case .elevationsFailed:
                    Button("Retry") { fetchElevations() }
                        .keyboardShortcut(.defaultAction)
                case .assigning:
                    Button("Add") { addAssignedCourse() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!centerlineGroups.allSatisfy { $0.assignedSubCourseIndex != nil })
                }
            }
            .padding()
        }
        .background(SheetResizing(size: step == .assigning ? Self.assignmentSize : nil))
        .interactiveDismissDisabled(step != .form)
        .alert("Error", isPresented: $showFetchError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(fetchErrorMessage)
        }
    }

    private var form: some View {
        VStack(spacing: 0) {
            Picker("Add Method", selection: $selectedTab) {
                Text("Search").tag(Tab.search)
                Text("Manual Entry").tag(Tab.manualEntry)
                Text("Import").tag(Tab.importFile)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.top, 16)
            .padding(.horizontal)

            Group {
                switch selectedTab {
                case .search:
                    searchTab
                case .manualEntry:
                    manualEntryTab
                case .importFile:
                    importTab
                }
            }
            .frame(width: 450, height: 370)
        }
    }

    private var lookupProgress: some View {
        VStack(spacing: 16) {
            ProgressView()
            VStack(spacing: 4) {
                Text("Looking for the course in OpenStreetMap")
                Text(lookupStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
    }

    private func elevationFailure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            Text("The course data could not be fetched.")
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("The course is added only once all of its data is fetched. Retry carries on from where the fetch stopped. Or cancel and add the course later, when the network or the servers may be working better.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
    }

    private func lookupFailure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            Text("Could not look for the course in OpenStreetMap.")
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("The course is added only after this lookup works. Retry, or cancel and add the course later.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
    }

    private var manualEntryTab: some View {
        Form {
            TextField("Club Name", text: $clubName)
            TextField("Course Name", text: $name)
            TextField("Latitude", text: $latitude)
            TextField("Longitude", text: $longitude)
            Picker("Holes", selection: $holeCount) {
                Text("9").tag(9)
                Text("18").tag(18)
                Text("27").tag(27)
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
        .padding()
    }

    private var importTab: some View {
        VStack(spacing: 16) {
            Spacer()
            if let course = importedCourse {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.green)
                    Text(course.name)
                        .font(.headline)
                    Text(course.location.cityStateDisplay)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    let holeCount = course.subCourses.reduce(0) { $0 + $1.holes.count }
                    Text("\(holeCount) holes · \(course.tees.count) tees")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else if !importError.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text(importError)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                Image(systemName: "doc.badge.arrow.up")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Select a CourseBuilder JSON file")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("Choose File...") { chooseImportFile() }
            Spacer()
        }
        .padding()
    }

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
                Table(searchResults, selection: $selectedResultIDs) {
                    TableColumn("Name") { Text(displayName($0)) }
                    TableColumn("City") { Text($0.location.city ?? "") }
                    TableColumn("State") { Text($0.location.state ?? "") }
                    TableColumn("Country") { Text($0.location.country ?? "") }
                }
                Text("If the course spans more than one result, such as three 9-hole courses, select them all. CourseBuilder combines them into one course.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
    }

    private func addCourse() {
        switch selectedTab {
        case .search:
            // In the order shown, so the sub-courses come out in the same order.
            let selected = searchResults.filter { selectedResultIDs.contains($0.id) }
            guard !selected.isEmpty else { return }
            fetchAndAddCourses(selected)
        case .importFile:
            if let course = importedCourse {
                // A file has no OpenStreetMap record of its own. What it needs is fetched.
                let baseline = (try? OSMBaselineStore().load(courseID: course.id)) ?? OSMBaseline(course: course)
                fetchElevations(for: course, baseline: baseline, status: ElevationStatusStore().load(courseID: course.id))
            }
        case .manualEntry:
            guard let lat = Double(latitude), let lon = Double(longitude) else { return }
            isGeocodingManual = true
            let coord = Coordinate(lat: lat, lon: lon)
            let courseName = name
            let courseClubName = clubName
            let courseHoleCount = holeCount
            reverseGeocode(latitude: lat, longitude: lon) { address, city, state, country, geocodeError in
                isGeocodingManual = false
                if let geocodeError {
                    fetchErrorMessage = "Reverse geocode failed: \(geocodeError)"
                    showFetchError = true
                    return
                }
                let subCourseCount = courseHoleCount / 9
                let subCourseNames = ["Front", "Back", "Third"]
                var subCourses: [SubCourse] = []
                for i in 0..<subCourseCount {
                    let holes = (1...9).map { Hole(number: $0, par: 4) }
                    subCourses.append(SubCourse(name: subCourseNames[i], holes: holes))
                }
                let course = Course(
                    name: courseName,
                    clubName: courseClubName,
                    location: CourseLocation(
                        address: address,
                        city: city,
                        state: state,
                        country: country,
                        coordinate: coord
                    ),
                    subCourses: subCourses
                )
                lookUpOSM(for: course)
            }
        }
    }

    private func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .gzip]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            var data = try Data(contentsOf: url)
            // Detect gzip by magic bytes (0x1f 0x8b)
            if data.count >= 2, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b {
                data = try data.gzipDecompressed()
            }
            let course = try JSONDecoder().decode(Course.self, from: data)
            importError = ""
            importedCourse = course
        } catch {
            importedCourse = nil
            importError = "Invalid CourseBuilder file: \(error.localizedDescription)"
        }
    }

    private func searchCourses() {
        guard !apiKey.isEmpty, !searchQuery.isEmpty else { return }
        isSearching = true
        searchError = ""
        searchResults = []
        selectedResultIDs = []
        Task {
            do {
                let client = GolfCourseAPIClient(apiKey: apiKey)
                let response = try await client.search(query: searchQuery)
                // A course with no location cannot be looked for in OpenStreetMap.
                searchResults = response.courses.filter(\.hasCoordinate)
            } catch {
                searchError = "Search failed: \(error.localizedDescription)"
            }
            isSearching = false
        }
    }

    private func fetchAndAddCourses(_ results: [GolfCourseAPIClient.CourseSearchResult]) {
        isFetching = true
        Task {
            do {
                let client = GolfCourseAPIClient(apiKey: apiKey)
                var details: [GolfCourseAPIClient.CourseDetail] = []
                for result in results {
                    let detail = try await client.fetchCourse(id: result.id)
                    details.append(detail)
                }
                let course = try GolfCourseAPIClient.convertToCourse(details: details)
                isFetching = false
                lookUpOSM(for: course)
            } catch {
                fetchErrorMessage = "Failed to fetch course: \(error.localizedDescription)"
                showFetchError = true
                isFetching = false
            }
        }
    }

    // MARK: - OpenStreetMap

    /// Looks for the course in OpenStreetMap. A course that is not there is added as it is. A
    /// course that is there is added with its OpenStreetMap data, once the user has assigned its
    /// holes to sub-courses.
    private func lookUpOSM(for course: Course) {
        pendingCourse = course
        osmResult = nil
        centerlineGroups = []
        lookupStatus = ""
        step = .lookingUp
        lookupTask = Task {
            do {
                let result = try await OSMCourseImport.fetch(around: course.location.coordinate) { lookupStatus = $0 }
                guard !Task.isCancelled else { return }
                guard OSMCheck.hasCourseData(result) else {
                    fetchElevations(for: course, baseline: nil)
                    return
                }
                let groups = OSMCourseImport.centerlineGroups(
                    from: result.centerlines,
                    subCourseSizes: course.subCourses.map(\.holes.count)
                )
                // With no hole lines there is nothing to assign.
                guard !groups.isEmpty else {
                    let imported = OSMCourseImport.apply(result, groups: [], to: course)
                    fetchElevations(for: imported.course, baseline: imported.baseline)
                    return
                }
                osmResult = result
                centerlineGroups = groups
                step = .assigning
            } catch {
                guard !Task.isCancelled else { return }
                step = .lookupFailed(error.localizedDescription)
            }
        }
    }

    /// Takes the user's sub-course choices, then goes on to the elevations.
    private func addAssignedCourse() {
        guard let pendingCourse, let osmResult else { return }
        let imported = OSMCourseImport.apply(osmResult, groups: centerlineGroups, to: pendingCourse)
        fetchElevations(for: imported.course, baseline: imported.baseline)
    }

    // MARK: - Elevations

    /// Starts fetching what a course still needs before it can be added: what its OpenStreetMap
    /// record lacks, then its elevations.
    private func fetchElevations(for course: Course, baseline: OSMBaseline?, status: ElevationStatus = ElevationStatus()) {
        elevationCourse = course
        importedBaseline = baseline
        elevationStatus = status
        fetchElevations()
    }

    /// Fetches what is still missing, then adds the course. Where USGS has no data the course
    /// is added without it. If a fetch fails, the user can retry or cancel.
    private func fetchElevations() {
        guard var course = elevationCourse else { return }
        var status = elevationStatus
        var baseline = importedBaseline
        let needsOSM = baseline.map { OSMBaselineFetch.isNeeded(for: $0, course: course) } ?? false
        let needsElevations = CourseElevationFetch.isNeeded(for: course, status: status)
        // With nothing to fetch there is nothing to show.
        guard needsOSM || needsElevations else {
            add(course, status: status)
            return
        }
        let oldStatus = status
        elevationProgress = nil
        osmRecordProgress = nil
        step = .fetchingElevations
        elevationTask = Task {
            do {
                if needsOSM, var record = baseline {
                    defer { baseline = record }
                    try await OSMBaselineFetch.run(baseline: &record, course: &course) { osmRecordProgress = $0 }
                    guard !Task.isCancelled else { return }
                    importedBaseline = record
                }
                osmRecordProgress = nil
                try await CourseElevationFetch.run(course: &course, status: &status) { elevationProgress = $0 }
                guard !Task.isCancelled else { return }
                step = .elevationsDone(CourseElevationFetch.noDataMessage(from: oldStatus, to: status)
                    ?? (needsElevations ? "The elevations were fetched." : "The OpenStreetMap data was fetched."))
                try await Task.sleep(for: ElevationFetchDialog.closeDelay)
                add(course, status: status)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                // Keeps what was fetched, so Retry carries on from here.
                elevationCourse = course
                elevationStatus = status
                importedBaseline = baseline
                step = .elevationsFailed(error.localizedDescription)
            }
        }
    }

    /// Saves what goes with the course, then adds the course. The course is not added if that
    /// fails: without the OpenStreetMap record, publishing would treat every feature as changed,
    /// and without the elevation record, the app would keep asking USGS for data it does not have.
    private func add(_ course: Course, status: ElevationStatus) {
        do {
            if let importedBaseline {
                try OSMBaselineStore().save(importedBaseline, courseID: course.id)
            }
            try ElevationStatusStore().save(status, courseID: course.id)
            onCreate(course)
        } catch {
            step = .elevationsFailed("Could not save the course's data: \(error.localizedDescription)")
        }
    }

    private func reverseGeocode(latitude: Double, longitude: Double, completion: @escaping (_ address: String, _ city: String, _ state: String, _ country: String, _ error: String?) -> Void) {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        if #available(macOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location) else {
                completion("", "", "", "", "Failed to create geocoding request")
                return
            }
            request.getMapItems { mapItems, error in
                let pm = mapItems?.first?.placemark
                let errMsg = pm == nil ? (error?.localizedDescription ?? "No location found for these coordinates") : nil
                DispatchQueue.main.async {
                    completion(
                        pm?.thoroughfare ?? "",
                        pm?.locality ?? "",
                        pm?.administrativeArea ?? "",
                        pm?.isoCountryCode ?? "",
                        errMsg
                    )
                }
            }
        } else {
            let geocoder = CLGeocoder()
            geocoder.reverseGeocodeLocation(location) { placemarks, error in
                let pm = placemarks?.first
                let errMsg = pm == nil ? (error?.localizedDescription ?? "No location found for these coordinates") : nil
                DispatchQueue.main.async {
                    completion(
                        pm?.thoroughfare ?? "",
                        pm?.locality ?? "",
                        pm?.administrativeArea ?? "",
                        pm?.isoCountryCode ?? "",
                        errMsg
                    )
                }
            }
        }
    }
}

/// Lets the user resize the sheet it is placed in, and grows the sheet to `size`.
///
/// A sheet is as big as its content and cannot be resized. With a `size`, the sheet's window is
/// made resizable and set to that size once. With `nil`, it goes back to fitting its content.
private struct SheetResizing: NSViewRepresentable {
    let size: CGSize?

    final class Coordinator {
        var appliedSize: CGSize?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        let size = size
        let coordinator = context.coordinator
        // The view has no window until the sheet is on screen.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            guard let size else {
                window.styleMask.remove(.resizable)
                coordinator.appliedSize = nil
                return
            }
            window.styleMask.insert(.resizable)
            guard coordinator.appliedSize != size else { return }
            coordinator.appliedSize = size
            // Grow from the top center, where a sheet hangs from.
            let old = window.frame
            let new = window.frameRect(forContentRect: CGRect(origin: .zero, size: size)).size
            window.setFrame(
                CGRect(x: old.midX - new.width / 2, y: old.maxY - new.height, width: new.width, height: new.height),
                display: true,
                animate: true
            )
        }
    }
}
