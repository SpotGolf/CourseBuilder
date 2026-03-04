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
            NewCourseSheet { course in
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

struct NewCourseSheet: View {
    let onCreate: (Course) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var city = ""
    @State private var state = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("New Course").font(.title2)
            TextField("Course Name", text: $name)
            TextField("City", text: $city)
            TextField("State (abbreviation)", text: $state)
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let course = Course(
                        name: name,
                        location: CourseLocation(
                            address: "",
                            city: city,
                            state: state,
                            country: "",
                            coordinate: Coordinate(latitude: 0, longitude: 0)
                        ),
                        holes: (1...18).map { Hole(number: $0, par: 4) }
                    )
                    onCreate(course)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || city.isEmpty || state.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 350)
    }
}
