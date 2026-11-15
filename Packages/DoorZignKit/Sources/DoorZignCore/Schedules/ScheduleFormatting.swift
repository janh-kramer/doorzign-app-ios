import Foundation

public enum ScheduleFormatting {
    /// Kurze Wochentagsnamen aus der Locale, Montag zuerst (de: „Mo“ … „So“, en: "Mon" … "Sun").
    public static var abbreviations: [String] {
        let symbols = CoreL10n.utcCalendar.shortStandaloneWeekdaySymbols  // beginnt mit Sonntag
        return Array(symbols[1...]) + [symbols[0]]
    }

    /// Voller Wochentagsname aus der Locale (1 = Montag … 7 = Sonntag), z. B. für VoiceOver.
    public static func fullName(_ day: Int) -> String {
        let symbols = CoreL10n.utcCalendar.standaloneWeekdaySymbols  // beginnt mit Sonntag
        return symbols[day % 7]
    }

    /// Wochentage (1 = Montag … 7 = Sonntag) kompakt: `[1,2,3,4,5]` → „Mo–Fr“, `[1,3,5]` → „Mo, Mi, Fr“,
    /// alle sieben → „Täglich“. Folgen ab drei Tagen werden zusammengefasst.
    public static func weekdays(_ days: [Int]) -> String {
        let sorted = Array(Set(days.filter { (1...7).contains($0) })).sorted()
        guard !sorted.isEmpty else { return "–" }
        if sorted.count == 7 { return L("Täglich") }
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
    /// Uhrzeiten im Format der Locale (de „08:00“, en "8:00 AM").
    public static func timeRange(start: String, end: String) -> String {
        let from = ClockTime(start)?.displayText ?? start
        let to = ClockTime(end)?.displayText ?? end
        return end < start ? L("\(from)–\(to) Uhr (über Mitternacht)") : L("\(from)–\(to) Uhr")
    }
}
