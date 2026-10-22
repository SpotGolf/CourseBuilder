import Testing
@testable import CourseBuilder

@Suite("Unassociated selection")
struct UnassociatedSelectionTests {
    private let unassociated: Set<Int> = [4, 5, 6]

    @Test func selectedHoleFeatureClearsRows() {
        let rows = UnassociatedSelection.rows(selectedFeatureID: 1, multiSelection: [4, 5], unassociatedIDs: unassociated, showsIgnored: false)
        #expect(rows.isEmpty)
    }

    @Test func selectedUnassociatedFeatureIsTheOnlyRow() {
        let rows = UnassociatedSelection.rows(selectedFeatureID: 5, multiSelection: [4, 6], unassociatedIDs: unassociated, showsIgnored: false)
        #expect(rows == [5])
    }

    @Test func severalRowsWithoutSelectedFeature() {
        let rows = UnassociatedSelection.rows(selectedFeatureID: nil, multiSelection: [4, 6], unassociatedIDs: unassociated, showsIgnored: false)
        #expect(rows == [4, 6])
    }

    @Test func ignoredListUsesItsOwnRows() {
        let rows = UnassociatedSelection.rows(selectedFeatureID: 5, multiSelection: [9], unassociatedIDs: unassociated, showsIgnored: true)
        #expect(rows == [9])
    }

    @Test func pickingOneRowSelectsTheFeature() {
        #expect(UnassociatedSelection.outcome(of: [5], showsIgnored: false) == .selectFeature(5))
        #expect(UnassociatedSelection.outcome(of: [4, 5], showsIgnored: false) == .rows([4, 5]))
        #expect(UnassociatedSelection.outcome(of: [9], showsIgnored: true) == .rows([9]))
        #expect(UnassociatedSelection.outcome(of: [], showsIgnored: false) == .rows([]))
    }
}
