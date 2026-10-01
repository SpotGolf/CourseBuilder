import SwiftUI
import CourseDataSwift

/// Alerts the user that a course file is missing elevations.
///
/// Set `course` to a loaded course that needs updating. Cancel drops the course (it is not loaded).
/// Continue looks up the elevations and passes the updated course to `onUpdated`. If USGS has no
/// data because the course is outside the United States, the missing elevations are set to sea level,
/// the course is passed to `onUpdated`, and a warning is shown. If the lookup fails for any other
/// reason, an error is shown and the course is not loaded.
struct ElevationUpdatePrompt: ViewModifier {
    @Binding var course: Course?
    let onUpdated: (Course) throws -> Void

    @State private var updateTask: Task<Void, Never>?
    @State private var completed = 0
    @State private var total = 0
    @State private var errorMessage: String?
    @State private var warningCourseName: String?

    func body(content: Content) -> some View {
        content
            .alert(
                "Course Needs Updating",
                isPresented: Binding(get: { course != nil }, set: { if !$0 { course = nil } }),
                presenting: course
            ) { course in
                Button("Cancel", role: .cancel) {}
                Button("Continue") { update(course) }
                    .keyboardShortcut(.defaultAction)
            } message: { course in
                Text("\"\(course.name)\" is missing elevations. Continue to look them up from USGS and update the file.")
            }
            .sheet(isPresented: Binding(get: { updateTask != nil }, set: { _ in })) {
                VStack(spacing: 12) {
                    Text("Updating Elevations")
                        .font(.headline)
                    if total > 0 {
                        ProgressView(value: Double(completed), total: Double(total))
                        Text("\(completed) of \(total) points")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                    Button("Cancel") { updateTask?.cancel() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(24)
                .frame(width: 300)
                .interactiveDismissDisabled()
            }
            .alert(
                "Elevation Update Failed",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
                presenting: errorMessage
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text("\(message)\n\nThe course was not loaded.")
            }
            .alert(
                "Elevations Set to Sea Level",
                isPresented: Binding(get: { warningCourseName != nil }, set: { if !$0 { warningCourseName = nil } }),
                presenting: warningCourseName
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { name in
                Text("\"\(name)\" is outside the United States, so USGS has no elevation data for it. All missing elevations were set to sea level (0 m).")
            }
    }

    @MainActor
    private func update(_ course: Course) {
        completed = 0
        total = 0
        updateTask = Task {
            do {
                let updated = try await ElevationUpdater.update(course) { completed, total in
                    Task { @MainActor in
                        self.completed = completed
                        self.total = total
                    }
                }
                try Task.checkCancellation()
                try onUpdated(updated)
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch let error as USGSElevationClient.ElevationError where error.isOutsideUnitedStates {
                do {
                    try onUpdated(ElevationUpdater.fillingMissingElevations(of: course, with: 0))
                    warningCourseName = course.name
                } catch {
                    errorMessage = error.localizedDescription
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            updateTask = nil
        }
    }
}

extension View {
    func elevationUpdatePrompt(for course: Binding<Course?>, onUpdated: @escaping (Course) throws -> Void) -> some View {
        modifier(ElevationUpdatePrompt(course: course, onUpdated: onUpdated))
    }
}
