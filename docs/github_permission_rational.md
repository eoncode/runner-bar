# GitHub OAuth Permission Rationale

RunnerBar requests two OAuth scopes when you sign in with GitHub: `repo` and `read:org`. This document explains exactly why each is needed.

---

## `repo`

The `repo` scope grants read access to repository data and Actions. RunnerBar requires it for three core features:

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

The `read:org` scope grants read-only access to organisation membership and org-level Actions data. RunnerBar uses it to support organisation-scoped runner monitoring:

- `GET /orgs/{org}/actions/runners` — lists self-hosted runners for an org
- `GET /orgs/{org}/actions/runs` — fetches active workflow runs across an org
- `GET /user/orgs` — discovers which organisations the authenticated user belongs to, used to populate the scope picker

Without `read:org`, only `owner/repo`-scoped monitoring works. Users who add an org slug (e.g. `mycompany`) as a scope instead of a single repo would see no data.

---

## What RunnerBar does NOT do

- Does not read, write, or access repository source code or file contents beyond what is listed above
- Does not write to repositories, open issues, or create pull requests on your behalf
- Does not access private user data beyond organisation membership
- Does not store your token anywhere other than the macOS Keychain on your local machine
- Does not transmit your token to any server other than `api.github.com`
