import Foundation

/// Appends to ~/Library/Logs/Panescroll.log (and stderr).
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Panescroll.log")
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    /// When the log passes this size it's moved to Panescroll.log.1 (one backup).
    private static let maxBytes = 1_000_000

    static func write(_ msg: String) {
        rotateIfNeeded()
        let line = "\(fmt.string(from: Date())) \(msg)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    private static func rotateIfNeeded() {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes else { return }
        let backup = url.appendingPathExtension("1")
        try? fm.removeItem(at: backup)
        try? fm.moveItem(at: url, to: backup)
    }
}
