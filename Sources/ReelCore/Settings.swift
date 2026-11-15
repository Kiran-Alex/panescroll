import AppKit
import ServiceManagement
import SwiftUI

final class SettingsModel: ObservableObject {
    @Published var config: Config {
        didSet {
            config.save()
            onChange(config)
        }
    }
    @Published var recording: String?
    /// Actions whose shortcut another app already owns.
    @Published var taken = Set<String>()
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    var onChange: (Config) -> Void = { _ in }
    /// Global hotkeys swallow key presses, so they're paused while recording.
    var onRecording: (Bool) -> Void = { _ in }
    private var monitor: Any?

    init(config: Config) { self.config = config }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.write("launch at login failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func startRecording(_ action: String) {
        stopRecording()
        recording = action
        onRecording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event)
            return nil
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording != nil {
            recording = nil
            onRecording(false)
        }
    }

    private func record(_ event: NSEvent) {
        guard let action = recording else { return }
        switch event.keyCode {
        case 53: // Esc: cancel
            stopRecording()
            return
        case 51, 117: // Delete: clear this shortcut
            config.shortcuts[action] = ""
            stopRecording()
            return
        default: break
        }
        let flags = event.modifierFlags
        var parts: [String] = []
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("opt") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.command) { parts.append("cmd") }
        guard !parts.isEmpty,
              let key = keyCodes.first(where: { $0.value == UInt32(event.keyCode) })?.key else {
            NSSound.beep() // needs at least one modifier and a supported key
            return
        }
        config.shortcuts[action] = (parts + [key]).joined(separator: "+")
        stopRecording()
    }
}

private struct ShortcutField: View {
    @ObservedObject var model: SettingsModel
    let action: String

    var body: some View {
        let recording = model.recording == action
        let combo = model.config.shortcuts[action].flatMap(KeyCombo.init)
        let isTaken = model.taken.contains(action) && !recording
        Button {
            recording ? model.stopRecording() : model.startRecording(action)
        } label: {
            Text(recording ? "Press keys…" : (combo.map { $0.display + (isTaken ? " ⚠︎" : "") } ?? "Not set"))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(recording ? Color.accentColor : isTaken ? .orange : (combo == nil ? .secondary : .primary))
                .frame(width: 110, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(recording ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .help(isTaken ? "Another app already uses this shortcut. Click to pick a different one." : "")
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    private let modifierOptions: [(String, String)] = [
        ("ctrl+opt", "⌃⌥ Control–Option"),
        ("opt", "⌥ Option"),
        ("ctrl", "⌃ Control"),
        ("cmd+opt", "⌘⌥ Command–Option"),
        ("", "Off"),
    ]

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Toggle("Animate when focus moves", isOn: $model.config.animate)
                LabeledContent("Gap between windows") {
                    HStack {
                        Slider(value: $model.config.gap, in: 0...24, step: 2).frame(width: 160)
                        Text("\(Int(model.config.gap)) pt").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                Picker("New window width", selection: $model.config.newWindowWidth) {
                    Text("Keep its own size").tag(Double?.none)
                    Text("⅓ of screen").tag(Double?.some(0.333))
                    Text("½ of screen").tag(Double?.some(0.5))
                    Text("⅔ of screen").tag(Double?.some(0.667))
                    Text("Full screen").tag(Double?.some(1.0))
                }
            }

            Section("Trackpad & mouse") {
                Picker("Hold to scroll the strip", selection: $model.config.scrollModifiers) {
                    ForEach(modifierOptions, id: \.0) { Text($0.1).tag($0.0) }
                }
                LabeledContent("Scroll speed") {
                    Slider(value: Binding(get: { abs(model.config.scrollSpeed) },
                                          set: { model.config.scrollSpeed = model.config.scrollSpeed < 0 ? -$0 : $0 }),
                           in: 0.3...3).frame(width: 200)
                }
                Toggle("Reverse scroll direction", isOn: Binding(get: { model.config.scrollSpeed < 0 },
                                                                  set: { model.config.scrollSpeed = abs(model.config.scrollSpeed) * ($0 ? -1 : 1) }))
            }

            Section {
                ForEach(Config.actions, id: \.id) { action in
                    LabeledContent(action.title) { ShortcutField(model: model, action: action.id) }
                }
            } header: {
                Text("Keyboard shortcuts")
            } footer: {
                HStack {
                    Text("Click a shortcut, then press the new keys. Esc cancels, Delete clears.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore defaults") { model.config.shortcuts = Config.defaultShortcuts }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 620)
        .onDisappear { model.stopRecording() }
    }
}
