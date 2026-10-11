<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# RC16 on two Sparks (2026-10-10)

The engine `install/atlas-source.json` pins (Enntity/atlas
`sparkqwen/atlas-20261010-rc16`, 1c43247d), measured on our pair (two GB10,
one 200G RoCE cable, TP=EP=2) through the recipe's own image: `git clone` of
this repository's `rc16` branch, `.env` with `WORKER` and `MODEL_ROOT`, then
`./start.sh`, which built `ghcr.io/enntity/atlas-sparkqwen:656234c336af` (the
`install/` tree) from the pinned commit and served each profile in turn
(`raw/recipe/`, driven by `raw/dev/round_rc16.sh`). Checkpoint
`nvidia/Qwen3.8-Flash-Next-NVFP4` @ fc694b54. Single-session measurements on
our pair, not a guarantee.

RC16 is RC15 plus content-loop steering (`ATLAS_LOOP_STEER=1`, on in every
profile), a Poolside stream fix that does not touch this model's serving, and
a formatting fix. vLLM was not re-run: its two runs on the same pair are in
[2026-10-08-rc15](../2026-10-08-rc15/RESULT.md).

## What changed: content-loop steering

At temperature 0 the model can fall into a repetition attractor. In RC15 one
of RigMark's three greedy code runs wrote `0, 0, 0, ...` into a Go test table
until the content-loop watchdog cut the response (finish reason `length`), so
that gate scored 2/3. With steering, the pick right after a loop tail the
watchdog would cut never takes the token that continues the cycle (at most 3
times a request; then loops end as before). The same run (RigMark replays the
same prompts for the same comparison id) now writes its 32 zeros, steps off
with `3 * time.Second}`, and finishes normally (`raw/recipe/rigmark-RC16.json`,
code run 3, finish `stop`). Nothing is rolled back or held back from the
stream, and output that never loops is unchanged: the exactness checks below
pass with steering on.

## Exactness

8 prompts, thinking on (reasoning effort low), greedy, 320 tokens
(`bench/greedy_eq.py`, `raw/recipe/exact/`). Reference: the recipe image with
a copy of the `8x32k` profile without prefix caching and speculation, one
request at a time. Against it, the default profile (speculation, prefix
caching and steering on):

| | 1 at a time | 4 at a time | 8 at a time |
|---|---|---|---|
| Plain prompts | 8/8 identical | 8/8 identical | 8/8 identical |
| Behind a shared ~4.4K-token prefix, every request a cache hit | 8/8 identical | 8/8 identical | 8/8 identical |

The reference texts equal RC15's (the same hashes, 8199ce ... 1c6136). The
development binary of the same commit also matched RC15's references with
steering off and on (`raw/dev/round_steer.out`). Concurrency crash gates pass
(`raw/recipe/crash-probes.out`).

## RigMark

[RigMark](https://github.com/alexellis/rigmark) (MIT) at 40fabca, the same
settings and comparison id as RC15 (`raw/recipe/rigmark-RC16.json`; appliance
metadata in `metadata-sq.json`).

| | RC16 | RC15 | vLLM v0.30 (2026-10-08) |
|---|---|---|---|
| Output gates | **9/9** | 8/9 (code 2/3) | 9/9 |
| Decode estimate, code / prose / structured | 86.6 / 51.8 / 98.9 tok/s | 84.6 / 51.7 / 98.8 | 68.0 / 44.4 / 76.0 |
| 16K cold prefill | 4,043 tok/s | 4,049 | 3,516 |
| Concurrency, C1 / C2 / C4 / C8 | 61.7 / 98.6 / 166.2 / 260.1 tok/s | 61.6 / 97.5 / 165.6 / 261.1 | 57.1 / 99.0 / 163.9 / 255.0 |

## Decode: sparkDash protocol

MiaAI-Lab's sparkDash prompts (MIT), thinking off, temperature 0, 400 forced
tokens, aggregate tok/s (`raw/recipe/sd-RC16.json`, `sd-RC16-8L.json`).

| | structured | prose | code | json |
|---|---|---|---|---|
| C1 | 102.0 | 72.7 | 93.8 | 84.5 |
| C2 | 165.1 | 112.5 | 147.9 | 141.4 |
| C4 | 251.0 | 170.5 | 214.3 | 217.7 |
| C8 | 389.1 | 260.3 | 296.9 | 333.0 |
| C8, `8x262k` | 387.6 | 257.1 | 294.1 | 331.7 |

Within run-to-run noise of RC15 (C8 389.6 / 261.1 / 297.1 / 333.1): steering
costs nothing measurable.

## Tool calling

`bench/tool_probe.py`: OpenAI `tools` end to end, seven cases (one call with a
string and an enum argument; integer arguments as JSON numbers; two parallel
calls; a tool result in and a final answer out; tools offered but none
needed; `tool_choice: "none"`; the first case streamed), each greedy once and
with the model's default sampling four more times. 35/35 on `8x32k` and 35/35
on `8x262k` (`raw/recipe/tools-RC16-*.json`); the development run also scored
35/35 (`raw/dev/steer/tools-RC16.json`). Calls are parsed in the checkpoint's
own `<tool_call><function=…>` format (Atlas's `qwen3_coder` parser).

## Prefill, quality, long context, agents, memory

- Cold time to first token (`raw/recipe/bench-RC16.json`, median of 2): 0.73 s
  at 2K, 2.08 s at 8K, 4.11 s at 16K, 7.32 s at 28K tokens. Warm turns
  0.16-0.21 s.
- Quality probe: 40/40 and 12/12 on `8x32k`, `4x262k` and `8x262k`.
- 77K needle, cold: 21.1 s and 57.6 tok/s (`4x262k`), 21.0 s and 57.4 tok/s
  (`8x262k`); follow-up turns 0.2-0.3 s; four concurrent 100K prompts all
  answered on both (`raw/recipe/long-*.out`).
- Agents (4 conversations of 5 turns over a shared ~20K system prompt): 20/20
  on both profiles; first turns 6.0-11.7 s, later turns median 0.48 s
  (`8x32k`) and 0.46 s (`8x262k`).
- KV pools (`raw/recipe/kvpool-*.out`): 3,265,104 tokens (`8x32k`), 3,355,520
  (`4x262k`), 3,187,216 (`8x262k`); 14-16 GiB MemAvailable after start.

## Files

Host names, cable addresses, user names and absolute home paths in `raw/` are
replaced with placeholders; the files are otherwise as written.
`raw/recipe/summary.out` is the round's own log. `raw/dev/` holds the
development-binary round that gated the release (RC15 environment plus
`ATLAS_LOOP_STEER=1`, `raw/dev/steer-on.list`). The two long-context logs were
written next to the clone rather than into `receipts/` by the round script and
were copied in afterwards. `SHA256SUMS` covers every file in `raw/`.
