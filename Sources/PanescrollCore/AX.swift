import AppKit
import ApplicationServices

// Private but long-stable API (used by yabai, AeroSpace, Rectangle, Hammerspoon)
// that maps an AX window element to its CGWindowID. Looked up at runtime with
// a C calling convention.
private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
private let _AXUIElementGetWindow: GetWindowFn? = {
    guard let sym = dlsym(dlopen(nil, RTLD_NOW), "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(sym, to: GetWindowFn.self)
}()

enum AX {
    static func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? { copy(el, attr) as? String }

    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? { (copy(el, attr) as? NSNumber)?.boolValue }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = copy(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
        (copy(el, attr) as? [AXUIElement]) ?? []
    }

    static func point(_ el: AXUIElement, _ attr: String) -> CGPoint? {
        guard let v = copy(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ el: AXUIElement, _ attr: String) -> CGSize? {
        guard let v = copy(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    static func setPoint(_ el: AXUIElement, _ p: CGPoint) {
        var p = p
        if let v = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v)
        }
    }

    static func setSize(_ el: AXUIElement, _ s: CGSize) {
        var s = s
        if let v = AXValueCreate(.cgSize, &s) {
            AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v)
        }
    }

    static func isSettable(_ el: AXUIElement, _ attr: String) -> Bool {
        var b: DarwinBoolean = false
        AXUIElementIsAttributeSettable(el, attr as CFString, &b)
        return b.boolValue
    }

    static func windowID(_ el: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard let fn = _AXUIElementGetWindow else { return nil }
        return fn(el, &id) == .success && id != 0 ? id : nil
    }
}

/// A managed top-level window. Coordinates are AX/CG global: origin at the
/// top-left of the primary display, y grows downward.
final class Window {
    let element: AXUIElement
    let pid: pid_t
    let id: CGWindowID
    let fixedSize: Bool
    private var lastFrame: CGRect?

    init?(_ element: AXUIElement, pid: pid_t) {
        guard let id = AX.windowID(element) else { return nil }
        self.element = element
        self.pid = pid
        self.id = id
        self.fixedSize = !AX.isSettable(element, kAXSizeAttribute)
    }

    var frame: CGRect? {
        guard let p = AX.point(element, kAXPositionAttribute),
              let s = AX.size(element, kAXSizeAttribute) else { return nil }
        return CGRect(origin: p, size: s)
    }

    var isEligible: Bool {
        guard AX.string(element, kAXRoleAttribute) == kAXWindowRole,
              AX.string(element, kAXSubroleAttribute) == kAXStandardWindowSubrole else { return false }
        if AX.bool(element, kAXMinimizedAttribute) == true { return false }
        if AX.bool(element, "AXFullScreen") == true { return false }
        return true
    }

    /// Where Panescroll last put this window.
    var placedFrame: CGRect? { lastFrame }

    /// Forget the cached frame so the next layout re-applies it.
    func invalidate() { lastFrame = nil; actualSize = nil }

    /// The size the window really ended up with last time we placed it.
    /// Can be larger than requested when the app enforces a minimum size.
    private(set) var actualSize: CGSize?
    /// Smallest size the app has been seen to accept (learned when it
    /// refuses to shrink further). Layout plans around it.
    private(set) var minSize = CGSize.zero

    /// Places the window and returns the size it actually took.
    @discardableResult
    /// `learn`: only true when the frame is fully on screen; macOS stretches
    /// windows pushed against a screen edge, which isn't the app's minimum.
    func apply(_ r: CGRect, force: Bool = false, learn: Bool = true) -> CGSize {
        if !force, lastFrame == r, let actualSize { return actualSize }
        // Scrolling only changes position: skip the (slow) resize calls then.
        // Also resize if the window isn't at the size it should have (e.g.
        // macOS stretched it at a screen edge while it was parked).
        let expected = CGSize(width: max(r.width, minSize.width), height: max(r.height, minSize.height))
        let sizeOff = actualSize.map { abs($0.width - expected.width) > 2 || abs($0.height - expected.height) > 2 } ?? true
        let resize = !fixedSize && (force || sizeOff || lastFrame?.size != r.size)
        lastFrame = r
        // Apps with AXEnhancedUserInterface on (Chrome, Electron) animate every
        // AX move; switch it off while we move them.
        let app = AXUIElementCreateApplication(pid)
        let enhanced = Window.usesEnhancedUI(pid, app)
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        // size → position → size: avoids the window being clamped by the
        // screen edge when it grows while still at its old position.
        if resize { AX.setSize(element, r.size) }
        AX.setPoint(element, r.origin)
        if resize { AX.setSize(element, r.size) }
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
        if resize || actualSize == nil {
            let real = frame?.size ?? r.size
            actualSize = real
            if fixedSize {
                minSize = real
            } else if learn, real.width > r.width + 1 || real.height > r.height + 1 {
                verifyMinimum(for: r)
            }
        }
        return actualSize ?? r.size
    }

    /// Called when a window learns a new minimum size, so layout can re-plan.
    static var onMinimumLearned: ((Window) -> Void)?

    /// Some apps (Chromium-based ones especially) finish resizing a moment
    /// later, so a bigger-than-asked size read right away may be transient.
    /// Only remember it as a minimum if it's still there shortly after.
    private func verifyMinimum(for r: CGRect) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.lastFrame == r, let real = self.frame?.size else { return }
            self.actualSize = real
            var learned = false
            if real.width > r.width + 1, real.width > self.minSize.width {
                self.minSize.width = real.width
                learned = true
            }
            if real.height > r.height + 1, real.height > self.minSize.height {
                self.minSize.height = real.height
                learned = true
            }
            if learned { Window.onMinimumLearned?(self) }
        }
    }

    private static var enhancedCache: [pid_t: Bool] = [:]
    private static func usesEnhancedUI(_ pid: pid_t, _ app: AXUIElement) -> Bool {
        if let v = enhancedCache[pid] { return v }
        let v = AX.bool(app, "AXEnhancedUserInterface") == true
        enhancedCache[pid] = v
        return v
    }

    func focus() {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    private func toAX(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: NSScreen.primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Full screen frame in AX coordinates.
    var axFrame: CGRect { toAX(frame) }
    /// Usable area (minus menu bar and Dock) in AX coordinates.
    var axVisibleFrame: CGRect { toAX(visibleFrame) }
}

func currentMouseLocationAX() -> CGPoint {
    CGEvent(source: nil)?.location ?? .zero
}
