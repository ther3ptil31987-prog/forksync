import SwiftUI

@main
struct ForkSyncApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup("ForkSync") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 940, minHeight: 540)
                .task {
                    await store.refresh()
                    if let path = ProcessInfo.processInfo.environment["FORKSYNC_SNAPSHOT"] {
                        try? await Task.sleep(for: .seconds(2))
                        print("forks=\(store.forks.count) fatal=\(store.fatal ?? "-")")
                        Snapshot.write(to: path)
                        NSApp.terminate(nil)
                    }
                }
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
