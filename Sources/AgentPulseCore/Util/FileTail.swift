import Foundation

/// Reads only the tail of a file. Used for big append-only logs.
public enum FileTail {
    /// Returns the last `maxBytes` of the file decoded as UTF-8.
    ///
    /// When the file is larger than `maxBytes`, the first (likely partial) line is
    /// dropped so that callers never see a truncated JSON object at the start.
    public static func read(url: URL, maxBytes: Int = 64 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size: UInt64
        do {
            size = try handle.seekToEnd()
        } catch {
            return nil
        }

        let truncated = size > UInt64(maxBytes)
        let start = truncated ? size - UInt64(maxBytes) : 0

        do {
            try handle.seek(toOffset: start)
        } catch {
            return nil
        }

        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        var text = String(decoding: data, as: UTF8.self)

        if truncated, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return text
    }
}
