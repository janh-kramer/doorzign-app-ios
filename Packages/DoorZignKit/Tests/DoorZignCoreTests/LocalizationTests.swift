import DoorZignAPI
import Foundation
import Testing
@testable import DoorZignCore

/// Texte aus DoorZignCore: Deutsch ist Quellsprache, Englisch über en.lproj.
@Suite @MainActor struct LocalizationTests {
    static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DoorZignCore")
    }

    /// Schlüssel aus `L("…")` und `L(key: "…", …)`; Interpolationen werden zu `%`.
    static func sourceKeys() throws -> Set<String> {
        var keys = Set<String>()
        let files = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && $0.lastPathComponent != "CoreL10n.swift" }
        for file in files {
            let text = Array(try String(contentsOf: file, encoding: .utf8))
            var i = 0
            while i < text.count - 3 {
                if text[i] == "L", text[i + 1] == "(", i == 0 || !(text[i - 1].isLetter || text[i - 1].isNumber) {
                    var j = i + 2
                    if text[j...].starts(with: Array("key: \"")) {
                        j += 6
                        var key = ""
                        while text[j] != "\"" { key.append(text[j]); j += 1 }
                        keys.insert(key)
                    } else if text[j] == "\"" {
                        keys.insert(parseLiteral(text, from: j + 1))
                    }
                }
                i += 1
            }
        }
        return keys
    }

    /// Liest ein Stringliteral ab `start` (nach dem öffnenden `"`); `\(…)` wird zu `%`.
    static func parseLiteral(_ text: [Character], from start: Int) -> String {
        var result = "", j = start
        while text[j] != "\"" {
            if text[j] == "\\", text[j + 1] == "(" {
                var depth = 1, k = j + 2, inString = false
                while depth > 0 {
                    if text[k] == "\"" { inString.toggle() } else if !inString {
                        if text[k] == "(" { depth += 1 } else if text[k] == ")" { depth -= 1 }
                    }
                    k += 1
                }
                result.append("%"); j = k
            } else {
                result.append(text[j]); j += 1
            }
        }
        return result
    }

    static func stringsKeys(_ language: String) throws -> [String: String] {
        let url = sourceRoot.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
        return try #require(NSDictionary(contentsOf: url) as? [String: String])
    }

    static func normalized(_ key: String) -> String {
        key.replacingOccurrences(of: "%lld", with: "%").replacingOccurrences(of: "%@", with: "%")
    }

    @Test func jederSchluesselHatEineEnglischeUebersetzung() throws {
        let used = try Self.sourceKeys()
        #expect(used.count > 60)
        let english = try Self.stringsKeys("en")
        let available = Set(english.keys.map(Self.normalized))
        let missing = used.filter { !available.contains($0) }.sorted()
        #expect(missing.isEmpty, "Ohne englische Übersetzung: \(missing)")
        let unused = Set(english.keys).filter { !used.contains(Self.normalized($0)) }.sorted()
        #expect(unused.isEmpty, "Nicht (mehr) verwendet: \(unused)")
        // Platzhalter müssen in Schlüssel und Übersetzung übereinstimmen.
        for (key, value) in english {
            #expect(key.components(separatedBy: "%").count == value.components(separatedBy: "%").count, "\(key)")
        }
    }

    @Test func englischeTexte() throws {
        let en = try #require(CoreL10n.bundle(language: "en"))
        CoreL10n.$bundleOverride.withValue(en) {
            #expect(ScheduleFormatting.weekdays([1, 2, 3, 4, 5]) == "Mon–Fri")
            #expect(ScheduleFormatting.weekdays(Array(1...7)) == "Daily")
            #expect(ScheduleFormatting.timeRange(start: "22:00", end: "06:00") == "22:00–06:00 (overnight)")
            #expect(ScheduleFormatting.validity(from: "2026-12-01", until: nil)?.hasPrefix("from ") == true)
            #expect(AdhocModel.label(minutes: 90) == "1 h 30 min")
            #expect(APIError.unexpected(statusCode: 502).message == "The system is currently unreachable (error 502).")
            #expect(APIError.calendarUnlicensedMessage == "There is no calendar license for this display.")
            #expect(SlotDraft.Kind.image.label == "Image")
            #expect(SlotEditorModel.fieldLabel("content.headline") == "Headline")
            var draft = SlotDraft(kind: .text)
            draft.text.headline = String(repeating: "H", count: 80)
            #expect(draft.incompleteReason == "Too long to save: Headline (80/75). Please shorten.")
        }
    }

    @Test func deutschBleibtQuelle() throws {
        let de = try #require(CoreL10n.bundle(language: "de"))
        CoreL10n.$bundleOverride.withValue(de) {
            #expect(ScheduleFormatting.weekdays([1, 2, 3, 4, 5]) == "Mo–Fr")
            #expect(AdhocModel.label(minutes: 90) == "1 Std. 30 Min.")
            #expect(APIError.unexpected(statusCode: 502).message == "Das System ist gerade nicht erreichbar (Fehler 502).")
        }
    }
}
