import SwiftUI
import ServiceManagement

/// Dünner Wrapper um das lokale `git` (kein Shell, Token nur per Umgebungsvariable, nie in Argumenten).
enum Git {
    static let path: String? = [
        "/opt/homebrew/bin/git", "/usr/local/bin/git",
        "/Library/Developer/CommandLineTools/usr/bin/git",
        "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    struct Output: Sendable {
        let code: Int32
        let out: String
        let err: String
        var ok: Bool { code == 0 }
        var trimmed: String { out.trimmingCharacters(in: .whitespacesAndNewlines) }
        var message: String {
            let t = (err.isEmpty ? out : err).trimmingCharacters(in: .whitespacesAndNewlines)
            return t.split(separator: "\n").last.map(String.init) ?? t
        }
    }

    static func run(_ args: [String], in dir: String? = nil, token: String? = nil, timeout: TimeInterval = 300) async -> Output {
        guard let path else {
            return Output(code: 127, out: "", err: tr("git nicht gefunden. Installation: xcode-select --install", "git not found. Install with: xcode-select --install"))
        }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                if let dir { p.currentDirectoryURL = URL(fileURLWithPath: dir) }
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                env["GIT_TERMINAL_PROMPT"] = "0"
                env["GIT_ASKPASS"] = ""
                env["LC_ALL"] = "C"
                if let token {
                    let basic = Data("x-access-token:\(token)".utf8).base64EncodedString()
                    env["GIT_CONFIG_COUNT"] = "1"
                    env["GIT_CONFIG_KEY_0"] = "http.https://github.com/.extraheader"
                    env["GIT_CONFIG_VALUE_0"] = "AUTHORIZATION: basic \(basic)"
                }
                p.environment = env
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(returning: Output(code: 126, out: "", err: error.localizedDescription)); return
                }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let box = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    box.value = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                killer.cancel()
                cont.resume(returning: Output(code: p.terminationStatus,
                                              out: String(data: outData, encoding: .utf8) ?? "",
                                              err: String(data: box.value, encoding: .utf8) ?? ""))
            }
        }
    }

    /// Token für git über HTTPS: eigener App-Login, sonst die `gh`-Anmeldung.
    static func token() async -> String? {
        if let t = Auth.token { return t }
        guard let data = try? await GH.run(["auth", "token"]),
              let t = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

/// Zustand eines lokalen Klons gegenüber GitHub.
struct LocalRepo: Identifiable, Hashable, Sendable {
    enum State: Hashable, Sendable { case notCloned, current, behind, ahead, diverged, noUpstream, foreign, error }
    var id: String { item.full }
    let item: RepoItem
    let dir: String
    var state: State = .notCloned
    var branch = ""
    var ahead = 0     // lokale Commits, die GitHub nicht hat
    var behind = 0    // Commits auf GitHub, die lokal fehlen
    var dirty = false // nicht committete Änderungen
    var detail = ""

    var statusText: String {
        switch state {
        case .notCloned: tr("Nicht geklont", "Not cloned")
        case .current: tr("Aktuell", "Up to date")
        case .behind: tr("\(behind) hinterher", "\(behind) behind")
        case .ahead: tr("\(ahead) lokal voraus", "\(ahead) ahead locally")
        case .diverged: tr("Abweichend: \(ahead) lokal / \(behind) neu", "Diverged: \(ahead) local / \(behind) new")
        case .noUpstream: tr("Kein Upstream-Branch", "No upstream branch")
        case .foreign: tr("Ordner belegt", "Folder in use")
        case .error: tr("Fehler", "Error")
        }
    }

    var color: Color {
        switch state {
        case .notCloned: .gray
        case .current: .green
        case .behind: .blue
        case .ahead: .purple
        case .diverged, .noUpstream: .orange
        case .foreign, .error: .red
        }
    }

    var exists: Bool { state != .notCloned && state != .foreign }
}

enum LocalPrefs {
    /// Im Testmodus (FORKSYNC_LOCALTEST) werden die echten Einstellungen nicht überschrieben.
    static let testing = ProcessInfo.processInfo.environment["FORKSYNC_LOCALTEST"] != nil
    private static let d = UserDefaults.standard
    static var root: String {
        get { d.string(forKey: "forksync.local.root") ?? (NSHomeDirectory() + "/Developer/GitHub") }
        set { if !testing { d.set(newValue, forKey: "forksync.local.root") } }
    }
    static var enabled: Set<String> {
        get { Set(d.stringArray(forKey: "forksync.local.enabled") ?? []) }
        set { if !testing { d.set(Array(newValue).sorted(), forKey: "forksync.local.enabled") } }
    }
    static var auto: Bool {
        get { d.bool(forKey: "forksync.local.auto") }
        set { if !testing { d.set(newValue, forKey: "forksync.local.auto") } }
    }
    static var interval: Int {
        get { let v = d.integer(forKey: "forksync.local.interval"); return v > 0 ? v : 60 }
        set { if !testing { d.set(newValue, forKey: "forksync.local.interval") } }
    }
}

enum LocalGit {
    /// Prüft einen Klon: holt den GitHub-Stand (nur `fetch`, ändert keine Arbeitsdateien) und vergleicht.
    static func inspect(_ item: RepoItem, root: String, token: String?, fetch: Bool = true) async -> LocalRepo {
        let dir = root + "/" + item.name
        var r = LocalRepo(item: item, dir: dir)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return r }
        guard FileManager.default.fileExists(atPath: dir + "/.git") else {
            r.state = .foreign
            r.detail = tr("Der Ordner existiert, ist aber kein Git-Repo.", "The folder exists but is not a git repo.")
            return r
        }
        let remote = await Git.run(["remote", "get-url", "origin"], in: dir)
        var url = remote.trimmed.lowercased()
        if url.hasSuffix(".git") { url.removeLast(4) }
        let want = item.full.lowercased()
        guard remote.ok, url.hasSuffix("github.com/" + want) || url.hasSuffix("github.com:" + want) else {
            r.state = .foreign
            r.detail = tr("Der Ordner gehört zu einem anderen Repo (\(remote.trimmed)).", "The folder belongs to a different repo (\(remote.trimmed)).")
            return r
        }
        if fetch {
            let f = await Git.run(["fetch", "--quiet", "--prune", "origin"], in: dir, token: token)
            if !f.ok { r.state = .error; r.detail = f.message; return r }
        }
        r.dirty = !(await Git.run(["status", "--porcelain"], in: dir)).trimmed.isEmpty
        r.branch = (await Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir)).trimmed
        let c = await Git.run(["rev-list", "--left-right", "--count", "HEAD...@{u}"], in: dir)
        let nums = c.trimmed.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard c.ok, nums.count == 2 else {
            r.state = .noUpstream
            r.detail = r.branch == "HEAD" ? tr("Detached HEAD.", "Detached HEAD.") : c.message
            return r
        }
        r.ahead = nums[0]; r.behind = nums[1]
        r.state = (r.ahead, r.behind) == (0, 0) ? .current : r.ahead == 0 ? .behind : r.behind == 0 ? .ahead : .diverged
        return r
    }
}

func runLimited<T: Sendable, R: Sendable>(_ items: [T], limit: Int, _ body: @escaping @Sendable (T) async -> R) async -> [R] {
    await withTaskGroup(of: R.self) { group in
        var results: [R] = []
        var it = items.makeIterator()
        var running = 0
        while running < limit, let next = it.next() { group.addTask { await body(next) }; running += 1 }
        while let r = await group.next() {
            results.append(r)
            if let next = it.next() { group.addTask { await body(next) } }
        }
        return results
    }
}

extension Store {
    var localItems: [RepoItem] { repos.filter { localEnabled.contains($0.full) } }

    func setLocalEnabled(_ full: String, _ on: Bool) {
        if on { localEnabled.insert(full) } else { localEnabled.remove(full) }
    }

    func chooseLocalRoot() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = tr("Auswählen", "Choose")
        p.message = tr("Ordner, in den die Repos geklont werden (je Repo ein Unterordner)", "Folder the repos are cloned into (one subfolder per repo)")
        p.directoryURL = URL(fileURLWithPath: localRoot).deletingLastPathComponent()
        if p.runModal() == .OK, let u = p.url { localRoot = u.path; local = [:]; Task { await reloadLocal() } }
    }

    /// Alles neu einlesen: Repo-Liste von GitHub und lokaler Stand aller ausgewählten Repos.
    func reloadLocal() async {
        await loadRepos()
        await checkLocal()
    }

    /// Nur vergleichen (fetch + Status), nichts verändern.
    func checkLocal() async {
        guard !localBusy else { return }
        if repos.isEmpty { await loadRepos() }
        localBusy = true
        defer { localBusy = false }
        let token = await Git.token()
        let root = localRoot
        let results = await runLimited(localItems, limit: 4) { await LocalGit.inspect($0, root: root, token: token) }
        for r in results { local[r.id] = r }
    }

    /// Fehlende Repos klonen, hinterherhinkende per Fast-Forward aktualisieren. Lokale Änderungen und
    /// abweichende Historien bleiben unberührt; es wird nie gepusht.
    func syncLocal(quiet: Bool = false) async {
        guard !localBusy else { return }
        if repos.isEmpty { await loadRepos() }
        let items = localItems
        guard !items.isEmpty else { return }
        localBusy = true
        defer { localBusy = false; localLast = Date() }
        let token = await Git.token()
        let root = localRoot
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let results = await runLimited(items, limit: 3) { item -> (LocalRepo, [(LogLine.Kind, String)]) in
            var r = await LocalGit.inspect(item, root: root, token: token)
            var notes: [(LogLine.Kind, String)] = []
            switch r.state {
            case .notCloned:
                let c = await Git.run(["clone", "--quiet", "https://github.com/\(item.full).git", r.dir], in: root, token: token)
                if c.ok {
                    notes.append((.ok, tr("\(item.name): geklont", "\(item.name): cloned")))
                    r = await LocalGit.inspect(item, root: root, token: token, fetch: false)
                } else {
                    r.state = .error; r.detail = c.message
                    notes.append((.fail, tr("\(item.name): Klonen fehlgeschlagen: \(c.message)", "\(item.name): clone failed: \(c.message)")))
                }
            case .behind where r.dirty:
                notes.append((.warn, tr("\(item.name): \(r.behind) neu auf GitHub, aber lokale Änderungen – übersprungen", "\(item.name): \(r.behind) new on GitHub but local changes – skipped")))
            case .behind:
                let m = await Git.run(["merge", "--ff-only", "--quiet", "@{u}"], in: r.dir)
                if m.ok {
                    notes.append((.ok, tr("\(item.name): \(r.behind) Commit(s) geholt", "\(item.name): pulled \(r.behind) commit(s)")))
                    r = await LocalGit.inspect(item, root: root, token: token, fetch: false)
                } else {
                    r.state = .error; r.detail = m.message
                    notes.append((.fail, "\(item.name): \(m.message)"))
                }
            case .diverged:
                notes.append((.warn, tr("\(item.name): Historien weichen ab (\(r.ahead) lokal / \(r.behind) neu) – bitte manuell lösen", "\(item.name): histories diverged (\(r.ahead) local / \(r.behind) new) – resolve manually")))
            case .foreign, .error:
                notes.append((.warn, "\(item.name): \(r.detail)"))
            default: break
            }
            return (r, notes)
        }
        var changed = 0, problems = 0
        for (r, notes) in results {
            local[r.id] = r
            for (k, t) in notes { add(k, t); if k == .ok { changed += 1 } else { problems += 1 } }
        }
        if !quiet || changed > 0 || problems > 0 {
            add(problems > 0 ? .warn : .ok, tr("Lokal geprüft: \(items.count) Repos, \(changed) aktualisiert, \(problems) Hinweise", "Local check: \(items.count) repos, \(changed) updated, \(problems) notices"))
        }
    }

    /// Wiederkehrender Abgleich, solange ForkSync läuft.
    func startLocalAuto() {
        localTask?.cancel()
        localTask = nil
        guard localAuto else { return }
        localTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.syncLocal(quiet: true)
                try? await Task.sleep(for: .seconds(Double(self.localInterval) * 60))
            }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            add(.fail, tr("Start bei Anmeldung: ", "Launch at login: ") + error.localizedDescription)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
