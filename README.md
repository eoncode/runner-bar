# RunnerBar

> Self-hosted GitHub Actions runners, at a glance in your macOS menu bar.

![screenshot.png](screenshot.png) 
 
---

## The problem

1. Status - Knowing if your selfhosted github runner is online, offline, busy.
2. Mananging - Removing them. Adding them? Pausing them? Which repo or org runners do you have installed.
3. Activity - Easily look through active or past runs, figure out what worked and what failed
---

## The solution:

1. Easily see which runners are offline, online, or buzy
2. Easily add / remove or pause your runners
3. Easily look through sessions, individual jobs and action logs.

## Features:
- Copy action logs to clipboard at every level, for quick resolvment in LLM's etc: action (all jobs), job (all steps), step (single step)
- Re-run or cancel action sessions / singular jobs
- Access action YML data and sha of jobs from the UI

## Install

```bash
curl -fsSL https://eonist.github.io/runner-bar/install.sh | bash
```
 
---

## Docs

- [DEVELOPMENT.md](DEVELOPMENT.md) — how to build and run locally
- [DEPLOYMENT.md](DEPLOYMENT.md) — how releases are built and deployed
- [AGENTS.md](AGENTS.md) — context for AI coding agents

---

## Quick deploy

1. Download and build. close current apps
2. Build and deploy
3. Test user-facing download

```bash
git pull && bash build.sh && pkill RunnerBar; sleep 1 && open dist/RunnerBar.app 2>&1
bash build.sh && bash deploy.sh
curl -fsSL https://eonist.github.io/runner-bar/install.sh | bash
```

**To test branches:**    
```
git fetch && git checkout feature/actions-section && git pull
bash build.sh && pkill RunnerBar; sleep 1 && open dist/RunnerBar.app 
```
