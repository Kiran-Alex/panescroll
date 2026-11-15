import AppKit
import ApplicationServices

private let axCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let wm = Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()
    wm.handle(notification: notification as String, element: element)
}

final class WindowManager {
    var config: Config
    private(set) var enabled = false
    private var strips: [CGDirectDisplayID: Strip] = [:]
    private var known: [CGWindowID: Window] = [:]
    /// Frame of each window when Panescroll first saw it, persisted to disk so a
    /// crash or relaunch never mistakes a tiled frame for the original.
    private var originalFrames: [CGWindowID: FrameStore.Entry] = [:]
    /// Every window ever tiled, kept even after it leaves the strip (other
    /// Space, full screen, hidden) so it can still be restored on stop.
    private var everSeen: [CGWindowID: Window] = [:]
    private var animationTimer: Timer?
    private var scrollSettleWork: DispatchWorkItem?
    /// Apps that refused the size the last layout asked for.
    private(set) var constrainedApps = Set<String>()
    private var observers: [pid_t: AXObserver] = [:]
    private var suppressResizeUntil = Date.distantPast
    private var reconcileWork: DispatchWorkItem?
    private var resizeWork: DispatchWorkItem?
    private var layoutPending = false
    private var timer: Timer?
    private var dragWork: DispatchWorkItem?
    /// Where a window sat before it left the strip (other Space, hidden,
    /// minimized, tab switched away), so it comes back to the same spot.
    private var detached: [CGWindowID: (display: CGDirectDisplayID, index: Int, width: CGFloat)] = [:]
    /// Apps that timed out (frozen); skipped for a few seconds so one hung
    /// app can't make all tiling stutter.
    private var unresponsiveUntil: [pid_t: Date] = [:]
    var onChange: (() -> Void)?

    var windowCount: Int { known.count }
    private var gap: CGFloat { CGFloat(config.gap) }

    init(config: Config) {
        self.config = config
        Window.onMinimumLearned = { [weak self] w in
            guard let self, self.enabled else { return }
            self.constrainedApps.insert(self.appName(w))
            self.scheduleLayout()
        }
        let ws = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ]
        for name in names {
            let delay = name == NSWorkspace.didLaunchApplicationNotification ? 0.5 : 0.05
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleReconcile(after: delay)
            }
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.dropObserver(app.processIdentifier)
            }
            self?.scheduleReconcile(after: 0.05)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.enabled else { return }
            self.rebuildStrips()
            self.layoutAll(force: true)
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !enabled else { return }
        enabled = true
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        originalFrames = FrameStore.load()
        rebuildStrips()
        reconcile(initial: true)
        syncFocus()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.reconcile()
        }
        onChange?()
    }

    /// Stops tiling and puts every window back where it was when first seen.
    func stop() {
        guard enabled else { return }
        enabled = false
        timer?.invalidate()
        timer = nil
        animationTimer?.invalidate()
        animationTimer = nil
        var restored = 0
        for (id, entry) in originalFrames {
            guard let w = everSeen[id] ?? known[id] else { continue }
            w.apply(onScreen(entry.frame), force: true)
            restored += 1
        }
        Log.write("stopped; restored \(restored) windows")
        strips.removeAll()
        known.removeAll()
        everSeen.removeAll()
        originalFrames.removeAll()
        FrameStore.clear()
        for pid in Array(observers.keys) { dropObserver(pid) }
        onChange?()
    }

    func retile() {
        reconcile()
        for s in strips.values { if let vp = viewport(s) { s.clamp(viewport: vp.width, gap: gap) } }
        layoutAll(force: true)
    }

    // MARK: Screens

    private func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == id }
    }

    private func screen(containing p: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.axFrame.contains(p) }
    }

    private func viewport(_ s: Strip) -> CGRect? { screen(for: s.displayID)?.axVisibleFrame }

    private func rebuildStrips() {
        let ids = NSScreen.screens.map(\.displayID)
        for id in ids where strips[id] == nil { strips[id] = Strip(displayID: id) }
        guard let main = ids.first.flatMap({ strips[$0] }) else { return }
        for (id, s) in strips where !ids.contains(id) {
            main.columns += s.columns
            strips[id] = nil
        }
    }

    /// Moves (and if needed shrinks) a frame so it sits fully inside the
    /// usable area of the screen it mostly overlaps. Restoring never leaves a
    /// window hanging off an edge or parked in a corner.
    private func onScreen(_ f: CGRect) -> CGRect {
        let screens = NSScreen.screens
        let best = screens.max { a, b in
            let ia = a.axFrame.intersection(f), ib = b.axFrame.intersection(f)
            return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
        }
        guard let vf = (best ?? NSScreen.main)?.axVisibleFrame else { return f }
        let w = min(f.width, vf.width), h = min(f.height, vf.height)
        let x = min(max(f.minX, vf.minX), vf.maxX - w)
        let y = min(max(f.minY, vf.minY), vf.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: Lookup

    private func locate(_ id: CGWindowID) -> (strip: Strip, col: Int, row: Int)? {
        for s in strips.values {
            if let (c, r) = s.locate(id) { return (s, c, r) }
        }
        return nil
    }

    private func focusedWindowID() -> CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        guard let w = AX.element(ax, kAXFocusedWindowAttribute) else { return nil }
        return AX.windowID(w)
    }

    private func activeStrip() -> Strip? {
        if let id = focusedWindowID(), let loc = locate(id) { return loc.strip }
        if let scr = screen(containing: currentMouseLocationAX()), let s = strips[scr.displayID] { return s }
        return NSScreen.main.flatMap { strips[$0.displayID] } ?? strips.values.first
    }

    /// The column/window commands act on: the focused window, or the strip's
    /// remembered focus if the focused window isn't managed.
    private func current() -> (strip: Strip, col: Int, row: Int)? {
        if let id = focusedWindowID(), let loc = locate(id) { return loc }
        guard let s = activeStrip(), !s.columns.isEmpty else { return nil }
        let c = min(s.focusedColumn, s.columns.count - 1)
        return (s, c, min(s.columns[c].focusedRow, s.columns[c].windows.count - 1))
    }

    // MARK: Discovery

    #if DEBUG
    /// Dev aid (screenshots): manage only this process's windows.
    static var onlyPID: pid_t?
    #endif

    private func isManageable(_ app: NSRunningApplication) -> Bool {
        #if DEBUG
        if let only = WindowManager.onlyPID, app.processIdentifier != only { return false }
        #endif
        return app.activationPolicy == .regular
            && app.processIdentifier != getpid()
            && !app.isHidden
            && !config.ignoredBundleIDs.contains(app.bundleIdentifier ?? "")
    }

    private func ensureObserver(_ pid: pid_t) {
        guard observers[pid] == nil else { return }
        var obs: AXObserver?
        guard AXObserverCreate(pid, axCallback, &obs) == .success, let obs else { return }
        let app = AXUIElementCreateApplication(pid)
        let ref = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(obs, app, n as CFString, ref)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[pid] = obs
    }

    private func dropObserver(_ pid: pid_t) {
        guard let obs = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }

    private func track(_ w: Window) {
        known[w.id] = w
        everSeen[w.id] = w
        if originalFrames[w.id]?.pid != w.pid, let f = w.frame {
            originalFrames[w.id] = .init(pid: w.pid, frame: onScreen(f))
            FrameStore.save(originalFrames)
        }
        if let obs = observers[w.pid] {
            let ref = Unmanaged.passUnretained(self).toOpaque()
            for n in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowResizedNotification, kAXWindowMovedNotification] {
                AXObserverAddNotification(obs, w.element, n as CFString, ref)
            }
        }
    }

    private func presetWidth(_ fraction: Double, _ vp: CGRect) -> CGFloat {
        (CGFloat(fraction) * (vp.width - gap) - gap).rounded()
    }

    private func initialWidth(_ w: Window, _ frame: CGRect?, _ vp: CGRect) -> CGFloat {
        let maxW = vp.width - 2 * gap
        if w.fixedSize, let frame { return frame.width }
        if let f = config.newWindowWidth { return presetWidth(f, vp) }
        return min(max(frame?.width ?? maxW / 2, 300), maxW)
    }

    /// Diff the live window list against the strips: add new windows, drop
    /// closed / minimized / hidden ones.
    func reconcile(initial: Bool = false) {
        guard enabled else { return }
        var live: [CGWindowID: Window] = [:]
        // Windows actually ordered in on this Space. Hidden native tabs are
        // still listed by AX but aren't here.
        let orderedIn = Set(((CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        let now = Date()
        for app in NSWorkspace.shared.runningApplications where isManageable(app) {
            let pid = app.processIdentifier
            if let until = unresponsiveUntil[pid], until > now {
                // Frozen app: keep its windows where they are, don't query it.
                for (id, w) in known where w.pid == pid { live[id] = w }
                continue
            }
            ensureObserver(pid)
            var value: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value)
            if err == .cannotComplete {
                unresponsiveUntil[pid] = now.addingTimeInterval(5)
                for (id, w) in known where w.pid == pid { live[id] = w }
                continue
            }
            for el in (value as? [AXUIElement]) ?? [] {
                guard let id = AX.windowID(el), orderedIn.contains(id) else { continue }
                if let existing = known[id] {
                    if existing.isEligible { live[id] = existing }
                } else if let w = Window(el, pid: pid), w.isEligible,
                          let f = w.frame, f.width >= 60, f.height >= 60 {
                    live[id] = w
                }
            }
        }

        var changed = false
        var refocus: Strip?
        for id in Array(known.keys) where live[id] == nil {
            if let loc = locate(id) {
                if loc.col == loc.strip.focusedColumn { refocus = loc.strip }
                detached[id] = (loc.strip.displayID, loc.col, loc.strip.columns[loc.col].width)
            }
            known[id] = nil
            for s in strips.values where s.remove(id) {
                if let vp = viewport(s) { s.clamp(viewport: vp.width, gap: gap) }
            }
            changed = true
        }

        let fresh = live.values.filter { known[$0.id] == nil }.sorted { $0.id < $1.id }
        if initial {
            // Keep the on-screen left-to-right order of existing windows.
            let fallback = NSScreen.screens.first?.displayID ?? 0
            var byScreen: [CGDirectDisplayID: [(Window, CGRect?)]] = [:]
            for w in fresh {
                let f = w.frame
                let sid = f.flatMap { screen(containing: CGPoint(x: $0.midX, y: $0.midY))?.displayID } ?? fallback
                byScreen[sid, default: []].append((w, f))
            }
            for (sid, list) in byScreen {
                guard let s = strips[sid], let vp = viewport(s) else { continue }
                for (w, f) in list.sorted(by: { ($0.1?.minX ?? 0) < ($1.1?.minX ?? 0) }) {
                    track(w)
                    s.columns.append(Column([w], width: initialWidth(w, f, vp)))
                }
            }
        } else {
            // Windows coming back (Space switch, unhide, unminimize) return to
            // their old slot and width, in their old order.
            let returning = fresh.filter { detached[$0.id] != nil }
                .sorted { detached[$0.id]!.index < detached[$1.id]!.index }
            for w in returning {
                guard let slot = detached.removeValue(forKey: w.id) else { continue }
                guard let s = strips[slot.display] ?? activeStrip() else { continue }
                track(w)
                let at = min(slot.index, s.columns.count)
                s.columns.insert(Column([w], width: slot.width), at: at)
                if at <= s.focusedColumn, s.columns.count > 1 { s.focusedColumn += 1 }
            }
            // Brand-new windows open right next to the focused one.
            for w in fresh where !returning.contains(where: { $0.id == w.id }) {
                guard let s = activeStrip(), let vp = viewport(s) else { continue }
                track(w)
                let at = s.columns.isEmpty ? 0 : min(s.focusedColumn + 1, s.columns.count)
                s.columns.insert(Column([w], width: initialWidth(w, w.frame, vp)), at: at)
                s.focusedColumn = at
                s.ensureVisible(at, viewport: vp.width, gap: gap)
            }
        }

        if changed || !fresh.isEmpty {
            Log.write("reconcile: \(known.count) windows; strips: " + strips.values.map { s in "display \(s.displayID) offset \(Int(s.offset)) cols " + s.columns.map { "\(Int($0.width))x\($0.windows.count)" }.joined(separator: ",") }.joined(separator: " | "))
            layoutAll()
            onChange?()
        }

        // The focused window closed / minimized: focus its neighbour on the
        // strip instead of whatever macOS picks (often an off-screen window).
        if let s = refocus, fresh.isEmpty, !s.columns.isEmpty {
            focus(s, col: min(s.focusedColumn, s.columns.count - 1))
        }
    }

    // MARK: Events

    func handle(notification: String, element: AXUIElement) {
        guard enabled else { return }
        if notification == kAXWindowResizedNotification || notification == kAXWindowMovedNotification {
            // Only the user's own drags (mouse held down). Panescroll's moves and
            // apps moving themselves happen with no mouse button pressed.
            guard NSEvent.pressedMouseButtons != 0 else { return }
            if notification == kAXWindowResizedNotification {
                userResized(element)
            } else {
                userMoved(element)
            }
        } else {
            scheduleReconcile(after: 0.05)
        }
    }

    private func scheduleReconcile(after delay: TimeInterval) {
        guard enabled else { return }
        reconcileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reconcile()
            self?.syncFocus()
        }
        reconcileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Drag a window by its title bar and drop it: it moves to the column
    /// under its centre, or snaps back if dropped in the same place.
    private func userMoved(_ el: AXUIElement) {
        dragWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finishDrag(el) }
        dragWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func finishDrag(_ el: AXUIElement) {
        // Still dragging: check again shortly.
        if NSEvent.pressedMouseButtons != 0 { userMoved(el); return }
        guard enabled, let id = AX.windowID(el), let w = known[id], let f = w.frame,
              let from = locate(id) else { return }
        if let placed = w.placedFrame {
            // Resizing from the left edge also moves the window: that's a
            // resize, handled elsewhere. A tiny nudge just snaps back.
            let resized = abs(f.width - placed.width) > 4 || abs(f.height - placed.height) > 4
            let nudged = abs(f.midX - placed.midX) < 40 && abs(f.midY - placed.midY) < 40
            if resized { return }
            if nudged { w.invalidate(); layoutAll(); return }
        }
        let center = CGPoint(x: f.midX, y: f.midY)
        let target = screen(containing: center).flatMap { strips[$0.displayID] } ?? from.strip
        guard let vp = viewport(target) else { return }

        // Take the window out of its column.
        let srcCol = from.strip.columns[from.col]
        srcCol.windows.remove(at: from.row)
        var removedColumn = false
        if srcCol.windows.isEmpty {
            from.strip.columns.remove(at: from.col)
            removedColumn = true
        } else {
            srcCol.focusedRow = min(srcCol.focusedRow, srcCol.windows.count - 1)
        }

        // Find the drop index from the centre's position on the strip.
        let stripX = center.x - vp.minX + target.offset
        var index = target.columns.count
        for i in target.columns.indices where stripX < target.x(of: i, gap: gap) + target.columns[i].width / 2 {
            index = i
            break
        }
        let width = removedColumn ? srcCol.width : min(srcCol.width, vp.width - 2 * gap)
        target.columns.insert(Column([w], width: width), at: index)
        if from.strip !== target { from.strip.clamp(viewport: viewport(from.strip)?.width ?? vp.width, gap: gap) }
        w.invalidate()
        Log.write("drag: moved window to column \(index)")
        focus(target, col: index)
    }

    /// A user drag-resize sets the column's width (debounced until the drag ends).
    private func userResized(_ el: AXUIElement) {
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let id = AX.windowID(el), let w = self.known[id], let f = w.frame,
                  let loc = self.locate(id), let vp = self.viewport(loc.strip) else { return }
            let col = loc.strip.columns[loc.col]
            guard abs(f.width - col.width) > 2 else { return }
            col.width = min(max(f.width, 150), vp.width - 2 * self.gap)
            col.windows.forEach { $0.invalidate() }
            loc.strip.ensureVisible(loc.col, viewport: vp.width, gap: self.gap)
            self.layoutAll()
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Scroll so the focused window is fully on screen.
    private func syncFocus() {
        guard enabled, let id = focusedWindowID(), let (s, c, r) = locate(id), let vp = viewport(s) else { return }
        s.focusedColumn = c
        s.columns[c].focusedRow = r
        s.ensureVisible(c, viewport: vp.width, gap: gap)
        layoutAll()
    }

    // MARK: Layout

    func layoutAll(force: Bool = false) {
        guard enabled else { return }
        suppressResizeUntil = Date().addingTimeInterval(0.5)
        var needsAnimation = false
        for s in strips.values {
            if !config.animate || abs(s.displayOffset - s.offset) < 1 {
                s.displayOffset = s.offset
            } else {
                needsAnimation = true
            }
            layout(s, force: force)
        }
        if needsAnimation { startAnimation() }
    }

    /// Eases each strip's drawn position toward its target at 60 fps.
    private func startAnimation() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self, self.enabled else { t.invalidate(); return }
            var moving = false
            for s in self.strips.values where s.displayOffset != s.offset {
                let d = s.offset - s.displayOffset
                s.displayOffset = abs(d) < 1.5 ? s.offset : s.displayOffset + d * 0.3
                if s.displayOffset != s.offset { moving = true }
                self.layout(s, force: false)
            }
            self.suppressResizeUntil = Date().addingTimeInterval(0.5)
            if !moving {
                t.invalidate()
                self.animationTimer = nil
            }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func scheduleLayout() {
        guard !layoutPending else { return }
        layoutPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            self?.layoutPending = false
            self?.layoutAll()
        }
    }

    private func layout(_ s: Strip, force: Bool) {
        guard let vp = viewport(s) else { return }
        if placeColumns(s, vp, force: force) {
            // A window refused to get as narrow as asked (app minimum width),
            // so its column grew. Re-check scroll and place again.
            s.ensureVisible(s.focusedColumn, viewport: vp.width, gap: gap)
            if !config.animate { s.displayOffset = s.offset }
            placeColumns(s, vp, force: false)
        }
    }

    /// Places every window. Columns adopt the real width of their widest
    /// window and stacked windows go below the real bottom of the one above,
    /// so apps with a minimum size never overlap their neighbours.
    ///
    /// Columns scrolled completely off screen are parked in the screen's
    /// bottom corner with 1 pt showing. macOS refuses to put a window fully
    /// off screen and would otherwise drag it back on top of visible ones.
    ///
    /// Returns true if any column width had to grow.
    @discardableResult
    private func placeColumns(_ s: Strip, _ vp: CGRect, force: Bool) -> Bool {
        let full = screen(for: s.displayID)?.axFrame ?? vp
        var changed = false
        for (i, col) in s.columns.enumerated() {
            // Never ask for less than a window is known to accept.
            let minW = col.windows.map(\.minSize.width).max() ?? 0
            if minW > col.width + 1 {
                col.width = minW
                changed = true
                constrainedApps.formUnion(col.windows.filter { $0.minSize.width >= minW }.map(appName))
            }
            let x = (vp.minX + s.x(of: i, gap: gap) - s.displayOffset).rounded()
            let offLeft = x + col.width <= vp.minX
            let offRight = x >= vp.maxX
            let heights = Strip.stackHeights(minimums: col.windows.map(\.minSize.height),
                                             available: vp.height - gap * CGFloat(col.windows.count + 1))
            var y = vp.minY + gap
            for (j, w) in col.windows.enumerated() {
                var frame = CGRect(x: x, y: y.rounded(), width: col.width.rounded(), height: heights[j])
                if offLeft || offRight {
                    frame.origin = parkingOrigin(full, size: frame.size)
                }
                // Only the left screen edge stretches windows; overflowing on
                // the right is fine for learning minimum sizes.
                let canLearn = !(offLeft || offRight) && frame.minX >= vp.minX - 1
                w.apply(frame, force: force, learn: canLearn)
                y += heights[j] + gap
            }
        }
        return changed
    }

    /// A corner just outside this screen that doesn't reach into another
    /// display: bottom-right preferred (macOS stretches windows parked at a
    /// left edge), then bottom-left.
    private func parkingOrigin(_ full: CGRect, size: CGSize) -> CGPoint {
        let others = NSScreen.screens.map(\.axFrame).filter { $0 != full }
        let candidates = [CGPoint(x: full.maxX - 1, y: full.maxY - 1),
                          CGPoint(x: full.minX - size.width + 1, y: full.maxY - 1)]
        for p in candidates {
            let r = CGRect(origin: p, size: size).insetBy(dx: 2, dy: 2)
            if !others.contains(where: { $0.intersects(r) }) { return p }
        }
        return candidates[0]
    }

    private func appName(_ w: Window) -> String {
        NSRunningApplication(processIdentifier: w.pid)?.localizedName ?? "An app"
    }

    /// After a trackpad scroll settles, focus the column you scrolled to
    /// (the most visible one, preferring the one under the pointer) and snap
    /// it fully into view.
    private func focusMostVisible(_ s: Strip) {
        guard enabled, let vp = viewport(s), !s.columns.isEmpty else { return }
        let mouse = currentMouseLocationAX()
        var best = 0
        var bestScore: CGFloat = -1
        for i in s.columns.indices {
            let left = vp.minX + s.x(of: i, gap: gap) - s.offset
            let right = left + s.columns[i].width
            let visible = max(0, min(right, vp.maxX) - max(left, vp.minX))
            var score = visible / max(1, s.columns[i].width)
            if vp.contains(mouse), mouse.x >= left, mouse.x <= right { score += 0.5 }
            if score > bestScore { bestScore = score; best = i }
        }
        focus(s, col: best)
    }

    // MARK: Commands

    private func focus(_ s: Strip, col c: Int) {
        let col = s.columns[c]
        let w = col.windows[min(col.focusedRow, col.windows.count - 1)]
        s.focusedColumn = c
        if let vp = viewport(s) { s.ensureVisible(c, viewport: vp.width, gap: gap) }
        layoutAll()
        w.focus()
    }

    func focusColumn(_ delta: Int) {
        guard let (s, c, _) = current(), s.columns.indices.contains(c + delta) else { return }
        focus(s, col: c + delta)
    }

    func focusRow(_ delta: Int) {
        guard let (s, c, r) = current() else { return }
        let col = s.columns[c]
        guard col.windows.indices.contains(r + delta) else { return }
        col.focusedRow = r + delta
        focus(s, col: c)
    }

    func moveColumn(_ delta: Int) {
        guard let (s, c, _) = current(), s.columns.indices.contains(c + delta) else { return }
        s.columns.swapAt(c, c + delta)
        focus(s, col: c + delta)
    }

    func cycleWidth() {
        guard let (s, c, _) = current(), let vp = viewport(s) else { return }
        let col = s.columns[c]
        let widths = config.widthPresets.sorted().map { presetWidth($0, vp) }
        col.width = widths.first { $0 > col.width + 2 } ?? widths.first ?? col.width
        s.ensureVisible(c, viewport: vp.width, gap: gap)
        layoutAll()
    }

    func centerColumn() {
        guard let (s, c, _) = current(), let vp = viewport(s) else { return }
        s.center(c, viewport: vp.width, gap: gap)
        layoutAll()
    }

    /// Move the focused window into the column on its left (stack them).
    func stack() {
        guard let (s, c, r) = current(), c > 0 else { return }
        let col = s.columns[c]
        let w = col.windows.remove(at: r)
        if col.windows.isEmpty {
            s.columns.remove(at: c)
        } else {
            col.focusedRow = min(col.focusedRow, col.windows.count - 1)
        }
        let target = s.columns[c - 1]
        target.windows.append(w)
        target.focusedRow = target.windows.count - 1
        focus(s, col: c - 1)
    }

    /// Pop the focused window out of its stack into its own column.
    func unstack() {
        guard let (s, c, r) = current(), s.columns[c].windows.count > 1 else { return }
        let col = s.columns[c]
        let w = col.windows.remove(at: r)
        col.focusedRow = min(col.focusedRow, col.windows.count - 1)
        s.columns.insert(Column([w], width: col.width), at: c + 1)
        focus(s, col: c + 1)
    }

    /// Scroll the strip under point `p` (trackpad / mouse wheel). Returns
    /// whether the event was used.
    func scroll(by delta: CGFloat, at p: CGPoint) -> Bool {
        guard enabled, let scr = screen(containing: p), let s = strips[scr.displayID], let vp = viewport(s) else { return false }
        s.offset -= delta * CGFloat(config.scrollSpeed)
        s.clamp(viewport: vp.width, gap: gap)
        s.displayOffset = s.offset // follow the fingers directly, no easing
        scheduleLayout()
        scrollSettleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.focusMostVisible(s) }
        scrollSettleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        return true
    }

    // MARK: Panel support

    struct Snapshot {
        struct Item { let id: CGWindowID; let pid: pid_t; let focused: Bool }
        var windows: [Item] = []
        /// The preset fraction the focused column matches, if any.
        var focusedFraction: Double?
    }

    func snapshot() -> Snapshot {
        guard enabled, let (s, c, r) = current(), let vp = viewport(s) else { return Snapshot() }
        var snap = Snapshot()
        for (ci, col) in s.columns.enumerated() {
            for (ri, w) in col.windows.enumerated() {
                snap.windows.append(.init(id: w.id, pid: w.pid, focused: ci == c && ri == r))
            }
        }
        let width = s.columns[c].width
        snap.focusedFraction = config.widthPresets.first { abs(presetWidth($0, vp) - width) < 4 }
        return snap
    }

    func setWidth(_ fraction: Double) {
        guard let (s, c, _) = current(), let vp = viewport(s) else { return }
        s.columns[c].width = presetWidth(fraction, vp)
        s.ensureVisible(c, viewport: vp.width, gap: gap)
        layoutAll()
    }

    /// Regroup every window on the strip, in order, into columns of
    /// `pattern` sizes (repeating). `fraction` nil keeps each window's width.
    func applyLayout(pattern: [Int], fraction: Double?) {
        guard !pattern.isEmpty, let (s, c, r) = current(), let vp = viewport(s) else { return }
        let focusedID = s.columns[c].windows[r].id
        constrainedApps = []
        let items = s.columns.flatMap { col in col.windows.map { ($0, col.width) } }
        let cols = Strip.group(items, pattern: pattern).map { chunk -> Column in
            let first = chunk[0]
            let width = fraction.map { presetWidth($0, vp) }
                ?? originalFrames[first.0.id].map { min($0.frame.width, vp.width - 2 * gap) }
                ?? first.1
            return Column(chunk.map(\.0), width: width)
        }
        s.columns = cols
        if let (nc, nr) = s.locate(focusedID) {
            s.focusedColumn = nc
            s.columns[nc].focusedRow = nr
            s.ensureVisible(nc, viewport: vp.width, gap: gap)
        }
        known.values.forEach { $0.invalidate() }
        layoutAll()
    }

    func focusWindow(_ id: CGWindowID) {
        guard let (s, c, r) = locate(id) else { return }
        s.columns[c].focusedRow = r
        focus(s, col: c)
    }

    #if DEBUG
    /// Dev aid (screenshots): set the scroll position directly.
    func debugScroll(to offset: CGFloat) {
        for s in strips.values {
            s.offset = offset
            if let vp = viewport(s) { s.clamp(viewport: vp.width, gap: gap) }
            s.displayOffset = s.offset
        }
        layoutAll()
    }

    /// Dev aid (screenshots): window id → frame, in strip order.
    func debugFrames() -> [(CGWindowID, CGRect)] {
        strips.values.flatMap { $0.columns.flatMap { $0.windows } }.compactMap { w in w.frame.map { (w.id, $0) } }
    }
    #endif

    /// Dev aid: what the strip asked for vs. where windows really are.
    func debugReport() -> String {
        var out: [String] = []
        var visible: [(String, CGRect)] = []
        for s in strips.values {
            guard let vp = viewport(s) else { continue }
            out.append("viewport \(vp) offset \(Int(s.offset)) display \(Int(s.displayOffset))")
            for (i, col) in s.columns.enumerated() {
                for w in col.windows {
                    let name = NSRunningApplication(processIdentifier: w.pid)?.localizedName ?? "?"
                    let f = w.frame ?? .zero
                    out.append("  col \(i) want w=\(Int(col.width)) rows=\(col.windows.count) | \(name): \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))")
                    if f.intersects(vp) { visible.append((name, f)) }
                }
            }
        }
        for i in visible.indices {
            for j in visible.indices where j > i {
                let r = visible[i].1.intersection(visible[j].1)
                if !r.isNull, r.width > 2, r.height > 2 {
                    out.append("  OVERLAP \(visible[i].0) & \(visible[j].0): \(Int(r.width))x\(Int(r.height))")
                }
            }
        }
        return out.joined(separator: "\n")
    }

    /// Keyboard scroll by a third of the screen.
    func scrollStep(_ direction: CGFloat) {
        guard let s = activeStrip(), let vp = viewport(s) else { return }
        s.offset += direction * vp.width / 3
        s.clamp(viewport: vp.width, gap: gap)
        layoutAll()
    }
}
