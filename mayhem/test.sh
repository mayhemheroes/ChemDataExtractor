#!/usr/bin/env bash
#
# mayhem/test.sh — RUN ChemDataExtractor's own test suite (deps already installed by build.sh) and
# emit a CTRF (ctrf.io) summary. exit 0 iff failed==0. PATCH-grade oracle: these are the project's
# behavioral unittest assertions (text normalization, HTML/XML Selector + Cleaner output, the data
# model, BibTeX parsing, the chemistry word-tokenizer), so a no-op patch that neuters the library
# FAILS here (anti-reward-hacking).
#
# Only the OFFLINE test files run — the ones that exercise parsing/text/scrape/model/tokenize and do
# NOT need the ~hundreds-of-MB NLP model pickles from data.chemdataextractor.org. The three *sentence*
# tests in test_nlp_tokenize load the punkt sentence model, so they are deselected (-k 'not sentence');
# the word/chem tokenizer tests remain.
#
# It does NOT compile — build.sh installed pytest + deps and compiled chemdataextractor_run_tests. The
# suite runs through that compiled NON-system wrapper so the gate's sabotage check bites. The
# collections-ABC compat shim is installed by the site-dir sitecustomize.py (see build.sh), so
# chemdataextractor imports on Python 3.13 with no upstream/root edit.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"

SRC="${SRC:-/mayhem}"
cd "$SRC"

PY_PREFIX=/opt/toolchains/python
# shellcheck disable=SC1091
[ -f "$PY_PREFIX/env.sh" ] && source "$PY_PREFIX/env.sh"
export PYTHONPATH="$PY_PREFIX/site:$SRC:$SRC/mayhem${PYTHONPATH:+:$PYTHONPATH}"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

RUNNER="$SRC/chemdataextractor_run_tests"
if [ ! -x "$RUNNER" ]; then
  echo "test.sh: $RUNNER missing/not executable — mayhem/build.sh must build it first" >&2
  emit_ctrf "pytest" 0 1 0
  exit 1
fi

TESTS=(
  tests/test_text.py
  tests/test_scrape_selector.py
  tests/test_scrape_clean.py
  tests/test_model.py
  tests/test_biblio.py
  tests/test_nlp_tokenize.py
)

LOG="$(mktemp)"
"$RUNNER" -p no:cacheprovider -o addopts= -k 'not sentence' -q "${TESTS[@]}" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

line="$(grep -E '^(=+ )?[0-9].*(passed|failed|error|skipped)' "$LOG" | tail -1)"
get() { echo "$line" | grep -oE "[0-9]+ $1" | grep -oE '^[0-9]+' | head -1; }
passed="$(get passed)";  passed="${passed:-0}"
failed="$(get failed)";  failed="${failed:-0}"
errors="$(get error)";   errors="${errors:-0}"
skipped="$(get skipped)"; skipped="${skipped:-0}"
rm -f "$LOG"

failed=$(( failed + errors ))

if [ "$(( passed + failed + skipped ))" -eq 0 ] && [ "$rc" -ne 0 ]; then
  emit_ctrf "pytest" 0 1 0
  exit 1
fi

emit_ctrf "pytest" "$passed" "$failed" "$skipped"
