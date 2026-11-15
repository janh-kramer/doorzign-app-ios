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

extension View {
    /// Blockiert die Oberfläche mit einem Fortschrittsindikator.
    func busyOverlay(_ isBusy: Bool) -> some View {
        overlay {
            if isBusy {
                ZStack {
                    Color.black.opacity(0.15).ignoresSafeArea()
                    ProgressView()
                        .controlSize(.large)
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .allowsHitTesting(true)
        .disabled(isBusy)
    }
}
