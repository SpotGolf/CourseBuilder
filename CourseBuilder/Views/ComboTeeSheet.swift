import SwiftUI
import CourseDataSwift

/// Turns a tee into a combo tee, or edits an existing combo tee. The user picks the 2 tees that
/// make up the combo and which of them each hole plays from. For a new combo tee both are filled
/// in from the tee's name and yardages. For an existing one they are filled in from the course.
struct ComboTeeSheet: View {
    @Binding var course: Course
    let teeName: String
    let onDismiss: () -> Void
    /// Whether `teeName` is an existing combo tee rather than a tee to convert.
    private let isEditing: Bool

    @State private var firstTee: String
    @State private var secondTee: String
    @State private var assignments: [ComboTeeBuilder.HolePosition: String]

    init(course: Binding<Course>, teeName: String, onDismiss: @escaping () -> Void) {
        _course = course
        self.teeName = teeName
        self.onDismiss = onDismiss
        let existing = course.wrappedValue.comboTees.first { $0.name == teeName }
        isEditing = existing != nil
        let components = existing?.tees ?? ComboTeeBuilder.guessComponents(for: teeName, in: course.wrappedValue)
        let first = components.count > 0 ? components[0] : ""
        let second = components.count > 1 ? components[1] : ""
        _firstTee = State(initialValue: first)
        _secondTee = State(initialValue: second)
        if existing != nil {
            _assignments = State(initialValue: ComboTeeBuilder.assignments(forComboNamed: teeName, in: course.wrappedValue))
        } else {
            _assignments = State(initialValue: ComboTeeBuilder.guessAssignments(
                for: teeName,
                components: [first, second].filter { !$0.isEmpty },
                in: course.wrappedValue
            ))
        }
    }

    private var otherTees: [String] {
        course.tees.map(\.name).filter { $0 != teeName }
    }

    private var selectedTees: [String] {
        [firstTee, secondTee].filter { !$0.isEmpty }
    }

    private var allPositions: [ComboTeeBuilder.HolePosition] {
        course.subCourses.indices.flatMap { subCourseIndex in
            course.subCourses[subCourseIndex].holes.indices.map {
                ComboTeeBuilder.HolePosition(subCourseIndex: subCourseIndex, holeIndex: $0)
            }
        }
    }

    private var unassignedCount: Int {
        allPositions.filter { assignments[$0] == nil }.count
    }

    private var canConvert: Bool {
        !firstTee.isEmpty && !secondTee.isEmpty && firstTee != secondTee && unassignedCount == 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isEditing ? "Edit Combo Tee \"\(teeName)\"" : "Make \"\(teeName)\" a Combo Tee")
                .font(.headline)

            HStack(spacing: 12) {
                teePicker("First Tee", selection: $firstTee)
                teePicker("Second Tee", selection: $secondTee)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(course.subCourses.indices, id: \.self) { subCourseIndex in
                        subCourseSection(subCourseIndex)
                    }
                }
            }
            .frame(height: 360)

            if firstTee == secondTee && !firstTee.isEmpty {
                Text("Pick 2 different tees.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if unassignedCount > 0 {
                Text("\(unassignedCount) holes have no tee picked.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Make Combo Tee") {
                    if isEditing {
                        ComboTeeBuilder.update(
                            comboNamed: teeName,
                            components: [firstTee, secondTee],
                            assignments: assignments,
                            in: &course
                        )
                    } else {
                        ComboTeeBuilder.convert(
                            teeNamed: teeName,
                            components: [firstTee, secondTee],
                            assignments: assignments,
                            in: &course
                        )
                    }
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConvert)
            }
        }
        .padding()
        .frame(width: 520)
        .onChange(of: firstTee) { reguessAssignments() }
        .onChange(of: secondTee) { reguessAssignments() }
    }

    private func teePicker(_ label: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Picker(label, selection: selection) {
                Text("None").tag("")
                ForEach(otherTees, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
        }
    }

    private func subCourseSection(_ subCourseIndex: Int) -> some View {
        let subCourse = course.subCourses[subCourseIndex]
        return VStack(alignment: .leading, spacing: 4) {
            Text(subCourse.name).bold()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Hole").bold().frame(width: 40, alignment: .leading)
                    if !isEditing {
                        Text(teeName).bold().frame(width: 80, alignment: .leading)
                    }
                    Text("Plays From").bold()
                }
                Divider()
                ForEach(subCourse.holes.indices, id: \.self) { holeIndex in
                    let hole = subCourse.holes[holeIndex]
                    let position = ComboTeeBuilder.HolePosition(subCourseIndex: subCourseIndex, holeIndex: holeIndex)
                    GridRow {
                        Text("\(hole.number)").frame(width: 40, alignment: .leading)
                        if !isEditing {
                            Text(hole.yardages[teeName].map { "\($0)" } ?? "-")
                                .frame(width: 80, alignment: .leading)
                        }
                        Picker("Plays From", selection: Binding(
                            get: { assignments[position] },
                            set: { assignments[position] = $0 }
                        )) {
                            ForEach(selectedTees, id: \.self) { name in
                                Text("\(name) (\(hole.yardages[name].map { "\($0)" } ?? "-"))")
                                    .tag(String?.some(name))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .background(assignments[position] == nil ? Color.orange.opacity(0.2) : Color.clear)
                    }
                }
            }
        }
    }

    /// A new combo tee is guessed again from its yardages. An existing combo tee has no yardages,
    /// so it keeps the holes whose tee is still picked and clears the rest.
    private func reguessAssignments() {
        if isEditing {
            assignments = assignments.filter { selectedTees.contains($0.value) }
        } else {
            assignments = ComboTeeBuilder.guessAssignments(for: teeName, components: selectedTees, in: course)
        }
    }
}
