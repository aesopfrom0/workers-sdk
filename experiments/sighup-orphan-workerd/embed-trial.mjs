// Automated version of embed-repro.mjs: spawns a host process that embeds
// Miniflare, sends SIGHUP to that host only, and reports whether workerd
// survived.
//
//   node embed-trial.mjs <baseline|patched> <run> <projectDir>
//
// Prints one TSV row on stdout; everything else goes to stderr.
//
// This is the case the PR actually argues about. `wrangler dev` puts workerd in
// the caller's process group, so a group-wide SIGHUP reaches workerd directly
// and it exits on its own — the exit hook never has to work. Embedded, only the
// host sees the signal, so the hook is the sole thing that can stop workerd.
// vitest-pool-workers, @cloudflare/vite-plugin and remote-bindings all embed it,
// and vitest-pool-workers never calls dispose() itself.

import { spawn, execSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const [, , variant, run, projectDirArg] = process.argv;
if (!variant || !run || !projectDirArg) {
	console.error("usage: node embed-trial.mjs <baseline|patched> <run> <projectDir>");
	process.exit(2);
}

// macOS temp dirs live under /var, a symlink to /private/var. The process table
// reports the resolved path, so matching the unresolved one finds nothing.
const projectDir = fs.realpathSync(projectDirArg);
const isWindows = process.platform === "win32";
const log = (m) => console.error(`    ${m}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function listWorkerd() {
	try {
		if (isWindows) {
			const raw = execSync(
				"powershell -NoProfile -Command \"Get-CimInstance Win32_Process -Filter \\\"Name='workerd.exe'\\\" | Select-Object ProcessId,ParentProcessId,ExecutablePath | ConvertTo-Json -Compress\"",
				{ encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }
			).trim();
			if (!raw) {
				return [];
			}
			const parsed = JSON.parse(raw);
			return (Array.isArray(parsed) ? parsed : [parsed])
				.filter((r) => r.ExecutablePath?.startsWith(projectDir))
				.map((r) => ({ pid: r.ProcessId, ppid: r.ParentProcessId }));
		}
		const raw = execSync("ps -Aeo pid,ppid,command", { encoding: "utf8" });
		return raw
			.split("\n")
			.map((l) => l.trim())
			.filter((l) => {
				if (!l.includes(path.join(projectDir, "node_modules"))) {
					return false;
				}
				// Match the workerd binary itself, not any line that happens to
				// mention the directory — this script's own command line does.
				const executable = l.split(/\s+/).slice(2).join(" ").split(/\s+/)[0] ?? "";
				return /(^|[\\/])workerd(\.exe)?$/.test(executable);
			})
			.map((l) => l.split(/\s+/))
			.map(([pid, ppid]) => ({ pid: Number(pid), ppid: Number(ppid) }))
			// Reject 0: Number("") is 0, and kill(0, sig) signals our own group.
			.filter((p) => Number.isInteger(p.pid) && p.pid > 0 && p.pid !== process.pid);
	} catch {
		return [];
	}
}

function isAlive(pid) {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
}

function killPid(pid) {
	if (!Number.isInteger(pid) || pid <= 0 || pid === process.pid) {
		return;
	}
	try {
		if (isWindows) {
			execSync(`taskkill /F /PID ${pid}`, { stdio: "ignore" });
		} else {
			process.kill(pid, "SIGKILL");
		}
	} catch {
		// already gone
	}
}

function cleanup() {
	for (const w of listWorkerd()) {
		killPid(w.pid);
	}
}

const hostScript = path.join(projectDir, "embed-host.mjs");
fs.writeFileSync(
	hostScript,
	`import { Miniflare } from "miniflare";
const mf = new Miniflare({
  script: "export default { fetch() { return new Response('ok'); } };",
  modules: true,
  port: 0,
});
await mf.ready;
console.log("ready pid=" + process.pid);
setInterval(() => {}, 1000);
`
);

const logFile = path.join(projectDir, `embed-${variant}-${run}.log`);
cleanup();
await sleep(2000);

const host = spawn(process.execPath, [hostScript], {
	cwd: projectDir,
	detached: !isWindows,
	stdio: ["ignore", fs.openSync(logFile, "w"), fs.openSync(logFile, "a")],
});
host.unref();

let workerd = [];
for (let i = 0; i < 60; i++) {
	await sleep(1000);
	workerd = listWorkerd();
	if (workerd.length > 0) {
		break;
	}
}
await sleep(2000);
workerd = listWorkerd();

function emit(fields) {
	console.log(
		["embed", variant, "SIGHUP", run, ...fields, process.platform, os.release()].join("\t")
	);
}

if (workerd.length === 0) {
	log(`run ${run}: workerd never started — see ${logFile}`);
	try {
		log(fs.readFileSync(logFile, "utf8").trim() || "(log is empty)");
	} catch (e) {
		log(`could not read ${logFile}: ${e.message}`);
	}
	killPid(host.pid);
	cleanup();
	emit(["0", "NA", "NA", "STARTUP_FAIL"]);
	process.exit(0);
}

const before = workerd.map((w) => w.pid);
log(`run ${run}: host=${host.pid}, workerd=${before.join(", ")}`);

// The host only. workerd must not receive this directly.
const forbidden = new Set([process.pid, process.ppid, 0]);
if (!forbidden.has(host.pid)) {
	try {
		process.kill(host.pid, "SIGHUP");
	} catch (e) {
		log(`run ${run}: could not signal ${host.pid}: ${e.message}`);
	}
}

await sleep(isWindows ? 12000 : 8000);

const survivors = before.filter((pid) => isAlive(pid));
const verdict = survivors.length > 0 ? "ORPHANED" : "CLEAN";
const detail =
	survivors.length > 0
		? survivors
				.map((pid) => {
					const found = listWorkerd().find((w) => w.pid === pid);
					return found ? `${pid}(ppid ${found.ppid})` : `${pid}`;
				})
				.join(" ")
		: "none";

log(`run ${run}: ${verdict} — survivors: ${detail}`);

killPid(host.pid);
cleanup();

emit([String(before.length), String(survivors.length), detail, verdict]);
