import CoreGraphics

/// One column on the strip. Usually a single window; stacked windows split
/// the height evenly.
final class Column {
    var windows: [Window]
    var width: CGFloat
    var focusedRow = 0

    init(_ windows: [Window], width: CGFloat) {
        self.windows = windows
        self.width = width
    }
}

/// A horizontally scrolling row of columns, one per display.
/// `offset` is how far the strip is scrolled, in points.
final class Strip {
    let displayID: CGDirectDisplayID
    var columns: [Column] = []
    /// Where the strip should be scrolled to.
    var offset: CGFloat = 0
    /// Where it's drawn right now; eases toward `offset` when animating.
    var displayOffset: CGFloat = 0
    var focusedColumn = 0

    init(displayID: CGDirectDisplayID) { self.displayID = displayID }

    func locate(_ id: CGWindowID) -> (col: Int, row: Int)? {
        for (c, col) in columns.enumerated() {
            if let r = col.windows.firstIndex(where: { $0.id == id }) { return (c, r) }
        }
        return nil
    }

    /// Left edge of column `i` in strip space (before scrolling).
    func x(of i: Int, gap: CGFloat) -> CGFloat {
        var x = gap
        for k in 0..<min(i, columns.count) { x += columns[k].width + gap }
        return x
    }

    func totalWidth(gap: CGFloat) -> CGFloat { x(of: columns.count, gap: gap) }

    func clamp(viewport w: CGFloat, gap: CGFloat) {
        let maxOffset = max(0, totalWidth(gap: gap) - w)
        offset = min(max(offset, 0), maxOffset)
    }

    /// Scroll the minimum amount needed for column `i` to be fully visible.
    func ensureVisible(_ i: Int, viewport w: CGFloat, gap: CGFloat) {
        guard columns.indices.contains(i) else { return }
        let left = x(of: i, gap: gap) - gap
        let right = left + columns[i].width + 2 * gap
        if left < offset || right - left > w {
            offset = left
        } else if right > offset + w {
            offset = right - w
        }
        clamp(viewport: w, gap: gap)
    }

    func center(_ i: Int, viewport w: CGFloat, gap: CGFloat) {
        guard columns.indices.contains(i) else { return }
        offset = x(of: i, gap: gap) + columns[i].width / 2 - w / 2
        clamp(viewport: w, gap: gap)
    }

    /// Removes a window; drops its column if it becomes empty.
    @discardableResult
    func remove(_ id: CGWindowID) -> Bool {
        guard let (c, r) = locate(id) else { return false }
        let col = columns[c]
        col.windows.remove(at: r)
        if col.windows.isEmpty {
            columns.remove(at: c)
            if c < focusedColumn || focusedColumn >= columns.count {
                focusedColumn = max(0, focusedColumn - 1)
            }
        } else {
            col.focusedRow = min(col.focusedRow, col.windows.count - 1)
        }
        return true
    }

    /// Splits a column's height between `minimums.count` stacked windows:
    /// a window whose known minimum is above the even share gets its minimum,
    /// the rest share what's left (never below 80 pt).
    static func stackHeights(minimums mins: [CGFloat], available: CGFloat) -> [CGFloat] {
        let n = mins.count
        guard n > 0 else { return [] }
        var fixed = Set<Int>()
        var share = available / CGFloat(n)
        while true {
            let flexible = n - fixed.count
            guard flexible > 0 else { break }
            let used = fixed.reduce(0) { $0 + mins[$1] }
            share = (available - used) / CGFloat(flexible)
            let more = (0..<n).filter { !fixed.contains($0) && mins[$0] > share }
            if more.isEmpty { break }
            fixed.formUnion(more)
        }
        return (0..<n).map { (fixed.contains($0) ? mins[$0] : max(80, share)).rounded(.down) }
    }

    /// Splits items, in order, into consecutive groups whose sizes follow
    /// `pattern`, repeating it: pattern [2, 1] → sizes 2, 1, 2, 1, …
    static func group<T>(_ items: [T], pattern: [Int]) -> [[T]] {
        guard !pattern.isEmpty, pattern.allSatisfy({ $0 > 0 }) else { return items.map { [$0] } }
        var out: [[T]] = []
        var i = 0, p = 0
        while i < items.count {
            let end = min(i + pattern[p % pattern.count], items.count)
            out.append(Array(items[i..<end]))
            i = end
            p += 1
        }
        return out
    }
}
