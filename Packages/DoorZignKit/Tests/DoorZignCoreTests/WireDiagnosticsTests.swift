// Diagnose: Wie gehen body-lose POSTs (identify, resend) und logout über URLSession raus?
//   DOORZIGN_WIRE_ECHO=http://127.0.0.1:4099/mobile/v1   Echo-Server, der Header protokolliert
//   DOORZIGN_WIRE_LINK=doorzign://edge?…                  Edge: HTTP-Version + body-loser POST ohne Token (keine Zustandsänderung)
import DoorZignAPI
import Foundation
import Testing
@testable import DoorZignCore

private let env = ProcessInfo.processInfo.environment

/// Sammelt die Metriken einer einzelnen Task (Aushandlung h2 / http/1.1).
private final class MetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _protocols: [String] = []
    var protocols: [String] { lock.withLock { _protocols } }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.withLock { _protocols += metrics.transactionMetrics.compactMap(\.networkProtocolName) }
    }
}

@Suite(.serialized)
struct WireDiagnosticsTests {
    @Test(.enabled(if: env["DOORZIGN_WIRE_ECHO"] != nil))
    func echoHeader() async throws {
        let url = try #require(env["DOORZIGN_WIRE_ECHO"].flatMap(URL.init(string:)))
        let client = ClientFactory.makeConnection(baseURL: url, trust: .system).client
        _ = try? await client.identifyDisplay(path: .init(displayId: "d-1"))
        _ = try? await client.resendDisplay(path: .init(displayId: "d-1"))
        _ = try? await client.logout(body: .json(.init(refreshToken: "rt")))
    }

    @Test(.enabled(if: env["DOORZIGN_WIRE_LINK"] != nil))
    func edgeProtokollUndLeererPost() async throws {
        guard case .edge(let urls, let fp, _, _) = try PairingLink.parse(try #require(env["DOORZIGN_WIRE_LINK"])) else { return }
        let base = try #require(urls.first)
        let connection = ClientFactory.makeConnection(baseURL: base, trust: .pinned(fingerprint: fp))
        defer { connection.invalidate() }

        for (label, method) in [("GET /system", "GET"), ("POST identify ohne Body, ohne Token", "POST")] {
            var request = URLRequest(url: method == "GET"
                ? base.appendingPathComponent("system")
                : base.appendingPathComponent("displays/diagnose/identify"))
            request.httpMethod = method
            request.timeoutInterval = 10
            let collector = MetricsCollector()
            let started = Date()
            do {
                let (_, response) = try await connection.session.data(for: request, delegate: collector)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("WIRE \(label): status \(status), Protokoll \(collector.protocols), \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            } catch {
                print("WIRE \(label): FEHLER \(error.localizedDescription), Protokoll \(collector.protocols), \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            }
        }
    }
}
