import CoreGraphics
import Foundation

/// Persists each window's original frame to
/// ~/Library/Application Support/Reel/original-frames.json, so turning tiling
/// off restores real sizes even after Reel crashed or was relaunched.
enum FrameStore {
    struct Entry: Codable {
        let pid: pid_t
        let frame: CGRect
    }

    private static var url: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Reel")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("original-frames.json")
    }

    /// Entries whose process is gone are dropped (window IDs restart after reboot).
    static func load() -> [CGWindowID: Entry] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        var out: [CGWindowID: Entry] = [:]
        for (k, v) in raw where kill(v.pid, 0) == 0 {
            if let id = CGWindowID(k) { out[id] = v }
        }
        return out
    }

    static func save(_ frames: [CGWindowID: Entry]) {
        let raw = Dictionary(uniqueKeysWithValues: frames.map { (String($0.key), $0.value) })
        try? JSONEncoder().encode(raw).write(to: url, options: .atomic)
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }
}
