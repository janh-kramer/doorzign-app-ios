import DoorZignCore
import Foundation
import Observation

/// Verteilt geöffnete Verbindungslinks je nach Phase (ui-spec §1 „Verbindungslinks“, decisions 45).
/// Ein Link bleibt nie unbemerkt liegen: Nur während des App-Starts wird er gehalten, bis die Phase feststeht.
@MainActor
@Observable
final class LinkRouter {
    /// Angemeldet, Link auf ein anderes System: wartet auf „Verbindung trennen“ oder „Abbrechen“.
    struct SwitchRequest: Identifiable {
        let id = UUID()
        let raw: String
    }

    var switchRequest: SwitchRequest?
    @ObservationIgnored private var startupLink: String?

    func handle(_ raw: String, session: AppSession, onboarding: OnboardingModel) async {
        switch LinkRouting.decide(raw: raw, context: session.phase.linkContext) {
        case .wait:
            startupLink = raw
        case .onboarding:
            await onboarding.receiveLink(raw, session: session)
        case .leaveLogin:
            session.cancelLogin()
            await onboarding.receiveLink(raw, session: session)
        case .invalidOnLogin:
            session.notice = String(localized: "Dieser QR-Code ist kein Doorzign-Verbindungscode.")
        case .confirmSwitch:
            switchRequest = SwitchRequest(raw: raw)
        case .ignore:
            break
        }
    }

    /// Phase gewechselt: Bestätigung verfällt außerhalb der Anmeldung; ein beim Start gehaltener Link kommt dran.
    func phaseChanged(session: AppSession, onboarding: OnboardingModel) async {
        if case .signedIn = session.phase {} else { switchRequest = nil }
        if case .starting = session.phase { return }
        if let raw = startupLink {
            startupLink = nil
            await handle(raw, session: session, onboarding: onboarding)
        }
    }

    /// „Verbindung trennen“: abmelden (wie Einstellungen) und den Link im Onboarding übernehmen.
    func confirmSwitch(session: AppSession, onboarding: OnboardingModel) async {
        guard let request = switchRequest else { return }
        switchRequest = nil
        await session.signOut()
        await onboarding.receiveLink(request.raw, session: session)
    }
}
