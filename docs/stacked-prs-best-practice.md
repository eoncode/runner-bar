```

> Merge this stacked PR series into `main` from the bottom up. Do not do per‑PR merges that re‑introduce the same conflict at each layer. Follow exactly:
>
> 1. Identify the stack order, lowest (base) PR first.
> 2. Merge the lowest PR into `main`.
> 3. Rebase the next PR onto the updated `main` with `git rebase --onto main <old-base-sha> <branch>`, where `<old-base-sha>` is the commit the PR was originally branched from — NOT a plain `git rebase main` (that replays already‑merged commits and causes duplicate conflicts).
> 4. Resolve any conflict once, `git rebase --continue`, then `git push --force-with-lease`.
> 5. Re‑point that PR's base to `main` on GitHub, confirm CI passes, merge it.
> 6. Repeat steps 3–5 for each remaining PR up the stack.
> 7. If squash‑merge is used on `main`, after each squash always use `git rebase --onto main <old-base-sha> <branch>` so the squashed‑away commits don't reappear as conflicts.
> 8. If a rebase gets stuck, run `git rebase --abort` and report back — do not force a resolution.

```
