#!/usr/bin/env bash
# round_rc16.sh -- RC16 receipts through the recipe image: a clean clone of Enntity/sparkqwen rc16, ./start.sh builds
# ghcr.io/enntity/atlas-sparkqwen:<install tree> from the pinned engine and serves each profile. Everything lands in
# ~/sparkqwen-rc16/receipts/. Run on rank 0 with the pair held and nothing else serving.
set -uo pipefail
R=~/sparkqwen-rc16; O=$R/receipts; mkdir -p $O/exact; cd ~
log() { echo "$@" | tee -a $O/summary.out; }
up() { for i in $(seq 240); do curl -sf -m 5 http://127.0.0.1:8893/health >/dev/null && return 0; sleep 5; done; return 1; }
serve() {  # serve PROFILE TAG
  (cd $R && ./start.sh stop > /dev/null 2>&1; sleep 20; PROFILE=$1 ./start.sh > $O/start-$2.log 2>&1) || { log "start $1 failed"; tail -20 $O/start-$2.log; exit 1; }
  up || { log "$1 not healthy"; exit 1; }
  docker logs atlas-sparkqwen-rank0 2>&1 | sed "s/\x1b\[[0-9;]*m//g" | grep -E "KV cache: |ssm_pool|SSM snapshot pool|Prefill config|loop steering" > $O/kvpool-$2.out
  log "== $1 up: $(grep -oE '[0-9]+ max KV tokens' $O/kvpool-$2.out) $(grep MemAvailable /proc/meminfo | tr -s ' ')"
}
cd $R && git log --oneline -1 | tee -a $O/summary.out && ./install/build.sh --tag | tee -a $O/summary.out
B=$R/bench; G="python3 $B/greedy_eq.py"; export SPARKDASH_DIR=~/sparkDash
log "## reference: 8x32k without prefix caching and speculation, one at a time"
python3 - "$O/exact/8x32k-ref-nocache-nospec.json" <<'PY'
import json, sys
p = json.load(open("install/profiles/8x32k.json"))
p["note"] = "Reference for exactness checks: the 8x32k profile without prefix caching and speculation."
p["server_argv"] = [a for a in p["server_argv"] if a not in ("--enable-prefix-caching", "--speculative") and not a.startswith("--num-drafts")]
json.dump(p, open(sys.argv[1], "w"), indent=1)
PY
W=$(grep ^WORKER= .env | cut -d= -f2); ssh -n $W "mkdir -p $O/exact" && scp -q $O/exact/8x32k-ref-nocache-nospec.json $W:$O/exact/
serve $O/exact/8x32k-ref-nocache-nospec.json ref
(cd $O/exact && $G run REF1 1 && $G run REFP1 1 --prefix) | tee -a $O/summary.out
log "## 8x32k (default)"
serve 8x32k 8x32k
(cd $O/exact && for c in 1 4 8; do $G run D$c $c; $G run DP$c $c --prefix; done; for c in 1 4 8; do $G compare REF1 D$c | tail -1; $G compare REFP1 DP$c | tail -1; done) | grep -E "identical|differ" | tee -a $O/summary.out
(cd ~/sparkqwen-dev && python3 crash_probe.py | tail -1; python3 multi_probe.py http://127.0.0.1:8893 --burst 70 --cached 2>&1 | tail -7) | tee $O/crash-probes.out | tail -2 | tee -a $O/summary.out
(cd $O && node $B/sd_bench.mjs RC16 structured,prose,code,json 1,2,4,8 2>&1 | tee sd-RC16.out | grep -E "C1:|C8:") | tee -a $O/summary.out
(cd $O && python3 $B/quality_probe.py RC16 4 2>&1 | tail -2) | tee -a $O/summary.out
(cd $O && python3 $B/sq_bench.py RC16 decode prefill warm > sq-RC16.out 2>&1; grep -E "^prefill|^warm" sq-RC16.out | tail -12) | tee -a $O/summary.out
(cd $O && python3 $B/agentic_probe.py RC16 2>&1 | tail -1) | tee -a $O/summary.out
(cd $O && python3 $B/tool_probe.py RC16 5 2>&1 | tail -1) | tee -a $O/summary.out
python3 - "$O/kvpool-8x32k.out" "$(cd $R && ./install/build.sh --tag)" "$(cd $R && git rev-parse --short HEAD)" <<'PY'
import json, re, sys, os
kv = open(sys.argv[1]).read(); tag = sys.argv[2]; rev = sys.argv[3]
m = re.search(r"(\d+) blocks .{1,4} 16 tok/block = (\d+) max KV tokens", kv)
n, tokens = int(m.group(1)), int(m.group(2))
p = os.path.expanduser("~/rigmark/metadata-sq.json"); d = json.load(open(p))
pool, aux = n * 196608, n * 16 * 768
d.update({
  "serving_engine": f"Atlas (Enntity/atlas sparkqwen/atlas-20261010-rc16 @ 1c43247d), recipe image {tag}, SparkQwen 8x32k profile, GPU_MEMORY_UTILIZATION=0.88",
  "serving_image": f"{tag} via ./start.sh",
  "kv_cache_memory_per_rank": pool + aux,
  "logical_kv_tokens": tokens,
  "kv_cache_layout": f"BF16 paged KV, 16-token blocks: 12 full-attention layers x 1 KV head per rank x head dim 256 (196,608 B per block across layers, {pool:,} B) + QSA indexer carry at 768 B/token ({aux:,} B); the 36 Gated DeltaNet layers keep recurrent state outside the pool (SSM state pool 8 slots 454 MB, MTP intermediates/checkpoints 4,115 MB, prefix-cache snapshot pool 16 slots 909 MB); no prefill-MoE weight duplicate",
  "recipe_revision": f"{rev} (install/ tree {tag.split(':')[-1]})",
  "loop_steering": "on (ATLAS_LOOP_STEER=1): after a content-loop tail the watchdog would cut, the next pick skips the cycle's continuation token, up to 3 times a request; output is unchanged where no loop forms",
})
json.dump(d, open(p, "w"), indent=2)
print("metadata:", tokens, "tokens,", pool + aux, "bytes/rank")
PY
cp ~/rigmark/metadata-sq.json $O/metadata-sq.json
(cd ~/rigmark && ./rigmark run --base-url http://127.0.0.1:8893 --model auto --metadata metadata-sq.json --comparison-id sparkqwen-rc15 --runs 3 --prefill-runs 2 --prefill-depths 16384 \
   --concurrency 1,2,4,8 --concurrency-runs 1 --extra-body '{"chat_template_kwargs":{"reasoning_effort":"low"}}' --label SparkQwen-RC16 --output $O/rigmark-RC16.json > $O/rigmark-RC16.log 2>&1)
sed -n '/R I G M A R K/,$p' $O/rigmark-RC16.log | grep -E "GATES|CODE|PROSE|STRUCT|PREFILL|AGGREGATE" | head -8 | tee -a $O/summary.out
docker logs atlas-sparkqwen-rank0 2>&1 | grep -c "Content-loop steer" | sed 's/^/steer log lines (8x32k): /' | tee -a $O/summary.out
log "## 4x262k"
serve 4x262k 4x262k
(cd $O && python3 $B/long_probe.py needle 2>&1 | tail -2; python3 $B/long_probe.py needle 2>&1 | tail -2; python3 $B/long_probe.py exhaust 2>&1 | tail -4) | tee long-4x262k.out | tee -a $O/summary.out
(cd $O && python3 $B/quality_probe.py RC16L 4 2>&1 | tail -2) | tee -a $O/summary.out
log "## 8x262k"
serve 8x262k 8x262k
(cd $O && python3 $B/long_probe.py needle 2>&1 | tail -2; python3 $B/long_probe.py exhaust 2>&1 | tail -4) | tee long-8x262k.out | tee -a $O/summary.out
(cd $O && python3 $B/agentic_probe.py RC16-8L 2>&1 | tail -1; python3 $B/quality_probe.py RC16-8L 4 2>&1 | tail -2; python3 $B/tool_probe.py RC16-8L 3 2>&1 | tail -1) | tee -a $O/summary.out
(cd $O && node $B/sd_bench.mjs RC16-8L structured,prose,code,json 8 2>&1 | tee sd-RC16-8L.out | grep C8) | tee -a $O/summary.out
(cd $R && ./start.sh stop > /dev/null 2>&1)
log "free: $(free -g | sed -n 2p)"
log RDONE
