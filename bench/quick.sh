#!/usr/bin/env bash
# bench/quick.sh: a 3-minute speed check of this engine on your machine, printed as a block you can paste into a
# "Measurement on my machine" issue. Not the benchmark behind the README (that is bench/box.sh + jobs.sh, hours per box).
#
#   ./bench/quick.sh              # default settings (what ./serve runs), 6 prompts x 128 tokens, greedy
#   ./bench/quick.sh --plain      # also measure plain decoding (./serve --no-spec)
#   ./bench/quick.sh --prompts 12 --tokens 256 --port 8191 --threads N
#
# It starts its own server on a spare port, so stop a running ./serve first on an 8 GB machine (two do not fit).
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PORT=8191; NP=6; NTOK=128; PLAIN=0; THREADS=
while [ $# -gt 0 ]; do case $1 in
  --plain) PLAIN=1 ;; --prompts) NP=$2; shift ;; --tokens) NTOK=$2; shift ;; --port) PORT=$2; shift ;;
  --threads) THREADS=$2; shift ;;
  -h|--help) sed -n 2,9p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown option: $1" >&2; exit 2 ;; esac; shift; done
command -v python3 >/dev/null || { echo "python3 is needed" >&2; exit 1; }
PREFIX=${OPENSET_LLM_HOME:-$HOME/.openset-llm}
[ -x "$PREFIX/bin/llama-server" ] || { echo "not installed: run ./install.sh (or ./start) first" >&2; exit 1; }
if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then echo "port $PORT is in use; pass --port" >&2; exit 1; fi
LOG=$(mktemp); PID=
stop() { [ -n "$PID" ] && kill "$PID" 2>/dev/null && wait "$PID" 2>/dev/null; PID=; return 0; }
trap 'stop; rm -f "$LOG"' EXIT

arm() {   # arm <label> <serve args...>: one server, NP prompts, one result line on stdout
  local label=$1; shift
  bash "$HERE/serve" --port "$PORT" --no-webui ${THREADS:+--threads "$THREADS"} "$@" >"$LOG" 2>&1 &
  PID=$!
  for _ in $(seq 1 300); do
    curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
    kill -0 "$PID" 2>/dev/null || { echo "the server stopped while loading:" >&2; tail -5 "$LOG" >&2; exit 1; }
    sleep 1
  done
  LABEL=$label MODE=$(grep -m1 '^serving on' "$LOG" | sed 's/.*(\(.*\))/\1/') \
  python3 - "$HERE/bench/prompts24.jsonl" "$PORT" "$NP" "$NTOK" <<'PY'
import json, os, statistics as st, sys, urllib.request
path, port, n, ntok = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
P = [json.loads(l) for l in open(path)]
P = P[:: max(1, len(P) // n)][:n]
dec, pp, dn, da = [], [], 0, 0
for p in P:
    body = {"messages": p["messages"], "max_tokens": ntok, "temperature": 0, "cache_prompt": False}
    rq = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions", json.dumps(body).encode(), {"Content-Type": "application/json"})
    t = json.load(urllib.request.urlopen(rq, timeout=1800))["timings"]
    dec.append(t["predicted_per_second"]); pp.append(t["prompt_per_second"])
    dn += t.get("draft_n") or 0; da += t.get("draft_n_accepted") or 0
    print(".", end="", file=sys.stderr, flush=True)
print(file=sys.stderr)
acc = f", {100 * da / dn:.0f} % of drafts accepted" if dn else ""
print(f"| {os.environ['LABEL']} | {st.median(dec):.2f} [{min(dec):.2f}–{max(dec):.2f}] | {st.median(pp):.1f} | {os.environ['MODE']}{acc} |")
PY
  stop
}

cpu=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')
flags=" $(grep -m1 '^flags' /proc/cpuinfo | cut -d: -f2) "
simd=; for f in avx2 avx512f avx512bw avx512_vnni avx512vbmi; do case "$flags" in *" $f "*) simd="$simd $f" ;; esac; done
cores=$(lscpu 2>/dev/null | awk -F: '/^Core\(s\) per socket/ {c=$2} /^Socket\(s\)/ {s=$2} END {if (c && s) print c * s}')
ram=$(awk '/^MemTotal:/ {printf "%.1f", $2 / 1048576}' /proc/meminfo)
commit=$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo "no git checkout")
echo "measuring: $NP prompts x $NTOK tokens per row (a few minutes)..." >&2
rows=$(arm "./serve"); [ "$PLAIN" = 1 ] && rows="$rows
$(arm "./serve --no-spec" --no-spec)"
cat <<OUT

**openset-llm quick check** (\`bench/quick.sh\`, commit $commit, $(date -u +%Y-%m-%d))

- CPU: $cpu, ${cores:-?} cores / $(nproc) threads${THREADS:+ (run with --threads $THREADS)}
- SIMD:${simd:- none of avx2 / avx512}
- RAM: $ram GiB, $(uname -sr)

| setting | decode tok/s, median [min–max] | prompt tok/s, median | server mode |
|---|---|---|---|
$rows

$NP prompts x $NTOK tokens, greedy, one run. Speed depends on the text and on what else the machine is doing.
OUT
