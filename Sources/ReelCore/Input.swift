import AppKit
import Carbon

// MARK: Shortcut parsing

let keyCodes: [String: UInt32] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
    "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
    "return": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
    "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
    "left": 123, "right": 124, "down": 125, "up": 126,
]

let keySymbols: [String: String] = [
    "left": "←", "right": "→", "up": "↑", "down": "↓",
    "return": "↩", "tab": "⇥", "space": "Space",
]

struct Modifiers: OptionSet {
    let rawValue: Int
    static let control = Modifiers(rawValue: 1)
    static let option = Modifiers(rawValue: 2)
    static let shift = Modifiers(rawValue: 4)
    static let command = Modifiers(rawValue: 8)

    /// Parses one modifier token; nil if it isn't a modifier.
    init?(token: String) {
        switch token {
        case "ctrl", "control", "⌃": self = .control
        case "opt", "option", "alt", "⌥": self = .option
        case "shift", "⇧": self = .shift
        case "cmd", "command", "⌘": self = .command
        default: return nil
        }
    }

    init(rawValue: Int) { self.rawValue = rawValue }

    init?(string: String) {
        var m: Modifiers = []
        for t in string.lowercased().split(separator: "+") {
            guard let one = Modifiers(token: String(t)) else { return nil }
            m.insert(one)
        }
        self = m
    }

    var carbon: UInt32 {
        var v = 0
        if contains(.control) { v |= controlKey }
        if contains(.option) { v |= optionKey }
        if contains(.shift) { v |= shiftKey }
        if contains(.command) { v |= cmdKey }
        return UInt32(v)
    }

    var cgFlags: CGEventFlags {
        var f: CGEventFlags = []
        if contains(.control) { f.insert(.maskControl) }
        if contains(.option) { f.insert(.maskAlternate) }
        if contains(.shift) { f.insert(.maskShift) }
        if contains(.command) { f.insert(.maskCommand) }
        return f
    }

    var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
            + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

struct KeyCombo {
    let keyCode: UInt32
    let modifiers: Modifiers
    let display: String

    /// Parses strings like "ctrl+opt+left" or "cmd+shift+[".
    init?(_ string: String) {
        // Split on "+" but allow "+" itself? Not supported; keep it simple.
        let parts = string.lowercased().split(separator: "+").map(String.init)
        guard let key = parts.last, let code = keyCodes[key] else { return nil }
        var mods: Modifiers = []
        for t in parts.dropLast() {
            guard let m = Modifiers(token: t) else { return nil }
            mods.insert(m)
        }
        keyCode = code
        modifiers = mods
        display = mods.symbols + (keySymbols[key] ?? key.uppercased())
    }
}

// MARK: Global hotkeys (Carbon — needs no extra permission)

final class HotKeys {
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, refcon in
            guard let event, let refcon else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let me = Unmanaged<HotKeys>.fromOpaque(refcon).takeUnretainedValue()
            me.handlers[hk.id]?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    /// Returns false if macOS refused it (usually already taken by another app).
    @discardableResult
    func register(_ combo: KeyCombo, _ handler: @escaping () -> Void) -> Bool {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers.carbon,
                                         EventHotKeyID(signature: OSType(0x5245_454C), id: id), // 'REEL'
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs.append(ref)
        handlers[id] = handler
        return true
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }
}

// MARK: Modifier + scroll to move the strip

final class ScrollTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var modifiers: CGEventFlags
    /// (delta, location) → true if the event was consumed.
    let handler: (CGFloat, CGPoint) -> Bool

    init(modifiers: CGEventFlags, handler: @escaping (CGFloat, CGPoint) -> Bool) {
        self.modifiers = modifiers
        self.handler = handler
    }

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: { _, type, event, refcon in
            let pass = Unmanaged.passUnretained(event)
            guard let refcon else { return pass }
            let me = Unmanaged<ScrollTap>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return pass
            }
            guard type == .scrollWheel, !me.modifiers.isEmpty else { return pass }
            let held = event.flags.intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand])
            guard held == me.modifiers else { return pass }
            let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let d = abs(dx) > abs(dy) ? dx : dy
            return me.handler(CGFloat(d), event.location) ? nil : pass
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        Log.write("scroll tap created=\(tap != nil)")
        guard let tap else { return }
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}
