import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case forks, repos
    var id: String { rawValue }
    var title: String { self == .forks ? "Forks" : tr("Meine Repos", "My repos") }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @AppStorage(Lang.key) private var lang = Lang.system.rawValue
    @State private var selection = Set<String>()
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var showLog = false
    @State private var page: Page = .forks
    @AppStorage("forksync.disclaimerAccepted") private var accepted = false
    @State private var showDisclaimer = false
    @State private var confirmRemove = false
    @State private var confirmSetupAll = false

    private var visible: [Fork] {
        store.forks.filter { filter.matches($0) && (search.isEmpty || $0.full.localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let fatal = store.fatal {
                ErrorView(message: fatal)
            } else if page == .repos {
                RepoView(search: search)
            } else {
                if store.missingWorkflowScope {
                    Label(tr("gh fehlt der Scope „workflow“ – im Terminal: gh auth refresh -s workflow", "gh is missing the “workflow” scope – run in Terminal: gh auth refresh -s workflow"),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.orange.opacity(0.1))
                }
                HStack {
                    Picker("Filter", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer(minLength: 12)
                    Text(tr("\(visible.count) von \(store.forks.count) Forks", "\(visible.count) of \(store.forks.count) forks"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
                list
                Divider()
                ActionBar(selection: selection, showLog: $showLog, confirmRemove: $confirmRemove, confirmSetupAll: $confirmSetupAll)
            }
        }
        .id(lang)
        .searchable(text: $search, prompt: tr("Forks durchsuchen", "Search forks"))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { showDisclaimer = true } label: { Image(systemName: "info.circle") }
                    .help(tr("Hinweis und Haftungsausschluss", "Notice and disclaimer"))
            }
            ToolbarItem(placement: .principal) {
                Picker("", selection: $page) {
                    ForEach(Page.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("", selection: $lang) {
                    Text("DE").tag(Lang.de.rawValue)
                    Text("EN").tag(Lang.en.rawValue)
                }
                .pickerStyle(.segmented)
                .frame(width: 80)
                .help(tr("Sprache", "Language"))
            }
            ToolbarItem(placement: .primaryAction) {
                if store.ownLogin {
                    Menu {
                        Button(tr("Abmelden", "Sign out"), systemImage: "rectangle.portrait.and.arrow.right") { store.logout() }
                    } label: { Label(store.user ?? tr("Konto", "Account"), systemImage: "person.crop.circle") }
                } else if !Auth.clientID.isEmpty {
                    Button { store.startLogin() } label: { Label(tr("Anmelden", "Sign in"), systemImage: "person.crop.circle.badge.plus") }
                        .help(tr("Mit GitHub anmelden", "Sign in with GitHub"))
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await store.refresh() } } label: {
                    if store.loading { ProgressView().controlSize(.small) }
                    else { Label(tr("Aktualisieren", "Refresh"), systemImage: "arrow.clockwise") }
                }
                .disabled(store.loading)
                .help(tr("Status neu laden (⌘R)", "Reload status (⌘R)"))
            }
        }
        .sheet(isPresented: $showLog) { LogView() }
        .sheet(isPresented: $showDisclaimer) { DisclaimerSheet() }
        .onAppear { if !accepted { showDisclaimer = true } }
        .confirmationDialog(tr("Auto-Sync in \(selection.count) Fork(s) entfernen?", "Remove auto-sync from \(selection.count) fork(s)?"),
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(tr("Entfernen", "Remove"), role: .destructive) { Task { await store.remove(selection) } }
        }
        .confirmationDialog(tr("Auto-Sync in \(store.setupAllIDs.count) Forks einrichten?", "Set up auto-sync in \(store.setupAllIDs.count) forks?"),
                            isPresented: $confirmSetupAll, titleVisibility: .visible) {
            Button(tr("Alle einrichten (\(store.modeChoice.title))", "Set up all (\(store.modeChoice.title))")) {
                Task { await store.install(store.setupAllIDs, mode: store.modeChoice, runAfter: false) }
            }
        } message: {
            Text(tr("Schreibt in jeden Fork ohne Auto-Sync die Datei .github/workflows/upstream-sync.yml. Der erste Lauf erfolgt zum eingestellten Zeitplan.",
                    "Writes .github/workflows/upstream-sync.yml into every fork without auto-sync. The first run happens at the configured schedule."))
        }
    }

    private var list: some View {
        Group {
            if store.loading && store.forks.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(tr("Forks werden geprüft …", "Checking forks …")).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                ContentUnavailableView(tr("Keine Forks", "No forks"), systemImage: "arrow.triangle.branch",
                                       description: Text(store.forks.isEmpty ? tr("Dein Account hat keine Forks.", "Your account has no forks.") : tr("Kein Fork passt zum Filter.", "No fork matches the filter.")))
            } else {
                List(visible, selection: $selection) { fork in
                    ForkRow(fork: fork, busy: store.busy.contains(fork.id)) { Task { await store.syncNow([fork.id]) } }
                        .tag(fork.id)
                        .simultaneousGesture(TapGesture(count: 2).onEnded { NSWorkspace.shared.open(fork.url) })
                        .contextMenu {
                            Button(tr("Auf GitHub öffnen", "Open on GitHub")) { NSWorkspace.shared.open(fork.url) }
                            if let p = fork.parent, let u = URL(string: "https://github.com/\(p)") {
                                Button(tr("Original öffnen", "Open original")) { NSWorkspace.shared.open(u) }
                            }
                        }
                }
                .listStyle(.inset)
            }
        }
    }
}

struct ForkRow: View {
    let fork: Fork
    let busy: Bool
    let onSync: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: fork.stateIcon)
                .font(.title2)
                .foregroundStyle(fork.stateColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(fork.name).font(.headline).lineLimit(1)
                Text(fork.parent.map { tr("Fork von \($0)", "Fork of \($0)") } ?? fork.full)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .layoutPriority(-1)
            Spacer(minLength: 8)
            Text(fork.statusText)
                .font(.callout)
                .foregroundStyle(fork.stateColor)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(fork.stateColor.opacity(0.12), in: Capsule())
            if fork.syncFailed && fork.behind > 0 && fork.error == nil && !busy {
                Button(action: onSync) { Label(tr("Syncen", "Sync"), systemImage: "arrow.triangle.2.circlepath") }
                    .controlSize(.small)
                    .help(tr("Auto-Sync ist fehlgeschlagen (z. B. weil das Original Workflow-Dateien ändert). Jetzt mit deinem Login syncen.", "Auto-sync failed (e.g. because the original changes workflow files). Sync now with your login."))
            }
            Group {
                if busy { ProgressView().controlSize(.small) }
                else if let mode = fork.workflowMode ?? (fork.hasAutoSync ? .ff : nil) {
                    Label("Auto · \(mode.short)", systemImage: "bolt.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(fork.needsAdapt ? .orange : .green)
                        .help(fork.needsAdapt ? tr("Eigene Commits vorhanden – Modus „auto“ empfohlen", "Has own commits – mode “auto” recommended") : tr("Täglicher Auto-Sync aktiv", "Daily auto-sync active"))
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
    @Binding var confirmSetupAll: Bool

    private var adaptCount: Int { store.forks.filter(\.needsAdapt).count }
    private var hasSync: Bool { store.forks.contains { selection.contains($0.id) && $0.hasAutoSync } }

    var body: some View {
        HStack(spacing: 12) {
            Picker(tr("Modus", "Mode"), selection: $store.modeChoice) {
                ForEach(SyncMode.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            ScheduleButton()
            Spacer(minLength: 8)
            if adaptCount > 0 {
                Button { Task { await store.adaptAll() } } label: {
                    Label(tr("\(adaptCount) umstellen", "Switch \(adaptCount)"), systemImage: "wand.and.stars")
                }.help(tr("ff-Forks mit eigenen Commits auf Modus „auto“ umstellen (eigene Commits bleiben erhalten)", "Switch ff forks that have own commits to mode “auto” (own commits are kept)"))
            }
            Button { showLog = true } label: { Image(systemName: "list.bullet.rectangle") }.help(tr("Protokoll", "Log"))
            Button { Task { await store.syncNow(selection) } } label: { Label(tr("Syncen", "Sync"), systemImage: "play.fill") }
                .disabled(selection.isEmpty)
                .help(tr("Sofort synchronisieren (eigene Commits bleiben erhalten)", "Sync now (own commits are kept)"))
            Button(role: .destructive) { confirmRemove = true } label: { Image(systemName: "trash") }.help(tr("Auto-Sync entfernen", "Remove auto-sync"))
                .disabled(!hasSync)
            Button { confirmSetupAll = true } label: {
                Label(tr("Alle einrichten (\(store.setupAllIDs.count))", "Set up all (\(store.setupAllIDs.count))"), systemImage: "bolt.badge.checkmark")
            }
            .disabled(store.setupAllIDs.isEmpty || !store.schedule.isValid)
            .help(tr("Auto-Sync in allen Forks einrichten, die noch keinen haben", "Set up auto-sync in every fork that has none yet"))
            Button { Task { await store.install(selection, mode: store.modeChoice) } } label: {
                Label(tr("Einrichten", "Set up"), systemImage: "bolt.fill")
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
                Text(tr("Protokoll", "Log")).font(.title3.bold())
                Spacer()
                Button(tr("Leeren", "Clear")) { store.log.removeAll() }.disabled(store.log.isEmpty)
                Button(tr("Fertig", "Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding()
            Divider()
            if store.log.isEmpty {
                ContentUnavailableView(tr("Noch keine Einträge", "No entries yet"), systemImage: "text.alignleft")
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
            Label(tr("Nicht bei GitHub angemeldet", "Not signed in to GitHub"), systemImage: "person.crop.circle.badge.exclamationmark")
        } description: {
            if let dc = store.deviceCode {
                Text(tr("Gib diesen Code auf GitHub ein:", "Enter this code on GitHub:"))
                Text(dc.userCode).font(.system(size: 34, weight: .bold, design: .monospaced)).textSelection(.enabled)
                Label(tr("Code in die Zwischenablage kopiert – im Browser einfach einfügen (⌘V).", "Code copied to the clipboard – just paste it in the browser (⌘V)."), systemImage: "doc.on.clipboard.fill")
                    .foregroundStyle(.green)
                Text(tr("Der Browser wurde geöffnet. Warte auf Bestätigung …", "The browser has opened. Waiting for confirmation …")).foregroundStyle(.secondary)
            } else {
                Text(message).textSelection(.enabled)
                if let e = store.loginError { Text(e).foregroundStyle(.red) }
                if Auth.clientID.isEmpty {
                    Text(tr("Anmelden per Terminal: gh auth login  (danach: gh auth refresh -s workflow)", "Sign in via Terminal: gh auth login  (then: gh auth refresh -s workflow)"))
                        .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        } actions: {
            if store.deviceCode != nil {
                Button(tr("Abbrechen", "Cancel")) { store.cancelLogin() }
            } else {
                if !Auth.clientID.isEmpty {
                    Button(tr("Mit GitHub anmelden", "Sign in with GitHub")) { store.login() }.buttonStyle(.borderedProminent)
                }
                Button(tr("Erneut versuchen", "Try again")) { Task { await store.refresh() } }
            }
        }
        .onChange(of: store.deviceCode?.userCode) { _, code in
            if let uri = store.deviceCode?.uri, code != nil, let url = URL(string: uri) { NSWorkspace.shared.open(url) }
        }
    }
}
