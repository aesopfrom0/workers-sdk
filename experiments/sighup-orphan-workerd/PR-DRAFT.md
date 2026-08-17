Related to #9193, though only partly: this closes one reproducible path to an orphaned `workerd` and leaves the others open. I've noted at the end which reports it won't help with.

`packages/miniflare/src/exit-hook.ts` listens for `exit`, `SIGINT`, `SIGTERM` and an IPC `message`, but not `SIGHUP`. When the Miniflare process receives `SIGHUP` it therefore exits on the default disposition without running any handler: the dispose callback registered in `src/index.ts` never runs, execution never reaches `runtimeProcess.kill("SIGKILL")` in `src/runtime/index.ts`, and `workerd` survives with no parent.

That set of signals isn't an oversight — it's inherited. `exit-hook.ts` replaced the `exit-hook` npm package in #13515, and that package listens for exactly `exit`, `SIGINT`, `SIGTERM` and an IPC `message` too. For an ordinary CLI the omission is harmless: nothing is left behind when the process dies without running a handler. Other libraries make the opposite choice — `signal-exit`, already in this tree, does include `SIGHUP`.

Miniflare is in the second category, because it owns a child process. When it exits without running its handler, `workerd` outlives it. So the default that suits a plain CLI doesn't suit this use, and `SIGHUP` is the one termination signal where that difference actually bites.

Where that shows up is when Miniflare is embedded rather than driven by `wrangler dev`, which is how `vitest-pool-workers`, `@cloudflare/vite-plugin` and `remote-bindings` all use it. Running `wrangler dev` from a shell puts `workerd` in the terminal's process group, so a `SIGHUP` on that group reaches `workerd` directly and it exits on its own — Miniflare's cleanup never has to work. Embed it and that incidental protection is gone: the signal goes to the host process, `workerd` doesn't see it, and only the exit hook can save it.

`vitest-pool-workers` never calls `dispose()` itself, so on `SIGHUP` it depends entirely on this hook. A minimal embed reproduces it directly:

```js
const mf = new Miniflare({ script: "...", modules: true, port: 0 });
await mf.ready;
setInterval(() => {}, 1000);   // stay alive, like a watch-mode runner
```

`kill -HUP` that process and `workerd` is reparented to init. With this change it exits cleanly. That's the same shape as @koistya's report of zombie `workerd` under the VSCode Vitest extension, and the "could have been the Vitest runner code" case @petebacondarwin mentioned.

The thread already identified the shape of this: @kentonv concluded that "miniflare must be failing to send the SIGKILL in some circumstances", and @petebacondarwin described the gap as parent processes that "somehow die without cleaning up". `SIGHUP` is one such circumstance, and one such way of dying. The `SIGKILL` is correct and already there — it simply isn't reached, because no handler runs before Node exits. Adding the listener mirrors `onSignalTerm` exactly; only the exit code differs.

### Measurements

The signal goes to the parent only — if `workerd` receives it directly it terminates on its own and the trial measures nothing. Three trials per cell, wrangler 4.107.0 with miniflare 4.20260701.0, on GitHub-hosted runners:

| OS | | SIGHUP | SIGTERM | SIGINT |
| --- | --- | --- | --- | --- |
| Linux | before | **orphaned 3/3** | clean | clean |
| Linux | after | **clean 3/3** | clean | clean |
| macOS | before | **orphaned 3/3** | clean | clean |
| macOS | after | **clean 3/3** | clean | clean |

An earlier macOS run over 30 trials split the same way (orphaned 5/5 before, 0/5 after). `SIGTERM` and `SIGINT` stay clean on both sides, so the paths that already worked are unchanged. The `SIGHUP` case also leaked the temp directory, since `removeDirSync` sits in the same dispose callback; that goes away too.

To reproduce by hand: start `wrangler dev`, then send `SIGHUP` to the `wrangler-dist/cli.js` process — not to the process group — and check for a `workerd` whose parent is now init.

One thing worth stating plainly, since it's the obvious thing to try: **closing a terminal window does not reproduce this.** I checked on iTerm2, Zed's terminal and `tmux kill-session`, expecting all three to leak, and none of them did — for the process-group reason above. The embedded case is the one that leaks.

### What this does not fix

`SIGHUP` is one route to an orphaned `workerd`, not the only one, and probably not the most common one. `SIGKILL` on the parent can't be handled this way at all, since it can't have a handler installed.

The orphans that first sent me looking at this are a different route, and I couldn't pin it down. They accumulated over several days on one machine, each sitting in its own process group whose leader had already exited, under a tool that supervises dev servers rather than a shell. Whatever killed the parents evidently never reached `workerd`, so no handler in Miniflare would have run — this change would not have prevented any of them.

That matters for reading the reports in #9193: the ones involving editor integrations or long-idle servers are likely on that other route, and I'd expect them to persist after this. Covering those needs Miniflare to kill the process tree rather than a single child, which is a larger change than this one.

Windows is untested. `exit-hook.ts` has no platform branching, and Node raises `SIGHUP` there when a console window closes, so I'd expect the same gap — but `process.kill()` can't deliver `SIGHUP` on Windows, so CI can't measure it, and I'd rather leave it unclaimed than report a number I can't stand behind.

A process-group or `tree-kill` approach, raised by @danawoodman and @petebacondarwin in the thread, would also cover the crash case. This doesn't conflict with that: it removes one cause outright in 12 lines, without changing how processes are spawned, and a broader change would still be worth doing on top.

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
