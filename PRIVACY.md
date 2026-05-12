# Privacy & Data Storage

RunnerBar is a macOS status-bar app that monitors GitHub Actions on your own repositories. This document explains exactly what data the app stores, where, and how.

---

## Authentication & Credentials

RunnerBar **never stores your GitHub token itself**. Instead it delegates credential management entirely to the [GitHub CLI (`gh`)](https://cli.github.com).

### How it works

1. You authenticate once with `gh auth login` in your terminal.
2. The `gh` CLI stores your Personal Access Token (PAT) or OAuth token in the **macOS Keychain** — the same secure, encrypted store used by Safari, Mail, and other system apps.
3. Each time RunnerBar needs to make a GitHub API call it runs `gh auth token` to retrieve the token **in memory only** for that request. The token is never written to disk by RunnerBar.

### Fallback sources (in priority order)

| Priority | Source | Notes |
|---|---|---|
| 1 | `gh auth token` (GitHub CLI) | Token lives in macOS Keychain — managed by `gh`, not RunnerBar |
| 2 | `GH_TOKEN` environment variable | Useful in scripted / CI contexts |
| 3 | `GITHUB_TOKEN` environment variable | Actions-style fallback |

RunnerBar will not start making API calls until at least one of these sources returns a non-empty token.

### What RunnerBar does NOT do

- ❌ Does not write tokens to `UserDefaults`, files, or any app-managed store
- ❌ Does not transmit credentials to any server other than `api.github.com`
- ❌ Does not log tokens in console output or crash reports

---

## Preferences & Settings

All user preferences are stored in **`UserDefaults`** (the standard macOS per-app preferences store located at `~/Library/Preferences/`). No preference data leaves your device.

| Setting | Key | Type | Default |
|---|---|---|---|
| Polling interval | `settings.pollingInterval` | Integer (10–300 s) | 30 |
| Show dimmed runners | `settings.showDimmedRunners` | Boolean | `true` |
| Notify on success | `notifications.notifyOnSuccess` | Boolean | `false` |
| Notify on failure | `notifications.notifyOnFailure` | Boolean | `false` |
| Watched scopes (repos/orgs) | `scopes` | String array | `[]` |
| Legal acceptance | `legal.*` | Boolean flags | `false` |

You can inspect or delete these values at any time:

```bash
# List all RunnerBar defaults
defaults read com.eoncode.RunnerBar

# Delete all RunnerBar defaults
defaults delete com.eoncode.RunnerBar
```

---

## Network Activity

RunnerBar makes HTTPS requests **only** to:

- `api.github.com` — GitHub REST API (runs, jobs, steps, runners)

No analytics, telemetry, crash reporting, or third-party network calls are made. All requests use the token obtained from `gh auth token` and are made over TLS.

---

## Local Data

RunnerBar holds all run/job/step data **in memory only**. Nothing is cached to disk between sessions. When you quit the app, all fetched data is discarded.

---

## macOS Permissions

| Permission | Why |
|---|---|---|---|
| **Notifications** | Optional — used to notify on job success/failure if enabled in Settings |
| **Outbound network** | Required — to call `api.github.com` |

RunnerBar does not request access to contacts, location, camera, microphone, Photos, or any other sensitive macOS permission category.

---

## Open Source

RunnerBar is open source. You can audit every network call, every persistence write, and every credential access in the source code:

- Credential access: [`Sources/RunnerBar/Auth.swift`](Sources/RunnerBar/Auth.swift)
- Preferences: [`Sources/RunnerBar/SettingsStore.swift`](Sources/RunnerBar/SettingsStore.swift), [`Sources/RunnerBar/NotificationPrefsStore.swift`](Sources/RunnerBar/NotificationPrefsStore.swift)
- Watched scopes: [`Sources/RunnerBar/ScopeStore.swift`](Sources/RunnerBar/ScopeStore.swift)
- GitHub API calls: [`Sources/RunnerBar/GitHub.swift`](Sources/RunnerBar/GitHub.swift)
