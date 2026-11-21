import DoorZignCore
import SwiftUI

/// Onboarding Edge: QR-Code (primär), Suche im Netzwerk oder Adresse.
struct EdgeConnectView: View {
    @Environment(AppSession.self) private var session
    @Environment(OnboardingModel.self) private var model
    @State private var search = GatewaySearch()
    @State private var address = ""
    @State private var showScanner = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Button {
                    showScanner = true
                } label: {
                    Label("QR-Code scannen", systemImage: "qrcode.viewfinder")
                        .font(.headline)
                }
            } footer: {
                Text("Den QR-Code findest du in der Edge-Weboberfläche unter „Doorzign-App verbinden“.")
            }

            ErrorSection(message: model.errorMessage)

            Section {
                switch search.state {
                case .failed(let message):
                    Text(message).foregroundStyle(.secondary)
                default:
                    if search.gateways.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Suche läuft …").foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(search.gateways) { gateway in
                    Button {
                        Task { await model.connectEdge(gateway: gateway) }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(gateway.displayName).foregroundStyle(.primary)
                            if let node = gateway.node, node != gateway.displayName {
                                Text(node).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Im Netzwerk suchen")
            }

            Section {
                TextField("z. B. 192.168.1.10", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit(connectAddress)
                Button("Verbinden", action: connectAddress)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Adresse eingeben")
            } footer: {
                Text("Host oder IP-Adresse, optional mit Port (Standard 9443).")
            }
        }
        .navigationTitle("Doorzign Edge")
        .onAppear { search.start() }
        .onDisappear { search.stop() }
        .sheet(isPresented: $showScanner) {
            QRScannerSheet { code in
                showScanner = false
                Task { await model.connect(scannedCode: code, session: session) }
            }
        }
        .sheet(item: $model.pendingTrust) { trust in
            FingerprintConfirmView(trust: trust)
        }
    }

    private func connectAddress() {
        Task { await model.connectEdge(address: address) }
    }
}

/// Trust on first use: Fingerprint anzeigen und bestätigen lassen.
struct FingerprintConfirmView: View {
    @Environment(AppSession.self) private var session
    @Environment(OnboardingModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let trust: OnboardingModel.PendingTrust
    @State private var showFull = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("System", value: trust.probe.system.name)
                    LabeledContent("Adresse", value: trust.probe.baseURL.host() ?? trust.probe.baseURL.absoluteString)
                }
                Section {
                    Text(Fingerprint.short(trust.fingerprint))
                        .font(.system(.title3, design: .monospaced))
                        .textSelection(.enabled)
                    if showFull {
                        Text(Fingerprint.formatted(trust.fingerprint))
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    } else {
                        Button("Vollständig anzeigen") { showFull = true }
                    }
                } header: {
                    Text("Zertifikats-Fingerprint")
                } footer: {
                    Text("Vergleiche den Fingerprint mit der Anzeige in der Edge-Weboberfläche unter „Doorzign-App verbinden“. Verbinde dich nur, wenn er übereinstimmt.")
                }
                Section {
                    Button("Vertrauen") {
                        dismiss()
                        Task { await model.confirmTrust(trust, session: session) }
                    }
                    .font(.headline)
                    Button("Abbrechen", role: .cancel) { dismiss() }
                }
            }
            .navigationTitle("Zertifikat bestätigen")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
    }
}
