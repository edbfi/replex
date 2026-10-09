#!/usr/bin/env bash
# Smoke: start the built replex binary and check that GET /ping answers "pong!".
# Run from the repo root after `cargo build --locked`:
#   REPLEX_HOST=http://127.0.0.1:9 bash scripts/smoke.sh
# REPLEX_HOST is required at startup; /ping never contacts it, so a dead port will do.
# The server binds port 0, so the kernel gives it a free port; readiness only counts
# a listener owned by the spawned process, and the smoke fails if that process exits.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${REPLEX_HOST:?set REPLEX_HOST, e.g. http://127.0.0.1:9}"
bin="target/debug/replex"
if [[ ! -x "$bin" ]]; then
  echo "error: $bin is missing; run cargo build --locked first" >&2
  exit 1
fi

log="$(mktemp)"
pid=""
cleanup() {
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -f "$log"
}
trap cleanup EXIT

fail() {
  echo "error: $*" >&2
  echo "--- replex log ---" >&2
  cat "$log" >&2
  exit 1
}

REPLEX_PORT=0 RUST_LOG=info "$bin" >"$log" 2>&1 &
pid=$!

port=""
for _ in $(seq 1 150); do
  kill -0 "$pid" 2>/dev/null || fail "replex (pid $pid) exited during startup"
  # The TCP listener that belongs to our process, never any other one.
  port="$(ss -Hltnp 2>/dev/null | awk -v want="pid=$pid," 'index($0, want) { n = split($4, a, ":"); print a[n]; exit }')"
  [[ -n "$port" ]] && break
  sleep 0.2
done
[[ -n "$port" ]] || fail "replex (pid $pid) never listened on a TCP port"

body="$(curl -fsS --max-time 10 "http://127.0.0.1:$port/ping")" || fail "GET /ping on port $port failed"
kill -0 "$pid" 2>/dev/null || fail "replex (pid $pid) exited while serving /ping"
[[ "$body" == "pong!" ]] || fail "GET /ping returned '$body', expected 'pong!'"
echo "smoke ok: replex (pid $pid) on port $port answered /ping with pong!"
