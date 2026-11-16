import Foundation
import Testing
@testable import CourseBuilder

@Suite("Panel divider")
struct PanelDividerTests {
    private let range = 200.0...480.0

    @Test func draggingRightWidensThePanelOnTheLeft() {
        #expect(PanelDivider.size(from: 260, translation: CGSize(width: 40, height: 9), direction: .leading, range: range) == 300)
    }

    @Test func draggingRightNarrowsThePanelOnTheRight() {
        #expect(PanelDivider.size(from: 260, translation: CGSize(width: 40, height: 9), direction: .trailing, range: range) == 220)
    }

    @Test func draggingDownMakesThePanelAboveTaller() {
        #expect(PanelDivider.size(from: 260, translation: CGSize(width: 9, height: 40), direction: .above, range: range) == 300)
    }

    @Test func sizeStaysInsideItsRange() {
        #expect(PanelDivider.size(from: 260, translation: CGSize(width: -500, height: 0), direction: .leading, range: range) == 200)
        #expect(PanelDivider.size(from: 260, translation: CGSize(width: 500, height: 0), direction: .leading, range: range) == 480)
    }
}
