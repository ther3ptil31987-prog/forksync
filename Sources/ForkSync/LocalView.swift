import SwiftUI

/// Klone auf dem Mac: auswählen, mit GitHub vergleichen, per Fast-Forward aktuell halten (nie pushen).
struct LocalView: View {
    @EnvironmentObject var store: Store
    let search: String
    @State private var filter: LFilter = .all
    @State private var showForks = false

    enum LFilter: String, CaseIterable, Identifiable {
        case all, selected, attention
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: tr("Alle", "All")
            case .selected: tr("Ausgewählt", "Selected")
            case .attention: tr("Abweichend", "Needs attention")
            }
        }
    }

    private var pool: [RepoItem] { store.repos.filter { showForks || !$0.isFork || store.localEnabled.contains($0.full) } }

    private var visible: [RepoItem] {
        pool.filter { r in
            guard search.isEmpty || r.full.localizedCaseInsensitiveContains(search) else { return false }
            switch filter {
            case .all: return true
            case .selected: return store.localEnabled.contains(r.full)
            case .attention:
                guard let s = store.local[r.full] else { return false }
                return store.localEnabled.contains(r.full) && (s.state != .current || s.dirty)
            }
        }
    }

    private var shortRoot: String { store.localRoot.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                Text(shortRoot).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Button(tr("Ändern …", "Change …")) { store.chooseLocalRoot() }
                    .disabled(store.localBusy)
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: store.localRoot)) } label: { Image(systemName: "arrow.up.forward.app") }
                    .help(tr("Im Finder öffnen", "Open in Finder"))
                    .disabled(!FileManager.default.fileExists(atPath: store.localRoot))
                Button { Task { await store.reloadLocal() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(store.localBusy || store.reposLoading)
                    .help(tr("Alles neu einlesen: Repo-Liste von GitHub und lokaler Stand", "Reload everything: repo list from GitHub and local state"))
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 12).padding(.top, 8)
            HStack {
                Picker("", selection: $filter) {
                    ForEach(LFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Toggle(tr("Forks anzeigen", "Show forks"), isOn: $showForks).toggleStyle(.checkbox)
                Menu(tr("Auswahl", "Selection")) {
                    Button(tr("Alle sichtbaren auswählen", "Select all visible")) { visible.forEach { store.localEnabled.insert($0.full) } }
                    Button(tr("Alle sichtbaren abwählen", "Deselect all visible")) { visible.forEach { store.localEnabled.remove($0.full) } }
                }.fixedSize()
                Spacer(minLength: 12)
                Text(tr("\(store.localEnabled.count) ausgewählt · \(visible.count) von \(pool.count) Repos", "\(store.localEnabled.count) selected · \(visible.count) of \(pool.count) repos"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if store.reposLoading && store.repos.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(tr("Repos werden geladen …", "Loading repos …")).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                ContentUnavailableView(tr("Keine Repos", "No repos"), systemImage: "tray")
            } else {
                List(visible) { repo in
                    LocalRow(repo: repo, state: store.local[repo.full],
                             enabled: Binding(get: { store.localEnabled.contains(repo.full) },
                                              set: { store.setLocalEnabled(repo.full, $0) }))
                        .simultaneousGesture(TapGesture(count: 2).onEnded { open(repo) })
                        .contextMenu {
                            if store.local[repo.full]?.exists == true {
                                Button(tr("Im Finder zeigen", "Show in Finder")) { open(repo) }
                            }
                            Button(tr("Auf GitHub öffnen", "Open on GitHub")) { NSWorkspace.shared.open(URL(string: "https://github.com/\(repo.full)")!) }
                        }
                }
                .listStyle(.inset)
            }
            Divider()
            LocalBar()
        }
        .task {
            if store.repos.isEmpty { await store.loadRepos() }
            if store.local.isEmpty, !store.localEnabled.isEmpty { await store.checkLocal() }
        }
    }

    private func open(_ repo: RepoItem) {
        if let s = store.local[repo.full], s.exists {
            NSWorkspace.shared.open(URL(fileURLWithPath: s.dir))
        } else if let u = URL(string: "https://github.com/\(repo.full)") {
            NSWorkspace.shared.open(u)
        }
    }
}

struct LocalRow: View {
    let repo: RepoItem
    let state: LocalRepo?
    @Binding var enabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $enabled).toggleStyle(.checkbox).labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(repo.name).font(.headline).lineLimit(1)
                    if repo.isPrivate { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.orange) }
                    if repo.isFork { Image(systemName: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary) }
                }
                Text(state?.detail.isEmpty == false ? state!.detail : (state?.branch.isEmpty == false ? tr("Branch \(state!.branch)", "Branch \(state!.branch)") : repo.full))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .layoutPriority(-1)
            Spacer(minLength: 8)
            if let s = state, enabled {
                if s.dirty {
                    Text(tr("Änderungen", "Changes"))
                        .font(.callout).foregroundStyle(.orange).lineLimit(1).fixedSize()
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                        .help(tr("Nicht committete lokale Änderungen – es wird nichts überschrieben.", "Uncommitted local changes – nothing is overwritten."))
                }
                Text(s.statusText)
                    .font(.callout).foregroundStyle(s.color).lineLimit(1).fixedSize()
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(s.color.opacity(0.12), in: Capsule())
            } else if enabled {
                Text(tr("Noch nicht geprüft", "Not checked yet")).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct LocalBar: View {
    @EnvironmentObject var store: Store

    private static let intervals = [15, 30, 60, 180, 720, 1440]
    private func label(_ m: Int) -> String {
        m < 60 ? tr("alle \(m) Min.", "every \(m) min") : m == 1440 ? tr("täglich", "daily") : tr("alle \(m / 60) Std.", "every \(m / 60) h")
    }

    var body: some View {
        HStack(spacing: 12) {
            Toggle(tr("Automatisch", "Automatic"), isOn: $store.localAuto).toggleStyle(.switch)
                .help(tr("Gleicht die ausgewählten Repos regelmäßig ab, solange ForkSync läuft.", "Regularly syncs the selected repos while ForkSync is running."))
            Picker("", selection: $store.localInterval) {
                ForEach(Self.intervals, id: \.self) { Text(label($0)).tag($0) }
            }
            .labelsHidden().fixedSize().disabled(!store.localAuto)
            Toggle(tr("Bei Anmeldung starten", "Launch at login"),
                   isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox)
                .help(tr("Damit der automatische Abgleich auch nach einem Neustart läuft.", "So the automatic sync also runs after a restart."))
            Spacer(minLength: 8)
            if store.localBusy { ProgressView().controlSize(.small) }
            else if let d = store.localLast {
                Text(tr("Zuletzt: ", "Last: ") + d.formatted(date: .omitted, time: .shortened)).font(.callout).foregroundStyle(.secondary)
            }
            Button { Task { await store.checkLocal() } } label: { Label(tr("Prüfen", "Check"), systemImage: "arrow.triangle.2.circlepath") }
                .disabled(store.localEnabled.isEmpty || store.localBusy)
                .help(tr("Lokalen Stand mit GitHub vergleichen (ändert nichts)", "Compare local state with GitHub (changes nothing)"))
            Button { Task { await store.syncLocal() } } label: { Label(tr("Auf den Mac syncen", "Sync to Mac"), systemImage: "arrow.down.circle.fill") }
                .buttonStyle(.borderedProminent)
                .disabled(store.localEnabled.isEmpty || store.localBusy)
                .help(tr("Fehlende Repos klonen, hinterherhinkende per Fast-Forward aktualisieren. Lokale Änderungen bleiben unberührt, es wird nie gepusht.", "Clone missing repos, fast-forward repos that are behind. Local changes are never touched, nothing is ever pushed."))
        }
        .padding(12)
        .background(.bar)
        .labelStyle(.titleAndIcon)
    }
}
