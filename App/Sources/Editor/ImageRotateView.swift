import DoorZignCore
import SwiftUI

/// Schritt „Bild drehen“ nach Kamera/Fotomediathek (ui-spec §4 Bild, decisions 44): Vorschau mit angewendeter
/// EXIF-Ausrichtung, Drehen in 90°-Schritten. Gedreht wird erst beim Hochladen in den Pixeln (ImagePreparation).
struct ImageRotateView: View {
    let data: Data
    let onCancel: () -> Void
    let onUpload: (_ quarterTurns: Int) -> Void

    @State private var turns = 0
    @State private var preview: CGImage?
    @State private var unreadable = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Dreh das Bild so, wie es auf dem Display stehen soll.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5))
                    if let preview, let shown = ImagePreparation.rotated(preview, quarterTurns: turns) {
                        Image(decorative: shown, scale: 1)
                            .resizable()
                            .scaledToFit()
                            .padding(8)
                            .accessibilityIdentifier("rotatePreview")
                    } else if unreadable {
                        Label("Das Bild konnte nicht gelesen werden.", systemImage: "photo.badge.exclamationmark")
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack(spacing: 12) {
                    Button { turns -= 1 } label: { Label("Links drehen", systemImage: "rotate.left") }
                    Button { turns += 1 } label: { Label("Rechts drehen", systemImage: "rotate.right") }
                }
                .buttonStyle(.bordered)
                .disabled(preview == nil)
            }
            .padding(16)
            .navigationTitle("Bild drehen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hochladen") { onUpload(turns) }
                        .disabled(unreadable)
                }
            }
        }
        .interactiveDismissDisabled()
        .task {
            let data = data
            let image = await Task.detached(priority: .userInitiated) {
                ImagePreparation.previewImage(data, maxPixelSize: 1200)
            }.value
            preview = image
            unreadable = image == nil
        }
    }
}
