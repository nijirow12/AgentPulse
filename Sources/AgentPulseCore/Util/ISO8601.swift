import Foundation

public enum ISO8601 {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    /// Parses the ISO-8601 variants the APIs actually return (with or without
    /// fractional seconds, `+00:00` or `Z`).
    public static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let date = try? withFraction.parse(string) { return date }
        if let date = try? plain.parse(string) { return date }
        if let normalized = normalizedFraction(string), let date = try? withFraction.parse(normalized) {
            return date
        }
        return nil
    }

    /// Slices long fractional-second runs (`...123456+00:00`) down to milliseconds,
    /// which `ISO8601FormatStyle` accepts.
    private static func normalizedFraction(_ string: String) -> String? {
        guard let dot = string.firstIndex(of: ".") else { return nil }
        let afterDot = string.index(after: dot)
        var end = afterDot
        while end < string.endIndex, string[end].isNumber {
            end = string.index(after: end)
        }
        let digits = string[afterDot..<end]
        guard digits.count > 3 else { return nil }
        let kept = digits.prefix(3)
        return String(string[..<afterDot]) + "." + kept + String(string[end...])
    }
}
