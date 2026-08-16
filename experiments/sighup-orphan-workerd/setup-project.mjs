// Builds the throwaway wrangler project used by signal-trial.mjs and selects
// which miniflare variant to test.
//
//   node setup-project.mjs <baseline|patched> <projectDir> [wranglerVersion]
//
// `patched` injects the SIGHUP handler into the *installed* miniflare bundle so
// the only difference between the two runs is those three edits. Patching the
// published bundle rather than building this repo keeps the comparison honest:
// a HEAD build of miniflare is not drop-in compatible with a pinned wrangler.

import { execSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const [, , variant, projectDir, wranglerVersion = "4.107.0"] = process.argv;
if (!variant || !projectDir) {
	console.error(
		"usage: node setup-project.mjs <baseline|patched> <projectDir> [wranglerVersion]"
	);
	process.exit(2);
}

const entry = path.join(
	projectDir,
	"node_modules",
	"miniflare",
	"dist",
	"src",
	"index.js"
);
const backup = `${entry}.bak`;

if (!fs.existsSync(backup)) {
	fs.rmSync(projectDir, { recursive: true, force: true });
	fs.mkdirSync(path.join(projectDir, "src"), { recursive: true });

	// No framework on purpose: the original reports reproduced this under both
	// Hono and Next.js, so the app layer is not the variable.
	fs.writeFileSync(
		path.join(projectDir, "src", "index.js"),
		'export default { fetch() { return new Response("ok"); } };\n'
	);
	fs.writeFileSync(
		path.join(projectDir, "wrangler.json"),
		JSON.stringify(
			{
				name: "sighup-test",
				main: "src/index.js",
				compatibility_date: "2026-01-01",
			},
			null,
			2
		)
	);
	fs.writeFileSync(
		path.join(projectDir, "package.json"),
		JSON.stringify(
			{ name: "wrangler-sighup-test", private: true, version: "0.0.0" },
			null,
			2
		)
	);

	console.log(`installing wrangler@${wranglerVersion} ...`);
	execSync(`npm install wrangler@${wranglerVersion} --no-audit --no-fund`, {
		cwd: projectDir,
		stdio: "inherit",
	});

	// npm only warns on an engines mismatch, then wrangler fails to start later
	// and the trial reports STARTUP_FAIL with no obvious cause. Fail loudly here.
	const required = JSON.parse(
		fs.readFileSync(
			path.join(projectDir, "node_modules", "wrangler", "package.json"),
			"utf8"
		)
	).engines?.node;
	if (required) {
		const min = Number(required.replace(/[^\d.]/g, "").split(".")[0]);
		const current = Number(process.versions.node.split(".")[0]);
		if (Number.isFinite(min) && current < min) {
			console.error(
				`wrangler@${wranglerVersion} requires node ${required}, but this is node ${process.versions.node}. ` +
					`It would install and then fail to start workerd.`
			);
			process.exit(1);
		}
	}

	if (!fs.existsSync(entry)) {
		console.error(`miniflare bundle not found at ${entry}`);
		process.exit(1);
	}
	fs.copyFileSync(entry, backup);
}

// Always restore the pristine bundle first so runs cannot drift into each other.
fs.copyFileSync(backup, entry);

if (variant === "baseline") {
	console.log("miniflare: stock (no SIGHUP handler)");
	process.exit(0);
}

let source = fs.readFileSync(entry, "utf8");

const addAnchor =
	'  process.on("SIGINT", onSignalInt);\n  process.on("SIGTERM", onSignalTerm);';
if (source.split(addAnchor).length - 1 !== 1) {
	console.error(
		"could not locate the exit-hook listener registration in the miniflare bundle"
	);
	process.exit(1);
}
source = source.replace(
	addAnchor,
	`${addAnchor}\n  process.on("SIGHUP", onSignalHup);`
);

const removeAnchor =
	'  process.removeListener("SIGTERM", onSignalTerm);\n  process.removeListener("message", onMessage);';
if (source.split(removeAnchor).length - 1 !== 1) {
	console.error(
		"could not locate the exit-hook listener removal in the miniflare bundle"
	);
	process.exit(1);
}
source = source.replace(
	removeAnchor,
	'  process.removeListener("SIGTERM", onSignalTerm);\n  process.removeListener("SIGHUP", onSignalHup);\n  process.removeListener("message", onMessage);'
);

// Mirror onSignalTerm exactly; only the exit code differs (128 + SIGHUP).
const termMatch = /function onSignalTerm\(\)\s*\{[^}]*\}/.exec(source);
if (!termMatch) {
	console.error("could not locate onSignalTerm in the miniflare bundle");
	process.exit(1);
}
const insertAt = termMatch.index + termMatch[0].length;
const hup =
	'\nfunction onSignalHup() {\n  runCallbacks();\n  process.exit(128 + 1);\n}\n__name(onSignalHup, "onSignalHup");';
source = source.slice(0, insertAt) + hup + source.slice(insertAt);

fs.writeFileSync(entry, source);

const count = (fs.readFileSync(entry, "utf8").match(/onSignalHup/g) ?? []).length;
if (count < 3) {
	console.error(
		`SIGHUP patch did not apply cleanly (${count} references, expected >= 3)`
	);
	process.exit(1);
}
console.log(`miniflare: patched (onSignalHup present, ${count} references)`);
