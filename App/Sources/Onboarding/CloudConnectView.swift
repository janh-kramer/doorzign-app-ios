import DoorZignCore
import SwiftUI

/// Onboarding Cloud: Instanz eingeben oder QR-Code aus dem Zeitwart-Profil scannen.
struct CloudConnectView: View {
    @Environment(AppSession.self) private var session
    @Environment(OnboardingModel.self) private var model
    @State private var instance = ""
    @State private var showScanner = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 0) {
                    TextField("firma", text: $instance)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .onSubmit(connect)
                    if !instance.contains(".") && !instance.contains("://") {
                        Text(".zeitwart.de").foregroundStyle(.secondary)
                    }
                }
                Button("Weiter", action: connect)
                    .disabled(instance.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Instanz")
            } footer: {
                Text("Name deiner Zeitwart-Instanz oder die vollständige Adresse.")
            }

            ErrorSection(message: model.errorMessage)

            Section {
                Button {
                    showScanner = true
                } label: {
                    Label("QR-Code scannen", systemImage: "qrcode.viewfinder")
                }
            } footer: {
                Text("Den QR-Code findest du in Zeitwart in deinem Profil.")
            }
        }
        .navigationTitle("Zeitwart Cloud")
        .sheet(isPresented: $showScanner) {
            QRScannerSheet { code in
                showScanner = false
                Task { await model.connect(scannedCode: code, session: session) }
            }
        }
    }

    private func connect() {
        Task { await model.connectCloud(input: instance, session: session) }
    }
}
