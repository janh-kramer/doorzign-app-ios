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
        do {
            // Kein ephemerer Browser: vorhandene Anmeldungen beim Identity Provider (z. B. Microsoft) werden genutzt.
            let callback = try await webAuthenticationSession.authenticate(using: url, callbackURLScheme: SSOFlow.callbackScheme)
            let code = try SSOFlow.code(from: callback, expectedState: pkce.state)
            isBusy = true
            defer { isBusy = false }
            try await session.completeSSO(context: context, code: code, verifier: pkce.verifier)
        } catch let authError as ASWebAuthenticationSessionError where authError.code == .canceledLogin {
            // Vom Benutzer abgebrochen – kein Fehler.
        } catch let callbackError as SSOFlow.CallbackError {
            error = APIError(code: "sso", message: Self.message(for: callbackError))
        } catch {
            self.error = APIError.from(error)
        }
    }

    static func message(for error: SSOFlow.CallbackError) -> String {
        switch error {
        case .provider(code: "access_denied"): String(localized: "Die Anmeldung wurde abgelehnt.")
        case .provider(code: "expired"): String(localized: "Die Anmeldung hat zu lange gedauert. Bitte erneut versuchen.")
        case .provider: String(localized: "Die Anmeldung beim Anbieter ist fehlgeschlagen.")
        case .stateMismatch, .invalidCallback: String(localized: "Ungültige Antwort der Anmeldung. Bitte erneut versuchen.")
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
