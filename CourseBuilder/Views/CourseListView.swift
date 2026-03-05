import SwiftUI

struct CourseListView: View {
    @EnvironmentObject var store: CourseStore
    @State private var showNewCourse = false
    @State private var showDeleteConfirmation = false
    @State private var selectedCourse: Course?

    var body: some View {
        NavigationSplitView {
            List(store.courses, selection: $selectedCourse) { course in
                NavigationLink(value: course) {
                    VStack(alignment: .leading) {
                        Text(course.name)
                            .font(.headline)
                        Text("\(course.location.city), \(course.location.state)")
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
            if let course = selectedCourse {
                ScorecardView(course: course)
                    .id(course.id)
            } else {
                Text("Select a course or create a new one")
                    .foregroundStyle(.secondary)
            }
        }
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
                    selectedCourse = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
        .onAppear {
            try? store.loadAll()
        }
    }
}

struct AddCourseSheet: View {
    let onCreate: (Course) -> Void

    enum Tab: Hashable {
        case search, manualEntry, importFile
    }

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: Tab = .search

    // Search fields
    @AppStorage("golfCourseAPIKey") private var apiKey: String = ""
    @State private var searchQuery = ""
    @State private var searchResults: [GolfCourseAPIClient.CourseSearchResult] = []
    @State private var selectedClubName: String?
    @State private var checkedResultIDs: Set<Int> = []
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
    @State private var address = ""
    @State private var city = ""
    @State private var state = ""
    @State private var country = ""
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var holeCount = 18

    private var groupedResults: [(clubName: String, courses: [GolfCourseAPIClient.CourseSearchResult])] {
        var groups: [String: [GolfCourseAPIClient.CourseSearchResult]] = [:]
        var order: [String] = []
        for result in searchResults {
            if groups[result.clubName] == nil {
                order.append(result.clubName)
            }
            groups[result.clubName, default: []].append(result)
        }
        return order.map { (clubName: $0, courses: groups[$0]!) }
    }

    private var canAdd: Bool {
        switch selectedTab {
        case .search:
            return !checkedResultIDs.isEmpty
        case .manualEntry:
            return !name.isEmpty && !city.isEmpty && !state.isEmpty
        case .importFile:
            return importedCourse != nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                searchTab
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag(Tab.search)

                manualEntryTab
                    .tabItem { Label("Manual Entry", systemImage: "square.and.pencil") }
                    .tag(Tab.manualEntry)

                importTab
                    .tabItem { Label("Import", systemImage: "square.and.arrow.down") }
                    .tag(Tab.importFile)
            }
            .padding(.top, 8)
            .frame(width: 450, height: 370)

            Divider()

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
        }
        .alert("Error", isPresented: $showFetchError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(fetchErrorMessage)
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
            HStack {
                TextField("Latitude", text: $latitude)
                TextField("Longitude", text: $longitude)
            }
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
                    Text("\(course.location.city), \(course.location.state)")
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
                List {
                    ForEach(groupedResults, id: \.clubName) { group in
                        let isSelected = selectedClubName == group.clubName
                        HStack {
                            Image(systemName: isSelected ? "chevron.down" : "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                            VStack(alignment: .leading) {
                                Text(group.clubName)
                                    .font(.headline)
                                if let loc = group.courses.first?.location {
                                    Text("\(loc.city), \(loc.state)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isSelected {
                                selectedClubName = nil
                                checkedResultIDs = []
                            } else {
                                selectedClubName = group.clubName
                                checkedResultIDs = Set(group.courses.map(\.id))
                            }
                        }

                        if isSelected {
                            ForEach(group.courses, id: \.id) { result in
                                Toggle(isOn: Binding(
                                    get: { checkedResultIDs.contains(result.id) },
                                    set: { checked in
                                        if checked {
                                            checkedResultIDs.insert(result.id)
                                        } else {
                                            checkedResultIDs.remove(result.id)
                                        }
                                    }
                                )) {
                                    Text(result.courseName)
                                        .font(.subheadline)
                                }
                                .toggleStyle(.checkbox)
                                .padding(.leading, 24)
                            }
                        }
                    }
                }
            }
        }
    }

    private func addCourse() {
        switch selectedTab {
        case .search:
            guard !checkedResultIDs.isEmpty else { return }
            let selected = searchResults.filter { checkedResultIDs.contains($0.id) }
            fetchAndAddCourses(selected)
        case .importFile:
            if let course = importedCourse {
                // Assign a new ID so it doesn't collide with any existing course
                let newCourse = Course(
                    name: course.name,
                    clubName: course.clubName,
                    golfCourseAPIIds: course.golfCourseAPIIds,
                    location: course.location,
                    tees: course.tees,
                    subCourses: course.subCourses
                )
                onCreate(newCourse)
            }
        case .manualEntry:
            let subCourseCount = holeCount / 9
            let subCourseNames = ["Front", "Back", "Third"]
            var subCourses: [SubCourse] = []
            for i in 0..<subCourseCount {
                let holes = (1...9).map { Hole(number: $0, par: 4) }
                subCourses.append(SubCourse(name: subCourseNames[i], holes: holes))
            }
            let course = Course(
                name: name,
                clubName: clubName,
                location: CourseLocation(
                    address: address,
                    city: city,
                    state: state,
                    country: country,
                    coordinate: Coordinate(latitude: Double(latitude) ?? 0, longitude: Double(longitude) ?? 0)
                ),
                subCourses: subCourses
            )
            onCreate(course)
        }
    }

    private func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            importedCourse = try JSONDecoder().decode(Course.self, from: data)
            importError = ""
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
        selectedClubName = nil
        checkedResultIDs = []
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
                let course = GolfCourseAPIClient.convertToCourse(details: details)
                onCreate(course)
            } catch {
                fetchErrorMessage = "Failed to fetch course: \(error.localizedDescription)"
                showFetchError = true
            }
            isFetching = false
        }
    }
}
