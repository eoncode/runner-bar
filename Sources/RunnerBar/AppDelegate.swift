import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.title = "⚫"
            button.action = #selector(showMenu)
            button.target = self
        }

        RunnerStore.shared.onChange = { [weak self] in
            guard let self else { return }
            self.statusItem?.button?.title = RunnerStore.shared.aggregateStatus.dot
            self.statusItem?.menu = self.buildMenu()
        }

        if githubToken() != nil && !ScopeStore.shared.isEmpty {
            RunnerStore.shared.start()
        }

        statusItem?.menu = buildMenu()
    }

    @objc private func showMenu() {
        statusItem?.button?.performClick(nil)
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()

        guard githubToken() != nil else {
            menu.addItem(NSMenuItem(title: "Run `gh auth login` in Terminal", action: nil, keyEquivalent: ""))
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            return menu
        }

        if ScopeStore.shared.isEmpty {
            menu.addItem(NSMenuItem(title: "Enter owner/repo or org:", action: nil, keyEquivalent: ""))
            let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
            textField.placeholderString = "e.g. eonist/runner-bar"
            textField.target = self
            textField.action = #selector(scopeSubmitted(_:))
            let textItem = NSMenuItem()
            textItem.view = textField
            menu.addItem(textItem)
        } else {
            menu.addItem(NSMenuItem(title: "RunnerBar v0.1", action: nil, keyEquivalent: ""))
            for scope in ScopeStore.shared.scopes {
                menu.addItem(NSMenuItem(title: "• \(scope)", action: nil, keyEquivalent: ""))
            }
            menu.addItem(.separator())
            let refresh = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r")
            refresh.target = self
            menu.addItem(refresh)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func scopeSubmitted(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        ScopeStore.shared.add(value)
        RunnerStore.shared.start()
        statusItem?.menu = buildMenu()
    }

    @objc private func refresh() {
        RunnerStore.shared.fetch()
    }
}
