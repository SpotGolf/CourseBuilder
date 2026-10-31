import SwiftUI

/// Actions for the map editor window in front. An action is nil when its menu item is disabled.
struct MapActions {
    var camera: MapCamera
    /// The tool in use, for the check mark in the menu.
    var activeTool: ToolMode
    /// Switches to a tool. Nil for a tool that is not available.
    var selectTool: (ToolMode) -> (() -> Void)?
    var imageryLayer: ImageryLayer
    var setImageryLayer: (ImageryLayer) -> Void
    var importOSM: (() -> Void)?
}

extension FocusedValues {
    /// The map editor window in front. Nil while one of its sheets is open, so the
    /// single-key shortcuts do not take typing from the sheet.
    @Entry var mapActions: MapActions?
}

/// The Map menu, for the map editor window in front.
struct MapCommands: Commands {
    @FocusedValue(\.mapActions) private var actions

    var body: some Commands {
        CommandMenu("Map") {
            ForEach(ToolMode.allCases, id: \.self) { mode in
                let action = actions?.selectTool(mode)
                Toggle(mode.menuTitle, isOn: Binding(
                    get: { actions?.activeTool == mode },
                    set: { _ in action?() }
                ))
                .keyboardShortcut(KeyEquivalent(mode.shortcutKey), modifiers: [])
                .disabled(action == nil)
            }
            Divider()
            Picker("Imagery", selection: Binding(
                get: { actions?.imageryLayer ?? .esri },
                set: { actions?.setImageryLayer($0) }
            )) {
                ForEach(ImageryLayer.allCases) { layer in
                    Text(layer.name).tag(layer)
                }
            }
            .disabled(actions == nil)
            Button("Next Imagery") {
                if let actions { actions.setImageryLayer(actions.imageryLayer.next) }
            }
            .keyboardShortcut("v", modifiers: [])
            .disabled(actions == nil)
            Divider()
            Button("Zoom In") { actions?.camera.zoomIn() }
                .keyboardShortcut("+")
                .disabled(actions == nil)
            Button("Zoom Out") { actions?.camera.zoomOut() }
                .keyboardShortcut("-")
                .disabled(actions == nil)
            Divider()
            Button("Import OSM…") { actions?.importOSM?() }
                .disabled(actions?.importOSM == nil)
        }
    }
}
