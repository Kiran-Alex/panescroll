import AppKit
import SwiftUI

/// A borderless floating panel pinned right under the menu bar icon.
/// Used instead of NSPopover, which repositions itself when SwiftUI content
/// resizes and ends up floating away from the menu bar.
final class PanelWindow: NSPanel {
    private let host: NSHostingView<PanelView>
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?

    init(model: PanelModel) {
        host = NSHostingView(rootView: PanelView(model: model))
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 0.5
        blur.layer?.borderColor = NSColor.separatorColor.cgColor
        host.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor),
            host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        contentView = blur
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }

    /// Shows the panel centred under `button`, kept inside the screen.
    func show(below button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let size = host.fittingSize
        var x = anchor.midX - size.width / 2
        if let vf = screen?.visibleFrame {
            x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        }
        let y = anchor.minY - 6 - size.height
        setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: true)
        makeKeyAndOrderFront(nil)

        // Close on any click outside the panel, or on Escape.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.close(); return nil }
            return event
        }
    }

    override func close() {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        outsideClickMonitor = nil
        keyMonitor = nil
        orderOut(nil)
    }
}
