Related to #9193 — this closes one path to an orphaned `workerd`, not all of them.

`packages/miniflare/src/exit-hook.ts` listens for `exit`, `SIGINT`, `SIGTERM` and an IPC `message`, but not `SIGHUP`. On `SIGHUP` Node exits on the default disposition without running any handler, so the dispose callback never runs, execution never reaches `runtimeProcess.kill("SIGKILL")` in `src/runtime/index.ts`, and `workerd` survives with no parent.

That signal set is inherited rather than chosen: it matches the `exit-hook` npm package this file replaced in #13515. Harmless for a plain CLI, but Miniflare owns a child process, so exiting without running the handler leaks one. (`signal-exit`, also in this tree, does listen for `SIGHUP`.)

This is the circumstance @kentonv was pointing at — "miniflare must be failing to send the SIGKILL in some circumstances". The `SIGKILL` is correct and already there; it just isn't reached.

### Where it bites

Running `wrangler dev` from a shell puts `workerd` in the terminal's process group, so a `SIGHUP` reaches `workerd` directly and it exits on its own — the cleanup never has to work. **Closing a terminal window does not reproduce this**; I checked on iTerm2, Zed's terminal and `tmux kill-session`, and all three were clean.

It bites when Miniflare is embedded instead, which is how `vitest-pool-workers`, `@cloudflare/vite-plugin` and `remote-bindings` use it. Then the signal only reaches the host process, and `vitest-pool-workers` never calls `dispose()` itself, so this hook is the only thing that can stop `workerd`. That matches @koistya's zombie `workerd` under the VSCode Vitest extension, and the "could have been the Vitest runner code" case @petebacondarwin raised.

Minimal repro — embed Miniflare, keep the process alive like a watch-mode runner, then `SIGHUP` that process:

```js
const mf = new Miniflare({ script: "...", modules: true, port: 0 });
await mf.ready;
setInterval(() => {}, 1000);
```

### Measurements

Signalling the host process only — if `workerd` gets the signal directly it exits on its own and the trial measures nothing. Three trials per cell on GitHub-hosted runners, miniflare 4.20260701.0:

| OS | before | after |
| --- | --- | --- |
| Linux | **orphaned 3/3** | **clean 3/3** |
| macOS | **orphaned 3/3** | **clean 3/3** |

The `SIGHUP` case also leaked the temp directory, since `removeDirSync` sits in the same callback; that goes away too.

Separately, driving the same trials through `wrangler dev` — signalling only the process that owns `workerd`, so the process group doesn't shield it — gives the same split on both platforms, and `SIGTERM`/`SIGINT` stay clean before and after, so the paths that already worked are unchanged. An earlier 30-trial macOS run agreed.

### Scope

`SIGKILL` on the parent can't be handled this way at all, so crashes and `kill -9` still leak. The orphans that first sent me looking at this turned out to be another route I couldn't pin down — each sat in its own process group whose leader had already exited, so no signal ever reached them and no handler would have run. Reports in #9193 about idle servers or editor integrations are likely on those routes and should be expected to survive this change; covering them needs Miniflare to kill the process tree, which is a larger change.

Windows is untested. `exit-hook.ts` has no platform branching and Node raises `SIGHUP` there on console close, so I'd expect the same gap — but `process.kill()` can't deliver `SIGHUP` on Windows and `GenerateConsoleCtrlEvent` only accepts `CTRL_C_EVENT`/`CTRL_BREAK_EVENT`, so it needs an interactive session rather than CI. I'd rather leave it unclaimed than report a number I can't stand behind.

A process-group or `tree-kill` approach, raised by @danawoodman and @petebacondarwin in the thread, would cover more than this does. This doesn't conflict with it: 12 lines, no change to how processes are spawned.

---

<!--
Please don't delete the checkboxes <3
The following selections do not need to be completed if this PR only contains changes to .md files
-->

- Tests
  - [x] Tests included/updated
  - [ ] Automated tests not possible - manual testing has been completed as follows:
  - [ ] Additional testing not necessary because:
- Public documentation
  - [ ] Cloudflare docs PR(s): <!--e.g. <https://github.com/cloudflare/cloudflare-docs/pull/>...-->
  - [x] Documentation not necessary because: internal cleanup behaviour, with no change to any public API, CLI flag or configuration option.

> [!NOTE]
> This is a contribution from an AI agent: Claude Code, Opus 5. The agent did the
> diagnosis and wrote the harness; verifying it across operating systems on CI was
> my call, and I reviewed the finding, the scope and the wording here.
