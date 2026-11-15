import Foundation

/// User settings, stored at ~/.config/panescroll/config.json. Missing keys fall back
/// to defaults, so the file only needs the values you want to change.
struct Config: Codable {
    var gap: Double = 8
    /// Fractions of screen width that "cycleWidth" steps through.
    var widthPresets: [Double] = [0.333, 0.5, 0.667, 1.0]
    /// Width for newly opened windows as a fraction of the screen. nil keeps
    /// the window's own width.
    var newWindowWidth: Double? = nil
    /// Hold these and scroll (two fingers or mouse wheel) to move the strip.
    var scrollModifiers: String = "ctrl+opt"
    /// Scroll multiplier. Make it negative to flip the direction.
    var scrollSpeed: Double = 1.0
    /// Smoothly slide the strip when focus moves.
    var animate: Bool = true
    /// Bundle IDs that Panescroll leaves alone, e.g. "com.apple.calculator".
    var ignoredBundleIDs: [String] = []
    var shortcuts: [String: String] = Config.defaultShortcuts

    static let defaultShortcuts: [String: String] = [
        "focusLeft": "ctrl+opt+left",
        "focusRight": "ctrl+opt+right",
        "focusUp": "ctrl+opt+up",
        "focusDown": "ctrl+opt+down",
        "moveLeft": "ctrl+opt+shift+left",
        "moveRight": "ctrl+opt+shift+right",
        "scrollLeft": "ctrl+opt+,",
        "scrollRight": "ctrl+opt+.",
        "cycleWidth": "ctrl+opt+r",
        "center": "ctrl+opt+c",
        "stack": "ctrl+opt+[",
        "unstack": "ctrl+opt+]",
        "retile": "ctrl+opt+t",
    ]

    /// Every shortcut action with a readable name, in display order.
    static let actions: [(id: String, title: String)] = [
        ("focusLeft", "Focus left"),
        ("focusRight", "Focus right"),
        ("focusUp", "Focus up in stack"),
        ("focusDown", "Focus down in stack"),
        ("moveLeft", "Move window left"),
        ("moveRight", "Move window right"),
        ("scrollLeft", "Scroll left"),
        ("scrollRight", "Scroll right"),
        ("cycleWidth", "Cycle width"),
        ("center", "Center window"),
        ("stack", "Stack into left column"),
        ("unstack", "Pop out of stack"),
        ("retile", "Re-tile all"),
    ]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        gap = try c.decodeIfPresent(Double.self, forKey: .gap) ?? d.gap
        widthPresets = try c.decodeIfPresent([Double].self, forKey: .widthPresets) ?? d.widthPresets
        newWindowWidth = try c.decodeIfPresent(Double.self, forKey: .newWindowWidth)
        scrollModifiers = try c.decodeIfPresent(String.self, forKey: .scrollModifiers) ?? d.scrollModifiers
        scrollSpeed = try c.decodeIfPresent(Double.self, forKey: .scrollSpeed) ?? d.scrollSpeed
        animate = try c.decodeIfPresent(Bool.self, forKey: .animate) ?? d.animate
        ignoredBundleIDs = try c.decodeIfPresent([String].self, forKey: .ignoredBundleIDs) ?? d.ignoredBundleIDs
        let custom = try c.decodeIfPresent([String: String].self, forKey: .shortcuts) ?? [:]
        shortcuts = d.shortcuts.merging(custom) { _, new in new }
    }

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/panescroll/config.json")
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: Config.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(self).write(to: Config.fileURL, options: .atomic)
    }

    /// Loads the config, writing a default file on first run.
    /// Returns an error message if the file exists but couldn't be parsed.
    static func load() -> (Config, String?) {
        let url = fileURL
        guard let data = try? Data(contentsOf: url) else {
            let cfg = Config()
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(cfg).write(to: url)
            return (cfg, nil)
        }
        do {
            return (try JSONDecoder().decode(Config.self, from: data), nil)
        } catch {
            return (Config(), "Couldn't read \(url.path): \(error.localizedDescription). Using defaults.")
        }
    }
}
