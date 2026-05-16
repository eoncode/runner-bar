// swiftlint:disable all
import Foundation

func ghToken() -> String {
    if let env = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !env.isEmpty { return env }
    if let ud = UserDefaults.standard.string(forKey: "githubToken"), !ud.isEmpty { return ud }
    return ""
}
