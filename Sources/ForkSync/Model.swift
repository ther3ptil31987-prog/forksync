import SwiftUI

enum SyncMode: String, CaseIterable, Identifiable {
    case auto, ff, pr
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: tr("Automatisch (Spiegel / Merge)", "Automatic (mirror / merge)")
        case .ff: tr("Nur Spiegeln (Fast-Forward)", "Mirror only (fast-forward)")
        case .pr: tr("Immer Pull Request", "Always pull request")
        }
    }
    var short: String { rawValue }
}

struct Fork: Identifiable, Hashable {
    var id: String { full }
    let full: String
    let name: String
    let branch: String
    var owner: String { String(full.split(separator: "/").first ?? "") }
    var parent: String?
    var parentBranch: String?
    var ahead = 0     // Commits im Fork, die das Original nicht hat
    /// Herkunft der Fork-Commits: Bots (github-actions[bot]), fremde Autoren (z. B. Original-Entwickler,
    /// dessen Historie umgeschrieben wurde) oder tatsaechlich eigene Commits.
    enum AheadKind { case bot, foreign, own }
    var aheadKind: AheadKind = .own
    var ownCommits: Bool { ahead > 0 && aheadKind == .own }
    var behind = 0    // neue Commits im Original
    var workflowSha: String?
    /// Letzter Auto-Sync-Lauf im Fork ist fehlgeschlagen und der Fork hängt hinterher (z. B. Workflow-Sperre).
    var syncFailed = false
    var workflowMode: SyncMode?
    var error: String?
    var url: URL { URL(string: "https://github.com/\(full)")! }

    var hasAutoSync: Bool { workflowSha != nil }
    var recommendedMode: SyncMode { .auto }
    var needsAdapt: Bool { workflowMode == .ff && ownCommits }

    enum State { case current, behind, ahead, diverged, error }
    var state: State {
        if error != nil { return .error }
        switch (ahead, behind) {
        case (0, 0): return .current
        case (0, _): return .behind
        case (_, 0): return .ahead
        default: return .diverged
        }
    }

    var statusText: String {
        if let error { return error }
        switch (state, aheadKind) {
        case (.current, _): return tr("Aktuell", "Up to date")
        case (.behind, _): return tr(behind == 1 ? "1 neuer Commit im Original" : "\(behind) neue Commits im Original",
                                    behind == 1 ? "1 new commit upstream" : "\(behind) new commits upstream")
        case (.ahead, .bot): return tr(ahead == 1 ? "1 Bot-/Sync-Commit" : "\(ahead) Bot-/Sync-Commits",
                                      ahead == 1 ? "1 bot/sync commit" : "\(ahead) bot/sync commits")
        case (.ahead, .foreign): return tr(ahead == 1 ? "1 Commit des Original-Autors" : "\(ahead) Commits des Original-Autors",
                                          ahead == 1 ? "1 commit by the original author" : "\(ahead) commits by the original author")
        case (.ahead, .own): return tr(ahead == 1 ? "1 eigener Commit" : "\(ahead) eigene Commits",
                                      ahead == 1 ? "1 own commit" : "\(ahead) own commits")
        case (.diverged, .own): return tr("Getrennt: \(ahead) eigene / \(behind) neue", "Diverged: \(ahead) own / \(behind) new")
        case (.diverged, .bot): return tr(ahead == 1 ? "1 Sync-Commit / \(behind) neu" : "\(ahead) Sync-Commits / \(behind) neu",
                                         ahead == 1 ? "1 sync commit / \(behind) new" : "\(ahead) sync commits / \(behind) new")
        case (.diverged, _): return tr("Historie umgeschrieben: \(ahead) alt / \(behind) neu", "History rewritten: \(ahead) old / \(behind) new")
        case (.error, _): return tr("Fehler", "Error")
        }
    }

    var stateColor: Color {
        switch state {
        case .current: .green
        case .behind: .blue
        case .ahead: aheadKind == .own ? .purple : .teal
        case .diverged: aheadKind == .own ? .orange : .teal
        case .error: .red
        }
    }

    var stateIcon: String {
        switch state {
        case .current: "checkmark.circle.fill"
        case .behind: "arrow.down.circle.fill"
        case .ahead: "arrow.up.circle.fill"
        case .diverged: "arrow.triangle.branch"
        case .error: "exclamationmark.triangle.fill"
        }
    }
}

enum Filter: String, CaseIterable, Identifiable {
    case all, behind, failed, own, auto, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: tr("Alle", "All")
        case .behind: tr("Hinterher", "Behind")
        case .failed: tr("Fehlgeschlagen", "Failed")
        case .own: tr("Eigene Commits", "Own commits")
        case .auto: "Auto-Sync"
        case .off: tr("Ohne Auto-Sync", "No auto-sync")
        }
    }
    func matches(_ f: Fork) -> Bool {
        switch self {
        case .all: true
        case .behind: f.behind > 0
        case .failed: f.syncFailed
        case .own: f.ownCommits
        case .auto: f.hasAutoSync
        case .off: !f.hasAutoSync && f.error == nil
        }
    }
}

struct RepoItem: Identifiable, Hashable {
    var id: String { full }
    let full: String
    let name: String
    let isPrivate: Bool
    let isFork: Bool
    let archived: Bool
    let stars: Int
    let forks: Int
}

struct LogLine: Identifiable, Codable {
    enum Kind: String, Codable { case info, ok, warn, fail }
    var id = UUID()
    let kind: Kind
    let text: String
    var date = Date()
}

/// Protokoll dauerhaft in ~/Library/Application Support/ForkSync/log.json (die letzten 500 Einträge).
enum LogStore {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ForkSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("log.json")
    }

    static func load() -> [LogLine] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([LogLine].self, from: data)) ?? []
    }

    static let limit = 500

    static func save(_ lines: [LogLine]) {
        if let data = try? JSONEncoder().encode(Array(lines.suffix(limit))) { try? data.write(to: url, options: .atomic) }
    }
}

enum WorkflowTemplate {
    static let wfPath = ".github/workflows/upstream-sync.yml"
    static let wfName = "upstream-sync.yml"

    static func render(_ f: Fork, mode: SyncMode, cron: String) -> String {
        template
            .replacingOccurrences(of: "@@MODE@@", with: mode.rawValue)
            .replacingOccurrences(of: "@@CRON@@", with: cron)
            .replacingOccurrences(of: "@@UPSTREAM@@", with: yaml(f.parent ?? ""))
            .replacingOccurrences(of: "@@UPSTREAM_BRANCH@@", with: yaml(f.parentBranch ?? ""))
            .replacingOccurrences(of: "@@BRANCH@@", with: yaml(f.branch))
    }

    /// Wert für einen einfach quotierten YAML-String. Die Werte landen nur in `env:`/`with:`, nie direkt im Shell-Skript.
    private static func yaml(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "''") }

    /// Namen, die GitHub Actions als Ausdruck auswerten würde oder die das YAML sprengen, werden nicht eingesetzt.
    static func isSafe(_ s: String) -> Bool { !s.contains("${{") && !s.contains(where: \.isNewline) }

    // Identisch zur Vorlage in forksync.py (erste Zeile `# mode:` erkennt das Tool wieder).
    static let template = #"""
# mode: @@MODE@@
# Verwaltet von forksync.py - manuelle Aenderungen werden beim Update ueberschrieben.
name: Upstream sync
on:
  schedule:
    - cron: '@@CRON@@'
  workflow_dispatch:
permissions:
  contents: write
  pull-requests: write
jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          ref: '@@BRANCH@@'
          fetch-depth: 0
      - name: Sync
        env:
          GH_TOKEN: ${{ github.token }}
          MODE: '@@MODE@@'
          BRANCH: '@@BRANCH@@'
          UPSTREAM: '@@UPSTREAM@@'
          UPSTREAM_BRANCH: '@@UPSTREAM_BRANCH@@'
        run: |
          set -e
          git remote add upstream "https://github.com/$UPSTREAM.git"
          git fetch upstream "$UPSTREAM_BRANCH"
          UP="upstream/$UPSTREAM_BRANCH"

          if git merge-base --is-ancestor "$UP" HEAD; then
            echo "Schon aktuell"; exit 0
          fi

          if git merge-base --is-ancestor HEAD "$UP"; then
            if git push origin "$UP:refs/heads/$BRANCH"; then
              echo "Fast-Forward durchgefuehrt"; exit 0
            fi
            if gh api "repos/$GITHUB_REPOSITORY/merge-upstream" -X POST -f branch="$BRANCH" > /dev/null; then
              echo "Fast-Forward durchgefuehrt (GitHub-Sync-API)"; exit 0
            fi
            echo "::error::Push abgelehnt (z. B. aendert das Original .github/workflows). In der App 'Syncen' nutzen."
            exit 1
          fi

          if [ "$MODE" = "ff" ]; then
            echo "::warning::Fork hat eigene Commits, Fast-Forward nicht moeglich (Modus ff). Nichts geaendert."
            exit 0
          fi

          if [ "$MODE" = "auto" ]; then
            git config user.name "forksync"
            git config user.email "forksync@users.noreply.github.com"
            if git merge --no-edit "$UP"; then
              if git push origin "HEAD:refs/heads/$BRANCH"; then
                echo "Original eingemergt, eigene Commits bleiben erhalten"; exit 0
              fi
              git reset --hard "origin/$BRANCH"
              if gh api "repos/$GITHUB_REPOSITORY/merge-upstream" -X POST -f branch="$BRANCH" > /dev/null 2>&1; then
                echo "Original eingemergt (GitHub-Sync-API), eigene Commits bleiben erhalten"; exit 0
              fi
              echo "::error::Merge sauber, aber Push abgelehnt (z. B. aendert das Original .github/workflows). In der App 'Syncen' nutzen."
              exit 1
            fi
            git merge --abort 2>/dev/null || true
            git reset --hard "origin/$BRANCH"
            if gh api "repos/$GITHUB_REPOSITORY/merge-upstream" -X POST -f branch="$BRANCH" > /dev/null 2>&1; then
              echo "Original eingemergt (GitHub-Sync-API), eigene Commits bleiben erhalten"; exit 0
            fi
            echo "::warning::Automatischer Merge nicht moeglich (Konflikt), Pull Request wird erstellt."
          fi

          if ! git push --force origin "$UP:refs/heads/upstream-sync"; then
            echo "::error::Push abgelehnt (z. B. aendert das Original .github/workflows). In der App 'Syncen' nutzen."
            exit 1
          fi
          if [ -z "$(gh pr list --repo "$GITHUB_REPOSITORY" --head upstream-sync --state open --json number -q '.[].number')" ]; then
            gh pr create --repo "$GITHUB_REPOSITORY" --base "$BRANCH" --head upstream-sync \
              --title "Sync with upstream" \
              --body "Automatisch erstellt von forksync: neue Aenderungen aus $UPSTREAM."
          fi

"""#
}
