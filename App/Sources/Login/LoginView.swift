import AuthenticationServices
import DoorZignAPI
import DoorZignCore
import SwiftUI

/// Anmeldung: Benutzername/Passwort (lokal oder über Passwort-Provider) und SSO im Systembrowser.
struct LoginView: View {
    let context: LoginContext

    @Environment(AppSession.self) private var session
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    @State private var username = ""
    @State private var password = ""
    /// `nil` = lokales Konto, sonst Id eines Providers mit `flow = password`.
    @State private var passwordProvider: String?
    @State private var isBusy = false
    @State private var error: APIError?
    /// Ruhiger Hinweis ohne Fehlerdarstellung (z. B. SSO vom Benutzer abgebrochen).
    @State private var notice: String?

    private enum Field { case username, password }
    @FocusState private var focus: Field?

    private var showsPasswordForm: Bool {
        context.passwordEnabled || !context.passwordProviders.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.system.name).font(.title2.bold())
                        Text(context.profile.systemType == .edge ? "DoorZign Edge" : "Zeitwart Cloud")
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                }

                ErrorSection(message: error?.message)
                if let notice {
                    Section { Text(notice).foregroundStyle(.secondary) }
                }

                if showsPasswordForm {
                    Section {
                        if !context.passwordProviders.isEmpty {
                            Picker("Anmelden über", selection: $passwordProvider) {
                                if context.passwordEnabled {
                                    Text("Lokales Konto").tag(String?.none)
                                }
                                ForEach(context.passwordProviders, id: \.id) { provider in
                                    Text(provider.name).tag(String?.some(provider.id))
                                }
                            }
                        }
                        TextField("Benutzername oder E-Mail", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .username)
                            .submitLabel(.next)
                            .onSubmit { focus = .password }
                        if let messages = error?.fields["username"] {
                            FieldErrors(messages: messages)
                        }
                        SecureField("Passwort", text: $password)
                            .textContentType(.password)
                            .focused($focus, equals: .password)
                            .submitLabel(.go)
                            .onSubmit(loginWithPassword)
                        if let messages = error?.fields["password"] {
                            FieldErrors(messages: messages)
                        }
                        Button("Anmelden", action: loginWithPassword)
                            .font(.headline)
                            .disabled(username.isEmpty || password.isEmpty)
                    }
                }

                if !context.browserProviders.isEmpty {
                    Section {
                        ForEach(context.browserProviders, id: \.id) { provider in
                            Button("Anmelden mit \(provider.name)") {
                                Task { await loginWithSSO(provider) }
                            }
                        }
                    } header: {
                        if showsPasswordForm { Text("Oder") }
                    }
                }

                Section {
                    TextField("Gerätename", text: Binding(
                        get: { session.deviceName },
                        set: { session.deviceName = String($0.prefix(100)) }
                    ))
                } header: {
                    Text("Dieses Gerät")
                } footer: {
                    // Cloud: keine Zeitwart-Menünamen, neutral auf den Administrator verweisen.
                    Text(context.profile.systemType == .edge
                         ? "Unter diesem Namen erscheint das Gerät in der Weboberfläche unter „Verbundene Geräte“."
                         : "Unter diesem Namen erkennt dein Administrator das Gerät. Zum Abmelden einzelner Geräte wende dich an deinen Administrator.")
                }

                if !showsPasswordForm && context.browserProviders.isEmpty {
                    Section {
                        Text("Für dieses System ist keine Anmeldung über die App eingerichtet.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Anmelden")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Anderes System") { session.cancelLogin() }
                }
            }
            .busyOverlay(isBusy)
            .onAppear {
                if !context.passwordEnabled { passwordProvider = context.passwordProviders.first?.id }
            }
        }
    }

    private func loginWithPassword() {
        guard !username.isEmpty, !password.isEmpty else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            notice = nil
            do {
                try await session.login(context: context, username: username, password: password, provider: passwordProvider)
            } catch {
                self.error = APIError.from(error)
                password = ""
            }
        }
    }

    private func loginWithSSO(_ provider: Components.Schemas.SsoProvider) async {
        let pkce = PKCE()
        guard let url = SSOFlow.startURL(
            baseURL: context.profile.baseURL,
            provider: provider.id,
            pkce: pkce,
            deviceName: session.deviceName,
            appVersion: session.appVersion
        ) else { return }
        error = nil
        notice = nil
        do {
            // Ephemerer Browser (Koordination 2026-11-15): Zeitwart schließt nur ab, wenn die Anmeldung nach dem Start
            // im selben Browser erfolgt; eine ältere Web-Session hilft nicht (→ access_denied).
            let callback = try await webAuthenticationSession.authenticate(
                using: url, callbackURLScheme: SSOFlow.callbackScheme, preferredBrowserSession: .ephemeral
            )
            let code = try SSOFlow.code(from: callback, expectedState: pkce.state)
            isBusy = true
            defer { isBusy = false }
            try await session.completeSSO(context: context, code: code, verifier: pkce.verifier)
        } catch let authError as ASWebAuthenticationSessionError where authError.code == .canceledLogin {
            // Vom Benutzer geschlossen – auch wenn der IdP-Fehler im Browser stehen blieb (Zeitwart sendet dann
            // kein error=). Kein Fehlerdialog, nur ein ruhiger Hinweis.
            notice = String(localized: "Anmeldung abgebrochen.")
        } catch let callbackError as SSOFlow.CallbackError {
            error = APIError(code: "sso", message: SSOFlow.message(for: callbackError))
        } catch {
            self.error = APIError.from(error).forSSO
        }
    }
}

struct FieldErrors: View {
    let messages: [String]

    var body: some View {
        ForEach(messages, id: \.self) { message in
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }
}
