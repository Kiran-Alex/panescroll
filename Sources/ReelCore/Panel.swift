import AppKit
import SwiftUI

struct LayoutPreset: Identifiable {
    let id: String
    let detail: String
    /// Windows per column, repeated along the strip.
    let pattern: [Int]
    /// Column width as a fraction of the screen; nil keeps each window's width.
    let fraction: Double?

    static let all: [LayoutPreset] = [
        .init(id: "halves", detail: "Two windows side by side on every screen.", pattern: [1], fraction: 0.5),
        .init(id: "thirds", detail: "Three windows side by side on every screen.", pattern: [1], fraction: 0.333),
        .init(id: "stackLeft", detail: "Two stacked on the left, one on the right. Repeats along the strip.", pattern: [2, 1], fraction: 0.5),
        .init(id: "stackRight", detail: "One on the left, two stacked on the right. Repeats along the strip.", pattern: [1, 2], fraction: 0.5),
        .init(id: "grid4", detail: "A 2×2 grid on every screen.", pattern: [2], fraction: 0.5),
        .init(id: "grid6", detail: "Three columns of two stacked windows.", pattern: [2], fraction: 0.333),
        .init(id: "full", detail: "One window fills the screen. Scroll to reach the others.", pattern: [1], fraction: 1.0),
        .init(id: "row", detail: "One row again, each window at its own original width.", pattern: [1], fraction: nil),
    ]

    /// Column counts to draw in the preview: one screen's worth.
    var previewColumns: [Int] {
        let visible = fraction.map { max(1, Int((1 / $0).rounded())) } ?? 4
        return (0..<visible).map { pattern[$0 % pattern.count] }
    }
}

struct WindowItem: Identifiable {
    let id: CGWindowID
    let icon: NSImage
    let name: String
    let focused: Bool
}

final class PanelModel: ObservableObject {
    @Published var needsPermission = false
    @Published var enabled = false
    @Published var windows: [WindowItem] = []
    @Published var focusedFraction: Double?
    @Published var hint: String?
    @Published var showShortcuts = false
    @Published var warning: String?
    var widthPresets: [Double] = [0.333, 0.5, 0.667, 1.0]
    var shortcuts: [String: String] = [:]
    var scrollModifiers = "ctrl+opt"

    var onWidth: (Double) -> Void = { _ in }
    var onLayout: (LayoutPreset) -> Void = { _ in }
    var onFocus: (CGWindowID) -> Void = { _ in }
    var onToggle: (Bool) -> Void = { _ in }
    var onSettings: () -> Void = {}
    var onRetile: () -> Void = {}
    var onQuit: () -> Void = {}
    var onPermissions: () -> Void = {}

    var focusedIcon: NSImage? { windows.first(where: \.focused)?.icon }

    func shortcut(_ action: String) -> String {
        guard let s = shortcuts[action], let combo = KeyCombo(s) else { return "" }
        return "   \(combo.display)"
    }
}

// MARK: Views

private let accent = Color.accentColor

private struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(1.0)
            .foregroundStyle(accent)
    }
}

private struct AppIcon: View {
    let image: NSImage?
    var size: CGFloat = 18
    var body: some View {
        if let image {
            Image(nsImage: image).resizable().frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.25)).frame(width: size * 0.7, height: size * 0.7)
        }
    }
}

/// A rounded tile with hover feedback and a selected outline.
private struct Tile<Content: View>: View {
    let selected: Bool
    let hint: String
    @Binding var hover: String?
    let action: () -> Void
    var padding: CGFloat = 5
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content
                .padding(padding)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hovering ? 0.12 : 0.05)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? accent : .clear, lineWidth: 1.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in
            hovering = h
            hover = h ? hint : nil
        }
    }
}

private struct Slot: View {
    var filled = false
    var icon: NSImage?
    var showIcon = true
    var iconSize: CGFloat = 14
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(filled ? accent.opacity(0.4) : Color.primary.opacity(0.10))
            .overlay {
                if filled || icon != nil, showIcon { AppIcon(image: icon, size: iconSize) }
            }
    }
}

private struct IconButton: View {
    let symbol: String
    let hint: String
    @Binding var hover: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hovering ? 0.12 : 0.06)))
        }
        .buttonStyle(.plain)
        .onHover { h in
            hovering = h
            hover = h ? hint : nil
        }
    }
}

struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if model.needsPermission {
                permissionBanner
            } else {
                Group {
                    if model.showShortcuts {
                        shortcutsList
                    } else {
                        VStack(alignment: .leading, spacing: 9) {
                            labeled("WIDTH") { widthRow }
                            labeled("LAYOUT") { layoutsRow }
                            labeled("WINDOWS") { windowsRow }
                        }
                        .disabled(!model.enabled)
                        .opacity(model.enabled ? 1 : 0.45)
                    }
                }
                .frame(height: 124, alignment: .top) // same height in both modes
            }
            Divider()
            Text(model.hint ?? defaultHint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: 30, alignment: .topLeading) // fixed so the panel never resizes
        }
        .padding(14)
        .frame(width: 460)
    }

    private func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) {
            SectionTitle(text: title).frame(width: 68, alignment: .leading)
            content()
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 20, height: 20)
            Text("Reel").font(.system(size: 13, weight: .semibold))
            Spacer()
            IconButton(symbol: "arrow.clockwise", hint: "Re-tile every window.\(model.shortcut("retile"))", hover: $model.hint, action: model.onRetile)
            IconButton(symbol: model.showShortcuts ? "square.grid.2x2" : "keyboard",
                       hint: model.showShortcuts ? "Back to layouts." : "Show keyboard shortcuts.",
                       hover: $model.hint, action: { model.showShortcuts.toggle() })
            IconButton(symbol: "gearshape", hint: "Settings: shortcuts, scrolling, gaps, launch at login.", hover: $model.hint, action: model.onSettings)
            IconButton(symbol: "power", hint: "Quit Reel. Windows go back to where they were.", hover: $model.hint, action: model.onQuit)
            Toggle("", isOn: Binding(get: { model.enabled }, set: { model.onToggle($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(model.needsPermission)
                .onHover { model.hint = $0 ? "Turn tiling on or off. Off puts windows back where they were." : nil }
        }
    }

    private var shortcutsList: some View {
        let items = Config.actions.map { ($0.title, model.shortcuts[$0.id].flatMap(KeyCombo.init)?.display ?? "—") }
            + [("Scroll the strip", (Modifiers(string: model.scrollModifiers)?.symbols ?? "") + " + scroll")]
        let half = (items.count + 1) / 2
        return HStack(alignment: .top, spacing: 18) {
            ForEach([Array(items.prefix(half)), Array(items.dropFirst(half))], id: \.first?.0) { col in
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(col, id: \.0) { item in
                        HStack {
                            Text(item.0).foregroundStyle(.secondary)
                            Spacer()
                            Text(item.1).font(.system(size: 11, weight: .medium, design: .rounded))
                        }
                        .font(.system(size: 11))
                    }
                }
            }
        }
    }

    private var defaultHint: String {
        if model.needsPermission { return "" }
        if let w = model.warning { return w }
        if !model.enabled { return "Tiling is paused. Turn it back on with the switch." }
        return "Hold ⌃⌥ and scroll to move along the strip. Hover anything to see what it does."
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reel needs Accessibility access").font(.system(size: 12, weight: .semibold))
            Text("Turn on Reel in System Settings → Privacy & Security → Accessibility. If it's already on, remove it with − and add it again.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Accessibility Settings", action: model.onPermissions)
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
    }

    private var widthRow: some View {
        HStack(spacing: 6) {
            ForEach(model.widthPresets, id: \.self) { f in
                Tile(selected: model.focusedFraction == f,
                     hint: "Make the focused window \(label(f)) of the screen.\(model.shortcut("cycleWidth"))",
                     hover: $model.hint, action: { model.onWidth(f) }) {
                    HStack(spacing: 2) {
                        Slot(filled: true, icon: model.focusedIcon, iconSize: 12)
                            .frame(width: max(14, 62 * f))
                        if f < 0.99 { Slot() }
                    }
                    .frame(width: 64, height: 20)
                }
            }
        }
    }

    private var layoutsRow: some View {
        HStack(spacing: 5) {
            ForEach(LayoutPreset.all) { preset in
                Tile(selected: false, hint: preset.detail, hover: $model.hint, action: { model.onLayout(preset) }, padding: 4) {
                    preview(preset).frame(width: 30, height: 22)
                }
            }
        }
    }

    private var windowsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if model.windows.isEmpty {
                    Text("No windows on this screen yet.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(model.windows) { w in
                    Tile(selected: w.focused, hint: "Jump to \(w.name).", hover: $model.hint, action: { model.onFocus(w.id) }, padding: 3) {
                        AppIcon(image: w.icon, size: 22)
                    }
                }
            }
            .padding(2)
        }
        .frame(height: 34)
    }

    /// Mini picture of one screen with the layout.
    private func preview(_ preset: LayoutPreset) -> some View {
        let cols = preset.previewColumns
        return HStack(spacing: 2) {
            ForEach(0..<cols.count, id: \.self) { c in
                VStack(spacing: 2) {
                    ForEach(0..<cols[c], id: \.self) { _ in Slot(filled: true, showIcon: false) }
                }
            }
        }
    }

    private func label(_ f: Double) -> String {
        switch f {
        case ..<0.3: return "a quarter"
        case ..<0.4: return "a third"
        case ..<0.6: return "half"
        case ..<0.8: return "two thirds"
        default: return "the full width"
        }
    }
}
