# Privacy & Data Storage

RunnerBar is a macOS status-bar app that monitors GitHub Actions on your own repositories. This document explains exactly what data the app stores, where, and how — verified directly from the source code.

---

## Authentication & Credentials

RunnerBar uses the **GitHub OAuth Authorization Code flow** to authenticate. You sign in once inside the app; no external CLI tool is required.

### How it works

1. Clicking **Sign In** opens GitHub's authorization page in your default browser (`OAuthService.signIn()`).
2. After you click **Authorize**, GitHub redirects back to `runnerbar://oauth/callback` with a short-lived code.
3. RunnerBar exchanges the code for an access token via a server-side POST to `github.com/login/oauth/access_token`.
4. The token is stored **exclusively in the macOS Keychain** using `Security.framework` with `kSecUseDataProtectionKeychain: true` and `kSecAttrAccessibleAfterFirstUnlock` — the same modern Data Protection Keychain used by Safari and iCloud.
5. The token is never written to `UserDefaults`, files, logs, or any other location.

> **CSRF protection:** A random `state` nonce is generated per sign-in and verified on callback — mismatches are rejected before the token exchange begins (`OAuthService.handleCallback()`).

### Token storage details (from `Keychain.swift`)

| Key | Value |
|---|---|
| `kSecAttrService` | `runner-bar` |
| `kSecAttrAccount` | `github-oauth-token` |
| `kSecAttrAccessible` | `kSecAttrAccessibleAfterFirstUnlock` |
| Storage | macOS Data Protection Keychain |

To remove the token at any time: **Settings → Sign Out**, or `security delete-generic-password -s runner-bar` in Terminal.

---

## GitHub OAuth Scopes

RunnerBar requests the following scopes at sign-in (from `OAuthService.swift`):

| Scope | Why it is needed |
|---|---|
| `repo` | Read workflow runs, jobs, steps, and logs for private repositories. Also required to generate runner registration tokens at repo level. |
| `read:org` | Discover which organisations the authenticated user belongs to, and list org-level workflow runs. |
| `admin:org` | Required to list and manage self-hosted runners on organisations where the user is an **owner**. Without this, `/orgs/{org}/actions/runners` returns 403 for owner-level accounts. |
| `manage_runners:org` | Fine-grained runner-management scope (introduced 2023). Requested alongside `admin:org` for forward-compatibility as GitHub migrates runner APIs to require it on fine-grained tokens. |
| `workflow` | Required to **Re-run**, **Re-run failed**, and **Cancel** workflow runs via the API. Read-only tokens silently fail these write actions. |

### Why not a fine-grained PAT?

Fine-grained tokens do not yet support all Actions and runner management endpoints RunnerBar depends on. Classic OAuth is currently the only option that covers the full feature set.

### What RunnerBar does NOT do with your token

- ❌ Does not make any API calls to read, write, or access repository source code or file contents (even though the `repo` scope technically permits this)
- ❌ Does not open issues, create pull requests, or write to repositories on your behalf
- ❌ Does not transmit your token to any server other than `api.github.com` and `github.com` (for the OAuth exchange)
- ❌ Does not log your token in console output, crash reports, or analytics

---

## Preferences & Settings

All user preferences are stored in **`UserDefaults.standard`** — the standard macOS per-app preferences store at `~/Library/Preferences/`. No preference data leaves your device.

### Global settings

| Setting | Type | Notes |
|---|---|---|
| Polling interval | Integer (seconds) | Global default; can be overridden per scope |
| Notify on success | Boolean | Global default; can be overridden per scope |
| Notify on failure | Boolean | Global default; can be overridden per scope |
| Watched scopes | String array | List of `owner/repo` or `org` slugs |

### Per-scope settings (keyed as `scope.<scope>.<field>`)

From `ScopePreferencesStore.swift`:

| Field | Key suffix | Type |
|---|---|---|
| Human-readable alias | `alias` | String |
| Polling interval override | `pollingInterval` | Integer |
| Notify on success override | `notifyOnSuccess` | Boolean |
| Notify on failure override | `notifyOnFailure` | Boolean |
| Failure hook enabled | `failureHookEnabled` | Boolean |
| Failure hook shell command | `failureHookCommand` | String |
| Local repo path | `localRepoPath` | String |
| Failure hook branch filter | `failureHookBranch` | String |

All per-scope keys are removed when a scope is deleted (`ScopePreferencesStore.cleanUp(scope:)`).

You can inspect or delete these values at any time:

```bash
# List all RunnerBar defaults
defaults read dev.eonist.runnerbar

# Delete all RunnerBar defaults
defaults delete dev.eonist.runnerbar
```

---

## Failure Hooks

When a workflow run fails, RunnerBar can optionally fire a **user-defined shell command** in Terminal (`FailureHookRunner.swift`). The following tokens are substituted before the command runs:

| Token | Substituted with |
|---|---|
| `$FAILURE_LOG` | The workflow job log text fetched from GitHub |
| `$LOCAL_PATH` | The local filesystem path you configured for this scope |
| `$BRANCH` | The branch name of the failed run |
| `$RUN_LINK` | The GitHub URL of the failed run |

The command, path, and branch filter are stored in `UserDefaults` as described above. **RunnerBar does not transmit failure logs anywhere** — they are fetched from `api.github.com` and passed directly to your local shell command.

---

## Network Activity

RunnerBar makes HTTPS requests **only** to:

- `api.github.com` — GitHub REST API (runs, jobs, steps, logs, runners)
- `github.com` — OAuth token exchange only (at sign-in)
- `*.amazonaws.com` — GitHub's job log endpoints (`/actions/jobs/{id}/logs`) return a 302 redirect to a pre-signed S3 URL. RunnerBar's `Authorization` token is **not** forwarded to S3; Apple's URLSession automatically strips the `Authorization` header before following cross-origin redirects (per RFC 7235). S3 authenticates purely via the pre-signed query parameters embedded in the redirect URL.

No analytics, telemetry, crash reporting, or third-party network calls are made. All API requests are made over TLS with your OAuth token in the `Authorization` header.

---

## In-Memory Data

All fetched run, job, step, and log data is held **in memory only**. Nothing is cached to disk between sessions. When you quit the app, all fetched data is discarded.

---

## macOS Permissions

| Permission | Why |
|---|---|
| **Notifications** | Optional — notifies on job success or failure when enabled in Settings |
| **Outbound network** | Required — to call `api.github.com` |
| **Launch at login** | Optional — registers a LoginItem via `ServiceManagement` when enabled |

RunnerBar does not request access to contacts, location, camera, microphone, Photos, or any other sensitive macOS permission category.

---

## Open Source

RunnerBar is open source. You can audit every network call, every persistence write, and every credential access in the source code:

- OAuth flow: [`Sources/RunnerBar/GitHub/OAuthService.swift`](../Sources/RunnerBar/GitHub/OAuthService.swift)
- Token storage: [`Sources/RunnerBar/GitHub/Keychain.swift`](../Sources/RunnerBar/GitHub/Keychain.swift)
- GitHub API calls: [`Sources/RunnerBar/GitHub/GitHubURLSessionTransport.swift`](../Sources/RunnerBar/GitHub/GitHubURLSessionTransport.swift)
- Per-scope preferences: [`Sources/RunnerBarCore/Scope/ScopePreferencesStore.swift`](../Sources/RunnerBarCore/Scope/ScopePreferencesStore.swift)
- Failure hooks: [`Sources/RunnerBar/Services/FailureHookRunner.swift`](../Sources/RunnerBar/Services/FailureHookRunner.swift)
