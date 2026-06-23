with open('Sources/RunnerBar/Views/Settings/SettingsView.swift', 'r') as f:
    content = f.read()

# 1. Insert oauthService + lifecycleService after localRunnerStore
old = '    var localRunnerStore: LocalRunnerStore = .shared\n'
new = old + '    /// OAuth service injected from `AppDelegate`.\n    /// Typed to protocol so tests can supply a stub without the live singleton.\n    var oauthService: any OAuthServiceProtocol\n    /// Runner lifecycle service injected from `AppDelegate` and forwarded into `LocalRunnersView`.\n    /// Typed to protocol so tests can supply a stub without spawning real `svc.sh` processes.\n    /// No default -- callers must supply the `AppDelegate`-owned instance explicitly.\n    var lifecycleService: any RunnerLifecycleServiceProtocol\n'
assert content.count(old) == 1
content = content.replace(old, new, 1)

# 2. Remove duplicate oauthService line + old MARK
old_block = '    // MARK: - Injected services\n    /// OAuth service used for sign-in / sign-out flows.\n    /// Defaults to the shared live instance; swap for a fake in tests.\n    let oauthService: OAuthService\n    /// App-wide preference store (notifications, update channel, etc.).\n    /// Injected as a concrete reference; `@Observable` types don\'t need `@State` wrapping.\n    let settings: AppPreferencesStore\n    /// Notification opt-in preferences per scope.\n    let notifications: NotificationPreferences\n'
new_block = '    // MARK: - Injected services\n    /// App-wide preference store (notifications, update channel, etc.).\n    /// Injected as a concrete reference; `@Observable` types don\'t need `@State` wrapping.\n    let settings: AppPreferencesStore\n    /// Notification opt-in preferences per scope.\n    let notifications: NotificationPreferences\n'
assert content.count(old_block) == 1
content = content.replace(old_block, new_block, 1)

# 3. Init signature: oauthService type + add lifecycleService param
old = '        oauthService: OAuthService = .shared,'
new = '        oauthService: any OAuthServiceProtocol = OAuthService.shared,'
assert content.count(old) == 1
content = content.replace(old, new, 1)

old = '        notifications: NotificationPreferences = .shared\n    ) {\n        self.onBack = onBack\n        self.store = store\n        self.localRunnerStore = localRunnerStore\n        self.oauthService = oauthService\n        self.settings = settings\n        self.notifications = notifications\n'
new = '        notifications: NotificationPreferences = .shared,\n        lifecycleService: any RunnerLifecycleServiceProtocol\n    ) {\n        self.onBack = onBack\n        self.store = store\n        self.localRunnerStore = localRunnerStore\n        self.oauthService = oauthService\n        self.settings = settings\n        self.notifications = notifications\n        self.lifecycleService = lifecycleService\n'
assert content.count(old) == 1
content = content.replace(old, new, 1)

# 4. Wire lifecycleService into LocalRunnersView call
old = '                    localRunnerStore: localRunnerStore\n                )\n            } else if showScopes {'
new = '                    localRunnerStore: localRunnerStore,\n                    lifecycleService: lifecycleService\n                )\n            } else if showScopes {'
assert content.count(old) == 1
content = content.replace(old, new, 1)

with open('Sources/RunnerBar/Views/Settings/SettingsView.swift', 'w') as f:
    f.write(content)

print('Done')
