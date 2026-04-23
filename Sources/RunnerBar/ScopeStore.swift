import Foundation

final class ScopeStore {
    static let shared = ScopeStore()
    private let key = "scopes"

    var scopes: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    var isEmpty: Bool { scopes.isEmpty }

    func add(_ scope: String) {
        let trimmed = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !scopes.contains(trimmed) else { return }
        scopes.append(trimmed)
    }

    func remove(_ scope: String) {
        scopes.removeAll { $0 == scope }
    }
}
