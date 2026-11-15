import DoorZignCore
import SwiftUI

/// Hauptansicht nach der Anmeldung.
struct HomeView: View {
    let context: SignedInContext

    var body: some View {
        TabView {
            NavigationStack {
                DisplayListView(context: context)
            }
            .tabItem { Label("Displays", systemImage: "rectangle.portrait.on.rectangle.portrait") }

            NavigationStack {
                JobsView(context: context, scope: .all, title: nil)
                    .navigationDestination(for: String.self) { id in
                        DisplayDetailView(context: context, displayId: id, initial: nil)
                    }
            }
            .tabItem { Label("Übertragungen", systemImage: "arrow.up.arrow.down.circle") }

            NavigationStack {
                SettingsView(context: context)
            }
            .tabItem { Label("Einstellungen", systemImage: "gearshape") }
        }
    }
}
