import SwiftUI

/// Fehlermeldung als Formularabschnitt.
struct ErrorSection: View {
    let message: String?

    var body: some View {
        if let message {
            Section {
                Label {
                    Text(message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                .font(.callout)
            }
        }
    }
}

/// Symbol und Text eng nebeneinander. Der Standardstil richtet Label-Symbole in `List`-Zeilen
/// in einer festen Spalte aus und lässt dahinter viel Platz – für Kennzahlen wie Akku und Signal zu weit.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

extension LabelStyle where Self == CompactLabelStyle {
    static var compact: CompactLabelStyle { CompactLabelStyle() }
}

extension View {
    /// Schwebendes Bedienelement über Inhalt: Liquid Glass ab iOS 26, darunter Material.
    @ViewBuilder
    func floatingGlass(in shape: some Shape) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    /// Zusätzliche Leiste oben am Inhalt: ab iOS 26 als `safeAreaBar` (Kanteneffekt wie die
    /// Systemleisten, ohne eigenen Hintergrund), darunter als Inset mit Leistenhintergrund.
    @ViewBuilder
    func topBar(@ViewBuilder _ content: () -> some View) -> some View {
        if #available(iOS 26, *) {
            safeAreaBar(edge: .top, content: content)
        } else {
            safeAreaInset(edge: .top) { content().background(.bar) }
        }
    }

    /// Blockiert die Oberfläche mit einem Fortschrittsindikator.
    func busyOverlay(_ isBusy: Bool) -> some View {
        overlay {
            if isBusy {
                ZStack {
                    Color.black.opacity(0.15).ignoresSafeArea()
                    ProgressView()
                        .controlSize(.large)
                        .padding(24)
                        .floatingGlass(in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .allowsHitTesting(true)
        .disabled(isBusy)
    }
}
