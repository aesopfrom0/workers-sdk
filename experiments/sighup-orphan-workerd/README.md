# SIGHUP orphan `workerd` — harness

Scratch work behind the change in `packages/miniflare/src/exit-hook.ts`. Not part of the PR.

Start with **`이해하기.md`** for the whole story in Korean. This file is just how to run things.

## What's here

| File | What it's for |
| --- | --- |
| `이해하기.md` | Full write-up: what workerd/Miniflare/Wrangler are, the bug, the reversal, what's still unknown |
| `PR-DRAFT.md` | The PR description as it will be submitted |
| `PR-DRAFT-ko.md` | Korean version for review, plus notes on decisions made while drafting |
| **`embed-repro.mjs`** | **The reproduction that matters.** Miniflare embedded as a library |
| `run-experiment.sh` | macOS/Linux harness — signals the parent, counts survivors |
| `signal-trial.mjs` | Cross-platform trial runner used by CI |
| `setup-project.mjs` | Builds the throwaway project, applies or reverts the patch |
| `windows-check.ps1` | Windows check. Mostly manual — see below for why |

## The short version

`exit-hook.ts` listens for `exit`, `SIGINT`, `SIGTERM` and an IPC `message`, but not `SIGHUP`. On
`SIGHUP` Node exits without running any handler, so `dispose()` never runs, the `SIGKILL` that
stops `workerd` is never reached, and the child survives.

**Closing a terminal window does not reproduce this** — I checked on iTerm2, Zed's terminal and
`tmux kill-session`, and all three cleaned up. Running `wrangler dev` from a shell puts `workerd`
in the terminal's process group, so the `SIGHUP` reaches it directly and it exits on its own.

The case that leaks is Miniflare **embedded** as a library, which is how `vitest-pool-workers`,
`@cloudflare/vite-plugin` and `remote-bindings` use it. There the signal only reaches the host
process, and `vitest-pool-workers` never calls `dispose()`, so the exit hook is the only thing
that can stop `workerd`.

## Reproducing it (the important one)

```bash
mkdir /tmp/mf && cd /tmp/mf
npm init -y && npm pkg set type=module
npm install miniflare@4.20260701.0
cp <this-dir>/embed-repro.mjs .
node embed-repro.mjs &
# it prints "ready pid=NNNN"
kill -HUP NNNN
sleep 5
ps -Aeo pid,ppid,command | grep workerd   # parent 1 => orphaned
```

Measured 6 times: orphaned 3/3 before the change, clean 3/3 after.

## macOS / Linux matrix

```bash
./run-experiment.sh baseline 3
./run-experiment.sh patched  3
```

Results append to `results-macos.tsv`. This is the same thing CI runs; the 54-trial CI output
lives in `~/z-idea-brewery/dev-docs/wrangler-orphan-evidence/results-ci-3os.tsv`.

## Windows

**There is no way to script this.** Two routes were tried and both are dead ends:

| Approach | Why it fails |
| --- | --- |
| `process.kill(pid, "SIGHUP")` | Node can only terminate a target with `SIGINT`, `SIGTERM` or `SIGKILL` on Windows |
| `GenerateConsoleCtrlEvent` | Accepts only `CTRL_C_EVENT` and `CTRL_BREAK_EVENT` — Node maps those to `SIGINT` and `SIGBREAK` |

`SIGHUP` on Windows is Node's mapping of `CTRL_CLOSE_EVENT`, which is raised only when a console
window is genuinely closed. So a person has to close it.

```powershell
.\windows-check.ps1 -Variant baseline   # close the window it opens, then press Enter
.\windows-check.ps1 -Variant patched
```

Expected: `baseline` orphans, `patched` doesn't. If both come back clean, Windows doesn't have
this bug and the PR should say so rather than claiming cross-platform behaviour — that's a useful
answer too.

Do not press Ctrl+C during the check. That's `SIGINT`, a path that already works, and it would
measure the wrong thing.
