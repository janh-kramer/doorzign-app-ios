import DoorZignCore
import SwiftUI

/// Hauptansicht nach der Anmeldung.
struct HomeView: View {
    let context: SignedInContext
    @State private var displays: DisplayListModel

    init(context: SignedInContext) {
        self.context = context
        _displays = State(initialValue: DisplayListModel(client: context.client))
    }

    var body: some View {
        TabView {
            NavigationStack {
                DisplayListView(context: context, model: displays)
            }
            .tabItem { Label("Displays", systemImage: "rectangle.portrait.on.rectangle.portrait") }

            NavigationStack {
                JobsView(context: context, scope: .all, title: nil) { id in
                    displays.displays.first { $0.id == id }?.mac
                }
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
