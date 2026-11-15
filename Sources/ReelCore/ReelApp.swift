import AppKit
import SwiftUI

/// Entry point. `main.swift` in the `Reel` target only calls `ReelApp.run()`;
/// everything else lives in this library so it can be unit-tested.
public enum ReelApp {
    private static var delegate: AppDelegate?

    public static func run() {
        let args = CommandLine.arguments
        if args.contains("--diagnose") { diagnose(); exit(0) }
        #if DEBUG
        if let i = args.firstIndex(of: "--render-panel"), i + 1 < args.count {
            renderPanel(to: args[i + 1], shortcuts: args.contains("--shortcuts"), settings: args.contains("--settings"))
            exit(0)
        }
        if args.contains("--test-layouts") { testLayouts(); exit(0) }
        if args.contains("--demo-windows") {
            // Separate process so the tiling instance treats them as another app.
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let windows = DemoWindows.open()
            _ = windows
            app.activate()
            app.run()
        }
        if let i = args.firstIndex(of: "--demo-layout"), i + 1 < args.count, let pid = pid_t(args[i + 1]) {
            demoLayout(pid: pid)
            exit(0)
        }
        #endif

        let app = NSApplication.shared
        let delegate = AppDelegate()
        self.delegate = delegate // NSApplication.delegate is weak
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        app.run()
    }

    /// Read-only: prints permission status and every window Reel can see.
    /// Safe to ask users to run for bug reports.
    private static func diagnose() {
        print("Reel diagnostics")
        print("accessibility trusted:", AXIsProcessTrusted())
        print("screens:", NSScreen.screens.map { "\($0.localizedName) \($0.axVisibleFrame)" })
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            var v: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &v)
            let lines = ((v as? [AXUIElement]) ?? []).map { el -> String in
                let w = Window(el, pid: app.processIdentifier)
                let role = "\(AX.string(el, kAXRoleAttribute) ?? "?")/\(AX.string(el, kAXSubroleAttribute) ?? "?")"
                return "    id=\(AX.windowID(el).map(String.init) ?? "nil") \(role) eligible=\(w?.isEligible ?? false) frame=\(w?.frame.map { "\($0)" } ?? "?")"
            }
            print("\(app.bundleIdentifier ?? "?") (AX error \(err.rawValue))")
            lines.forEach { print($0) }
        }
    }

    #if DEBUG
    /// Dev aid: render the panel or settings with sample data to a PNG.
    private static func renderPanel(to path: String, shortcuts: Bool, settings: Bool) {
        // Unbundled debug builds have no icon; use the repo's.
        if let icon = NSImage(contentsOfFile: "Resources/AppIcon-1024.png") {
            NSApplication.shared.applicationIconImage = icon
        }
        let m = PanelModel()
        let icons = ["com.apple.finder", "com.apple.Safari", "com.apple.Terminal", "com.apple.Notes", "com.apple.systempreferences"]
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        m.windows = icons.enumerated().map { WindowItem(id: CGWindowID($0.offset + 1), icon: $0.element, name: "App", focused: $0.offset == 1) }
        m.enabled = true
        m.focusedFraction = 0.5
        m.shortcuts = Config.defaultShortcuts
        m.showShortcuts = shortcuts
        let host: NSView = settings
            ? NSHostingView(rootView: SettingsView(model: SettingsModel(config: Config())))
            : NSHostingView(rootView: AnyView(PanelView(model: m).background(Color(white: 0.15))))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        print("size:", host.fittingSize)
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Dev aid (README screenshot): tiles only the demo process's windows
    /// into a showcase arrangement and prints "windowID x y w h" lines.
    private static func demoLayout(pid: pid_t) {
        WindowManager.onlyPID = pid
        var cfg = Config()
        cfg.animate = false
        let wm = WindowManager(config: cfg)
        wm.start()
        func pump(_ t: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }
        pump(0.6)
        // Browser | Editor | Terminal over Notes | Chat, each at its own width.
        wm.applyLayout(pattern: [1, 1, 2, 1], fraction: nil)
        pump(0.6)
        // Scroll so Browser peeks in on the left and the stack on the right.
        wm.debugScroll(to: 486)
        pump(1.0)
        for (id, f) in wm.debugFrames() {
            print("\(id) \(Int(f.minX)) \(Int(f.minY)) \(Int(f.width)) \(Int(f.height))")
        }
        // Leave windows where they are for the capture; no stop()/restore.
    }

    /// Dev aid: applies every panel layout to your REAL windows, prints where
    /// they ended up, then restores them. Quit Reel first.
    private static func testLayouts() {
        var cfg = Config()
        cfg.animate = false
        let wm = WindowManager(config: cfg)
        wm.start()
        func pump(_ t: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }
        pump(0.5)
        print("== initial\n" + wm.debugReport())
        for preset in LayoutPreset.all {
            wm.applyLayout(pattern: preset.pattern, fraction: preset.fraction)
            pump(0.8)
            print("== \(preset.id)\n" + wm.debugReport())
        }
        wm.stop()
        pump(0.3)
    }
    #endif
}
