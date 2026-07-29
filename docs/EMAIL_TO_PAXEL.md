# Email to the Paxel team

Every claim below was verified by running the tool, not by reading it. Where the
real run disproved something I'd inferred from the source, the email says so —
that honesty is what makes the remaining findings worth their attention.

**To:** paxel@ycombinator.com

---

**Subject:** upload.sh dies with ENOSPC on large session sets — repro, root cause, and a preflight tool

---

Hi Paxel team,

I ran `upload.sh` on a large project, it failed partway through, and I dug into
why. Sending the findings in case they're useful — one is a real bug with an easy
fix, and I've open-sourced the preflight tool I built while debugging it.

Setup: 4,598 sessions + 521 subagents (1,813 MB as your uploader reports it),
1,102-commit repo. macOS arm64, Docker 29.5.2. Tested against `upload.sh` sha256
`b87487fc7bc420e88ff4baeae4956cb6e2a7b053e44b42f20a3527476733bf74`.

## The bug: ENOSPC in the merge step, ~4 steps into an 87-minute job

```
Preparing local database...
bin/rails aborted!
Errno::ENOSPC: No space left on device @ dir_s_mkdir - /tmp/paxel-merged-ea089dce
/rails/lib/analyze_local_merge.rb:69:in 'block in AnalyzeLocalMerge.merge_agent_sessions!'
Analysis failed for aaquant (exit code: 1).
```

`merge_agent_sessions!` writes every session into container `/tmp`. My Docker VM's
disk was **23.4 GB of 23.5 GB used (100%)** — while the **host had 204 GB free**.

What makes this a bad failure mode isn't the error, it's that every instinct
points the wrong way. `df` on the host shows plenty of room. Memory is fine. The
repo is fine. The full disk is inside a VM most users never inspect, and the
failure lands deep into a job advertised at ~87 minutes.

Fix on my side was `docker image prune -af --filter until=24h && docker builder
prune -af` — reclaimed 5.6 GB, and the rerun got past the merge and completed.

**Suggested fix:** before the merge, check free space in the container and fail
fast with the numbers. Something like *"needs ~1.4 GB in container /tmp, 0 B
available — try `docker image prune -af`"*. Failing in 2 seconds with a remedy
beats failing in 20 minutes with a Ruby backtrace. A related symptom: the image
pull failed on the same full disk but reported `Using cached image (pull failed,
may be offline)` — blaming the network for a disk problem.

## Two smaller things

**Memory isn't bounded.** `docker run` is invoked with no `--memory`, so the
container takes the Docker Desktop default (commonly 2 GB). Transcript parsing
looks whole-file; I measured a 185 MB transcript costing **573 MB peak RSS**
(3.1×, `/usr/bin/time -l`, jq 1.7). At a 5.8 GB ceiling this was fine and did
*not* cause my failure — but on a stock 2 GB Docker install, several large
sessions in flight would be tight. An explicit `--memory` sized from the largest
transcript, or streaming instead of slurping, would close it.

**The time estimate ignores cache state.** "~87 minutes" appears to key off
session count alone, though your own output notes reruns typically hit 95%+ cache
and "finish in minutes". It's minor, but it's what made a slow run
indistinguishable from a wedged one — which is what sent me digging.

## One thing I got wrong, in case it saves you time

Reading the source first, I thought `COMMIT_LIMIT=1000` was silently truncating
history on repos with more commits. Running it showed that's wrong on two counts,
and I'd rather correct it than have you chase it:

1. The cap applies **inside the `--since` window** (`git log -$COMMIT_LIMIT
   $since_flag`), not to all history. Your run reported "382 author-filtered
   commits" — exactly my repo's 30-day count, not its 1,102 total. A repo only
   trips the cap with >1,000 commits in the window.
2. The true total **is** still recorded — `git rev-list --count HEAD >
   ..._commit_count.txt` runs right above it. The numstat *detail* is capped; the
   commit *count* isn't.

So: not a bug. My preflight tool now models the window correctly instead of
over-warning.

## The tool

https://github.com/abhinaykrupa/paxel-largerepo — MIT, 15 tests, CI on Ubuntu +
macOS.

- `paxel-preflight` — read-only. Checks container disk (via `df` inside a
  throwaway container), memory headroom, and the commit cap against the `--since`
  window. Prints the exact remedy. `--json` for CI.
- `paxel-chunk` — shards oversized JSONL transcripts on line boundaries with a
  provenance header. Byte-identical round-trip is asserted in the suite; never
  modifies originals.
- `paxel-run` — thin wrapper: preflight, set overrides, then download your
  `upload.sh` and exec it **unmodified**. It changes nothing about what's
  uploaded, redacted, or scored.

This is a workaround, not a competing tool. If you add the pre-merge disk check
upstream, most of it becomes unnecessary and I'll happily archive it. Happy to
open a PR against `upload.sh` instead if you'd prefer the fix directly — just
point me at the repo.

Thanks for building this. The analysis is genuinely good once it gets through.

Best,
Abhi Gadikoppula
github.com/abhinaykrupa
