import SwiftUI

@main
struct ForkSyncApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup("ForkSync") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 860, minHeight: 540)
                .task { await store.refresh() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Aktualisieren") { Task { await store.refresh() } }
                    .keyboardShortcut("r")
            }
        }
    }
}
