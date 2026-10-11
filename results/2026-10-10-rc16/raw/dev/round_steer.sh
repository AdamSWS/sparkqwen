#!/usr/bin/env bash
# round_steer.sh -- RC16 candidate (sparkqwen/int-20261008-rc16 1c43247d = RC15 + rc15-fixes + loop-steer) on the pair,
# RC15 environment. Needs the pair (01/02) and bin/spark-sqrc16c-1c43247d on both hosts. Prep from the Mac (01 cannot reach 03):
#   scp -3 <build-host>:atlas-builds/spark-sqrc16c-1c43247d <rank0-host>:sparkqwen-dev/bin/  (and <rank1-host>), chmod +x
# Fail fast:
#   1. steering OFF: greedy text identical to the RC15 references (the binary is RC15 + an inert switch);
#   2. steering ON: the same exactness checks (no loop in those prompts, so steering must stay inert),
#      plain at C4 and behind a cached ~4.4K prefix at C8;
#   3. RigMark decode only, RC15's comparison id (the same prompts, incl. code run 3 that looped): code gate;
#   4. sparkDash C8 code + structured: no throughput cost.
#   5. tool calling end to end (bench/tool_probe.py).
set -uo pipefail
cd ~/sparkqwen-dev; B=spark-sqrc16c-1c43247d; S7="--speculative --num-drafts 7"; W=<rank1-cable-ip>
G="python3 $HOME/sparkqwen-rc15/bench/greedy_eq.py"; R=~/sparkqwen-dev/steer; mkdir -p $R
stop() { docker rm -f atlas-sparkglm-rank0 >/dev/null 2>&1; ssh -n $W "docker rm -f atlas-sparkglm-rank1 >/dev/null 2>&1"; }
cp rc15.list steer-off.list; (cat rc15.list; echo ATLAS_LOOP_STEER=1) > steer-on.list
echo "## 1. steering OFF"
LP=0 SEQS=8 EXTRA="$S7" ENVF=steer-off.list bash go_sq_tp.sh SOFF $B none > SOFF.out 2>&1; grep -E "up after|FAILED" SOFF.out
(cd $R && $G run off4 4 && cp ~/sparkqwen-rc15/receipts/exact/greedy-REF1.json . && $G compare REF1 off4) | tail -2
stop
echo "## 2. steering ON: exactness"
LP=0 SEQS=8 EXTRA="$S7" ENVF=steer-on.list bash go_sq_tp.sh SON $B none > SON.out 2>&1; grep -E "up after|FAILED" SON.out
grep -m1 "content-loop steering armed" SON.rank0.log || echo "STEERING NOT ARMED"
(cd $R && cp ~/sparkqwen-rc15/receipts/exact/greedy-REFP1.json . && $G run on4 4 && $G run onp8 8 --prefix && $G compare REF1 on4 && $G compare REFP1 onp8) | tail -4
echo "## 3. RigMark decode, RC15 prompts"
(cd ~/rigmark && ./rigmark run --base-url http://127.0.0.1:8893 --model auto --metadata metadata-sq.json --comparison-id sparkqwen-rc15 --runs 3 \
   --skip-prefill --skip-concurrency --extra-body '{"chat_template_kwargs":{"reasoning_effort":"low"}}' --label SparkQwen-steer --output $R/rig-steer.json > $R/rig-steer.log 2>&1)
sed -n '/R I G M A R K/,$p' $R/rig-steer.log | grep -E "GATES|CODE|PROSE|STRUCT" | head -5
grep -c "Content-loop steer" SON.rank0.log
echo "## 4. sparkDash C8"
(cd ~/sparkqwen-rc15/bench && SPARKDASH_DIR=~/sparkDash node sd_bench.mjs STEER code,structured 8 2>&1 | grep C8)
echo "## 5. tool calling (OpenAI tools, 7 cases x 5 runs: greedy + 4 sampled)"
(cd $R && python3 ~/sparkqwen-rc15/bench/tool_probe.py RC16 5)
stop
echo SDONE
