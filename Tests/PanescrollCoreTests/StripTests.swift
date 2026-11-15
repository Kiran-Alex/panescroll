import XCTest
@testable import PanescrollCore

final class StripTests: XCTestCase {
    private let gap: CGFloat = 8

    /// A strip with empty columns of the given widths (geometry only).
    private func strip(_ widths: [CGFloat]) -> Strip {
        let s = Strip(displayID: 1)
        s.columns = widths.map { Column([], width: $0) }
        return s
    }

    func testColumnPositionsIncludeGaps() {
        let s = strip([100, 200, 300])
        XCTAssertEqual(s.x(of: 0, gap: gap), 8)
        XCTAssertEqual(s.x(of: 1, gap: gap), 116)
        XCTAssertEqual(s.x(of: 2, gap: gap), 324)
        XCTAssertEqual(s.totalWidth(gap: gap), 632)
    }

    func testClampKeepsOffsetInRange() {
        let s = strip([600, 600, 600])
        s.offset = -50
        s.clamp(viewport: 1000, gap: gap)
        XCTAssertEqual(s.offset, 0)
        s.offset = 10_000
        s.clamp(viewport: 1000, gap: gap)
        XCTAssertEqual(s.offset, s.totalWidth(gap: gap) - 1000)
    }

    func testClampWhenEverythingFits() {
        let s = strip([300, 300])
        s.offset = 120
        s.clamp(viewport: 1280, gap: gap)
        XCTAssertEqual(s.offset, 0, "nothing to scroll when the strip is narrower than the screen")
    }

    func testEnsureVisibleScrollsRightJustEnough() {
        let s = strip([600, 600, 600])
        s.ensureVisible(2, viewport: 1000, gap: gap)
        // Right edge of column 2 plus a gap lands exactly on the screen edge.
        XCTAssertEqual(s.offset, s.x(of: 2, gap: gap) + 600 + gap - 1000)
    }

    func testEnsureVisibleScrollsLeftJustEnough() {
        let s = strip([600, 600, 600])
        s.offset = 1000
        s.clamp(viewport: 1000, gap: gap)
        s.ensureVisible(0, viewport: 1000, gap: gap)
        XCTAssertEqual(s.offset, 0)
    }

    func testEnsureVisibleLeavesVisibleColumnAlone() {
        let s = strip([300, 300, 300])
        s.offset = 0
        s.ensureVisible(1, viewport: 1280, gap: gap)
        XCTAssertEqual(s.offset, 0)
    }

    func testEnsureVisibleAlignsWideColumnToLeft() {
        let s = strip([400, 2000, 400])
        s.ensureVisible(1, viewport: 1000, gap: gap)
        XCTAssertEqual(s.offset, s.x(of: 1, gap: gap) - gap)
    }

    func testCenter() {
        let s = strip([500, 500, 500, 500])
        s.center(2, viewport: 1000, gap: gap)
        XCTAssertEqual(s.offset, s.x(of: 2, gap: gap) + 250 - 500)
    }

    func testEnsureVisibleIgnoresBadIndex() {
        let s = strip([500])
        s.offset = 0
        s.ensureVisible(5, viewport: 1000, gap: gap)
        s.center(-1, viewport: 1000, gap: gap)
        XCTAssertEqual(s.offset, 0)
    }
}

final class StackHeightTests: XCTestCase {
    func testEvenSplitWithoutMinimums() {
        XCTAssertEqual(Strip.stackHeights(minimums: [0, 0], available: 800), [400, 400])
        XCTAssertEqual(Strip.stackHeights(minimums: [0, 0, 0], available: 900), [300, 300, 300])
    }

    func testWindowWithLargeMinimumGetsIt() {
        // System Settings needs 470: the other window gets the rest.
        XCTAssertEqual(Strip.stackHeights(minimums: [0, 470], available: 779), [309, 470])
    }

    func testCascadingMinimums() {
        // After the 500 is honoured, the share drops below 300, so that one
        // is fixed too; the last window gets what's left.
        XCTAssertEqual(Strip.stackHeights(minimums: [500, 300, 0], available: 1000), [500, 300, 200])
    }

    func testNeverBelowFloor() {
        XCTAssertEqual(Strip.stackHeights(minimums: [700, 0], available: 750), [700, 80])
    }

    func testEmpty() {
        XCTAssertEqual(Strip.stackHeights(minimums: [], available: 800), [])
    }
}

final class LayoutGroupingTests: XCTestCase {
    func testRepeatingPattern() {
        XCTAssertEqual(Strip.group(Array(1...5), pattern: [2, 1]), [[1, 2], [3], [4, 5]])
        XCTAssertEqual(Strip.group(Array(1...4), pattern: [1, 2]), [[1], [2, 3], [4]])
        XCTAssertEqual(Strip.group(Array(1...5), pattern: [2]), [[1, 2], [3, 4], [5]])
    }

    func testOneColumnEach() {
        XCTAssertEqual(Strip.group(["a", "b", "c"], pattern: [1]), [["a"], ["b"], ["c"]])
    }

    func testBadPatternFallsBackToOneEach() {
        XCTAssertEqual(Strip.group([1, 2], pattern: []), [[1], [2]])
        XCTAssertEqual(Strip.group([1, 2], pattern: [0]), [[1], [2]])
    }

    func testEveryPanelLayoutKeepsAllWindows() {
        for preset in LayoutPreset.all {
            let groups = Strip.group(Array(0..<7), pattern: preset.pattern)
            XCTAssertEqual(groups.flatMap { $0 }, Array(0..<7), preset.id)
        }
    }
}
