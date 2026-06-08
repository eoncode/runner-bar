how to run the app with streaming log in terminal:

Just pipe the whole thing into `tee` at the end — but since `open` detaches the app from the shell, you need to launch the binary directly instead:

```bash
git fetch origin && \
git checkout fix/issue-294-popover-redesign-design-branch-3 && \
git pull origin fix/issue-294-popover-redesign-design-branch-3 && \
bash build.sh && \
pkill RunnerBar 2>/dev/null; sleep 1 && \
./dist/RunnerBar.app/Contents/MacOS/RunnerBar 2>&1 | tee /tmp/runnerbar_log.txt
```

The key difference: `open dist/RunnerBar.app` launches the app and immediately returns — the process is detached from the terminal so you get no output. `./dist/RunnerBar.app/Contents/MacOS/RunnerBar` runs the binary directly in the foreground, so all its stdout/stderr flows through `tee` live.

**Ctrl+C** will kill it when you're done. The full log stays in `/tmp/runnerbar_log.txt` after.


The `tee` command — it splits stdout to both the terminal screen AND a file simultaneously.  When I ran:[1]

```bash
./dist/RunnerBar.app/Contents/MacOS/RunnerBar 2>&1 | tee /tmp/runnerbar_log.txt
```

- `2>&1` merges stderr into stdout (so you get everything)
- `| tee /tmp/runnerbar_log.txt` writes it to the file **and** prints it live to the terminal at the same time

So the Terminal window shows a live stream, and `/tmp/runnerbar_log.txt` accumulates the full history that I can read separately with `cat`.

The app itself is also doing the heavy lifting — it's already printing structured log lines like `[RunnerBar 2026-05-12T...] GitHub:43 — ghAPI › ...` to stdout.  That's coming from whatever `OSLog` or `print`-based logging is already in the RunnerBar source. `tee` just makes it visible in two places at once.[2]

Sources

## Newer approche:

```bash
cd ~/runner-bar-3 && \
pkill -x RunnerBar 2>/dev/null || true && \
git fetch origin && \
git checkout feature/1202-local-runners-view && \
git pull origin feature/1202-local-runners-view && \
bash build.sh && \
log stream --level debug --predicate 'subsystem == "com.eoncode.runner-bar"'

```

## For main:

```main
git fetch origin && \
git checkout main && \
git pull origin main && \
bash build.sh && \
pkill RunnerBar 2>/dev/null; sleep 1; \
log stream --level debug --predicate 'subsystem == "com.eoncode.runner-bar"' & LOG_PID=$!; sleep 1; \
./dist/RunnerBar.app/Contents/MacOS/RunnerBar; kill $LOG_PID
```

# More robust fresh build launch 

```
 % cd /Users/eon/runner-bar-3 && \
  pkill -x RunnerBar 2>/dev/null || true && \
  sleep 1 && \
  rm -rf dist/ && \
  echo "✓ old dist/ deleted" && \
  touch Sources/RunnerBar/App/AppDelegate.swift && \
  bash build.sh && \
  sleep 1 && \
  NEW_PID=$(pgrep -x RunnerBar) && \
  echo "✓ New PID: $NEW_PID" && \
  lsof -p $NEW_PID | grep "RunnerBar$" | head -3 && \
  log stream --level debug \
    --predicate 'subsystem == "com.eoncode.runner-bar"' 2>/dev/null \
  | grep -v -E "PollResult|RunnerStore|FailureHook|RunnerViewModel|RunnerPollState|Enricher|LocalRunnerStore"
```
