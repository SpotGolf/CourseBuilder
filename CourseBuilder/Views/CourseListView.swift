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

    // Manual entry fields
    @State private var clubName = ""
    @State private var name = ""
    @State private var address = ""
    @State private var city = ""
    @State private var state = ""
    @State private var country = ""
    @State private var holeCount = 18

    private var canAddManual: Bool {
        !name.isEmpty && !city.isEmpty && !state.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                Text("Search coming soon")
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
                Button("Add") { addCourse() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedTab == .search || (selectedTab == .manualEntry && !canAddManual))
            }
            .padding()
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

    private func addCourse() {
        guard selectedTab == .manualEntry else { return }
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
