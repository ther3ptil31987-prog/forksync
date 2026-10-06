import Foundation
import Security

/// Eigener GitHub-Login per Device-Flow (kein `gh` nötig). Das Token liegt im macOS-Schlüsselbund.
enum Auth {
    /// Öffentliche Client-ID der ForkSync-OAuth-App (kein Geheimnis; der Device-Flow braucht kein Client-Secret).
    static let clientID: String = ProcessInfo.processInfo.environment["FORKSYNC_CLIENT_ID"]
        ?? (Bundle.main.object(forInfoDictionaryKey: "GitHubClientID") as? String) ?? ""
    static let scopes = "repo workflow"
    private static let service = "de.steffen.forksync"
    private static let account = "github-token"

    // MARK: Schlüsselbund

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: String?
    nonisolated(unsafe) private static var loaded = false

    /// Wird nur einmal aus dem Schlüsselbund gelesen, damit macOS nicht bei jedem API-Aufruf nachfragt.
    static var token: String? {
        lock.lock(); defer { lock.unlock() }
        if !loaded { cache = readKeychain(); loaded = true }
        return cache
    }

    private static func readKeychain() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Liefert `false`, wenn der Schlüsselbund ablehnt; das Token gilt dann nur für diese Sitzung.
    @discardableResult
    static func save(_ token: String) -> Bool {
        delete()
        lock.lock(); cache = token; loaded = true; lock.unlock()
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecValueData as String: Data(token.utf8)]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        lock.lock(); cache = nil; loaded = true; lock.unlock()
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }

    // MARK: Device-Flow

    struct DeviceCode { let deviceCode: String; let userCode: String; let uri: String; let interval: Int; let expires: Int }

    private static func post(_ url: String, _ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func start() async throws -> DeviceCode {
        guard !clientID.isEmpty else { throw GHError(message: tr("Keine OAuth-Client-ID hinterlegt.", "No OAuth client ID configured.")) }
        let r = try await post("https://github.com/login/device/code", ["client_id": clientID, "scope": scopes])
        guard let dc = r["device_code"] as? String, let uc = r["user_code"] as? String,
              let uri = r["verification_uri"] as? String else {
            throw GHError(message: (r["error_description"] as? String) ?? tr("Anmeldung konnte nicht gestartet werden.", "Sign-in could not be started."))
        }
        return DeviceCode(deviceCode: dc, userCode: uc, uri: uri,
                          interval: r["interval"] as? Int ?? 5, expires: r["expires_in"] as? Int ?? 900)
    }

    /// Wartet, bis der Nutzer im Browser bestätigt hat, und speichert das Token.
    /// Rückgabe: ob es dauerhaft im Schlüsselbund liegt.
    @discardableResult
    static func finish(_ dc: DeviceCode) async throws -> Bool {
        var interval = dc.interval
        let deadline = Date().addingTimeInterval(Double(dc.expires))
        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            try Task.checkCancellation()
            let r = try await post("https://github.com/login/oauth/access_token", [
                "client_id": clientID, "device_code": dc.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
            if let t = r["access_token"] as? String { return save(t) }
            switch r["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "access_denied": throw GHError(message: tr("Anmeldung abgelehnt.", "Sign-in was denied."))
            case "expired_token": throw GHError(message: tr("Code abgelaufen, bitte erneut versuchen.", "Code expired, please try again."))
            default: throw GHError(message: (r["error_description"] as? String) ?? tr("Anmeldung fehlgeschlagen.", "Sign-in failed."))
            }
        }
        throw GHError(message: tr("Code abgelaufen, bitte erneut versuchen.", "Code expired, please try again."))
    }

    // MARK: REST

    static func request(_ path: String, method: String, body: [String: Any]?, paginate: Bool, token: String) async throws -> Any? {
        var url: URL? = URL(string: path.hasPrefix("http") ? path : "https://api.github.com/" + path)
        var pages: [Any] = []
        while let u = url {
            var req = URLRequest(url: u)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            req.setValue("ForkSync", forHTTPHeaderField: "User-Agent")
            if let body {
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as! HTTPURLResponse
            let obj = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            if http.statusCode >= 400 {
                if http.statusCode == 401 { delete() }
                var msg = ((obj as? [String: Any])?["message"] as? String) ?? "HTTP \(http.statusCode)"
                if let errs = (obj as? [String: Any])?["errors"] { msg += " \(errs)" }
                throw GHError(message: msg)
            }
            guard paginate else { return obj }
            pages.append(contentsOf: (obj as? [Any]) ?? (obj.map { [$0] } ?? []))
            url = nextLink(http.value(forHTTPHeaderField: "Link"))
        }
        return pages
    }

    private static func nextLink(_ header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") where part.contains("rel=\"next\"") {
            if let a = part.firstIndex(of: "<"), let b = part.firstIndex(of: ">") {
                return URL(string: String(part[part.index(after: a)..<b]))
            }
        }
        return nil
    }

    static func status(token: String) async -> (ok: Bool, user: String?, scopes: String, detail: String, authError: Bool) {
        var req = URLRequest(url: URL(string: "https://api.github.com/user")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("ForkSync", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse else {
            return (false, nil, "", tr("Keine Verbindung zu GitHub.", "No connection to GitHub."), false)
        }
        if http.statusCode == 401 { delete(); return (false, nil, "", tr("Anmeldung abgelaufen, bitte neu anmelden.", "Session expired, please sign in again."), true) }
        let login = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["login"] as? String
        let msg = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String).map { "\($0) (HTTP \(http.statusCode))" }
        return (http.statusCode < 400, login, http.value(forHTTPHeaderField: "X-OAuth-Scopes") ?? "", msg ?? "HTTP \(http.statusCode)", false)
    }
}
