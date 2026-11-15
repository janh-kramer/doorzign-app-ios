import DoorZignCore
import SwiftUI

/// Textfeld mit Zeichenzähler. Neue Eingaben über dem Limit werden abgeschnitten.
/// Bereits zu lange Texte (z. B. aus der Edge-Weboberfläche) bleiben unverändert stehen,
/// bis sie gekürzt werden – nie stilles Abschneiden vorhandener Inhalte.
struct CountedField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    let limit: Int
    var axis: Axis = .horizontal

    init(_ title: LocalizedStringKey, text: Binding<String>, limit: Int, axis: Axis = .horizontal) {
        self.title = title
        self._text = text
        self.limit = limit
        self.axis = axis
    }

    private var isTooLong: Bool { text.count > limit }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            TextField(title, text: Binding(
                get: { text },
                set: { text = SlotDraft.Text.limitedInput($0, previous: text, limit: limit) }
            ), axis: axis)
            .lineLimit(axis == .vertical ? 2...4 : 1...1)
            Text("\(text.count)/\(limit)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isTooLong ? Color.red : text.count == limit ? Color.orange : Color.secondary)
            if isTooLong {
                Text("Zu lang – bitte auf höchstens \(limit) Zeichen kürzen.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Auswahl Schwarz/Weiß/Rot.
struct ColorChoice: View {
    let title: LocalizedStringKey
    @Binding var selection: SlotColor

    var body: some View {
        Picker(title, selection: $selection) {
            Text("Schwarz").tag(SlotColor.black)
            Text("Weiß").tag(SlotColor.white)
            Text("Rot").tag(SlotColor.red)
        }
    }
}

/// Felder und Farben einer Textansicht – genutzt vom Editor und der Ad-hoc-Nachricht.
struct TextContentFields: View {
    @Binding var text: SlotDraft.Text

    var body: some View {
        let limits = SlotDraft.Text.limits
        Section("Text") {
            CountedField("Titel", text: $text.title, limit: limits.title)
            CountedField("Überschrift", text: $text.headline, limit: limits.headline)
            CountedField("Unterüberschrift", text: $text.subHeadline, limit: limits.subHeadline)
            CountedField("Nachricht", text: $text.message, limit: limits.message, axis: .vertical)
        }
        Section("Farben") {
            ColorChoice(title: "Text", selection: $text.color)
            ColorChoice(title: "Hintergrund", selection: $text.bg)
            ColorChoice(title: "Nachrichtentext", selection: $text.messageColor)
            ColorChoice(title: "Nachrichtenhintergrund", selection: $text.messageBg)
        }
    }
}
