import SwiftUI

@MainActor
final class Store: ObservableObject {
    @Published var forks: [Fork] = []
    @Published var loading = false
    @Published var busy: Set<String> = []
    @Published var log: [LogLine] = LogStore.load() { didSet { LogStore.save(log) } }
    @Published var user: String?
    @Published var fatal: String?
    @Published var missingWorkflowScope = false
    @Published var modeChoice: SyncMode = .auto
    @Published var schedule = Schedule.load() { didSet { schedule.save() } }
    var cron: String { schedule.cron }
    @Published var repos: [RepoItem] = []
    @Published var reposLoading = false
    @Published var deviceCode: Auth.DeviceCode?
    @Published var loginError: String?
    @Published var ownLogin = Auth.token != nil
    private var loginTask: Task<Void, Never>?

    func login() {
        loginError = nil
        loginTask?.cancel()
        loginTask = Task {
            do {
                let dc = try await Auth.start()
                deviceCode = dc
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(dc.userCode, forType: .string)
                try await Auth.finish(dc)
                deviceCode = nil
                ownLogin = true
                await refresh()
            } catch is CancellationError {
                deviceCode = nil
            } catch {
                deviceCode = nil
                loginError = (error as? GHError)?.message ?? error.localizedDescription
            }
        }
    }

    func startLogin() { fatal = tr("Anmeldung mit eigenem Konto", "Signing in with your own account"); login() }

    func cancelLogin() { loginTask?.cancel(); deviceCode = nil }

    func logout() {
        Auth.delete()
        ownLogin = false
        forks = []
        user = nil
        fatal = tr("Abgemeldet.", "Signed out.")
    }

    func add(_ kind: LogLine.Kind, _ text: String) { log.append(LogLine(kind: kind, text: text)) }

    // MARK: Repos (Sichtbarkeit)

    func loadRepos() async {
        guard !reposLoading else { return }
        reposLoading = true
        defer { reposLoading = false }
        do {
            let list = (try await GH.api("user/repos?affiliation=owner&per_page=100", paginate: true) as? [[String: Any]]) ?? []
            repos = list.map { r in
                RepoItem(full: r["full_name"] as? String ?? "?", name: r["name"] as? String ?? "?",
                         isPrivate: r["private"] as? Bool ?? false, isFork: r["fork"] as? Bool ?? false,
                         archived: r["archived"] as? Bool ?? false,
                         stars: r["stargazers_count"] as? Int ?? 0, forks: r["forks_count"] as? Int ?? 0)
            }.sorted { $0.full.lowercased() < $1.full.lowercased() }
        } catch {
            add(.fail, tr("Repos laden fehlgeschlagen: ", "Loading repos failed: ") + ((error as? GHError)?.firstLine ?? error.localizedDescription))
        }
    }

    func setVisibility(_ repo: RepoItem, toPrivate: Bool) async {
        do {
            try await GH.api("repos/\(repo.full)", method: "PATCH", body: ["visibility": toPrivate ? "private" : "public"])
            add(.ok, toPrivate ? tr("\(repo.full): jetzt privat", "\(repo.full): now private")
                               : tr("\(repo.full): jetzt öffentlich", "\(repo.full): now public"))
        } catch {
            add(.fail, "\(repo.full): " + ((error as? GHError)?.firstLine ?? error.localizedDescription))
        }
        await loadRepos()
    }

    // MARK: Laden

    func refresh() async {
        guard !loading else { return }
        loading = true
        fatal = nil
        defer { loading = false }
        let auth = await GH.authStatus()
        guard auth.ok else {
            fatal = auth.detail.isEmpty ? tr("Nicht bei GitHub angemeldet.", "Not signed in to GitHub.") : auth.detail
            return
        }
        user = auth.user
        missingWorkflowScope = !auth.hasWorkflowScope
        do {
            let repos = (try await GH.api("user/repos?affiliation=owner&per_page=100", paginate: true) as? [[String: Any]]) ?? []
            let candidates = repos.filter { ($0["fork"] as? Bool) == true && ($0["archived"] as? Bool) != true }
            var result: [Fork] = []
            for chunk in stride(from: 0, to: candidates.count, by: 8).map({ Array(candidates[$0..<min($0 + 8, candidates.count)]) }) {
                await withTaskGroup(of: Fork.self) { group in
                    for repo in chunk { group.addTask { await Store.inspect(repo) } }
                    for await f in group { result.append(f) }
                }
            }
            forks = result.sorted { $0.full.lowercased() < $1.full.lowercased() }
        } catch {
            fatal = (error as? GHError)?.message ?? error.localizedDescription
        }
    }

    nonisolated static func inspect(_ repo: [String: Any]) async -> Fork {
        let full = repo["full_name"] as? String ?? "?"
        let owner = (repo["owner"] as? [String: Any])?["login"] as? String ?? ""
        let branch = repo["default_branch"] as? String ?? "main"
        var fork = Fork(full: full, name: repo["name"] as? String ?? full, branch: branch)
        do {
            let detail = try await GH.api("repos/\(full)") as? [String: Any]
            guard let parent = detail?["parent"] as? [String: Any],
                  let pFull = parent["full_name"] as? String,
                  let pBranch = parent["default_branch"] as? String else {
                fork.error = "Kein Original gefunden"
                return fork
            }
            fork.parent = pFull
            // Gleichnamigen Branch des Originals vergleichen (Fork-main <-> Original-main), sonst dessen Standard-Branch.
            let enc = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
            let cmpBranch = (try? await GH.api("repos/\(pFull)/branches/\(enc)")) != nil ? branch : pBranch
            fork.parentBranch = cmpBranch
            let cmp = try await GH.api("repos/\(pFull)/compare/\(cmpBranch)...\(owner):\(branch)") as? [String: Any]
            fork.ahead = cmp?["ahead_by"] as? Int ?? 0
            fork.behind = cmp?["behind_by"] as? Int ?? 0
            if fork.ahead > 0 {
                fork.aheadKind = classify(cmp?["commits"] as? [[String: Any]] ?? [], ahead: fork.ahead, owner: owner)
            }
            if let f = try? await GH.api("repos/\(full)/contents/\(WorkflowTemplate.wfPath)?ref=\(branch)") as? [String: Any],
               let sha = f["sha"] as? String {
                fork.workflowSha = sha
                if fork.behind > 0,
                   let runs = try? await GH.api("repos/\(full)/actions/workflows/\(WorkflowTemplate.wfName)/runs?per_page=1&status=completed") as? [String: Any],
                   let last = (runs["workflow_runs"] as? [[String: Any]])?.first {
                    fork.syncFailed = (last["conclusion"] as? String) == "failure"
                }
                let b64 = (f["content"] as? String) ?? ""
                if let d = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
                   let text = String(data: d, encoding: .utf8),
                   let r = text.range(of: #"# mode: (auto|ff|pr)"#, options: .regularExpression) {
                    fork.workflowMode = SyncMode(rawValue: String(text[r].dropFirst(8)))
                }
            }
        } catch {
            fork.error = (error as? GHError)?.firstLine ?? error.localizedDescription
        }
        return fork
    }

    /// Die Compare-API liefert max. 250 Commits; fehlen welche, gilt der Fork vorsichtshalber als „eigen“.
    nonisolated static func classify(_ commits: [[String: Any]], ahead: Int, owner: String) -> Fork.AheadKind {
        guard !commits.isEmpty, commits.count == ahead else { return .own }
        func login(_ c: [String: Any], _ key: String) -> String {
            ((c[key] as? [String: Any])?["login"] as? String) ?? ""
        }
        // Commits, die ForkSync selbst erzeugt (Workflow einrichten, Upstream-Merge), zaehlen wie Bot-Commits.
        func isTool(_ c: [String: Any]) -> Bool {
            let msg = ((c["commit"] as? [String: Any])?["message"] as? String) ?? ""
            return msg.hasPrefix("Add upstream sync workflow (forksync")
                || msg.hasPrefix("Remove upstream sync workflow (forksync")
                || msg.hasPrefix("Merge remote-tracking branch 'upstream/")
        }
        let relevant = commits.filter { !isTool($0) }
        if relevant.isEmpty { return .bot }
        let commits = relevant
        if commits.contains(where: { login($0, "author").lowercased() == owner.lowercased()
                                     || login($0, "committer").lowercased() == owner.lowercased() }) { return .own }
        if commits.allSatisfy({ login($0, "author").hasSuffix("[bot]") }) { return .bot }
        // Commit ohne zuordenbaren GitHub-Account (author == nil) kann von dir sein -> eigen.
        if commits.contains(where: { login($0, "author").isEmpty }) { return .own }
        return .foreign
    }

    // MARK: Aktionen

    /// Alle Forks ohne Auto-Sync (und ohne Fehler) für „Alle einrichten“.
    var setupAllIDs: Set<String> { Set(forks.filter { !$0.hasAutoSync && $0.error == nil }.map(\.id)) }

    func install(_ ids: Set<String>, mode: SyncMode?, runAfter: Bool = true) async {
        for fork in forks where ids.contains(fork.id) {
            busy.insert(fork.id)
            await installOne(fork, mode: mode ?? fork.recommendedMode, runAfter: runAfter)
            busy.remove(fork.id)
        }
        await refresh()
    }

    private func installOne(_ f: Fork, mode: SyncMode, runAfter: Bool) async {
        if let e = f.error { add(.warn, tr("\(f.name): übersprungen (\(e))", "\(f.name): skipped (\(e))")); return }
        let content = Data(WorkflowTemplate.render(f, mode: mode, cron: cron).utf8).base64EncodedString()
        var body: [String: Any] = [
            "message": "Add upstream sync workflow (forksync, mode \(mode.rawValue))",
            "content": content,
        ]
        if let sha = f.workflowSha { body["sha"] = sha }
        // Unveränderte Datei nicht erneut committen (sonst wächst die Historie bei jedem Einrichten).
        var unchanged = false
        if f.workflowSha != nil,
           let cur = try? await GH.api("repos/\(f.full)/contents/\(WorkflowTemplate.wfPath)") as? [String: Any],
           let b64 = cur["content"] as? String {
            unchanged = b64.filter { !$0.isWhitespace } == content
        }
        do {
            if !unchanged { try await GH.api("repos/\(f.full)/contents/\(WorkflowTemplate.wfPath)", method: "PUT", body: body) }
        } catch {
            let msg = (error as? GHError)?.firstLine ?? error.localizedDescription
            let hint = msg.lowercased().contains("workflow") ? tr(" → im Terminal `gh auth refresh -s workflow` ausführen", " → run `gh auth refresh -s workflow` in Terminal") : ""
            add(.fail, tr("\(f.name): Schreiben fehlgeschlagen: \(msg)\(hint)", "\(f.name): write failed: \(msg)\(hint)"))
            return
        }
        var notes: [String] = []
        do { try await GH.api("repos/\(f.full)/actions/permissions", method: "PUT", body: ["enabled": true]) }
        catch { notes.append(tr("Actions im Fork manuell aktivieren", "Enable Actions in the fork manually")) }
        if mode != .ff {
            do {
                try await GH.api("repos/\(f.full)/actions/permissions/workflow", method: "PUT",
                                 body: ["default_workflow_permissions": "write", "can_approve_pull_request_reviews": true])
            } catch {
                notes.append(tr("Settings › Actions › General: „Allow GitHub Actions to create and approve pull requests“ manuell aktivieren", "Enable manually under Settings › Actions › General: “Allow GitHub Actions to create and approve pull requests”"))
            }
        }
        if !(await enableWorkflow(f)) { notes.append(tr("Workflow konnte nicht aktiviert werden (Reiter „Actions“ des Forks)", "Workflow could not be enabled (Actions tab of the fork)")) }
        if f.behind > 0 { await mergeUpstream(f) }
        if runAfter, !(await dispatch(f)) { notes.append(tr("Testlauf konnte nicht gestartet werden", "Test run could not be started")) }
        add(.ok, tr("\(f.name): eingerichtet (Modus \(mode.rawValue))", "\(f.name): set up (mode \(mode.rawValue))"))
        notes.forEach { add(.warn, "\(f.name): \($0)") }
    }

    func adaptAll() async {
        let ids = Set(forks.filter(\.needsAdapt).map(\.id))
        guard !ids.isEmpty else { add(.info, tr("Nichts anzupassen.", "Nothing to adjust.")); return }
        await install(ids, mode: .auto, runAfter: false)
    }

    /// Sofort mit dem eigenen Login syncen (GitHubs merge-upstream); klappt auch, wenn das Original
    /// Workflow-Dateien ändert, was der Actions-Token nicht darf. Eigene Commits bleiben erhalten.
    func syncNow(_ ids: Set<String>) async {
        for f in forks where ids.contains(f.id) && f.error == nil {
            busy.insert(f.id)
            await mergeUpstream(f)
            busy.remove(f.id)
        }
        await refresh()
    }

    private func mergeUpstream(_ f: Fork) async {
        do {
            let r = try await GH.api("repos/\(f.full)/merge-upstream", method: "POST", body: ["branch": f.branch]) as? [String: Any]
            switch r?["merge_type"] as? String {
            case "none": add(.ok, tr("\(f.name): schon aktuell", "\(f.name): already up to date"))
            case "fast-forward": add(.ok, tr("\(f.name): Fast-Forward durchgeführt", "\(f.name): fast-forwarded"))
            default: add(.ok, tr("\(f.name): Original eingemergt, eigene Commits bleiben erhalten", "\(f.name): upstream merged, own commits kept"))
            }
        } catch {
            let msg = (error as? GHError)?.firstLine ?? error.localizedDescription
            let conflict = msg.lowercased().contains("conflict") ? tr(" → Konflikt, bitte auf GitHub manuell lösen", " → conflict, please resolve manually on GitHub") : ""
            add(.fail, "\(f.name): \(msg)\(conflict)")
        }
    }

    /// Forks starten mit deaktivierten Workflows (disabled_fork) - einzeln aktivieren.
    private func enableWorkflow(_ f: Fork) async -> Bool {
        for _ in 0..<4 {
            do {
                try await GH.api("repos/\(f.full)/actions/workflows/\(WorkflowTemplate.wfName)/enable", method: "PUT")
                return true
            } catch { try? await Task.sleep(for: .seconds(3)) }
        }
        return false
    }

    func remove(_ ids: Set<String>) async {
        for f in forks where ids.contains(f.id) {
            guard let sha = f.workflowSha else { continue }
            busy.insert(f.id)
            do {
                try await GH.api("repos/\(f.full)/contents/\(WorkflowTemplate.wfPath)", method: "DELETE",
                                 body: ["message": "Remove upstream sync workflow (forksync)", "sha": sha])
                add(.ok, tr("\(f.name): Auto-Sync entfernt", "\(f.name): auto-sync removed"))
            } catch {
                add(.fail, "\(f.name): \((error as? GHError)?.firstLine ?? error.localizedDescription)")
            }
            busy.remove(f.id)
        }
        await refresh()
    }

    private func dispatch(_ f: Fork) async -> Bool {
        for _ in 0..<4 {
            do {
                try await GH.api("repos/\(f.full)/actions/workflows/\(WorkflowTemplate.wfName)/dispatches",
                                 method: "POST", body: ["ref": f.branch])
                return true
            } catch { try? await Task.sleep(for: .seconds(3)) }
        }
        return false
    }
}
