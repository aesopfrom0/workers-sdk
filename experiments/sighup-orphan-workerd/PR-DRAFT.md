Related to #9193 — this closes one path to an orphaned `workerd`, not all of them.

`packages/miniflare/src/exit-hook.ts` listens for `exit`, `SIGINT`, `SIGTERM` and an IPC `message`, but not `SIGHUP`. So on `SIGHUP` Node exits without running any handler: the dispose callback never runs, execution never reaches `runtimeProcess.kill("SIGKILL")` in `src/runtime/index.ts`, and `workerd` is left running with no parent.

That set of signals looks inherited rather than chosen. It's the same set the `exit-hook` npm package listens for, which this file replaced in #13515. For a plain CLI that's harmless, since nothing is left behind when the process dies. Miniflare owns a child process, so it isn't. (`signal-exit`, also in this tree, does include `SIGHUP`.)

This is the circumstance @kentonv was pointing at: "miniflare must be failing to send the SIGKILL in some circumstances". The `SIGKILL` is correct and already there; it just isn't reached.

### When it actually leaks

Running `wrangler dev` from a shell puts `workerd` in the terminal's process group. A `SIGHUP` on that group reaches `workerd` directly, so it exits on its own and Miniflare's cleanup never has to work. **Closing a terminal window does not reproduce this** — I checked on iTerm2, Zed's terminal and `tmux kill-session`, and all three were clean.

The leak shows up when Miniflare is embedded instead, which is how `vitest-pool-workers`, `@cloudflare/vite-plugin` and `remote-bindings` use it. There the signal only reaches the host process, and `vitest-pool-workers` never calls `dispose()` itself, so this hook is the only thing left that can stop `workerd`. That matches @koistya's zombie `workerd` under the VSCode Vitest extension, and the "could have been the Vitest runner code" case @petebacondarwin raised.

Minimal repro. Embed Miniflare, keep the process alive the way a watch-mode runner would, then send it `SIGHUP`:

```js
const mf = new Miniflare({ script: "...", modules: true, port: 0 });
await mf.ready;
setInterval(() => {}, 1000);
```

### Measurements

Signalling the host process only. If `workerd` receives the signal directly it exits by itself and the trial measures nothing. Three trials per cell on GitHub-hosted runners, miniflare 4.20260701.0:

| OS | before | after |
| --- | --- | --- |
| Linux | **orphaned 3/3** | **clean 3/3** |
| macOS | **orphaned 3/3** | **clean 3/3** |

`SIGHUP` also leaked the temp directory, since `removeDirSync` sits in the same callback. That goes away too.

I ran the same trials through `wrangler dev` as well, signalling only the process that owns `workerd` so the process group couldn't shield it. Same split on both platforms, and `SIGTERM` and `SIGINT` stayed clean before and after, so the paths that already worked are unchanged. An earlier 30-trial run on macOS agreed.

### Scope

`SIGKILL` on the parent can't be handled at all, so crashes and `kill -9` still leak. The orphans that first sent me looking at this turned out to be a different route, and one I couldn't pin down. Each sat in its own process group whose leader had already exited, so no signal ever reached them and no handler would have helped. Reports in #9193 about idle servers or editor integrations are probably on routes like that and will likely survive this change. Covering them means killing the process tree rather than one child, which is a much larger change.

Windows is untested. `exit-hook.ts` has no platform branching and Node raises `SIGHUP` there when a console window closes, so I'd expect the same gap. But `process.kill()` can't deliver `SIGHUP` on Windows, and `GenerateConsoleCtrlEvent` accepts only `CTRL_C_EVENT` and `CTRL_BREAK_EVENT`, so measuring it needs an interactive session rather than CI. I'd rather leave it unclaimed than report a number I can't stand behind.

The process-group and `tree-kill` approaches @danawoodman and @petebacondarwin raised in the thread would cover more ground than this does, and nothing here gets in their way — it's twelve lines, and it doesn't change how any process is spawned.

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
