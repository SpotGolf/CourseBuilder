import SwiftUI

/// A line between two panels. Dragging it resizes the panel beside it.
///
/// The map editor lays its panels out with plain stacks and these dividers, not with
/// `HSplitView` and `VSplitView`. A split view sizes its panels by itself, and its idea of a
/// panel's size can differ from the size the panel's content is laid out at, which leaves an
/// empty strip beside the content.
struct PanelDivider: View {
    enum Direction {
        /// The line is upright and the panel to resize is on its left.
        case leading
        /// The line is upright and the panel to resize is on its right.
        case trailing
        /// The line lies flat and the panel to resize is above it.
        case above
    }

    let direction: Direction
    /// The panel's width or height.
    @Binding var size: Double
    let range: ClosedRange<Double>
    /// False draws the line but does not let it be dragged.
    var isEnabled = true

    /// The panel's size when the drag began.
    @State private var startSize: Double?
    @State private var isHovering = false

    private var isUpright: Bool { direction != .above }

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: isUpright ? 1 : nil, height: isUpright ? nil : 1)
            .overlay {
                if isEnabled {
                    // Wider than the line, so it is easy to grab.
                    Color.clear
                        .frame(width: isUpright ? 9 : nil, height: isUpright ? nil : 9)
                        .contentShape(Rectangle())
                        .gesture(drag)
                        .onHover { hovering in
                            guard hovering != isHovering else { return }
                            isHovering = hovering
                            if hovering {
                                (isUpright ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                }
            }
            .zIndex(1)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = startSize ?? size
                startSize = start
                size = Self.size(from: start, translation: value.translation, direction: direction, range: range)
            }
            .onEnded { _ in startSize = nil }
    }

    /// The panel's size after a drag, kept inside `range`.
    static func size(from start: Double, translation: CGSize, direction: Direction, range: ClosedRange<Double>) -> Double {
        let change: Double
        switch direction {
        case .leading: change = translation.width
        case .trailing: change = -translation.width
        case .above: change = translation.height
        }
        return min(max(start + change, range.lowerBound), range.upperBound)
    }
}
