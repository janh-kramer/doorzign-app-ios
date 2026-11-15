# DoorZign iOS

Native DoorZign-App (SwiftUI, iOS 17) für **DoorZign Edge** (lokal) und **Zeitwart Cloud**.
Verbindliche Unterlagen: `../doorzign-app-coordination` (`contract/mobile-v1.yaml`, `docs/ui-spec.md`,
`docs/edge-connection.md`). Vertragsfragen gehen an die Koordinations-Session, nicht an die Backends.

## Aufbau
| Pfad | Inhalt |
|---|---|
| `project.yml` | XcodeGen-Spezifikation (Bundle-ID `de.doorzign.app`, URL-Schema `doorzign://`, Info.plist) |
| `App/Sources` | SwiftUI-Oberfläche: Onboarding (QR, mDNS, manuell), Anmeldung (Passwort/SSO), Displayliste, Display-Detail, Ansicht bearbeiten (Text/Bild inkl. Bibliothek/iCal), Ad-hoc, Zeitpläne, Übertragungen, Einstellungen |
| `Packages/DoorZignKit` | Swift-Package, unter macOS bau- und testbar |
| ├ `DoorZignAPI` | Client, generiert mit swift-openapi-generator. `openapi.yaml` ist ein **Symlink** auf `doorzign-app-coordination/contract/dist/mobile-v1.yaml` (gebündelter Vertrag) |
| └ `DoorZignCore` | Verbindungsprofil, Keychain, Cache pro `instanceId`, Token-Refresh (serialisiert), CA-Pinning/TOFU, QR-Links, PKCE/SSO, mDNS, Sitzung sowie die Modelle aller Screens (`DisplayListModel`, `DisplayDetailModel`, `SlotEditorModel`, `MediaLibraryModel`, `AdhocModel`, `SchedulesModel`, `JobsModel`) |

Die Koordination muss als Geschwisterverzeichnis `../doorzign-app-coordination` vorhanden sein.

## Bauen
```sh
brew install xcodegen
xcodegen generate        # erzeugt DoorZign.xcodeproj (nicht eingecheckt)
open DoorZign.xcodeproj
```
Benötigt Xcode 16+ (iOS-17-SDK). Signierung: `DEVELOPMENT_TEAM` in Xcode setzen.

## Tests (Kernlogik)
Swift Testing über `scripts/test-kit.sh` (läuft auch nur mit den Command Line Tools).

| Aufruf | Prüft |
|---|---|
| `./scripts/test-kit.sh` | Unit-Tests mit Stub-Transport und Vertrags-Fixtures (`../doorzign-app-coordination/contract/fixtures`) |
| `DOORZIGN_MOCK_URL=http://localhost:4010 ./scripts/test-kit.sh` | zusätzlich kompletter Ablauf gegen den Prism-Mock |
| `DOORZIGN_LIVE_URL=… ./scripts/test-kit.sh --filter LiveBackend` | öffentliche Endpunkte eines echten Backends |
| `DOORZIGN_LIVE_LINK=… DOORZIGN_LIVE_PASSWORD=… [DOORZIGN_LIVE_MUTATE=1] ./scripts/test-kit.sh --filter Live` | E2E mit Testbenutzern, Edge mit echtem CA-Pinning |
| `DOORZIGN_WIRE_ECHO=… / DOORZIGN_WIRE_LINK=… ./scripts/test-kit.sh --filter WireDiagnostics` | Diagnose: Header und HTTP-Version ausgehender Anfragen |

Live-Läufe nur nach Freigabe durch die Koordination, Start und Ende dort melden, nie parallel zur
Konformitätssuite. Zugangsdaten nur als Umgebungsvariablen übergeben, nie einchecken. Mutierende Läufe stellen
Ansicht 1 und den Ausgangsinhalt wieder her und beenden Ad-hoc. Details in `LiveBackendTests.swift`.

**Nicht durch Tests abgedeckt** (nur mit Xcode prüfbar): `QRScannerView`, `CameraPicker`, `AppInfo`, alle
SwiftUI-Views zur Laufzeit. `AppSession` baut eigene Verbindungen und ist über Mock- und Live-Tests abgedeckt.

## Typecheck ohne Xcode
```sh
./scripts/typecheck-app.sh   # prüft App/Sources unter macOS mit Shims für iOS-APIs (ohne QR-Scanner/AppInfo)
```
Behelf, solange kein iOS-SDK installiert ist – ersetzt keinen echten Build.

## Mock-Server
```sh
cd ../doorzign-app-coordination
docker run --rm --platform linux/amd64 -p 4010:4010 -v "$PWD/contract/dist":/c stoplight/prism:4 mock -h 0.0.0.0 /c/mobile-v1.yaml
```
In Debug-Builds gibt es im Willkommensbildschirm „Entwicklung: Mock-Server“ (Basis-URL ohne `/mobile/v1`,
im Simulator `http://localhost:4010`, auf Geräten die IP des Macs).

## Checkliste erster Xcode-Build
Bisher ist die App nur per Typecheck unter macOS geprüft (`scripts/typecheck-app.sh`). Beim ersten echten Build:

**Projekt und Signing**
- [ ] `brew install xcodegen && xcodegen generate`, Projekt öffnen; `DEVELOPMENT_TEAM` setzen; Bundle-ID `de.doorzign.app` im Team verfügbar?
- [ ] Build für Simulator und Gerät ohne Fehler mit `SWIFT_STRICT_CONCURRENCY=complete`. Zuerst kompilieren `QRScannerView.swift`, `CameraPicker.swift`, `AppInfo.swift`: Sie waren vom Typecheck ausgenommen.
- [ ] Unit-Tests von `DoorZignKit` in Xcode laufen lassen (Swift Testing), Ergebnis wie bei `test-kit.sh`.

**Info.plist und Berechtigungen** (erzeugt aus `project.yml`)
- [ ] Texte für `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`, `NSLocalNetworkUsageDescription` erscheinen korrekt.
- [ ] `NSBonjourServices` enthält `_doorzign._tcp`; `CFBundleURLTypes` registriert `doorzign`.
- [ ] Prüfen, ob `NSPhotoLibraryUsageDescription` nötig ist. `PhotosPicker` braucht keine Freigabe, der Eintrag ist aber unschädlich.

**QR-Code und Deep Link**
- [ ] QR-Scanner auf dem Gerät: Kamerafreigabe anfragen, `doorzign://edge?u=…&fp=…&i=…` erkennen und verbinden. Kamera ablehnen → Hinweis und manuelle Eingabe weiter möglich.
- [ ] Link aus Notizen oder Safari öffnet die App (`onOpenURL`) und startet die Verbindung.

**Kamera und Bilder**
- [ ] „Foto aufnehmen“ auf dem Gerät (`CameraPicker`); im Simulator ausgeblendet.
- [ ] Foto aus der Mediathek (auch HEIC) → Upload → Vorschau; „Aus Bibliothek“ zeigt Miniaturen (Bearer).

**Anmeldung per SSO**
- [ ] `ASWebAuthenticationSession` über `@Environment(\.webAuthenticationSession)`: Login-Seite öffnet sich, Rückruf auf Schema `doorzign` beendet die Sitzung, Abbruch durch den Benutzer ohne Fehlermeldung. Braucht ein Backend mit SSO-Anbieter; Edge-Konformität und lokales Zeitwart haben bisher nur Passwort.

**Lokales Netzwerk und TLS**
- [ ] Local-Network-Abfrage erscheint beim ersten Start der Gateway-Suche (nur auf dem Gerät). Ablehnen → manuelle Eingabe funktioniert; Suche erneut nach Freigabe in den Systemeinstellungen.
- [ ] Gefundene Gateways (TXT `id/name/node/https/fp`) werden angezeigt und verbinden mit Pinning.
- [ ] Edge mit selbstsigniertem Zertifikat auf dem Gerät verbinden, je einmal über **IP**, **`.local`-Namen** und einen **voll qualifizierten LAN-Hostnamen** (z. B. `gateway.firma.intern`). `NSAllowsLocalNetworking` bleibt bewusst auch im Release gesetzt, deckt aber nur `.local` und unqualifizierte Namen ab; IP-Literale sind ohnehin ausgenommen. Für voll qualifizierte Namen gilt ATS normal. Die technischen Anforderungen erfüllt Edge (Kette [Server, CA], ECDSA P-256/SHA-256, TLS 1.3, geprüft am 2026-11-15); das Vertrauen kommt aus dem Delegate (gepinnte CA). Falls ATS dort trotzdem blockiert, mit der Koordination eine Ausnahme klären.
- [ ] Mock im Simulator über `http://localhost:4010` (ATS `NSAllowsLocalNetworking`).

**Allgemein**
- [ ] Anmeldung übersteht einen Neustart der App (Keychain); Abmelden löscht Tokens und Cache.
- [ ] Dunkelmodus, Dynamic Type, VoiceOver auf Liste, Detail und Editor kurz prüfen.
