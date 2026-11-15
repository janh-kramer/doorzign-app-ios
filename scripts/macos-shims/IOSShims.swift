// Shims für scripts/typecheck-app.sh. Nicht Teil der App (App/Sources) und nicht im Xcode-Projekt.
// NUR für den Typecheck unter macOS: Nachbildungen iOS-spezifischer APIs. Nicht Teil der App.
import SwiftUI
import AppKit

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }

enum NavigationBarItemTitleDisplayModeShim { case inline, large, automatic }
extension View {
    func navigationBarTitleDisplayMode(_ m: NavigationBarItemTitleDisplayModeShim) -> some View { self }
    func textInputAutocapitalization(_ a: TextInputAutocapitalizationShim?) -> some View { self }
    func keyboardType(_ k: KeyboardTypeShim) -> some View { self }
}
struct TextInputAutocapitalizationShim { static let never = Self() }
enum KeyboardTypeShim { case URL, `default` }
extension ToolbarItemPlacement { static var topBarTrailing: ToolbarItemPlacement { .automatic } }

enum AppInfo {
    static var version: String { "1.0.0" }
    static var build: String { "1" }
    @MainActor static var deviceName: String { "Mac" }
}

struct QRScannerSheet: View {
    let onScan: (String) -> Void
    var body: some View { EmptyView() }
}

struct CameraPicker: View {
    let onImage: (Data) -> Void
    static var isAvailable: Bool { false }
    var body: some View { EmptyView() }
}
