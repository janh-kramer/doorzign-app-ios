import DoorZignAPI
import Foundation

public typealias ScheduleInput = Components.Schemas.ScheduleInput

/// Uhrzeit `HH:MM` ohne Datum und Zeitzone (gilt in `Display.timezone`).
public struct ClockTime: Equatable, Comparable, Hashable, Sendable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    public init?(_ text: String) {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m) else {
            return nil
        }
        self.init(hour: h, minute: m)
    }

    public var text: String { String(format: "%02d:%02d", hour, minute) }

    /// Uhrzeit im Format der Locale (de „08:00“, en "8:00 AM").
    public var displayText: String {
        let calendar = CoreL10n.utcCalendar
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: CoreL10n.locale, calendar: calendar)
        style.timeZone = calendar.timeZone
        return date(in: calendar).formatted(style)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute) }

    /// Für DatePicker: Datum im angegebenen Kalender mit dieser Uhrzeit (das Datum selbst ist bedeutungslos).
    public func date(in calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: hour, minute: minute)) ?? Date()
    }

    public init(date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        self.init(hour: c.hour ?? 0, minute: c.minute ?? 0)
    }
}

/// Kalenderdatum `YYYY-MM-DD` ohne Zeitzone.
public struct CalendarDay: Equatable, Comparable, Hashable, Sendable {
    public var year: Int, month: Int, day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year; self.month = month; self.day = day
    }

    public init?(_ text: String) {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    public var text: String { String(format: "%04d-%02d-%02d", year, month, day) }
    /// Kurzes Datum in der Sprache des Geräts, z. B. „01.12.2026“ bzw. „12/01/2026“.
    public var displayText: String {
        let calendar = CoreL10n.utcCalendar
        var style = Date.FormatStyle.dateTime.day(.twoDigits).month(.twoDigits).year().locale(CoreL10n.locale)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date(in: calendar).formatted(style)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day) }

    public func date(in calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date()
    }

    public init(date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 2000, month: c.month ?? 1, day: c.day ?? 1)
    }
}

/// Bearbeitbarer Zeitplan mit Validierung nach ui-spec §6.
public struct ScheduleDraft: Equatable, Sendable {
    public var name = ""
    public var slot = 1
    public var weekdays: Set<Int> = [1, 2, 3, 4, 5]
    public var start = ClockTime(hour: 8, minute: 0)
    public var end = ClockTime(hour: 17, minute: 0)
    public var validFrom: CalendarDay?
    public var validUntil: CalendarDay?
    public var priority = 50
    public var enabled = true

    public init() {}

    public init(_ schedule: Schedule) {
        name = schedule.name
        slot = schedule.slot
        weekdays = Set(schedule.weekdays)
        start = ClockTime(schedule.start) ?? ClockTime(hour: 0, minute: 0)
        end = ClockTime(schedule.end) ?? ClockTime(hour: 0, minute: 0)
        validFrom = schedule.validFrom.flatMap(CalendarDay.init)
        validUntil = schedule.validUntil.flatMap(CalendarDay.init)
        priority = schedule.priority
        enabled = schedule.enabled
    }

    /// Ende vor Start: Zeitfenster läuft über Mitternacht.
    public var crossesMidnight: Bool { end < start }

    /// Validierungsfehler (leer = gültig).
    public var problems: [String] {
        var result: [String] = []
        if weekdays.isEmpty { result.append(L("Bitte mindestens einen Wochentag wählen.")) }
        if start == end { result.append(L("Beginn und Ende dürfen nicht gleich sein.")) }
        if !(0...100).contains(priority) { result.append(L("Die Priorität muss zwischen 0 und 100 liegen.")) }
        if !(1...3).contains(slot) { result.append(L("Bitte eine Ansicht wählen.")) }
        if let validFrom, let validUntil, validUntil < validFrom {
            result.append(L("„Gültig bis“ liegt vor „Gültig ab“."))
        }
        return result
    }

    public var isValid: Bool { problems.isEmpty }

    public var input: ScheduleInput {
        ScheduleInput(
            name: name.trimmingCharacters(in: .whitespaces),
            slot: slot,
            weekdays: weekdays.sorted(),
            start: start.text,
            end: end.text,
            validFrom: validFrom?.text,
            validUntil: validUntil?.text,
            priority: priority,
            enabled: enabled
        )
    }
}

extension ScheduleFormatting {
    /// Gültigkeitszeitraum lesbar, `nil` = unbegrenzt.
    public static func validity(from: String?, until: String?) -> String? {
        let f = from.flatMap(CalendarDay.init)?.displayText
        let u = until.flatMap(CalendarDay.init)?.displayText
        switch (f, u) {
        case (nil, nil): return nil
        case (let f?, nil): return L("ab \(f)")
        case (nil, let u?): return L("bis \(u)")
        case (let f?, let u?): return "\(f) – \(u)"
        }
    }
}
