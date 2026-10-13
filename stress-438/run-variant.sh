#!/usr/bin/env bash
# TEMPORARY (#438). Run one declared variant of a stress batch.
#
#   run-variant.sh VARIANT-JSON INTEGRATION-TESTS-BINARY EVIDENCE-DIR WORKING-DIR
#
# The load is generated outside the test processes: `load` busy loops. The
# `processes` test processes run at once, and every process runs one bounded
# example after another, so the executable's one-example-at-a-time bound
# machinery holds in each of them. Every run is one process, one example
# selection and one seed.
set -uo pipefail
variant="$1"; bin="$2"; out="$3"; cwd="$4"
mkdir -p "$out/failures" "$out/runs"
eval "$(python3 -I - "$variant" <<'PY'
import json, shlex, sys
v = json.loads(sys.argv[1])
def put(k, x): print("%s=%s" % (k, shlex.quote(str(x))))
put("name", v["name"]); put("runs", v["runs"]); put("procs", v.get("processes", 1))
put("load", v.get("load", 0)); put("seedmode", v.get("seed", "random"))
put("fixedseed", v.get("fixedSeed", 1777504540)); put("delay", v.get("preErrorDelayMs", 0))
put("boundsecs", v.get("runTimeoutSeconds", 100)); put("mustpass", "1" if v.get("mustPass") else "")
put("rts", v.get("rts", ""))
matches = v["match"]
print("matches=(" + " ".join(shlex.quote(m) for m in matches) + ")")
PY
)"
args=()
for m in "${matches[@]}"; do args+=(--match "$m"); done
rtsargs=()
if [ -n "$rts" ]; then rtsargs=(+RTS $rts -RTS); fi
{
  echo "variant=$variant"
  echo "binary=$bin"; echo "cwd=$cwd"
  echo "command=$bin ${args[*]} --seed SEED ${rtsargs[*]:-}   (HET438_PRE_ERROR_DELAY_MS=$delay, per-run timeout ${boundsecs}s)"
  echo "nproc=$(nproc)"; echo "uname=$(uname -a)"; echo "loadavg_start=$(cat /proc/loadavg)"
  echo "started=$(date -u +%FT%TZ)"
} > "$out/declaration.txt"
loadpids=()
for _ in $(seq 1 "$load"); do ( while :; do :; done ) & loadpids+=("$!"); done
per=$(( (runs + procs - 1) / procs ))
worker() {
  local w="$1" i seed t0 t1 rc
  : > "$out/runs/worker-$w.tsv"
  for i in $(seq 1 "$per"); do
    [ $(( (w - 1) * per + i )) -le "$runs" ] || break
    if [ "$seedmode" = fixed ]; then seed="$fixedseed"; else seed=$(( (RANDOM * 32768 + RANDOM) )); fi
    t0=$(date +%s.%N)
    ( cd "$cwd" && HET438_PRE_ERROR_DELAY_MS="$delay" timeout "$boundsecs" "$bin" "${args[@]}" --seed "$seed" "${rtsargs[@]}" ) > "$out/runs/w$w-$i.log" 2>&1
    rc=$?
    t1=$(date +%s.%N)
    printf '%s\t%s\t%s\t%s\t%s\n' "$w" "$i" "$seed" "$rc" "$(python3 -c "print(round($t1-$t0,3))")" >> "$out/runs/worker-$w.tsv"
    if [ "$rc" -ne 0 ]; then cp "$out/runs/w$w-$i.log" "$out/failures/w$w-$i-seed$seed-rc$rc.log"; fi
    rm -f "$out/runs/w$w-$i.log"
  done
}
workerpids=()
for w in $(seq 1 "$procs"); do worker "$w" & workerpids+=("$!"); done
wait "${workerpids[@]}"
kill "${loadpids[@]}" 2>/dev/null
echo "loadavg_end=$(cat /proc/loadavg)" >> "$out/declaration.txt"
echo "finished=$(date -u +%FT%TZ)" >> "$out/declaration.txt"
python3 -I - "$out" "$name" "$runs" "$mustpass" <<'PY'
import glob, json, sys
out, name, runs, must = sys.argv[1], sys.argv[2], int(sys.argv[3]), bool(sys.argv[4])
rows = []
for f in sorted(glob.glob(out + "/runs/worker-*.tsv")):
    for line in open(f):
        w, i, seed, rc, secs = line.rstrip("\n").split("\t")
        rows.append((int(w), int(i), int(seed), int(rc), float(secs)))
bad = [r for r in rows if r[3] != 0]
secs = [r[4] for r in rows] or [0.0]
s = {"name": name, "declaredRuns": runs, "executed": len(rows), "failures": len(bad),
     "failedRuns": [{"worker": r[0], "index": r[1], "seed": r[2], "exit": r[3], "seconds": r[4]} for r in bad],
     "seconds": {"min": min(secs), "max": max(secs), "mean": round(sum(secs) / len(secs), 3)}, "mustPass": must}
json.dump(s, open(out + "/summary.json", "w"), indent=1)
print(json.dumps(s, indent=1))
PY
cat "$out/summary.json" >> "${GITHUB_STEP_SUMMARY:-/dev/null}" 2>/dev/null || true
exit 0
