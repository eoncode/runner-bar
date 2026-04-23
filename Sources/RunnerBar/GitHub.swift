import Foundation

func fetchRunners(for scope: String) -> [Runner] {
    let path: String
    if scope.contains("/") {
        path = "/repos/\(scope)/actions/runners"
    } else {
        path = "/orgs/\(scope)/actions/runners"
    }

    let json = shell("/opt/homebrew/bin/gh api \(path)")

    guard
        let data = json.data(using: .utf8),
        let response = try? JSONDecoder().decode(RunnersResponse.self, from: data)
    else {
        return []
    }

    return response.runners
}

private struct RunnersResponse: Codable {
    let runners: [Runner]
}
