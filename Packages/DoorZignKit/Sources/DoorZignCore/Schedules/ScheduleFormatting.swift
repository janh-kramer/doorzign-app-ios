import Foundation

public enum ScheduleFormatting {
    public static let abbreviations = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]

    /// Wochentage (1 = Montag … 7 = Sonntag) kompakt: `[1,2,3,4,5]` → „Mo–Fr“, `[1,3,5]` → „Mo, Mi, Fr“,
    /// alle sieben → „Täglich“. Folgen ab drei Tagen werden zusammengefasst.
    public static func weekdays(_ days: [Int]) -> String {
        let sorted = Array(Set(days.filter { (1...7).contains($0) })).sorted()
        guard !sorted.isEmpty else { return "–" }
        if sorted.count == 7 { return "Täglich" }
        var parts: [String] = []
        var runStart = sorted[0]
        var previous = sorted[0]
        func flush() {
            let length = previous - runStart + 1
            if length >= 3 {
                parts.append("\(abbreviations[runStart - 1])–\(abbreviations[previous - 1])")
            } else {
                parts.append(contentsOf: (runStart...previous).map { abbreviations[$0 - 1] })
            }
        }
        for day in sorted.dropFirst() {
            if day == previous + 1 {
                previous = day
            } else {
                flush()
                runStart = day
                previous = day
            }
        }
        flush()
        return parts.joined(separator: ", ")
    }

    /// Zeitfenster `start`–`end`; Ende vor Start bedeutet „über Mitternacht“.
    public static func timeRange(start: String, end: String) -> String {
        end < start ? "\(start)–\(end) Uhr (über Mitternacht)" : "\(start)–\(end) Uhr"
    }
}
