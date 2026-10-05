import SwiftUI

/// Eigene Repositories (keine Forks im Mittelpunkt): Sichtbarkeit öffentlich/privat umschalten – mit deutlichen Warnungen.
struct RepoView: View {
    @EnvironmentObject var store: Store
    let search: String
    @State private var filter: VisFilter = .all
    @State private var pending: RepoItem?
    @State private var showForks = false

    enum VisFilter: String, CaseIterable, Identifiable {
        case all, publicOnly, privateOnly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: tr("Alle", "All")
            case .publicOnly: tr("Öffentlich", "Public")
            case .privateOnly: tr("Privat", "Private")
            }
        }
    }

    private var pool: [RepoItem] { store.repos.filter { showForks || !$0.isFork } }

    private var visible: [RepoItem] {
        pool.filter {
            (search.isEmpty || $0.full.localizedCaseInsensitiveContains(search)) &&
            (filter == .all || (filter == .publicOnly && !$0.isPrivate) || (filter == .privateOnly && $0.isPrivate))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $filter) {
                    ForEach(VisFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
                Button { Task { await store.loadRepos() } } label: { Image(systemName: "arrow.clockwise") }
                    .help(tr("Repos neu laden", "Reload repos"))
                Toggle(tr("Forks anzeigen", "Show forks"), isOn: $showForks)
                    .toggleStyle(.checkbox)
                    .help(tr("Forks folgen der Sichtbarkeit des Originals und lassen sich hier nicht umstellen.", "Forks follow the original's visibility and cannot be changed here."))
                Spacer()
                Text(tr("\(visible.count) von \(pool.count) Repos", "\(visible.count) of \(pool.count) repos"))
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
                    RepoRow(repo: repo) { pending = repo }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            Divider()
            Label(tr("Vorsicht: Eine Änderung der Sichtbarkeit ist folgenreich und lässt sich nicht immer vollständig rückgängig machen. Nutzung auf eigene Verantwortung, keine Haftung.",
                     "Caution: changing visibility has real consequences and cannot always be fully undone. Use at your own risk, no liability."),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.bar)
        }
        .task { await store.loadRepos() }
        .sheet(item: $pending) { repo in VisibilitySheet(repo: repo).environmentObject(store) }
    }
}

struct RepoRow: View {
    let repo: RepoItem
    let action: () -> Void

    private var blockReason: String? {
        if repo.archived { return tr("Archivierte Repos sind schreibgeschützt.", "Archived repos are read-only.") }
        if repo.isFork { return tr("Bei Forks erlaubt GitHub das Umschalten in der Regel nicht (Sichtbarkeit folgt dem Original).",
                                   "GitHub generally does not allow changing a fork's visibility (it follows the original).") }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: repo.isPrivate ? "lock.fill" : "globe")
                .font(.title3).foregroundStyle(repo.isPrivate ? .orange : .green).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name).font(.headline)
                HStack(spacing: 8) {
                    if repo.isFork { Text("Fork") }
                    if repo.archived { Text(tr("archiviert", "archived")) }
                    Label("\(repo.stars)", systemImage: "star")
                    Label("\(repo.forks)", systemImage: "arrow.triangle.branch")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(repo.isPrivate ? tr("Privat", "Private") : tr("Öffentlich", "Public"))
                .font(.callout)
                .foregroundStyle(repo.isPrivate ? .orange : .green)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background((repo.isPrivate ? Color.orange : Color.green).opacity(0.12), in: Capsule())
            Button(action: action) {
                Text(repo.isPrivate ? tr("Öffentlich stellen …", "Make public …") : tr("Privat stellen …", "Make private …"))
            }
            .disabled(blockReason != nil)
            .help(blockReason ?? "")
        }
        .padding(.vertical, 4)
    }
}

struct VisibilitySheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let repo: RepoItem
    @State private var typed = ""
    @State private var working = false

    private var toPrivate: Bool { !repo.isPrivate }

    private var warnings: [String] {
        if toPrivate {
            return [
                tr("Stars und Watcher gehen dauerhaft verloren.", "Stars and watchers are lost permanently."),
                tr("Bestehende öffentliche Forks anderer Nutzer werden vom Repo getrennt.", "Existing public forks by other users are detached from the repo."),
                tr("GitHub Pages wird abgeschaltet; Links, Release-Downloads und Badges funktionieren für Fremde nicht mehr.", "GitHub Pages is unpublished; links, release downloads and badges stop working for others."),
                tr("Für private Repos gelten Limits bei GitHub Actions (Gratis-Kontingent).", "Private repos are subject to GitHub Actions limits (free quota)."),
            ]
        }
        return [
            tr("Quellcode und die KOMPLETTE Git-Historie sind danach für jeden im Internet sichtbar.", "Source code and the ENTIRE git history become visible to everyone on the internet."),
            tr("Auch alte Commits, gelöschte Dateien und die E-Mail-Adressen der Autoren in der Historie sind einsehbar.", "Old commits, deleted files and the authors' email addresses in the history are visible too."),
            tr("Jedes Passwort, Token oder jeder Schlüssel, der je committet wurde, gilt als kompromittiert und muss erneuert werden.", "Any password, token or key that was ever committed must be considered compromised and has to be rotated."),
            tr("Nicht vollständig rückgängig zu machen: Wer das Repo einmal geklont oder zwischengespeichert hat, behält die Daten, auch wenn du es wieder privat stellst.", "Cannot be fully undone: anyone who cloned or cached the repo keeps the data, even if you make it private again."),
            tr("Prüfe vorher Code, Historie, Issues, Wiki und Releases.", "Review code, history, issues, wiki and releases beforehand."),
        ]
    }

    private var confirmed: Bool { toPrivate || typed == repo.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(toPrivate ? tr("„\(repo.name)“ privat stellen?", "Make “\(repo.name)” private?")
                            : tr("„\(repo.name)“ öffentlich stellen?", "Make “\(repo.name)” public?"),
                  systemImage: toPrivate ? "lock.fill" : "exclamationmark.triangle.fill")
                .font(.title3.bold())
                .foregroundStyle(toPrivate ? Color.primary : Color.red)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(warnings, id: \.self) { w in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        Text(w).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text(tr("Du handelst auf eigene Verantwortung. Der Autor von ForkSync übernimmt keine Haftung für Schäden, Datenverlust oder veröffentlichte Daten.",
                    "You act at your own risk. The author of ForkSync accepts no liability for damage, data loss or exposed data."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !toPrivate {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Zur Bestätigung den Repo-Namen eintippen: \(repo.name)", "To confirm, type the repo name: \(repo.name)"))
                        .font(.callout)
                    TextField(repo.name, text: $typed).textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Spacer()
                Button(tr("Abbrechen", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(role: toPrivate ? nil : .destructive) {
                    working = true
                    Task { await store.setVisibility(repo, toPrivate: toPrivate); dismiss() }
                } label: {
                    Text(toPrivate ? tr("Jetzt privat stellen", "Make private now") : tr("Jetzt öffentlich stellen", "Make public now"))
                }
                .disabled(!confirmed || working)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
