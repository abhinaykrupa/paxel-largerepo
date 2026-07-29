#!/usr/bin/env bash
# Test suite for paxel-largerepo. No network, no Docker, no uploads.
# Everything runs in a temp dir and is torn down afterwards.
set -Euo pipefail   # NOT -e: a failing check must record and continue

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/../bin"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

_sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d" " -f1;
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d" " -f1;
  else echo "no sha256 tool (need shasum or sha256sum)" >&2; return 1; fi; }

pass=0; fail=0
ok()   { printf '  ✓ %s\n' "$1"; pass=$((pass+1)) || true; }
bad()  { printf '  ✗ %s\n' "$1"; fail=$((fail+1)) || true; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want=$3 got=$2)"; fi }

echo "paxel-largerepo test suite"
echo

# ── fixtures ─────────────────────────────────────────────────────────────────
mkdir -p "$TMP/tdir"
python3 - "$TMP/tdir" <<'PY'
import json,sys,os
d=sys.argv[1]
# one big transcript (shardable) and one small (must be left alone)
with open(os.path.join(d,"big.jsonl"),"w") as f:
    for i in range(20000):
        f.write(json.dumps({"i":i,"text":"y"*500})+"\n")
with open(os.path.join(d,"small.jsonl"),"w") as f:
    for i in range(10):
        f.write(json.dumps({"i":i,"text":"tiny"})+"\n")
PY

echo "paxel-chunk"

# 1. dry-run writes nothing
"$BIN/paxel-chunk" --transcript-dir "$TMP/tdir" --out "$TMP/out1" --max-mb 2 --dry-run >/dev/null 2>&1
check "dry-run creates no output dir" "$([ -d "$TMP/out1" ] && echo yes || echo no)" "no"

# 2. shards are produced for the big file
"$BIN/paxel-chunk" --transcript-dir "$TMP/tdir" --out "$TMP/out" --max-mb 2 >/dev/null 2>&1
n=$(find "$TMP/out" -maxdepth 1 -name 'big.part*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
[ "$n" -gt 1 ] && ok "big transcript sharded into $n parts" || bad "expected >1 shard, got $n"

# 3. small file is NOT sharded
s=$(find "$TMP/out" -maxdepth 1 -name 'small.part*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
check "small transcript left alone" "$s" "0"

# 4. originals untouched (the safety property that matters most)
check "original still present" "$([ -f "$TMP/tdir/big.jsonl" ] && echo yes || echo no)" "yes"
orig_sha=$(_sha256 < "$TMP/tdir/big.jsonl")

# 5. LOSSLESS: strip provenance, reassemble, compare bytes
for f in "$TMP/out"/big.part*.jsonl; do grep -v '"_paxel_shard"' "$f"; done > "$TMP/rebuilt.jsonl"
rb_sha=$(_sha256 < "$TMP/rebuilt.jsonl")
check "round-trip is byte-identical" "$rb_sha" "$orig_sha"

# 6. every shard is valid JSONL
badj=0
for f in "$TMP/out"/big.part*.jsonl; do jq -e . "$f" >/dev/null 2>&1 || badj=$((badj+1)); done
check "all shards parse as JSONL" "$badj" "0"

# 7. provenance header present and well-formed on every shard
noprov=0
for f in "$TMP/out"/big.part*.jsonl; do
  head -1 "$f" | jq -e '._paxel_shard.source and (._paxel_shard.shard|type=="number")' >/dev/null 2>&1 || noprov=$((noprov+1))
done
check "every shard carries provenance" "$noprov" "0"

# 8. no shard exceeds the cap (with header overhead tolerance)
overs=0; cap=$((2*1024*1024*12/10))
for f in "$TMP/out"/big.part*.jsonl; do
  sz=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f"); [ "$sz" -gt "$cap" ] && overs=$((overs+1))
done
check "no shard blows the size cap" "$overs" "0"

# 9. idempotent — a second run does not double-shard
"$BIN/paxel-chunk" --transcript-dir "$TMP/tdir" --out "$TMP/out" --max-mb 2 >/dev/null 2>&1
n2=$(find "$TMP/out" -maxdepth 1 -name 'big.part*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
check "re-run is idempotent" "$n2" "$n"

echo
echo "paxel-preflight"

# 10. runs clean on a small repo and reports no truncation
mkdir -p "$TMP/repo" && cd "$TMP/repo"
git init -q -b main; git config user.email t@t.t; git config user.name t
echo hi > a.txt; git add a.txt; git commit -qm "init"
out=$(PAXEL_TRANSCRIPT_DIR="$TMP/tdir" "$BIN/paxel-preflight" --repo "$TMP/repo" 2>&1) && rc=0 || rc=$?
check "small repo exits 0 (clear to run)" "$rc" "0"
echo "$out" | grep -q "clear to run" && ok "prints clear-to-run verdict" || bad "missing clear-to-run verdict"

# 11. JSON mode is valid JSON
PAXEL_TRANSCRIPT_DIR="$TMP/tdir" "$BIN/paxel-preflight" --repo "$TMP/repo" --json 2>/dev/null | jq -e . >/dev/null 2>&1 \
  && ok "--json emits valid JSON" || bad "--json output is not valid JSON"

# 12. truncation is detected when commits exceed the cap
out2=$(PAXEL_TRANSCRIPT_DIR="$TMP/tdir" STOCK_COMMIT_LIMIT=0 "$BIN/paxel-preflight" --repo "$TMP/repo" 2>&1) || true
echo "$out2" | grep -q "SILENT TRUNCATION" && ok "detects commit truncation" || bad "failed to detect truncation"

# 13. non-repo is rejected cleanly
PAXEL_TRANSCRIPT_DIR="$TMP/tdir" "$BIN/paxel-preflight" --repo "$TMP" >/dev/null 2>&1 && rc2=0 || rc2=$?
check "non-git path exits 2" "$rc2" "2"

echo
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
