// swiftlint:disable all
import Foundation

final class RunnerStore {
    var onStateChange: ((RunnerStoreState) -> Void)?
    private(set) var state: RunnerStoreState = RunnerStoreState()
    private var timer: Timer?
    private var iso = ISO8601DateFormatter()

    init() { startPolling() }

    func applySettings(_ settings: SettingsStore) {
        state.settings = settings
        state.actions  = []
        poll()
    }

    func reRunWorkflow(group: ActionGroup) async throws {
        let token = state.settings.githubToken
        let scope = state.settings.githubOrg
        guard !token.isEmpty, !scope.isEmpty else { return }
        for run in group.runs {
            let path = "repos/\(scope)/actions/runs/\(run.id)/rerun"
            _ = ghAPI(path, method: "POST")
        }
    }

    func cancelWorkflow(group: ActionGroup) async throws {
        let scope = state.settings.githubOrg
        for run in group.runs {
            _ = ghAPI("repos/\(scope)/actions/runs/\(run.id)/cancel", method: "POST")
        }
    }

    private func startPolling() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        let settings = state.settings
        guard !settings.githubToken.isEmpty, !settings.githubOrg.isEmpty else { return }
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            let cache = Dictionary(uniqueKeysWithValues: self.state.actions.map { ($0.headSha, $0) })
            let groups = fetchActionGroups(for: settings.githubOrg, cache: cache)
            DispatchQueue.main.async {
                self.state.actions = groups
                self.onStateChange?(self.state)
            }
        }
    }
}
