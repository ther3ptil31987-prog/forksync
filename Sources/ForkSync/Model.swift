import SwiftUI

enum SyncMode: String, CaseIterable, Identifiable {
    case auto, ff, pr
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Automatisch (Spiegel / Merge)"
        case .ff: "Nur Spiegeln (Fast-Forward)"
        case .pr: "Immer Pull Request"
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
        case (.current, _): return "Aktuell"
        case (.behind, _): return behind == 1 ? "1 neuer Commit im Original" : "\(behind) neue Commits im Original"
        case (.ahead, .bot): return ahead == 1 ? "1 Bot-Commit" : "\(ahead) Bot-Commits"
        case (.ahead, .foreign): return ahead == 1 ? "1 Commit des Original-Autors" : "\(ahead) Commits des Original-Autors"
        case (.ahead, .own): return ahead == 1 ? "1 eigener Commit" : "\(ahead) eigene Commits"
        case (.diverged, .own): return "Getrennt: \(ahead) eigene / \(behind) neue"
        case (.diverged, _): return "Historie umgeschrieben: \(ahead) alt / \(behind) neu"
        case (.error, _): return "Fehler"
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
    case all = "Alle", behind = "Hinterher", own = "Eigene Commits", auto = "Auto-Sync", off = "Ohne Auto-Sync"
    var id: String { rawValue }
    func matches(_ f: Fork) -> Bool {
        switch self {
        case .all: true
        case .behind: f.behind > 0
        case .own: f.ownCommits
        case .auto: f.hasAutoSync
        case .off: !f.hasAutoSync && f.error == nil
        }
    }
}

struct LogLine: Identifiable {
    enum Kind { case info, ok, warn, fail }
    let id = UUID()
    let kind: Kind
    let text: String
    let date = Date()
}

enum WorkflowTemplate {
    static let wfPath = ".github/workflows/upstream-sync.yml"
    static let wfName = "upstream-sync.yml"

    static func render(_ f: Fork, mode: SyncMode, cron: String) -> String {
        template
            .replacingOccurrences(of: "@@MODE@@", with: mode.rawValue)
            .replacingOccurrences(of: "@@CRON@@", with: cron)
            .replacingOccurrences(of: "@@UPSTREAM@@", with: f.parent ?? "")
            .replacingOccurrences(of: "@@UPSTREAM_BRANCH@@", with: f.parentBranch ?? "")
            .replacingOccurrences(of: "@@BRANCH@@", with: f.branch)
    }

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
          ref: @@BRANCH@@
          fetch-depth: 0
      - name: Sync
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          set -e
          git remote add upstream "https://github.com/@@UPSTREAM@@.git"
          git fetch upstream "@@UPSTREAM_BRANCH@@"
          UP="upstream/@@UPSTREAM_BRANCH@@"

          if git merge-base --is-ancestor "$UP" HEAD; then
            echo "Schon aktuell"; exit 0
          fi

          if git merge-base --is-ancestor HEAD "$UP"; then
            git push origin "$UP:refs/heads/@@BRANCH@@"
            echo "Fast-Forward durchgefuehrt"; exit 0
          fi

          if [ "@@MODE@@" = "ff" ]; then
            echo "::warning::Fork hat eigene Commits, Fast-Forward nicht moeglich (Modus ff). Nichts geaendert."
            exit 0
          fi

          if [ "@@MODE@@" = "auto" ]; then
            git config user.name "forksync"
            git config user.email "forksync@users.noreply.github.com"
            if git merge --no-edit "$UP" && git push origin "HEAD:refs/heads/@@BRANCH@@"; then
              echo "Original eingemergt, eigene Commits bleiben erhalten"; exit 0
            fi
            git merge --abort 2>/dev/null || true
            git reset --hard "origin/@@BRANCH@@"
            echo "::warning::Automatischer Merge nicht moeglich (Konflikt), Pull Request wird erstellt."
          fi

          git push --force origin "$UP:refs/heads/upstream-sync"
          if [ -z "$(gh pr list --head upstream-sync --state open --json number -q '.[].number')" ]; then
            gh pr create --base "@@BRANCH@@" --head upstream-sync \
              --title "Sync with upstream" \
              --body "Automatisch erstellt von forksync: neue Aenderungen aus @@UPSTREAM@@."
          fi

"""#
}
