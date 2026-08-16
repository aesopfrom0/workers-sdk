#!/usr/bin/env bash
#
# SIGHUP orphan workerd — macOS / Linux check.
#
# The counterpart of run-experiment.ps1. Same question, same output columns,
# so the two platforms can be compared directly.
#
#   ./run-experiment.sh baseline 3
#   ./run-experiment.sh patched  3
#
# Results are appended to results-macos.tsv next to this script.
#
# It builds its own throwaway project under a temp directory and only ever
# signals processes it started itself. Nothing else on the machine is touched.

set -uo pipefail

VARIANT="${1:-}"
TRIALS="${2:-3}"
WRANGLER_VERSION="${WRANGLER_VERSION:-4.107.0}"

if [ "$VARIANT" != "baseline" ] && [ "$VARIANT" != "patched" ]; then
  echo "usage: $0 <baseline|patched> [trials]" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${TMPDIR:-/tmp}/wrangler-sighup-test"
RESULTS="$SCRIPT_DIR/results-macos.tsv"
MARK="wrangler-sighup-test/node_modules"

step() { printf '  %s\n' "$1"; }

# --- one-time project setup -------------------------------------------------
setup_project() {
  rm -rf "$PROJECT_DIR"
  mkdir -p "$PROJECT_DIR/src"

  # No framework on purpose: the original macOS reports reproduced this under
  # both Hono and Next.js, so the app layer is not the variable.
  cat > "$PROJECT_DIR/src/index.js" <<'EOF'
export default { fetch() { return new Response("ok"); } };
EOF
  cat > "$PROJECT_DIR/wrangler.json" <<'EOF'
{ "name": "sighup-test", "main": "src/index.js", "compatibility_date": "2026-01-01" }
EOF
  cat > "$PROJECT_DIR/package.json" <<'EOF'
{ "name": "wrangler-sighup-test", "private": true, "version": "0.0.0" }
EOF

  step "installing wrangler@$WRANGLER_VERSION ..."
  ( cd "$PROJECT_DIR" && npm install "wrangler@$WRANGLER_VERSION" --no-audit --no-fund >/dev/null 2>&1 ) \
    || { echo "npm install failed" >&2; exit 1; }

  ENTRY="$PROJECT_DIR/node_modules/miniflare/dist/src/index.js"
  [ -f "$ENTRY" ] || { echo "miniflare bundle not found at $ENTRY" >&2; exit 1; }
  cp "$ENTRY" "$ENTRY.bak"
}

# --- select baseline / patched ---------------------------------------------
set_variant() {
  local entry="$PROJECT_DIR/node_modules/miniflare/dist/src/index.js"
  cp "$entry.bak" "$entry"          # always start from pristine

  if [ "$VARIANT" = "baseline" ]; then
    step "miniflare: stock (no SIGHUP handler)"
    return
  fi

  ENTRY="$entry" python3 - <<'PY'
import os, re, sys
p = os.environ["ENTRY"]
s = open(p, encoding="utf-8", errors="replace").read()

add_anchor = '  process.on("SIGINT", onSignalInt);\n  process.on("SIGTERM", onSignalTerm);'
if s.count(add_anchor) != 1:
    sys.exit("could not locate exit-hook listener registration in the bundle")
s = s.replace(add_anchor, add_anchor + '\n  process.on("SIGHUP", onSignalHup);')

rm_anchor = ('  process.removeListener("SIGTERM", onSignalTerm);\n'
             '  process.removeListener("message", onMessage);')
if s.count(rm_anchor) != 1:
    sys.exit("could not locate exit-hook listener removal in the bundle")
s = s.replace(rm_anchor,
              '  process.removeListener("SIGTERM", onSignalTerm);\n'
              '  process.removeListener("SIGHUP", onSignalHup);\n'
              '  process.removeListener("message", onMessage);')

# Mirror onSignalTerm exactly; only the exit code differs (128 + SIGHUP).
m = re.search(r'function onSignalTerm\(\)\s*\{[^}]*\}', s)
if not m:
    sys.exit("could not locate onSignalTerm in the bundle")
hup = ('\nfunction onSignalHup() {\n  runCallbacks();\n'
       '  process.exit(128 + 1);\n}\n__name(onSignalHup, "onSignalHup");')
s = s[:m.end()] + hup + s[m.end():]

open(p, "w", encoding="utf-8").write(s)
PY
  [ $? -eq 0 ] || { echo "patch failed" >&2; exit 1; }
  step "miniflare: patched (onSignalHup present, $(grep -c onSignalHup "$entry") references)"
}

cleanup_leftovers() {
  for p in $(ps -Aeo pid,command | grep "$MARK" | grep -v grep | awk '{print $1}'); do
    kill -9 "$p" 2>/dev/null
  done
  sleep 2
}

# --- a single trial ---------------------------------------------------------
run_trial() {
  local run="$1"
  cleanup_leftovers

  local log="$PROJECT_DIR/dev-$VARIANT-$run.log"

  # Detached, so it is not in this shell's process group. That matters: if the
  # signal reached workerd directly it would die on its own and the experiment
  # would measure nothing. Only the parent may be signalled.
  node -e '
const { spawn } = require("node:child_process"); const fs = require("node:fs");
const c = spawn(process.argv[1], ["dev","--port","0"], { detached: true, cwd: process.argv[4],
  stdio: ["ignore", fs.openSync(process.argv[2], "w"), fs.openSync(process.argv[2], "a")] });
fs.writeFileSync(process.argv[3], String(c.pid)); c.unref(); process.exit(0);
' "$PROJECT_DIR/node_modules/.bin/wrangler" "$log" "$PROJECT_DIR/launcher.pid" "$PROJECT_DIR"

  sleep 1
  local launcher; launcher=$(cat "$PROJECT_DIR/launcher.pid")

  local n=0
  for _ in $(seq 1 90); do
    n=$(ps -Aeo pid,command | grep "$MARK/@cloudflare" | grep -v grep | wc -l | tr -d ' ')
    [ "$n" -ge 2 ] && break
    sleep 1
  done
  sleep 3

  local before_pids
  before_pids=$(ps -Aeo pid,command | grep "$MARK/@cloudflare" | grep -v grep | awk '{print $1}' | tr '\n' ' ')
  local before_n; before_n=$(echo "$before_pids" | wc -w | tr -d ' ')

  if [ "$before_n" -eq 0 ]; then
    printf '    trial %s: workerd never started — see %s\n' "$run" "$log"
    printf '%s\t%s\t0\tNA\tNA\tSTARTUP_FAIL\t%s\n' "$VARIANT" "$run" "$(uname -sr)" >> "$RESULTS"
    cleanup_leftovers
    return
  fi

  local cli
  cli=$(ps -Aeo pid,command | grep "$MARK" | grep -v grep | grep "cli.js" | awk '{print $1}' | head -1)
  step "trial $run: cli.js=$cli, workerd=$before_pids"

  # Signal the parent only. workerd must not receive it directly.
  kill -HUP "$cli" 2>/dev/null
  kill -HUP "$launcher" 2>/dev/null
  sleep 8

  local survivors
  survivors=$(ps -Aeo pid,ppid,command | grep "$MARK/@cloudflare" | grep -v grep \
    | awk '{printf "%s(ppid %s) ", $1, $2}')
  local after_n
  after_n=$(ps -Aeo pid,command | grep "$MARK/@cloudflare" | grep -v grep | wc -l | tr -d ' ')

  local verdict="CLEAN"
  [ "$after_n" -gt 0 ] && verdict="ORPHANED"
  printf '    trial %s: %s — survivors: %s\n' "$run" "$verdict" "${survivors:-none}"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$VARIANT" "$run" "$before_n" "$after_n" "${survivors:-none}" "$verdict" "$(uname -sr)" >> "$RESULTS"

  cleanup_leftovers
}

# --- main -------------------------------------------------------------------
echo ""
echo "SIGHUP orphan workerd — $(uname -s) check ($VARIANT, $TRIALS trials)"
echo "$(uname -sr) | node $(node --version)"
echo ""

setup_project
set_variant
echo ""

if [ ! -f "$RESULTS" ]; then
  printf 'variant\trun\tworkerd_before\tworkerd_after\tsurvivors\tverdict\tos\n' > "$RESULTS"
fi

for run in $(seq 1 "$TRIALS"); do
  run_trial "$run"
done

echo ""
awk -F'\t' -v v="$VARIANT" 'NR>1 && $1==v {
  if ($6=="ORPHANED") o++; else if ($6=="CLEAN") c++; else f++
} END {
  printf "Summary [%s]: %d orphaned / %d clean / %d startup failures\n", v, o+0, c+0, f+0
}' "$RESULTS"
echo "Appended to $RESULTS"
echo ""
