import DoorZignCore
import SwiftUI

/// Textfeld mit Zeichenzähler; Eingaben über dem Limit werden abgeschnitten.
struct CountedField: View {
    let title: String
    @Binding var text: String
    let limit: Int
    var axis: Axis = .horizontal

    init(_ title: String, text: Binding<String>, limit: Int, axis: Axis = .horizontal) {
        self.title = title
        self._text = text
        self.limit = limit
        self.axis = axis
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            TextField(title, text: Binding(
                get: { text },
                set: { text = String($0.prefix(limit)) }
            ), axis: axis)
            .lineLimit(axis == .vertical ? 2...4 : 1...1)
            Text("\(text.count)/\(limit)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(text.count >= limit ? Color.orange : Color.secondary)
        }
    }
}

/// Auswahl Schwarz/Weiß/Rot.
struct ColorChoice: View {
    let title: String
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
