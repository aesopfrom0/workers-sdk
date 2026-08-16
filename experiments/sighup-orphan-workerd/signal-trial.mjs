// Cross-platform trial runner for the SIGHUP orphan-workerd experiment.
//
//   node signal-trial.mjs <baseline|patched> <SIGHUP|SIGTERM|SIGINT> <run> <projectDir>
//
// Prints one TSV row on stdout. Everything else goes to stderr so the caller can
// redirect cleanly.
//
// Why a Node script rather than bash/PowerShell: the parent must be signalled
// while `workerd` is not, and `process.kill` is the one API that behaves the
// same way on macOS, Linux and Windows. On Windows Node emulates the POSIX
// signal names, so `process.kill(pid, "SIGHUP")` delivers what a closing console
// would deliver. That is exactly the code path under test.

import { spawn, execSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const [, , variant, signal, run, projectDirArg] = process.argv;
if (!variant || !signal || !run || !projectDirArg) {
	console.error(
		"usage: node signal-trial.mjs <baseline|patched> <SIGNAL> <run> <projectDir>"
	);
	process.exit(2);
}

// macOS hands out temp dirs under /var, which is a symlink to /private/var. The
// process table reports the resolved path, so matching on the unresolved one
// silently finds nothing.
const projectDir = fs.realpathSync(projectDirArg);

const isWindows = process.platform === "win32";
const wranglerBin = path.join(
	projectDir,
	"node_modules",
	".bin",
	isWindows ? "wrangler.cmd" : "wrangler"
);

const log = (msg) => console.error(`    ${msg}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --- process inspection -----------------------------------------------------

/** All workerd processes belonging to this experiment's project directory. */
function listWorkerd() {
	try {
		if (isWindows) {
			// Win32_Process gives us ExecutablePath, so we can scope to our copy.
			const raw = execSync(
				"powershell -NoProfile -Command \"Get-CimInstance Win32_Process -Filter \\\"Name='workerd.exe'\\\" | Select-Object ProcessId,ParentProcessId,ExecutablePath | ConvertTo-Json -Compress\"",
				{ encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }
			).trim();
			if (!raw) {
				return [];
			}
			const parsed = JSON.parse(raw);
			const rows = Array.isArray(parsed) ? parsed : [parsed];
			return rows
				.filter((r) => r.ExecutablePath?.startsWith(projectDir))
				.map((r) => ({ pid: r.ProcessId, ppid: r.ParentProcessId }));
		}
		const raw = execSync("ps -Aeo pid,ppid,command", { encoding: "utf8" });
		return raw
			.split("\n")
			.filter((l) => l.includes(projectDir) && l.includes("workerd"))
			.map((l) => l.trim().split(/\s+/))
			.map(([pid, ppid]) => ({ pid: Number(pid), ppid: Number(ppid) }))
			.filter((p) => Number.isFinite(p.pid));
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

/**
 * The process that actually owns `workerd`.
 *
 * `wrangler` is a thin launcher that re-execs into `wrangler-dist/cli.js`, and it
 * is that inner process which spawns and disposes `workerd`. Signalling only the
 * launcher leaves the real parent running, so the trial would report survivors
 * for the wrong reason.
 */
function findRuntimeParent(launcherPid) {
	const workerd = listWorkerd();
	if (workerd.length > 0) {
		// Every workerd shares the same parent; that is the process under test.
		return workerd[0].ppid;
	}
	return launcherPid;
}

function killPid(pid) {
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

/**
 * Kill every process this experiment started: the workerd children and the node
 * processes running out of the throwaway project. Scoped by the project path so
 * nothing else on the machine is touched.
 */
function killEverything() {
	for (const p of listWorkerd()) {
		killPid(p.pid);
	}
	try {
		if (isWindows) {
			const raw = execSync(
				"powershell -NoProfile -Command \"Get-CimInstance Win32_Process -Filter \\\"Name='node.exe'\\\" | Select-Object ProcessId,CommandLine | ConvertTo-Json -Compress\"",
				{ encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }
			).trim();
			if (raw) {
				const parsed = JSON.parse(raw);
				for (const r of Array.isArray(parsed) ? parsed : [parsed]) {
					if (r.CommandLine?.includes("wrangler-sighup")) {
						killPid(r.ProcessId);
					}
				}
			}
		} else {
			const raw = execSync("ps -Aeo pid,command", { encoding: "utf8" });
			for (const line of raw.split("\n")) {
				if (line.includes(projectDir) && !line.includes("signal-trial")) {
					killPid(Number(line.trim().split(/\s+/)[0]));
				}
			}
		}
	} catch {
		// nothing to clean up
	}
}

// --- the trial --------------------------------------------------------------

const logFile = path.join(projectDir, `dev-${variant}-${signal}-${run}.log`);
killEverything();
await sleep(2000);

const child = spawn(wranglerBin, ["dev", "--port", "0"], {
	cwd: projectDir,
	detached: !isWindows, // own process group on POSIX; Windows has no equivalent here
	shell: isWindows, // .cmd needs a shell
	stdio: ["ignore", fs.openSync(logFile, "w"), fs.openSync(logFile, "a")],
});
child.unref();

// Wait for workerd to come up. wrangler normally starts two.
let workerd = [];
for (let i = 0; i < 90; i++) {
	await sleep(1000);
	workerd = listWorkerd();
	if (workerd.length >= 2) {
		break;
	}
}
await sleep(3000);
workerd = listWorkerd();

function emit(fields) {
	console.log(
		[variant, signal, run, ...fields, process.platform, os.release()].join("\t")
	);
}

if (workerd.length === 0) {
	log(`run ${run}: workerd never started — see ${logFile}`);
	// Print the whole log, not a slice: the useful line (an engines mismatch, a
	// missing entry point) is usually past the startup banner.
	try {
		log(fs.readFileSync(logFile, "utf8").trim() || "(log is empty)");
	} catch (e) {
		log(`could not read ${logFile}: ${e.message}`);
	}
	killPid(child.pid);
	killEverything();
	emit(["0", "NA", "NA", "STARTUP_FAIL"]);
	process.exit(0);
}

const before = workerd.map((w) => w.pid);
const runtimeParent = findRuntimeParent(child.pid);
log(
	`run ${run}: launcher=${child.pid}, runtime parent=${runtimeParent}, workerd=${before.join(", ")}`
);

// Signal the PARENT only. If workerd received the signal directly it would die
// on its own and the trial would prove nothing.
for (const pid of new Set([runtimeParent, child.pid])) {
	try {
		process.kill(pid, signal);
	} catch (e) {
		log(`run ${run}: could not signal ${pid}: ${e.message}`);
	}
}

// Windows force-terminates roughly 10s after a console close event, so give the
// slowest platform time to finish before judging.
await sleep(isWindows ? 12000 : 8000);

const survivors = before.filter((pid) => isAlive(pid));
const verdict = survivors.length > 0 ? "ORPHANED" : "CLEAN";
const survivorText =
	survivors.length > 0
		? survivors
				.map((pid) => {
					const found = listWorkerd().find((w) => w.pid === pid);
					return found ? `${pid}(ppid ${found.ppid})` : `${pid}`;
				})
				.join(" ")
		: "none";

log(`run ${run}: ${verdict} — survivors: ${survivorText}`);

killPid(child.pid);
killEverything();

emit([String(before.length), String(survivors.length), survivorText, verdict]);
