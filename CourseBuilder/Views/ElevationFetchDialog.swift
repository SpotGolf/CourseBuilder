import SwiftUI
import CourseDataSwift

/// A fetch of what a course is missing, shown to the user in a dialog: what its OpenStreetMap
/// record lacks, then its elevations and green surfaces.
struct ElevationFetchRequest: Identifiable {
    /// What the user is told before a Cancel that loses work.
    struct CancelWarning {
        var title: String
        var message: String
        /// The label of the button that gives the work up, such as "Delete".
        var confirmLabel: String
    }

    let id = UUID()
    /// The course to fetch for.
    var course: Course
    /// What USGS is already known not to have for the course.
    var status: ElevationStatus
    /// The course's OpenStreetMap record. When set, what it is missing is fetched first.
    var osmBaseline: OSMBaseline?
    /// Called with the record, right before `onFinished`, when what it was missing was fetched.
    /// The caller saves it.
    var onOSMBaselineFetched: (OSMBaseline) throws -> Void = { _ in }
    /// Shown when the user cancels. Nil when cancelling loses nothing.
    var cancelWarning: CancelWarning?
    /// Called once with the course and its status when the fetch is done. The caller saves them.
    /// The dialog stays open for a moment after this.
    var onFinished: (Course, ElevationStatus) throws -> Void
    /// Called when the user gives up. Nothing was saved.
    var onCancelled: () -> Void = {}
}

/// Fetches what the request asks for and shows how far along it is.
///
/// When the fetch is done the dialog says so, then closes by itself after ``closeDelay``. If the
/// fetch fails the user can retry, which carries on from where it stopped, or cancel.
struct ElevationFetchDialog: View {
    /// How long the dialog stays open once the fetch is done.
    static let closeDelay: Duration = .seconds(2)

    let request: ElevationFetchRequest
    let close: () -> Void

    private enum Phase: Equatable {
        case fetching
        case failed(title: String, message: String)
        case done(String)
    }

    private static let osmFailureTitle = "The OpenStreetMap data could not be fetched."
    private static let elevationFailureTitle = "The elevations could not be fetched."

    @State private var phase: Phase = .fetching
    @State private var progress: CourseElevationFetch.Progress?
    /// Set while the OpenStreetMap record is being fetched.
    @State private var osmProgress: OSMBaselineFetch.Progress?
    /// The record with what was fetched so far.
    @State private var osmBaseline: OSMBaseline?
    @State private var task: Task<Void, Never>?
    /// The course and status with what was fetched so far.
    @State private var course: Course?
    @State private var status: ElevationStatus?
    @State private var isShowingCancelWarning = false

    var body: some View {
        VStack(spacing: 16) {
            switch phase {
            case .fetching:
                if let osmProgress {
                    FetchProgressView(title: "Fetching OpenStreetMap data", detail: osmProgress.message)
                } else {
                    ElevationFetchProgressView(progress: progress)
                }
            case .failed(let title, let message):
                ElevationFetchFailureView(title: title, message: message)
            case .done(let message):
                ElevationFetchDoneView(message: message)
            }

            HStack {
                if !isDone {
                    Button("Cancel") { cancel() }
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                if case .failed = phase {
                    Button("Retry") { start() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 380)
        .interactiveDismissDisabled()
        .onAppear { start() }
        .onDisappear { task?.cancel() }
        .alert(
            request.cancelWarning?.title ?? "",
            isPresented: $isShowingCancelWarning,
            presenting: request.cancelWarning
        ) { warning in
            Button(warning.confirmLabel, role: .destructive) { giveUp() }
            if case .failed = phase {
                Button("Retry") { start() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Keep Fetching", role: .cancel) {}
            }
        } message: { warning in
            Text(warning.message)
        }
    }

    private var isDone: Bool {
        if case .done = phase { true } else { false }
    }

    /// Fetches what is still missing.
    private func start() {
        task?.cancel()
        var course = course ?? request.course
        var status = status ?? request.status
        var baseline = osmBaseline ?? request.osmBaseline
        progress = nil
        osmProgress = nil
        phase = .fetching
        task = Task {
            var failureTitle = Self.osmFailureTitle
            do {
                var fetchedRecord: OSMBaseline?
                if var record = baseline, OSMBaselineFetch.isNeeded(for: record, course: course) {
                    defer { baseline = record }
                    try await OSMBaselineFetch.run(baseline: &record, course: &course) { osmProgress = $0 }
                    try Task.checkCancellation()
                    fetchedRecord = record
                }
                osmProgress = nil

                failureTitle = Self.elevationFailureTitle
                let neededElevations = CourseElevationFetch.isNeeded(for: course, status: status)
                try await CourseElevationFetch.run(course: &course, status: &status) { progress = $0 }
                try Task.checkCancellation()
                failureTitle = "The course could not be saved."
                // The record and the course are saved together: the record remembers what was
                // looked for, and the course holds what was found.
                if let fetchedRecord {
                    try request.onOSMBaselineFetched(fetchedRecord)
                }
                try request.onFinished(course, status)

                phase = .done(CourseElevationFetch.noDataMessage(from: request.status, to: status)
                    ?? (neededElevations ? "The elevations were fetched." : "The OpenStreetMap data was fetched."))
                try await Task.sleep(for: Self.closeDelay)
                close()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                // Keeps what was fetched, so Retry carries on from here.
                self.course = course
                self.status = status
                osmBaseline = baseline
                phase = .failed(title: failureTitle, message: error.localizedDescription)
            }
        }
    }

    private func cancel() {
        if request.cancelWarning != nil {
            isShowingCancelWarning = true
        } else {
            giveUp()
        }
    }

    private func giveUp() {
        task?.cancel()
        request.onCancelled()
        close()
    }
}

/// How far along a fetch is.
struct FetchProgressView: View {
    let title: String
    let detail: String
    /// From 0 to 1. Nil shows a spinner.
    var fraction: Double?
    var note: String?

    var body: some View {
        VStack(spacing: 16) {
            if let fraction {
                ProgressView(value: fraction)
                    .frame(width: 280)
            } else {
                ProgressView()
            }
            VStack(spacing: 4) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
        }
    }
}

/// How far along an elevation fetch is.
struct ElevationFetchProgressView: View {
    let progress: CourseElevationFetch.Progress?

    var body: some View {
        FetchProgressView(
            title: "Fetching elevations from USGS",
            detail: progress?.message ?? "Starting...",
            fraction: progress?.fraction,
            note: "This can take a few minutes for a large course."
        )
    }
}

/// Tells the user a fetch is done.
struct ElevationFetchDoneView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("Done")
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Tells the user a fetch failed, and why.
struct ElevationFetchFailureView: View {
    var title = "The elevations could not be fetched."
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            Text(title)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Retry carries on from where the fetch stopped.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// Shows the fetch dialog while `request` is set.
    func elevationFetchDialog(_ request: Binding<ElevationFetchRequest?>) -> some View {
        sheet(item: request) { item in
            ElevationFetchDialog(request: item) { request.wrappedValue = nil }
        }
    }
}
