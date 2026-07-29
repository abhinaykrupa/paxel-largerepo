# Email to the Paxel team

Draft below. Two bug reports with reproductions, plus an MIT-licensed workaround
repo. Tone is "here's a bug and a reproduction," not "here's my replacement" —
the suggested upstream fixes would make the repo unnecessary, and the email says so.

---

**Subject:** Paxel silently truncates history >1000 commits (+ OOM on large transcripts) — repro + workaround

---

Hi Paxel team,

I hit two issues running `upload.sh` on a large project and wanted to send them
over with reproductions. One of them produces a wrong report rather than a failed
run, which seems worth prioritising.

My test case: 1,102 commits, 4,598 sessions + 521 subagents (1,813 MB as your
uploader reports it). Tested against `upload.sh` sha256 `b87487fc…33bf74`.

**1. Silent commit truncation — produces a wrong report, not a failed run**

`COMMIT_LIMIT` defaults to 1000. On a repo with more commits, the run analyzes
the newest 1,000, completes normally, and reports success. The remaining commits
are dropped with no warning in the output and nothing in the report indicating
history was cut.

On my repo that's 102 commits (9% of history) missing from a report that looks
complete. For a tool measuring engineering behavior over time, I think this is
worth a warning at minimum — a user currently has no way to know their report is
partial.

*Suggested fix:* compare `git rev-list --count HEAD` against `COMMIT_LIMIT`, and
if it exceeds, print the number of dropped commits and mark the report partial.

**2. Unbounded per-session memory → OOM kill mid-pipeline**

`docker run` is invoked without a `--memory` flag, so the container inherits the
Docker Desktop default (commonly 2 GB). Transcript parsing appears to be
whole-file, and JSON parsing costs several times file size in RAM. Measured with
`/usr/bin/time -l` (jq 1.7, macOS arm64):

    185 MB transcript  ->  573 MB peak RSS   (3.1x)

With several large sessions in flight this exceeds a 2 GB ceiling and the
container is killed partway through. The symptom is a run that dies mid-pipeline
with no error mentioning memory, which made it hard to diagnose.

*Suggested fix:* pass an explicit `--memory` sized from the largest transcript
found, and/or stream transcript parsing instead of slurping whole files.

**3. Smaller thing: the time estimate has no basis in the machine it's running on**

The run printed "Estimated time: ~87 minutes" for 4,598 sessions. That appears to
be a function of session count alone — it doesn't account for how much of the LLM
cache is already warm, which your own output says is the dominant factor
("reruns typically hit 95%+ cache and finish in minutes"). A first run and a
re-run of the same repo quote the same number. Not a bug, but it made it hard to
tell whether a long-running job was progressing or wedged, which is what prompted
me to start digging in the first place.

**Workaround I built**

https://github.com/abhinaykrupa/paxel-largerepo — MIT, 14 tests, CI on Ubuntu +
macOS.

Three bash tools that wrap the official uploader rather than forking it:

- `paxel-preflight` — read-only; measures a repo against both limits and prints
  the exact overrides needed. `--json` for CI.
- `paxel-chunk` — shards oversized JSONL transcripts on line boundaries with a
  provenance header. Byte-identical round-trip verified in the test suite; never
  modifies originals.
- `paxel-run` — derives `COMMIT_LIMIT` from the real commit count, raises
  `PAXEL_GIT_TIMEOUT`, optionally shards, then downloads your `upload.sh` and
  execs it **unmodified**. It changes nothing about what gets uploaded, redacted,
  or scored.

Measured effect of sharding on the same data: 66.1 MB → 11.4 MB peak RSS.

To be clear about intent — this is a workaround, not a competing tool. If you
fix the two items above upstream, my repo stops being necessary and I'll happily
archive it. Happy to open a PR against `upload.sh` instead if you'd prefer the
fixes directly; just point me at the right place.

Thanks for building this — the analysis output is genuinely useful once it
completes.

Best,
Abhi Gadikoppula
github.com/abhinaykrupa
