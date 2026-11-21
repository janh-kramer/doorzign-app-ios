import DoorZignCore
import SwiftUI

@main
struct DoorZignApp: App {
    @State private var session = AppSession(
        appVersion: AppInfo.version,
        deviceName: AppInfo.deviceName
    )

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .task { await session.bootstrap() }
        }
    }
}

/// Wählt anhand der Sitzungsphase den passenden Bildschirm.
struct RootView: View {
    @Environment(AppSession.self) private var session
    @State private var onboarding = OnboardingModel()
    @State private var links = LinkRouter()

    var body: some View {
        Group {
            switch session.phase {
            case .starting:
                ProgressView("Wird gestartet …")
            case .onboarding:
                WelcomeView()
            case .login(let context):
                LoginView(context: context)
            case .signedIn(let context):
                HomeView(context: context)
                    // Angemeldet, Link auf ein anderes System (decisions 45): gleicher Dialog wie in den Einstellungen.
                    .confirmationDialog(
                        "Mit anderem System verbinden?",
                        isPresented: Binding(get: { links.switchRequest != nil }, set: { if !$0 { links.switchRequest = nil } }),
                        titleVisibility: .visible
                    ) {
                        Button("Verbindung trennen", role: .destructive) {
                            Task { await links.confirmSwitch(session: session, onboarding: onboarding) }
                        }
                    } message: {
                        Text("Zugangsdaten und zwischengespeicherte Daten werden gelöscht.")
                    }
            }
        }
        .environment(onboarding)
        .animation(.default, value: session.phaseID)
        // QR-Codes, die mit der Kamera-App gescannt werden, öffnen die App über doorzign://edge|cloud.
        // Roh weiterreichen (auch ungültige Links zeigen einen Fehler); eigener Task, damit nichts die
        // Prüfung abbricht (decisions 45). Den SSO-Rückruf verarbeitet ASWebAuthenticationSession selbst.
        .onOpenURL { url in
            guard url.scheme?.lowercased() == "doorzign", ["edge", "cloud"].contains(url.host?.lowercased() ?? "") else { return }
            Task { await links.handle(url.absoluteString, session: session, onboarding: onboarding) }
        }
        .onChange(of: session.phaseID) {
            Task { await links.phaseChanged(session: session, onboarding: onboarding) }
        }
        #if DEBUG
        // UI-Tests/Screenshots: Verbindungslink per Startargument `-DZPairingLink <url>`,
        // ohne Systemdialog „In Doorzign öffnen?“.
        .task {
            if let text = UserDefaults.standard.string(forKey: "DZPairingLink") {
                await links.handle(text, session: session, onboarding: onboarding)
            }
        }
        #endif
        .alert(
            "Hinweis",
            isPresented: Binding(get: { session.notice != nil }, set: { if !$0 { session.notice = nil } }),
            actions: { Button("OK") { session.notice = nil } },
            message: { Text(session.notice ?? "") }
        )
    }
}

extension AppSession {
    /// Für Animationen beim Phasenwechsel.
    var phaseID: Int {
        switch phase {
        case .starting: 0
        case .onboarding: 1
        case .login: 2
        case .signedIn: 3
        }
    }
}
