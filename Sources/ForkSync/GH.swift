import Foundation

struct GHError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    var firstLine: String { message.split(separator: "\n").first.map(String.init) ?? message }
}

/// Zugriff auf GitHub: bevorzugt über den eigenen App-Login (Auth), sonst über die vorhandene `gh`-Anmeldung.
enum GH {
    static let path: String? = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    static func run(_ args: [String], stdin: Data? = nil) async throws -> Data {
        guard let path else {
            throw GHError(message: tr("GitHub CLI (gh) nicht gefunden. Installation: brew install gh", "GitHub CLI (gh) not found. Install with: brew install gh"))
        }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                env["GH_PROMPT_DISABLED"] = "1"
                p.environment = env
                let out = Pipe(), err = Pipe(), inp = Pipe()
                p.standardOutput = out
                p.standardError = err
                if stdin != nil { p.standardInput = inp }
                do { try p.run() } catch {
                    cont.resume(throwing: GHError(message: error.localizedDescription)); return
                }
                if let stdin {
                    inp.fileHandleForWriting.write(stdin)
                    try? inp.fileHandleForWriting.close()
                }
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
                if p.terminationStatus != 0 {
                    let text = String(data: box.value.isEmpty ? outData : box.value, encoding: .utf8) ?? "Fehler"
                    cont.resume(throwing: GHError(message: text.trimmingCharacters(in: .whitespacesAndNewlines)))
                } else {
                    cont.resume(returning: outData)
                }
            }
        }
    }

    @discardableResult
    static func api(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                    paginate: Bool = false) async throws -> Any? {
        if let token = Auth.token {
            return try await Auth.request(path, method: method, body: body, paginate: paginate, token: token)
        }
        var args = ["api", path, "-X", method]
        // Je Element eine Zeile; `--slurp` gibt es erst in neueren gh-Versionen.
        if paginate { args += ["--paginate", "--jq", ".[]"] }
        var input: Data?
        if let body {
            args += ["--input", "-"]
            input = try JSONSerialization.data(withJSONObject: body)
        }
        let data = try await run(args, stdin: input)
        if paginate {
            return try data.split(separator: 0x0A).filter { !$0.allSatisfy { $0 == 0x20 || $0 == 0x0D } }
                .map { try JSONSerialization.jsonObject(with: Data($0), options: [.fragmentsAllowed]) }
        }
        guard !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A }) else { return nil }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func authStatus() async -> (ok: Bool, user: String?, hasWorkflowScope: Bool, detail: String, authError: Bool) {
        if let token = Auth.token {
            let s = await Auth.status(token: token)
            return (s.ok, s.user, s.scopes.contains("workflow"), s.detail, s.authError)
        }
        do {
            let data = try await run(["auth", "status"])
            let text = String(data: data, encoding: .utf8) ?? ""
            return parse(text)
        } catch let e as GHError {
            return (false, nil, false, e.message, true)
        } catch {
            return (false, nil, false, error.localizedDescription, true)
        }
    }

    private static func parse(_ text: String) -> (Bool, String?, Bool, String, Bool) {
        var user: String?
        if let r = text.range(of: #"account (\S+)"#, options: .regularExpression) {
            user = String(text[r]).replacingOccurrences(of: "account ", with: "")
        }
        return (true, user, text.contains("workflow"), text, false)
    }
}

final class DataBox: @unchecked Sendable { var value = Data() }
