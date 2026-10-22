import SwiftUI

extension FocusedValues {
    /// The camera of the map editor window in front.
    @Entry var mapCamera: MapCamera?
}

/// Zoom In and Zoom Out in the View menu, for the map editor window in front.
struct MapCommands: Commands {
    @FocusedValue(\.mapCamera) private var camera

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Zoom In") { camera?.zoomIn() }
                .keyboardShortcut("+")
                .disabled(camera == nil)
            Button("Zoom Out") { camera?.zoomOut() }
                .keyboardShortcut("-")
                .disabled(camera == nil)
            Divider()
        }
    }
}
