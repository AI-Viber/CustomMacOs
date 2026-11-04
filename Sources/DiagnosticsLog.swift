import Foundation

/// Small rolling text logs used to troubleshoot behaviour on the user's Mac.
/// Written to the project folder the app was built from (build.sh records it in Info.plist
/// as CMOSProjectDir) if it still exists, otherwise ~/Library/Logs/CustomMacOS.
/// Each log keeps its most recent 300 lines.
enum DiagnosticsLog {
    private static let maxLines = 300
    private static let queue = DispatchQueue(label: "CustomMacOS.DiagnosticsLog")

    static var directory: URL {
        let fm = FileManager.default
        if let path = Bundle.main.object(forInfoDictionaryKey: "CMOSProjectDir") as? String, !path.isEmpty {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/CustomMacOS")
    }

    /// Appends a timestamped line to `<name>-diagnostics.txt`.
    static func append(_ name: String, _ line: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withFullDate, .withFullTime])
        let entry = "\(stamp)  \(line)"
        queue.async {
            let fm = FileManager.default
            let dir = directory
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(name)-diagnostics.txt")
            var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            lines.append(entry)
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
            try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
