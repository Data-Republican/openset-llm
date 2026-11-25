# bench — the harness behind the README numbers

The scripts that produced the benchmark tables in the top-level `README.md` (runs of 2026-11-11 and 2026-11-12): bare install of this package,
ik_llama.cpp and PrismML's fork built at pinned commits, every arm interleaved on the same box, and one analysis
script that prints the tables. Raw logs are not in this repo.

You need one or more x86 Linux boxes with AVX-512 (we used cloud boxes: 8 vCPU / 8 GB Ice Lake VMs, and an 8 vCPU / 16 GB
AMD EPYC 9354P box), sudo or root, ~15 GB of free disk, and a few hours per box. Compare arms only within one box.

**Just want a number from your own machine?** `./bench/quick.sh` (add `--plain` for plain decoding too): it starts its
own server, runs 6 of the prompts below at 128 tokens and prints a block you can paste into an issue. A few minutes, no
sudo, no rivals. The rest of this page is the full harness.

## Run it

1. **On each box, put this package at `~/release`** (a clean checkout of the commit you test; `bench/` is inside it).
   Optional: an older build of this package at `~/release-prev` for the new-vs-earlier arms (`prev*`; our own
   earlier build was never published, so these arms are for comparing your own versions).
2. **Set up** (logs in `~/res/setup.log`, `install.log`, `box.txt`):
   ```sh
   bash ~/release/bench/box.sh setup rivals prev ppl   # any subset; "setup" alone = ./install.sh as a user runs it
   ```
   `rivals` builds ik_llama.cpp and PrismML at `IK_SHA` / `PRISM_SHA` (defaults: their 2026-11-10 HEADs) into `/opt`;
   `prev` installs `~/release-prev` side by side in `~/.prev`; `ppl` builds `llama-perplexity` and fetches WikiText-2.
   On a root container with a cgroup CPU limit and a small disk, the model download is staged in a RAM tmpfs (10 GB disk).
3. **Measure**, detached (each phase writes `~/res/<phase>/` and a `DONE.<phase>` marker; a re-run skips finished
   phases and resumes row by row; the phase list is in the header of `jobs.sh`):
   ```sh
   setsid nohup bash ~/release/bench/jobs.sh lb short 1 ctx il1 short2 1 lbprev multi > /dev/null 2>&1 &
   ```
   What we ran: Ice Lake bench boxes `lb short <seed> ctx il1|il2 short2 <seed> lbprev multi replay 6
   ours,ours_nr,prev_ns,ik,prism lbmore`; Zen 4 `lb short 3 ctx zen short2 3 lbprev replay 0 ours,ours_nr replay 6
   prev,prev_ns,ik,prism lbmore ctx zen2`; identity / quality box `ident24 diag lp ppl kld quality kld2`.
   `replay` takes two arguments: the number of steps (0 = all) and the arms, comma-separated (names in
   `arms_replay.json`). Plans `plan_<name>.jsonl` choose the long-context cells per box.
4. **Collect** each box's `~/res` into `raw/<box>/` on your machine (`tar czf res.tgz res` on the box, copy, extract).
   `analyze.py` maps box names to CPU classes in `CLASS` at the top: name the folders `e1`, `e2`, `e3` (Ice Lake) and
   `d1` (Zen 4), or edit that map.
5. **Tables:** `python3 bench/analyze.py raw > tables.md` (also writes `headline.json`). Every ratio is paired per
   prompt, round or replay step on one box; CIs are percentile bootstraps of the median.

## Files

| file | what |
|---|---|
| `box.sh`, `jobs.sh` | box setup; the measurement phases |
| `bench2.py` | server benchmark: arms as sequential llama-servers, blocks of prompts, arm order reshuffled per block |
| `ctxrun.py`, `plan_*.jsonl`, `ctx_prompts.json` | long-context runner; per-box plans; WikiText haystacks with planted facts |
| `rrun.py`, `arms_replay.json` | agent replay (16k context, 64 tokens per step) |
| `multi.py` | `serve --multi 4`: aggregate tok/s and per-stream identity |
| `lp.py`, `prompts_diag.jsonl`, `arms_diag.json` | top-2 logprobs at each token (how near a tie a divergence is) |
| `evaluate.py`, `gsm8k.jsonl`, `problems_q160.jsonl`, `arms_quality.json` | quality gate: GSM8K-40 and 160 HumanEval + MBPP problems; the grader runs generated code, so run it on a throwaway box |
| `prompts24.jsonl`, `arms_short.json`, `arms_ctx.json` | the 24 benchmark prompts; arms (`@H@` = `$HOME`, `@C@` = context size) |
| `analyze.py` | every table |

## Not included

- **The agent-replay input** (`replay.json`, a recorded coding-agent session; it contains the files of the repository
  it was recorded on). Pass your own with `REPLAY=<file>`: `{"tools": [...], "requests": [{"step": n, "messages":
  [...]}, ...]}` in OpenAI chat format. To send rivals exactly the same tokens, render them once on our server with
  `rrun.py --dump-tokens tokens.json` and pass `REPLAY_TOKENS=tokens.json`.
- **The 128-prompt broad set** behind the identity counts (`BROAD=<file>`, same format as `prompts24.jsonl`).
- Raw logs of our runs.
