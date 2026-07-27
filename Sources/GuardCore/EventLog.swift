import Foundation

/// Where the engine's human-readable events go, in addition to os_log.
///
/// A file log exists because `log show` is TCC-restricted for non-interactive
/// shells on this machine: when the speaker misbehaves, os_log alone gives no
/// way to find out what the guard actually did.
public protocol EventSink: AnyObject, Sendable {
    func write(_ line: String)
}

public final class FileEventLog: EventSink, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private let maxBytes: UInt64
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Defaults to ~/Library/Logs/BMR1Guard.log
    public init(url: URL? = nil, maxBytes: UInt64 = 512 * 1024) {
        self.url = url ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/BMR1Guard.log")
        self.maxBytes = maxBytes
    }

    public var path: String { url.path }

    public func write(_ line: String) {
        let stamped = "\(formatter.string(from: Date()))  \(line)\n"
        guard let data = stamped.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64,
           size > maxBytes {
            // Single-generation rotation: keep the previous file for context.
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
