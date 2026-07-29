# paxel-largerepo

Make [Paxel](https://paxel.ycombinator.com) complete on large repositories.

Three small, dependency-light bash tools that wrap the **official** YC uploader.
Nothing here forks or replaces Paxel's analysis — `paxel-run` downloads
`upload.sh` from YC at run time and execs it unmodified. These tools fix the
*inputs* so the run finishes.

```bash
git clone https://github.com/<you>/paxel-largerepo
export PATH="$PWD/paxel-largerepo/bin:$PATH"

paxel-preflight              # will my repo complete? what do I need to change?
paxel-run --shard            # run the official uploader with safe settings
```

---

## The failure modes

Found by **running** `upload.sh` on a real project (4,598 sessions + 521
subagents, 1,813 MB) — not by reading it. See
[`docs/RUN_LOG_2026-07-29.md`](docs/RUN_LOG_2026-07-29.md) for the full log,
including two claims the real run disproved.

### 1. ENOSPC in the merge step — the one that actually broke the run

```
Errno::ENOSPC: No space left on device @ dir_s_mkdir - /tmp/paxel-merged-…
/rails/lib/analyze_local_merge.rb:69 … merge_agent_sessions!
Analysis failed (exit code: 1)
```

The merge writes every session into container `/tmp`. The **Docker VM disk was
100% full (23.4/23.5 GB)** while the **host had 204 GB free**.

Every instinct points the wrong way: host `df` looks fine, memory looks fine, the
repo looks fine. The full disk is in a VM most users never inspect, and the error
lands ~4 steps into a job advertised at ~87 minutes.

`paxel-preflight` catches it by running `df` **inside** a throwaway container.

### 2. Unbounded per-session memory

The uploader's `docker run` passes **no `--memory` flag**, so the container
inherits the Docker Desktop default (commonly 2 GB). Transcript parsing is
whole-file, and JSON parsing costs several times the file size in RAM:

| transcript | peak RSS | multiplier |
|---|---|---|
| 185 MB (real) | 573 MB | 3.1× |
| 30 MB (synthetic) | 66 MB | 2.2× |

*Measured with `/usr/bin/time -l`, jq 1.7, macOS arm64.*

On a stock 2 GB Docker install, several large sessions in flight would be tight.
**Honest caveat:** at the 5.8 GB ceiling on the test machine this did *not* cause
the failure, and preflight correctly reports `ok` rather than manufacturing a
problem.

### What is NOT a bug (corrected after running it)

An earlier version of this README claimed `COMMIT_LIMIT=1000` silently truncated
history. Running it disproved that: the cap applies **inside the `--since`
window** (`git log -$COMMIT_LIMIT $since_flag`), and the true total is still
recorded separately via `git rev-list --count HEAD`. A repo only trips it with
>1,000 commits in the window. Preflight now models this correctly instead of
over-warning.

---

## The tools

### `paxel-preflight` — will this run succeed?

Read-only. No Docker, no network, no uploads. Measures your repo against the
stock limits and prints the exact overrides needed.

```
$ paxel-preflight
  git
    commits              : 1102
    COMMIT_LIMIT (1000)  : ✗ SILENT TRUNCATION — 102 commits dropped
  transcripts
    files                : 4578
    total                : 950.4 MB
    largest              : 184.9 MB
  memory
    docker ceiling       : 5.8 GB
    peak jq RSS (1 file) : 573.2 MB   [3.1x largest transcript]
    required             : 3.4 GB
    verdict              : ok

  ── RUN WITH THESE OVERRIDES ───────────
    export COMMIT_LIMIT=1302
```

`--json` for CI. Exit `0` = clear to run, `1` = will truncate or OOM, `2` = usage.

It only reports OOM risk when your *actual* Docker ceiling is too low — on a
5.8 GB machine it says `ok`, because it is.

### `paxel-chunk` — shard oversized transcripts

JSONL splits losslessly on line boundaries. Shards any transcript above
`--max-mb` into `<name>.partNNN.jsonl`, each carrying a `_paxel_shard`
provenance header.

**Never modifies or deletes originals.** There is deliberately no `--in-place`
flag — transcripts are your only record of a session.

```
$ paxel-chunk --transcript-dir ~/.claude/projects/<slug> --max-mb 25 --dry-run
  031a322f-…   184 MB  52688 lines -> 8 shards
  4108a460-…   172 MB  49261 lines -> 7 shards
  scanned : 4578 transcripts
  sharded : 4  (produced 19 shards)
```

Verified byte-identical: strip the provenance lines, concatenate the shards, and
the SHA-256 matches the original exactly (covered by the test suite).

Effect on memory — same file, before and after:

```
whole 30 MB file    -> 66.1 MB peak RSS
largest 4.4 MB shard -> 11.4 MB peak RSS      (5.8x reduction)
```

### `paxel-run` — the official uploader, with safe settings

Thin wrapper. Preflights, derives `COMMIT_LIMIT` from your actual commit count,
raises `PAXEL_GIT_TIMEOUT`, optionally shards, then downloads and execs YC's
`upload.sh` **unmodified**. It prints the downloaded script's size and SHA-256
before running it, and refuses anything that isn't a bash script.

```bash
paxel-run --dry-run     # preflight + print the exact command, execute nothing
paxel-run --shard       # do it for real
```

It does not change what is uploaded, redacted, or scored — that stays entirely
YC's logic.

---

## Install

```bash
git clone https://github.com/<you>/paxel-largerepo
export PATH="$PWD/paxel-largerepo/bin:$PATH"   # or symlink into ~/.local/bin
```

Requires `bash`, `git`, `jq`, `curl`; `docker` only for the actual upload.
No language runtime, no package manager, no install step.

## Tests

```bash
./test/run_tests.sh      # 14 tests, no network, no Docker, no uploads
```

Covers the lossless round-trip, originals-untouched, shard validity, provenance
headers, size caps, idempotency, truncation detection, and JSON output validity.

## Suggested upstream fixes

If YC wants to fix this in `upload.sh` directly, the two minimal changes are:

1. **Warn on truncation.** When `rev-list --count` exceeds `COMMIT_LIMIT`, print
   the number of dropped commits and mark the report partial. A wrong report is
   worse than a slow one.
2. **Pass an explicit `--memory` to `docker run`,** sized from the largest
   transcript rather than inherited from the host default — and stream transcript
   parsing instead of whole-file slurping.

Neither requires the tools in this repo; they'd make it unnecessary.

## License

MIT
