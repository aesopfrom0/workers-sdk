// Minimal reproduction of the SIGHUP orphan when Miniflare is *embedded*
// rather than driven by `wrangler dev`.
//
//   npm install miniflare@4.20260701.0
//   node embed-repro.mjs &
//   kill -HUP <the pid it prints>
//   ps -Aeo pid,ppid,command | grep workerd     # parent 1 == orphaned
//
// Why embedding matters: running `wrangler dev` from a shell leaves workerd in
// the terminal's process group, so a SIGHUP on that group reaches workerd
// directly and it exits on its own — Miniflare's cleanup never has to work.
// Embedded, the signal only reaches the host process, so the exit hook is the
// only thing that can stop workerd. This is how vitest-pool-workers,
// @cloudflare/vite-plugin and remote-bindings use Miniflare, and
// vitest-pool-workers never calls dispose() itself.

import { Miniflare } from "miniflare";

const mf = new Miniflare({
	script: "export default { fetch() { return new Response('ok'); } };",
	modules: true,
	port: 0,
});

await mf.ready;
console.log(`ready pid=${process.pid}`);

// Stay alive the way a watch-mode test runner or dev server would.
setInterval(() => {}, 1000);
