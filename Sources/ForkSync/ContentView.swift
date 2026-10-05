import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var selection = Set<String>()
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var showLog = false
    @State private var confirmRemove = false

    private var visible: [Fork] {
        store.forks.filter { filter.matches($0) && (search.isEmpty || $0.full.localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let fatal = store.fatal {
                ErrorView(message: fatal)
            } else {
                if store.missingWorkflowScope {
                    Label("gh fehlt der Scope „workflow“ – im Terminal: gh auth refresh -s workflow",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.orange.opacity(0.1))
                }
                HStack {
                    Picker("Filter", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 520)
                    Spacer()
                    Text("\(visible.count) von \(store.forks.count) Forks")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
                list
                Divider()
                ActionBar(selection: selection, showLog: $showLog, confirmRemove: $confirmRemove)
            }
        }
        .searchable(text: $search, prompt: "Forks durchsuchen")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await store.refresh() } } label: {
                    if store.loading { ProgressView().controlSize(.small) }
                    else { Label("Aktualisieren", systemImage: "arrow.clockwise") }
                }
                .disabled(store.loading)
                .help("Status neu laden (⌘R)")
            }
        }
        .sheet(isPresented: $showLog) { LogView() }
        .confirmationDialog("Auto-Sync in \(selection.count) Fork(s) entfernen?",
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Entfernen", role: .destructive) { Task { await store.remove(selection) } }
        }
    }

    private var list: some View {
        Group {
            if store.loading && store.forks.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Forks werden geprüft …").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                ContentUnavailableView("Keine Forks", systemImage: "arrow.triangle.branch",
                                       description: Text(store.forks.isEmpty ? "Dein Account hat keine Forks." : "Kein Fork passt zum Filter."))
            } else {
                List(visible, selection: $selection) { fork in
                    ForkRow(fork: fork, busy: store.busy.contains(fork.id))
                        .tag(fork.id)
                        .contextMenu {
                            Button("Auf GitHub öffnen") { NSWorkspace.shared.open(fork.url) }
                            if let p = fork.parent, let u = URL(string: "https://github.com/\(p)") {
                                Button("Original öffnen") { NSWorkspace.shared.open(u) }
                            }
                        }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }
}

struct ForkRow: View {
    let fork: Fork
    let busy: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: fork.stateIcon)
                .font(.title2)
                .foregroundStyle(fork.stateColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(fork.name).font(.headline)
                Text(fork.parent.map { "Fork von \($0)" } ?? fork.full)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(fork.statusText)
                .font(.callout)
                .foregroundStyle(fork.stateColor)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(fork.stateColor.opacity(0.12), in: Capsule())
            Group {
                if busy { ProgressView().controlSize(.small) }
                else if let mode = fork.workflowMode ?? (fork.hasAutoSync ? .ff : nil) {
                    Label("Auto · \(mode.short)", systemImage: "bolt.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(fork.needsAdapt ? .orange : .green)
                        .help(fork.needsAdapt ? "Eigene Commits vorhanden – Modus „auto“ empfohlen" : "Täglicher Auto-Sync aktiv")
                } else {
                    Text("–").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 92, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}

struct ActionBar: View {
    @EnvironmentObject var store: Store
    let selection: Set<String>
    @Binding var showLog: Bool
    @Binding var confirmRemove: Bool

    private var adaptCount: Int { store.forks.filter(\.needsAdapt).count }
    private var hasSync: Bool { store.forks.contains { selection.contains($0.id) && $0.hasAutoSync } }

    var body: some View {
        HStack(spacing: 12) {
            Picker("Modus", selection: $store.modeChoice) {
                ForEach(SyncMode.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 300)
            ScheduleButton()
            Spacer()
            if adaptCount > 0 {
                Button { Task { await store.adaptAll() } } label: {
                    Label("\(adaptCount) umstellen", systemImage: "wand.and.stars")
                }.help("ff-Forks mit eigenen Commits auf Modus „auto“ umstellen (eigene Commits bleiben erhalten)")
            }
            Button { showLog = true } label: { Image(systemName: "list.bullet.rectangle") }.help("Protokoll")
            Button { Task { await store.syncNow(selection) } } label: { Label("Syncen", systemImage: "play.fill") }
                .disabled(selection.isEmpty)
                .help("Sofort synchronisieren (eigene Commits bleiben erhalten)")
            Button(role: .destructive) { confirmRemove = true } label: { Image(systemName: "trash") }.help("Auto-Sync entfernen")
                .disabled(!hasSync)
            Button { Task { await store.install(selection, mode: store.modeChoice) } } label: {
                Label("Einrichten", systemImage: "bolt.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(selection.isEmpty || !store.schedule.isValid)
        }
        .padding(12)
        .background(.bar)
        .labelStyle(.titleAndIcon)
    }
}

struct LogView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Protokoll").font(.title3.bold())
                Spacer()
                Button("Leeren") { store.log.removeAll() }.disabled(store.log.isEmpty)
                Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding()
            Divider()
            if store.log.isEmpty {
                ContentUnavailableView("Noch keine Einträge", systemImage: "text.alignleft")
            } else {
                List(store.log.reversed()) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(line.kind)).foregroundStyle(color(line.kind))
                        Text(line.text).textSelection(.enabled)
                        Spacer()
                        Text(line.date, style: .time).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(width: 640, height: 400)
    }

    private func icon(_ k: LogLine.Kind) -> String {
        switch k { case .info: "info.circle"; case .ok: "checkmark.circle.fill"; case .warn: "exclamationmark.triangle.fill"; case .fail: "xmark.octagon.fill" }
    }
    private func color(_ k: LogLine.Kind) -> Color {
        switch k { case .info: .secondary; case .ok: .green; case .warn: .orange; case .fail: .red }
    }
}

struct ErrorView: View {
    @EnvironmentObject var store: Store
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Nicht bei GitHub angemeldet", systemImage: "person.crop.circle.badge.exclamationmark")
        } description: {
            if let dc = store.deviceCode {
                Text("Gib diesen Code auf GitHub ein:")
                Text(dc.userCode).font(.system(size: 34, weight: .bold, design: .monospaced)).textSelection(.enabled)
                Text("Der Browser wurde geöffnet. Warte auf Bestätigung …").foregroundStyle(.secondary)
            } else {
                Text(message).textSelection(.enabled)
                if let e = store.loginError { Text(e).foregroundStyle(.red) }
                if Auth.clientID.isEmpty {
                    Text("Anmelden per Terminal: gh auth login  (danach: gh auth refresh -s workflow)")
                        .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        } actions: {
            if store.deviceCode != nil {
                Button("Abbrechen") { store.cancelLogin() }
            } else {
                if !Auth.clientID.isEmpty {
                    Button("Mit GitHub anmelden") { store.login() }.buttonStyle(.borderedProminent)
                }
                Button("Erneut versuchen") { Task { await store.refresh() } }
            }
        }
        .onChange(of: store.deviceCode?.userCode) { _, code in
            if let uri = store.deviceCode?.uri, code != nil, let url = URL(string: uri) { NSWorkspace.shared.open(url) }
        }
    }
}
