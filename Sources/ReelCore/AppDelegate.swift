import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let model = PanelModel()
    private lazy var panel = PanelWindow(model: model)
    private var config: Config
    private var configError: String?
    private var wm: WindowManager?
    private let hotKeys = HotKeys()
    private var scrollTap: ScrollTap?
    private var permissionTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private lazy var settingsModel = SettingsModel(config: config)
    private var settingsWindow: NSWindow?

    /// Keyboard actions, keyed by the names used in config.json.
    private let actions: [(id: String, run: (WindowManager) -> Void)] = [
        ("focusLeft", { $0.focusColumn(-1) }),
        ("focusRight", { $0.focusColumn(1) }),
        ("focusUp", { $0.focusRow(-1) }),
        ("focusDown", { $0.focusRow(1) }),
        ("moveLeft", { $0.moveColumn(-1) }),
        ("moveRight", { $0.moveColumn(1) }),
        ("scrollLeft", { $0.scrollStep(-1) }),
        ("scrollRight", { $0.scrollStep(1) }),
        ("cycleWidth", { $0.cycleWidth() }),
        ("center", { $0.centerColumn() }),
        ("stack", { $0.stack() }),
        ("unstack", { $0.unstack() }),
        ("retile", { $0.retile() }),
    ]

    override init() {
        (config, configError) = Config.load()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        setupPanel()
        installSignalHandlers()

        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        Log.write("launch pid=\(getpid()) path=\(Bundle.main.bundlePath) trusted=\(trusted)")
        if trusted {
            begin()
        } else {
            model.needsPermission = true
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
                if AXIsProcessTrusted() {
                    t.invalidate()
                    Log.write("permission granted")
                    self?.begin()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        wm?.stop() // put every window back where it started
        Log.write("quit")
    }

    private func begin() {
        Log.write("begin tiling")
        model.needsPermission = false
        let wm = WindowManager(config: config)
        wm.onChange = { [weak self] in self?.refreshPanel() }
        self.wm = wm
        wm.start()
        registerHotKeys()
        let tap = ScrollTap(modifiers: Modifiers(string: config.scrollModifiers)?.cgFlags ?? []) { [weak self] d, p in
            self?.wm?.scroll(by: d, at: p) ?? false
        }
        tap.start()
        scrollTap = tap
        refreshPanel()
        watchPermission()
        if let configError { showAlert(configError) }
        askLaunchAtLoginOnce()
    }

    /// If Accessibility access is switched off while running, stop cleanly,
    /// show the permission banner, and resume once it's back.
    private func watchPermission() {
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] t in
            guard let self, !AXIsProcessTrusted(), !self.model.needsPermission else { return }
            Log.write("accessibility permission lost")
            self.wm?.stop()
            self.hotKeys.unregisterAll()
            self.model.needsPermission = true
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t2 in
                guard AXIsProcessTrusted() else { return }
                t2.invalidate()
                Log.write("accessibility permission back")
                self?.model.needsPermission = false
                self?.wm?.start()
                self?.registerHotKeys()
                self?.refreshPanel()
            }
            _ = t
        }
    }

    /// First run only: offer to open Reel at login. Never asked again; the
    /// toggle stays in Settings.
    private func askLaunchAtLoginOnce() {
        let key = "askedLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard !settingsModel.launchAtLogin else { return }
        // Let the first tiling pass settle before interrupting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            let alert = NSAlert()
            alert.messageText = "Open Reel when you log in?"
            alert.informativeText = "Your windows will be tiled as soon as you start your Mac. You can change this any time in Reel Settings."
            alert.addButton(withTitle: "Open at Login")
            alert.addButton(withTitle: "Not Now")
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn {
                self?.settingsModel.setLaunchAtLogin(true)
                Log.write("launch at login: \(self?.settingsModel.launchAtLogin == true ? "on" : "failed")")
            }
        }
    }

    private func registerHotKeys() {
        hotKeys.unregisterAll()
        var taken = Set<String>()
        defer { settingsModel.taken = taken }
        for action in actions {
            guard let str = config.shortcuts[action.id], !str.isEmpty else { continue }
            guard let combo = KeyCombo(str) else {
                Log.write("can't parse shortcut \(action.id): \(str)")
                continue
            }
            let ok = hotKeys.register(combo) { [weak self] in
                Log.write("hotkey \(action.id)")
                guard let wm = self?.wm, wm.enabled else { return }
                action.run(wm)
            }
            if !ok {
                taken.insert(action.id)
                Log.write("shortcut \(combo.display) for \(action.id) is taken by another app")
            }
        }
    }

    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: Panel

    /// The app icon's "strip" as a menu bar template: focused window in the
    /// middle, neighbours either side. macOS tints it for light/dark bars.
    static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: CGRect(x: 1, y: 3.5, width: 3, height: 9), xRadius: 1.2, yRadius: 1.2).fill()
            NSBezierPath(roundedRect: CGRect(x: 6, y: 1.5, width: 8, height: 13), xRadius: 2.2, yRadius: 2.2).fill()
            NSBezierPath(roundedRect: CGRect(x: 16, y: 3.5, width: 3, height: 9), xRadius: 1.2, yRadius: 1.2).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Reel"
        return image
    }

    private func setupPanel() {
        model.widthPresets = config.widthPresets.sorted()
        model.shortcuts = config.shortcuts
        model.scrollModifiers = config.scrollModifiers
        model.onWidth = { [weak self] f in self?.wm?.setWidth(f); self?.refreshPanel() }
        model.onLayout = { [weak self] p in
            guard let self, let wm = self.wm else { return }
            wm.applyLayout(pattern: p.pattern, fraction: p.fraction)
            self.refreshPanel()
            // Minimum sizes are confirmed ~0.2 s after the resize.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let names = wm.constrainedApps.sorted()
                guard !names.isEmpty else { return }
                let list = ListFormatter.localizedString(byJoining: names)
                self.model.hint = "\(list) can't get that small, so \(names.count == 1 ? "it takes" : "they take") more room."
            }
        }
        model.onFocus = { [weak self] id in self?.panel.close(); self?.wm?.focusWindow(id) }
        model.onToggle = { [weak self] on in
            guard let self, let wm = self.wm else { return }
            // Paused: release the shortcuts so other apps can use those keys.
            if on {
                wm.start()
                self.registerHotKeys()
            } else {
                wm.stop()
                self.hotKeys.unregisterAll()
            }
            self.refreshPanel()
        }
        model.onSettings = { [weak self] in self?.panel.close(); self?.openSettings() }
        model.onRetile = { [weak self] in self?.reloadConfig() }
        model.onQuit = { NSApp.terminate(nil) }
        model.onPermissions = {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    private func refreshPanel() {
        model.enabled = wm?.enabled ?? false
        let stageManager = (CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString) as? Bool) == true
        model.warning = stageManager ? "⚠︎ Stage Manager is on and will fight Reel. Turn it off in Control Center." : nil
        let snap = wm?.snapshot() ?? .init()
        model.windows = snap.windows.map { item in
            let app = NSRunningApplication(processIdentifier: item.pid)
            return WindowItem(id: item.id, icon: app?.icon ?? NSImage(), name: app?.localizedName ?? "window", focused: item.focused)
        }
        model.focusedFraction = snap.focusedFraction
    }

    @objc private func togglePopover() {
        if panel.isVisible {
            panel.close()
            return
        }
        guard let button = statusItem.button else { return }
        refreshPanel()
        model.hint = nil
        panel.show(below: button)
        Log.write("panel shown at \(panel.frame)")
    }

    private func showAlert(_ text: String) {
        let a = NSAlert()
        a.messageText = "Reel"
        a.informativeText = text
        NSApp.activate()
        a.runModal()
    }

    private func openSettings() {
        if settingsWindow == nil {
            settingsModel.onChange = { [weak self] cfg in self?.apply(cfg) }
            settingsModel.onRecording = { [weak self] recording in
                recording ? self?.hotKeys.unregisterAll() : self?.registerHotKeys()
            }
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: settingsModel)))
            w.title = "Reel Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        settingsModel.config = config
        settingsWindow?.center()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Applies settings live (called on every change in the Settings window).
    private func apply(_ cfg: Config) {
        config = cfg
        model.widthPresets = cfg.widthPresets.sorted()
        model.shortcuts = cfg.shortcuts
        model.scrollModifiers = cfg.scrollModifiers
        scrollTap?.modifiers = Modifiers(string: cfg.scrollModifiers)?.cgFlags ?? []
        if settingsModel.recording == nil { registerHotKeys() }
        wm?.config = cfg
        wm?.layoutAll()
    }

    /// Re-reads config.json and re-tiles (the refresh button).
    private func reloadConfig() {
        let (cfg, err) = Config.load()
        config = cfg
        model.widthPresets = cfg.widthPresets.sorted()
        model.shortcuts = cfg.shortcuts
        model.scrollModifiers = cfg.scrollModifiers
        if let err { showAlert(err) }
        if let wm {
            wm.config = cfg
            registerHotKeys()
            scrollTap?.modifiers = Modifiers(string: cfg.scrollModifiers)?.cgFlags ?? []
            wm.retile()
        }
        refreshPanel()
    }
}
