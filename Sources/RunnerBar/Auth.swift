// swiftlint:disable all
import Foundation

func ghToken() -> String {
    if let env = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !env.isEmpty { return env }
    if let ud = UserDefaults.standard.string(forKey: "githubToken"), !ud.isEmpty { return ud }
    return ""
}

func ghAPI(_ path: String, method: String = "GET", body: Data? = nil) -> Data? {
    let token = ghToken()
    guard !token.isEmpty, let url = URL(string: "https://api.github.com/\(path)") else { return nil }
    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
    req.httpMethod = method
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    if let body {
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    var result: Data?
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, _, _ in result = data; sem.signal() }.resume()
    sem.wait()
    return result
}
