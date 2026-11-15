import DoorZignAPI
import Foundation
import OpenAPIRuntime

public typealias SlotColor = Components.Schemas.Color

/// Bearbeitbarer Entwurf einer Ansicht. Hält die Werte aller Typen, damit beim Umschalten
/// zwischen Text, Bild und Kalender nichts verloren geht; gespeichert wird nur der gewählte Typ.
public struct SlotDraft: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case text, image, calendar, deactivated
        public var id: Self { self }

        public var label: String {
            switch self {
            case .text: L("Text")
            case .image: L("Bild")
            case .calendar: L("Kalender")
            case .deactivated: L("Deaktiviert")
            }
        }
    }

    public struct Text: Equatable, Sendable {
        public static let limits = (title: 50, headline: 75, subHeadline: 50, message: 100)

        public var title = ""
        public var headline = ""
        public var subHeadline = ""
        public var message = ""
        // Standardfarben neue Ansicht (ui-spec §4).
        public var color: SlotColor = .black
        public var bg: SlotColor = .white
        public var messageColor: SlotColor = .white
        public var messageBg: SlotColor = .black

        public init() {}

        public var isValid: Bool {
            title.count <= Self.limits.title && headline.count <= Self.limits.headline
                && subHeadline.count <= Self.limits.subHeadline && message.count <= Self.limits.message
        }

        /// Felder über dem Vertragslimit (Edge-Web erlaubt längere Texte) mit Länge und Limit.
        public var tooLongFields: [(name: String, count: Int, limit: Int)] {
            [(L("Titel"), title, Self.limits.title), (L("Überschrift"), headline, Self.limits.headline),
             (L("Unterüberschrift"), subHeadline, Self.limits.subHeadline), (L("Nachricht"), message, Self.limits.message)]
                .filter { $0.1.count > $0.2 }
                .map { (name: $0.0, count: $0.1.count, limit: $0.2) }
        }

        /// Eingabe begrenzen: Wachsen über das Limit wird abgeschnitten; ein bereits zu langer Text
        /// darf nur gekürzt oder gleich lang bearbeitet werden und wird nicht still abgeschnitten.
        public static func limitedInput(_ new: String, previous: String, limit: Int) -> String {
            if new.count <= limit { return new }
            if previous.count <= limit { return String(new.prefix(limit)) }
            return new.count <= previous.count ? new : previous
        }

        /// Mindestens ein Feld enthält Text (außer Leerzeichen).
        public var hasText: Bool {
            [title, headline, subHeadline, message].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        public init(_ content: Components.Schemas.TextContent) {
            title = content.title ?? ""
            headline = content.headline ?? ""
            subHeadline = content.subHeadline ?? ""
            message = content.message ?? ""
            color = content.color ?? .black
            bg = content.bg ?? .white
            messageColor = content.messageColor ?? .white
            messageBg = content.messageBg ?? .black
        }

        public var textContent: Components.Schemas.TextContent {
            .init(
                _type: .text,
                title: title, headline: headline, subHeadline: subHeadline, message: message,
                color: color, bg: bg, messageColor: messageColor, messageBg: messageBg
            )
        }
    }

    public struct Image: Equatable, Sendable {
        public var mediaId: String?
        public var fit: Components.Schemas.ImageContent.FitPayload = .crop
        public var background: SlotColor = .white
        public var dither = true
        public init() {}
    }

    public struct Calendar: Equatable, Sendable {
        public var source: Components.Schemas.CalendarContent.SourcePayload = .ical
        public var name = ""
        public var url = ""
        public var timezone: String?
        /// Darstellung – in v1 unverändert durchreichen.
        public var view: Components.Schemas.CalendarContent.ViewPayload?
        public init() {}

        /// `webcal://` → `https://`, Leerraum entfernen.
        public static func normalizedURL(_ raw: String) -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("webcal://") {
                return "https://" + trimmed.dropFirst("webcal://".count)
            }
            return trimmed
        }

        public var isValidURL: Bool {
            guard let url = URL(string: Self.normalizedURL(self.url)),
                  let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
                  url.host() != nil
            else { return false }
            return true
        }
    }

    public var kind: Kind
    public var text = Text()
    public var image = Image()
    public var calendar = Calendar()

    public init(kind: Kind = .text) {
        self.kind = kind
    }

    public init(_ content: SlotContent) {
        switch content {
        case .text(let t):
            self.init(kind: .text)
            text = Text(t)
        case .image(let i):
            self.init(kind: .image)
            image.mediaId = i.mediaId
            image.fit = i.fit ?? .crop
            image.background = i.background ?? .white
            image.dither = i.dither ?? true
        case .calendar(let c):
            self.init(kind: .calendar)
            calendar.source = c.source
            calendar.name = c.name ?? ""
            calendar.url = c.url ?? ""
            calendar.timezone = c.timezone
            calendar.view = c.view
        case .deactivated:
            self.init(kind: .deactivated)
        }
    }

    /// Inhalt für `PUT`/`POST …/preview`, oder `nil`, wenn der Entwurf unvollständig ist.
    public var content: SlotContent? {
        switch kind {
        case .text:
            guard text.isValid else { return nil }
            return .text(text.textContent)
        case .image:
            guard let mediaId = image.mediaId else { return nil }
            return .image(.init(_type: .image, mediaId: mediaId, fit: image.fit, background: image.background, dither: image.dither))
        case .calendar:
            guard calendar.source == .ical, calendar.isValidURL else { return nil }
            return .calendar(.init(
                _type: .calendar,
                source: .ical,
                url: Calendar.normalizedURL(calendar.url),
                name: calendar.name,
                timezone: calendar.timezone,
                view: calendar.view
            ))
        case .deactivated:
            return .deactivated(.init(_type: .deactivated))
        }
    }

    /// Hinweis, warum der Entwurf (noch) nicht gespeichert werden kann.
    public var incompleteReason: String? {
        switch kind {
        case .text:
            text.isValid ? nil
                : L("Zu lang zum Speichern: \(text.tooLongFields.map { "\($0.name) (\($0.count)/\($0.limit))" }.joined(separator: ", ")). Bitte kürzen.")
        case .image: image.mediaId == nil ? L("Bitte ein Bild auswählen.") : nil
        case .calendar:
            calendar.source == .zeitwart ? L("Wird in Zeitwart konfiguriert.")
                : calendar.isValidURL ? nil : L("Bitte eine gültige Kalender-URL eingeben.")
        case .deactivated: nil
        }
    }
}
