# GitHub OAuth Permission Rationale

RunBot requests five OAuth scopes when you sign in with GitHub: `repo`, `read:org`, `admin:org`, `manage_runners:org`, and `workflow`. This document explains exactly why each is needed.

---

## `repo`

The `repo` scope grants read access to repository data and Actions. RunBot requires it for three core features:

### Job and run log viewing
Fetching step logs and full run logs uses the following GitHub API endpoints:

- `GET /repos/{owner}/{repo}/actions/jobs/{job_id}/logs`
- `GET /repos/{owner}/{repo}/actions/runs/{run_id}/logs`

Both endpoints require the `repo` scope. Without it, the GitHub API returns 403 and no log content can be displayed.

### Runner registration
Adding a new self-hosted runner requires generating a short-lived registration token via:

- `POST /repos/{owner}/{repo}/actions/runners/registration-token`

This endpoint also requires `repo` scope.

### Workflow run and job status
Polling for active, queued, and completed workflow runs uses:

- `GET /repos/{owner}/{repo}/actions/runs`
- `GET /repos/{owner}/{repo}/actions/runs/{run_id}/jobs`

These are the primary data source for everything shown in the menu bar popover.

---

## `read:org`

The `read:org` scope grants read-only access to organisation membership and org-level Actions data. RunBot uses it to support organisation-scoped runner monitoring for users who are **org members but not owners**:

- `GET /orgs/{org}/actions/runners` — lists self-hosted runners for an org
- `GET /orgs/{org}/actions/runs` — fetches active workflow runs across an org
- `GET /user/orgs` — discovers which organisations the authenticated user belongs to, used to populate the scope picker

Without `read:org`, only `owner/repo`-scoped monitoring works. Users who add an org slug (e.g. `mycompany`) as a scope instead of a single repo would see no data.

---

## `admin:org`

The `admin:org` scope is required to call the runners API on organisations where the authenticated user is an **owner**. For org owners, `read:org` alone is insufficient — `GET /orgs/{org}/actions/runners` returns 403 without `admin:org`. This is a GitHub API requirement for owner-level accounts, not a RunBot design choice.

---

## `manage_runners:org`

The `manage_runners:org` scope is a fine-grained runner management scope introduced by GitHub in 2023. It is requested alongside `admin:org` for forward-compatibility: GitHub is progressively migrating runner management APIs to require this explicit scope on fine-grained tokens. Requesting it now ensures RunBot continues to work without requiring users to re-authenticate as GitHub narrows the older broad scopes.

---

## `workflow`

The `workflow` scope is required to trigger write actions on workflow runs via the GitHub API. RunBot uses it for:

- `POST /repos/{owner}/{repo}/actions/runs/{run_id}/rerun` — Re-run a workflow run
- `POST /repos/{owner}/{repo}/actions/runs/{run_id}/rerun-failed-jobs` — Re-run only failed jobs
- `POST /repos/{owner}/{repo}/actions/runs/{run_id}/cancel` — Cancel a running workflow

Without `workflow`, these write actions fail silently with 403 even when `repo` is present. Read-only monitoring still works, but the Re-run and Cancel buttons do not.

---

## What RunBot does NOT do

- Does not make any API calls to read, write, or access repository source code or file contents (even though the `repo` scope technically permits this)
- Does not write to repositories, open issues, or create pull requests on your behalf
- Does not access private user data beyond organisation membership
- Does not store your token anywhere other than the macOS Keychain on your local machine
- Does not transmit your token to any server other than `api.github.com` and `github.com` (for the OAuth exchange)
