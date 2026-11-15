import DoorZignCore
import SwiftUI

/// Einstellungen: verbundenes System, Benutzer, Abmelden, System wechseln, App-Infos.
struct SettingsView: View {
    let context: SignedInContext
    @Environment(AppSession.self) private var session

    private enum Confirmation: Identifiable {
        case signOut, switchSystem
        var id: Self { self }
    }

    @State private var confirmation: Confirmation?
    @State private var isBusy = false

    var body: some View {
        Form {
            Section("Verbunden mit") {
                LabeledContent("System", value: context.system?.name ?? context.profile.name)
                LabeledContent("Typ", value: context.profile.systemType == .edge ? "DoorZign Edge" : "Zeitwart Cloud")
                LabeledContent("Adresse", value: Self.address(context.profile.baseURL))
                if let api = context.system?.raw.apiVersion {
                    LabeledContent("API-Version", value: api)
                }
                if let fingerprint = context.profile.tlsFingerprint {
                    LabeledContent("Zertifikat", value: Fingerprint.short(fingerprint))
                        .font(.system(.body, design: .monospaced))
                }
            }

            if let me = context.me {
                Section("Benutzer") {
                    LabeledContent("Name", value: me.displayName)
                    LabeledContent("Benutzername", value: me.username)
                    LabeledContent("Rolle", value: me.role == .admin ? String(localized: "Administrator") : String(localized: "Benutzer"))
                }
            }

            Section {
                Button("Abmelden", role: .destructive) { confirmation = .signOut }
                Button("Mit anderem System verbinden") { confirmation = .switchSystem }
            }

            Section("App") {
                LabeledContent("Version", value: "\(AppInfo.version) (\(AppInfo.build))")
                Link(destination: AppLinks.imprint) {
                    Label("Impressum", systemImage: "building.columns")
                }
                Link(destination: AppLinks.privacy) {
                    Label("Datenschutz", systemImage: "hand.raised")
                }
            }
        }
        .navigationTitle("Einstellungen")
        .refreshable { await session.refreshSignedInInfo() }
        .busyOverlay(isBusy)
        .confirmationDialog(
            confirmation == .signOut ? "Abmelden?" : "Mit anderem System verbinden?",
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            titleVisibility: .visible
        ) {
            Button(confirmation == .signOut ? "Abmelden" : "Verbindung trennen", role: .destructive) {
                Task {
                    isBusy = true
                    await session.signOut()
                    isBusy = false
                }
            }
        } message: {
            Text("Zugangsdaten und zwischengespeicherte Daten werden gelöscht.")
        }
    }

    static func address(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.path = ""
        return components.string ?? url.absoluteString
    }
}
