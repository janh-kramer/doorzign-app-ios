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
            }
        }
        .environment(onboarding)
        .animation(.default, value: session.phaseID)
        // QR-Codes, die mit der Kamera-App gescannt werden, öffnen die App über doorzign://edge|cloud.
        .onOpenURL { url in
            guard let link = try? PairingLink.parse(url.absoluteString) else { return }
            onboarding.pendingLink = link
        }
        #if DEBUG
        // UI-Tests/Screenshots: Verbindungslink per Startargument `-DZPairingLink <url>`,
        // ohne Systemdialog „In Doorzign öffnen?“.
        .task {
            if let text = UserDefaults.standard.string(forKey: "DZPairingLink"),
               let link = try? PairingLink.parse(text) {
                onboarding.pendingLink = link
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
