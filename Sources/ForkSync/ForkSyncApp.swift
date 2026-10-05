import SwiftUI

@main
struct ForkSyncApp: App {
    @StateObject private var store = Store()
    @AppStorage(Lang.key) private var lang = Lang.system.rawValue

    var body: some Scene {
        WindowGroup("ForkSync") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1180, minHeight: 540)
                .task {
                    await store.refresh()
                    if let root = ProcessInfo.processInfo.environment["FORKSYNC_LOCALTEST"] {
                        // Debug: Klonen/Abgleich headless gegen ein Testverzeichnis (echte Einstellungen bleiben unberührt)
                        setbuf(stdout, nil)
                        await store.loadRepos()
                        print("repos=\(store.repos.count)")
                        store.localRoot = root
                        let pick = store.repos.filter { !$0.isFork && !$0.isPrivate }.prefix(2).map(\.full)
                        store.localEnabled = Set(pick)
                        print("enabled=\(store.localEnabled)")
                        await store.syncLocal()
                        for r in store.local.values.sorted(by: { $0.id < $1.id }) {
                            print("\(r.id): \(r.state) ahead=\(r.ahead) behind=\(r.behind) dirty=\(r.dirty) \(r.detail)")
                        }
                        for l in store.log.suffix(6) { print("LOG \(l.kind.rawValue): \(l.text)") }
                        NSApp.terminate(nil)
                    }
                    store.startLocalAuto()
                    if let path = ProcessInfo.processInfo.environment["FORKSYNC_SNAPSHOT"] {
                        try? await Task.sleep(for: .seconds(2))
                        for f in store.forks where f.ahead > 0 || f.parentBranch != f.branch {
                            print("\(f.name): \(f.statusText) [fork:\(f.branch) <-> original:\(f.parentBranch ?? "?")]")
                        }
                        print("forks=\(store.forks.count) fatal=\(store.fatal ?? "-")")
                        Snapshot.write(to: path)
                        NSApp.terminate(nil)
                    }
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button(tr("Aktualisieren", "Refresh")) { Task { await store.refresh() } }
                    .keyboardShortcut("r")
                Divider()
                Button(tr("Mit GitHub anmelden …", "Sign in with GitHub …")) { store.startLogin() }
                    .disabled(Auth.clientID.isEmpty)
                Button(tr("Abmelden", "Sign out")) { store.logout() }
                    .disabled(!store.ownLogin)
            }
        }
    }
}

/// Debug-Hilfe: rendert das Hauptfenster in eine PNG-Datei (FORKSYNC_SNAPSHOT=<pfad>).
enum Snapshot {
    @MainActor static func write(to path: String) {
        guard let win = NSApp.windows.first(where: { $0.isVisible }),
              let view = win.contentView?.superview else { return }
        win.displayIfNeeded()
        let scale = win.backingScaleFactor
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale),
                                         pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = view.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        view.displayIgnoringOpacity(view.bounds, in: NSGraphicsContext.current!)
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
