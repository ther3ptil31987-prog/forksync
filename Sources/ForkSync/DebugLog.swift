import Foundation

/// Debug-Protokoll in Datei: ~/Library/Logs/ForkSync/debug.log (keine Tokens, nur Pfade, Status, Fehlertexte).
enum DebugLog {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/ForkSync")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }()
    private static let queue = DispatchQueue(label: "forksync.debuglog")
    private static let maxBytes = 2_000_000
    private static let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func write(_ category: String, _ text: String) {
        let line = "\(fmt.string(from: Date())) [\(category)] \(text)\n"
        queue.async {
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
                let old = url.deletingLastPathComponent().appendingPathComponent("debug.old.log")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
