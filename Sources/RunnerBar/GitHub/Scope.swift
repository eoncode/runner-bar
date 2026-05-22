import Foundation

// MARK: - Scope

enum Scope {
    case repo(owner: String, name: String)
    case org(String)

    /// Parses a raw scope string (e.g. "owner/repo" or "orgname") into a typed `Scope`.
    /// Returns `nil` for empty or malformed input.
    static func parse(_ string: String) -> Scope? {
        let parts = string.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
            return .repo(owner: parts[0], name: parts[1])
        }
        if parts.count == 1, !parts[0].isEmpty {
            return .org(parts[0])
        }
        return nil
    }

    /// The GitHub REST API path prefix for this scope.
    /// e.g. "repos/owner/repo" or "orgs/orgname"
    var apiPrefix: String {
        switch self {
        case .repo(let owner, let name): return "repos/\(owner)/\(name)"
        case .org(let org):              return "orgs/\(org)"
        }
    }
}
