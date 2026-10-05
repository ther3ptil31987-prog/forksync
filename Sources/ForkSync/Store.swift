import SwiftUI

@MainActor
final class Store: ObservableObject {
    @Published var forks: [Fork] = []
    @Published var loading = false
    @Published var busy: Set<String> = []
    @Published var log: [LogLine] = []
    @Published var user: String?
    @Published var fatal: String?
    @Published var missingWorkflowScope = false
    @Published var modeChoice: SyncMode = .auto
    @Published var cron = "17 5 * * *"

    func add(_ kind: LogLine.Kind, _ text: String) { log.append(LogLine(kind: kind, text: text)) }

    // MARK: Laden

    func refresh() async {
        guard !loading else { return }
        loading = true
        fatal = nil
        defer { loading = false }
        let auth = await GH.authStatus()
        guard auth.ok else {
            fatal = auth.detail.isEmpty ? "Nicht bei GitHub angemeldet." : auth.detail
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
            fork.parentBranch = pBranch
            let cmp = try await GH.api("repos/\(pFull)/compare/\(pBranch)...\(owner):\(branch)") as? [String: Any]
            fork.ahead = cmp?["ahead_by"] as? Int ?? 0
            fork.behind = cmp?["behind_by"] as? Int ?? 0
            if let f = try? await GH.api("repos/\(full)/contents/\(WorkflowTemplate.wfPath)?ref=\(branch)") as? [String: Any],
               let sha = f["sha"] as? String {
                fork.workflowSha = sha
                let b64 = (f["content"] as? String) ?? ""
                if let d = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
                   let text = String(data: d, encoding: .utf8),
                   let r = text.range(of: #"# mode: (ff|pr)"#, options: .regularExpression) {
                    fork.workflowMode = SyncMode(rawValue: String(text[r].dropFirst(8)))
                }
            }
        } catch {
            fork.error = (error as? GHError)?.firstLine ?? error.localizedDescription
        }
        return fork
    }

    // MARK: Aktionen

    func install(_ ids: Set<String>, mode: SyncMode?, runAfter: Bool = true) async {
        for fork in forks where ids.contains(fork.id) {
            busy.insert(fork.id)
            await installOne(fork, mode: mode ?? fork.recommendedMode, runAfter: runAfter)
            busy.remove(fork.id)
        }
        await refresh()
    }

    private func installOne(_ f: Fork, mode: SyncMode, runAfter: Bool) async {
        if let e = f.error { add(.warn, "\(f.name): übersprungen (\(e))"); return }
        var body: [String: Any] = [
            "message": "Add upstream sync workflow (forksync, mode \(mode.rawValue))",
            "content": Data(WorkflowTemplate.render(f, mode: mode, cron: cron).utf8).base64EncodedString(),
        ]
        if let sha = f.workflowSha { body["sha"] = sha }
        do {
            try await GH.api("repos/\(f.full)/contents/\(WorkflowTemplate.wfPath)", method: "PUT", body: body)
        } catch {
            let msg = (error as? GHError)?.firstLine ?? error.localizedDescription
            let hint = msg.lowercased().contains("workflow") ? " → im Terminal `gh auth refresh -s workflow` ausführen" : ""
            add(.fail, "\(f.name): Schreiben fehlgeschlagen: \(msg)\(hint)")
            return
        }
        var notes: [String] = []
        do { try await GH.api("repos/\(f.full)/actions/permissions", method: "PUT", body: ["enabled": true]) }
        catch { notes.append("Actions im Fork manuell aktivieren") }
        if mode != .ff {
            do {
                try await GH.api("repos/\(f.full)/actions/permissions/workflow", method: "PUT",
                                 body: ["default_workflow_permissions": "write", "can_approve_pull_request_reviews": true])
            } catch {
                notes.append("Settings › Actions › General: „Allow GitHub Actions to create and approve pull requests“ manuell aktivieren")
            }
        }
        if runAfter, !(await dispatch(f)) { notes.append("Testlauf konnte nicht gestartet werden") }
        add(.ok, "\(f.name): eingerichtet (Modus \(mode.rawValue))")
        notes.forEach { add(.warn, "\(f.name): \($0)") }
    }

    func adaptAll() async {
        let ids = Set(forks.filter(\.needsAdapt).map(\.id))
        guard !ids.isEmpty else { add(.info, "Nichts anzupassen."); return }
        await install(ids, mode: .auto, runAfter: false)
    }

    func runNow(_ ids: Set<String>) async {
        for f in forks where ids.contains(f.id) && f.hasAutoSync {
            busy.insert(f.id)
            let ok = await dispatch(f)
            add(ok ? .ok : .fail, "\(f.name): " + (ok ? "Sync gestartet" : "Start fehlgeschlagen"))
            busy.remove(f.id)
        }
    }

    func remove(_ ids: Set<String>) async {
        for f in forks where ids.contains(f.id) {
            guard let sha = f.workflowSha else { continue }
            busy.insert(f.id)
            do {
                try await GH.api("repos/\(f.full)/contents/\(WorkflowTemplate.wfPath)", method: "DELETE",
                                 body: ["message": "Remove upstream sync workflow (forksync)", "sha": sha])
                add(.ok, "\(f.name): Auto-Sync entfernt")
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
