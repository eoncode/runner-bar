// swiftlint:disable all
import Combine
import Foundation

final class ScopeStore: ObservableObject {
    @Published var scopes: [String] {
        didSet { save() }
    }
    @Published var selectedScope: String {
        didSet { UserDefaults.standard.set(selectedScope, forKey: Keys.selected) }
    }
    init() {
        let saved = UserDefaults.standard.stringArray(forKey: Keys.scopes) ?? []
        scopes = saved
        selectedScope = UserDefaults.standard.string(forKey: Keys.selected) ?? saved.first ?? ""
    }
    func add(_ scope: String) {
        let trimmed = scope.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !scopes.contains(trimmed) else { return }
        scopes.append(trimmed)
        if scopes.count == 1 { selectedScope = trimmed }
    }
    func remove(_ scope: String) {
        scopes.removeAll { $0 == scope }
        if selectedScope == scope { selectedScope = scopes.first ?? "" }
    }
    private func save() {
        UserDefaults.standard.set(scopes, forKey: Keys.scopes)
    }
    private enum Keys {
        static let scopes   = "scopeStore.scopes"
        static let selected = "scopeStore.selectedScope"
    }
}
