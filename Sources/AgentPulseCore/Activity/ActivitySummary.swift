import Foundation

/// Builds the one-line "what is it doing now" strings shared by every collector.
public enum ActivitySummary {
    /// `Bash: npm test` — first present of command / file_path / pattern / description.
    public static func summarize(toolName: String, input: [String: Any]?) -> String {
        guard let input else { return toolName }
        for key in ["command", "file_path", "pattern", "description"] {
            if let value = stringValue(input[key]), !value.isEmpty {
                return "\(toolName): \(truncate(value))"
            }
        }
        return toolName
    }

    /// Collapses whitespace and cuts to `limit` characters.
    public static func truncate(_ text: String, limit: Int = 80) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit))
    }

    static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String: value
        case let value as NSNumber: value.stringValue
        case let value as [String: Any]:
            // e.g. arguments objects; show a compact form.
            value.keys.sorted().compactMap { key in
                stringValue(value[key]).map { "\(key): \($0)" }
            }.joined(separator: ", ")
        case let value as [Any]:
            value.compactMap { stringValue($0) }.joined(separator: " ")
        default: nil
        }
    }
}
