import DoorZignCore
import SwiftUI

/// Onboarding Schritt 1: System wählen.
struct WelcomeView: View {
    @Environment(AppSession.self) private var session
    @Environment(OnboardingModel.self) private var model

    enum Route: Hashable {
        case edge
        case cloud
    }

    @State private var path: [Route] = []
    #if DEBUG
    @State private var showMock = false
    #endif

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                        .padding(.top, 32)
                    Text("Willkommen bei Doorzign")
                        .font(.title.bold())
                    Text("Mit welchem System möchtest du dich verbinden?")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    NavigationLink(value: Route.edge) {
                        SystemCard(
                            icon: "server.rack",
                            title: "Doorzign Edge",
                            subtitle: "Lokale Installation über WLAN oder VPN"
                        )
                    }
                    NavigationLink(value: Route.cloud) {
                        SystemCard(
                            icon: "cloud",
                            title: "Zeitwart Cloud",
                            subtitle: "Verbindung über das Internet"
                        )
                    }
                    #if DEBUG
                    // Nicht in Screenshots (Start mit `-DZPairingLink`).
                    if UserDefaults.standard.string(forKey: "DZPairingLink") == nil {
                        Button("Entwicklung: Mock-Server") { showMock = true }
                            .font(.footnote)
                            .padding(.top, 24)
                    }
                    #endif
                }
                .padding()
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .edge: EdgeConnectView()
                case .cloud: CloudConnectView()
                }
            }
            #if DEBUG
            .sheet(isPresented: $showMock) { MockConnectView() }
            #endif
        }
        .busyOverlay(model.isBusy)
        // Fehler eines QR-Links (onOpenURL) – die Unterseiten zeigen ihre Fehler selbst an.
        .alert(
            "Hinweis",
            isPresented: Binding(
                get: { model.errorMessage != nil && path.isEmpty && !isMockShown },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            actions: { Button("OK") { model.errorMessage = nil } },
            message: { Text(model.errorMessage ?? "") }
        )
    }

    private var isMockShown: Bool {
        #if DEBUG
        showMock
        #else
        false
        #endif
    }
}

private struct SystemCard: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title)
                .frame(width: 44)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.leading)
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .foregroundStyle(.primary)
    }
}

#if DEBUG
private struct MockConnectView: View {
    @Environment(AppSession.self) private var session
    @Environment(OnboardingModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var address = "http://localhost:4010"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Adresse", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } footer: {
                    Text("Prism-Mock aus doorzign-app-coordination (Pfade ohne /mobile/v1). Auf einem echten Gerät die IP des Macs verwenden.")
                }
                ErrorSection(message: model.errorMessage)
                Button("Verbinden") {
                    Task {
                        await model.connectMock(address: address, session: session)
                        if model.errorMessage == nil { dismiss() }
                    }
                }
            }
            .navigationTitle("Mock-Server")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
    }
}
#endif
