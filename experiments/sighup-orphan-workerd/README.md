# SIGHUP orphan `workerd` — Windows verification

Goal: find out whether the orphaned-`workerd` behaviour reproduced on macOS
(issue [#9193](https://github.com/cloudflare/workers-sdk/issues/9193)) also happens on Windows,
and whether the `SIGHUP` handler added to `packages/miniflare/src/exit-hook.ts` fixes it there.

**This branch is for experiments only. It is not the PR branch.**

## What is already known

Verified on macOS 26.5.2 (arm64), wrangler 4.107.0, miniflare 4.20260701.0, 30 trials:

| miniflare | signal sent to the parent | orphaned `workerd` |
| --- | --- | --- |
| unpatched | `SIGHUP` | **5/5 trials** |
| unpatched | `SIGTERM` | 0/5 |
| unpatched | `SIGINT` | 0/5 |
| patched | `SIGHUP` | **0/5** |
| patched | `SIGTERM` | 0/5 |
| patched | `SIGINT` | 0/5 |

An orphan is a `workerd` whose parent died without cleaning it up, so the OS reparented it
(PPID becomes 1 on macOS/Linux). On this machine 15 of them had accumulated, the oldest running
for over four days.

### Why it happens

`packages/miniflare/src/exit-hook.ts` registers handlers for `exit`, `SIGINT`, `SIGTERM` and an
IPC `message`, but not for `SIGHUP`. Closing a terminal window sends `SIGHUP`, Node exits on the
default disposition without running any handler, so this chain never completes:

```
exit-hook handler  →  Miniflare dispose callback (src/index.ts:899)
                   →  Runtime#dispose() (src/runtime/index.ts:396)
                   →  runtimeProcess.kill("SIGKILL")   ← never reached
```

The `SIGKILL` that stops `workerd` is already there and correct. The problem is that on `SIGHUP`
execution never gets to it.

This matches what @kentonv wrote in the issue:

> if SIGKILL were actually performed, there's no way workerd could be left orphaned.
> It must be that miniflare is failing to send SIGKILL in some circumstances.

The circumstance is `SIGHUP`.

## Why Windows needs separate verification

`exit-hook.ts` contains no platform branching, so the missing handler affects every OS. The
Node docs also state that Windows raises `SIGHUP`:

> `'SIGHUP'` is generated on Windows when the console window is closed... It can have a listener
> installed, however Node.js will be unconditionally terminated by Windows about 10 seconds later.

But two things are genuinely different on Windows and cannot be assumed:

1. **There is no reparenting to PID 1.** A Windows process keeps its recorded parent PID even
   after the parent exits, so "orphan" has to be detected differently (see below).
2. **The 10 second kill.** Windows terminates the process about 10 seconds after the console
   closes regardless of the handler. Cleanup has to finish inside that window. It should — the
   dispose path is sub-millisecond — but that is a prediction, not a measurement.

So the question this experiment answers is: **on Windows, does closing the console window leave
`workerd` running, and does the patch stop that?**

## How to detect an orphan on Windows

Do not look for PPID 1. Instead check whether a `workerd` process is still alive while its
recorded parent PID is gone:

```powershell
Get-CimInstance Win32_Process -Filter "Name='workerd.exe'" |
  Select-Object ProcessId, ParentProcessId, CreationDate
```

A `workerd.exe` whose `ParentProcessId` no longer exists (or has been recycled) is the Windows
equivalent of the macOS orphan. `run-experiment.ps1` does this check for you.

## Running it

Requires Node 20+, pnpm, and PowerShell 5.1 or 7+. From this directory:

```powershell
# 1. Baseline: current miniflare from npm, no patch
.\run-experiment.ps1 -Variant baseline -Trials 3

# 2. Patched: applies the SIGHUP handler to the installed miniflare bundle
.\run-experiment.ps1 -Variant patched -Trials 3
```

The script writes `results-windows.tsv` in this directory. Please attach that file (or paste it)
along with the summary the script prints.

### What the script does

For each trial:

1. starts `wrangler dev` in its own console (`Start-Process`), so it owns a console that can be
   closed
2. waits for `workerd.exe` children to appear and records their PIDs
3. sends the console-close event with `GenerateConsoleCtrlEvent` (`CTRL_CLOSE_EVENT`), which is
   what Node maps to `SIGHUP` — this is the Windows analogue of closing the terminal window
4. waits, then checks whether any recorded `workerd.exe` is still alive
5. kills anything left over so trials do not contaminate each other

It only touches processes it started itself, under a temp directory it creates.

## Interpreting the result

| Outcome | Meaning |
| --- | --- |
| baseline leaves `workerd` alive, patched does not | Same bug as macOS, patch fixes it on Windows |
| both leave `workerd` alive | Patch is insufficient on Windows — likely the 10s kill, or the handler never runs |
| neither leaves `workerd` alive | Windows already cleans up (e.g. console process group teardown); the fix is macOS/Linux only |

Any of the three is a useful answer. **The third one is not a failure** — it would mean the PR
description should scope the fix to macOS/Linux instead of claiming cross-platform behaviour.

## What this does NOT cover

The `SIGHUP` path is one route to orphaned `workerd`, not the only one. While collecting the
macOS data a new orphan appeared **while its parent wrangler was still alive** and no terminal
had been closed, so at least one other route exists. `kill -9` on the parent, and crashes of
wrangler itself, are also unfixable this way — `SIGKILL` cannot have a handler installed.

@danawoodman suggested killing the process **group** in the issue thread, and @petebacondarwin
looked at `tree-kill`. That approach is more thorough than a signal handler and would cover the
crash case too. This experiment does not evaluate it.
