import SwiftUI

struct CourseListView: View {
    @EnvironmentObject var store: CourseStore
    @State private var showNewCourse = false
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
                        Text("\(course.holes.count) holes")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .navigationTitle("Courses")
            .safeAreaInset(edge: .bottom) {
                Button {
                    showNewCourse = true
                } label: {
                    Image(systemName: "plus")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        } detail: {
            if let course = selectedCourse {
                ScorecardImportView(course: course)
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
        .onAppear {
            try? store.loadAll()
        }
    }
}

struct AddCourseSheet: View {
    let onCreate: (Course) -> Void

    enum Tab: Hashable {
        case search, manualEntry
    }

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: Tab = .search

    // Search fields
    @AppStorage("golfCourseAPIKey") private var apiKey: String = ""
    @State private var searchQuery = ""
    @State private var searchResults: [GolfCourseAPIClient.CourseSearchResult] = []
    @State private var selectedResult: GolfCourseAPIClient.CourseSearchResult?
    @State private var isSearching = false
    @State private var searchError = ""
    @State private var isFetching = false
    @State private var showFetchError = false
    @State private var fetchErrorMessage = ""

    // Manual entry fields
    @State private var clubName = ""
    @State private var name = ""
    @State private var address = ""
    @State private var city = ""
    @State private var state = ""
    @State private var country = ""
    @State private var holeCount = 18

    private var canAdd: Bool {
        switch selectedTab {
        case .search:
            return selectedResult != nil
        case .manualEntry:
            return !name.isEmpty && !city.isEmpty && !state.isEmpty
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
            }
            .frame(width: 450, height: 350)

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
            Picker("Holes", selection: $holeCount) {
                Text("9").tag(9)
                Text("18").tag(18)
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
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
                List(searchResults, id: \.id, selection: $selectedResult) { result in
                    VStack(alignment: .leading) {
                        Text(result.courseName)
                            .font(.headline)
                        Text("\(result.location.city), \(result.location.state)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(result)
                }
            }
        }
    }

    private func addCourse() {
        switch selectedTab {
        case .search:
            guard let result = selectedResult else { return }
            fetchAndAddCourse(result)
        case .manualEntry:
            let course = Course(
                name: name,
                clubName: clubName,
                location: CourseLocation(
                    address: address,
                    city: city,
                    state: state,
                    country: country,
                    coordinate: Coordinate(latitude: 0, longitude: 0)
                ),
                holes: (1...holeCount).map { Hole(number: $0, par: 4) }
            )
            onCreate(course)
        }
    }

    private func searchCourses() {
        guard !apiKey.isEmpty, !searchQuery.isEmpty else { return }
        isSearching = true
        searchError = ""
        searchResults = []
        selectedResult = nil
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

    private func fetchAndAddCourse(_ result: GolfCourseAPIClient.CourseSearchResult) {
        isFetching = true
        Task {
            do {
                let client = GolfCourseAPIClient(apiKey: apiKey)
                let detail = try await client.fetchCourse(id: result.id)
                let course = GolfCourseAPIClient.convertToCourse(detail: detail)
                onCreate(course)
            } catch {
                fetchErrorMessage = "Failed to fetch course: \(error.localizedDescription)"
                showFetchError = true
            }
            isFetching = false
        }
    }
}
