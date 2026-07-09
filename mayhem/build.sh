#!/usr/bin/env bash
#
# mayhem/build.sh — build the ChemDataExtractor Atheris fuzz harness + its standalone reproducer,
# and prepare the project's own test suite. Runs inside the commit image (mayhem/Dockerfile) as
# `mayhem` in /mayhem. Python adaptation of the C/C++ template (see checkouts/python-fitparse).
#
# Idempotent + air-gapped on re-run (SPEC §6.2 item 9 / §6.5):
#   1. Populate / reuse an in-image wheelhouse under /opt/toolchains/python (HOME-independent), then
#      install ChemDataExtractor's runtime deps + atheris + pytest OFFLINE into a fixed site dir on
#      PYTHONPATH. Deps notes:
#        * DAWG (upstream pin) has no cp313 wheel and its bundled Cython C references the removed
#          CPython longintrepr.h -> will NOT build on Python 3.13. DAWG2 is the maintained drop-in
#          fork: installs as the SAME `dawg` import module (dawg.CompletionDAWG) with a cp313 wheel.
#        * cssselect pinned <1.2.0 (matches the prior Mayhem integration).
#      ChemDataExtractor itself stays the editable source tree (repo root on PYTHONPATH).
#   2. Compile launcher.c -> ELF Mayhem target `chemdataextractor_fuzzer` (Atheris is a .py; Mayhem
#      needs an ELF cmd and the gate needs DWARF < 4 -> compiled wrapper).
#   3. Same launcher as the standalone (run-once) reproducer.
#   4. Compile the pytest ELF runner wrapper so the sabotage oracle bites.
#
# The base image exports the build contract (CC, SANITIZER_FLAGS, DEBUG_FLAGS, ...). The launcher is
# a thin C exec wrapper -- applying SANITIZER_FLAGS to it would just instrument the wrapper, not the
# fuzzed Python; Atheris instruments the chemdataextractor library itself at import time. So we only
# thread DEBUG_FLAGS (DWARF < 4) through the wrapper compiles; SANITIZER_FLAGS is intentionally not
# applied to the exec-only launcher.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
export DEBUG_FLAGS CC MAYHEM_JOBS

SRC="${SRC:-/mayhem}"
cd "$SRC"

PY_PREFIX=/opt/toolchains/python
WHEELHOUSE="$PY_PREFIX/wheelhouse"
SITE="$PY_PREFIX/site"
mkdir -p "$WHEELHOUSE" "$SITE"

PY="$(command -v python3)"

PKGS=(
  appdirs beautifulsoup4 click "cssselect<1.2.0" lxml nltk "pdfminer.six"
  python-crfsuite DAWG2 python-dateutil requests six PyYAML
  atheris pytest
)

# 1) Wheelhouse (online once; reused offline on re-run).
need_download=0
"$PY" -c "import os,glob,sys; sys.exit(0 if glob.glob(os.path.join('$WHEELHOUSE','atheris-*.whl')) else 1)" || need_download=1
if [ "$need_download" -eq 1 ]; then
  echo ">> populating wheelhouse (online) at $WHEELHOUSE"
  "$PY" -m pip download --dest "$WHEELHOUSE" "${PKGS[@]}"
else
  echo ">> wheelhouse already populated — reusing $WHEELHOUSE (air-gapped re-run path)"
fi

# 2) Install deps OFFLINE into the fixed site dir. Idempotent.
if "$PY" -c "import os,glob,sys; sys.exit(0 if (glob.glob(os.path.join('$SITE','atheris*')) and glob.glob(os.path.join('$SITE','dawg*'))) else 1)"; then
  echo ">> deps already installed in $SITE — skipping (idempotent re-run)"
else
  echo ">> installing deps (offline) into $SITE"
  "$PY" -m pip install --no-index --find-links="$WHEELHOUSE" --target "$SITE" "${PKGS[@]}"
fi

# chemdataextractor is a top-level package at the repo root; mayhem/ on the path too so _compat resolves.
PYRUN="$SITE:$SRC:$SRC/mayhem"

cat > "$PY_PREFIX/env.sh" <<EOF
export PYTHONPATH="$PYRUN\${PYTHONPATH:+:\$PYTHONPATH}"
export PYTHON_BIN="$PY"
EOF

# sitecustomize.py in the site dir: CPython auto-imports it at startup, so the pytest interpreter
# gets the collections-ABC compat shim before importing chemdataextractor. Keeps the port additive
# (no repo-root conftest.py, no upstream edit). The harness also imports _compat explicitly.
cat > "$SITE/sitecustomize.py" <<'PYEOF'
# Auto-imported by CPython at startup (site dir on PYTHONPATH). Installs the collections-ABC aliases
# ChemDataExtractor 1.3.0 needs on Python >= 3.10.
try:
    import _compat  # noqa: F401  (mayhem/_compat.py, also on PYTHONPATH)
except Exception:
    pass
PYEOF

# Sanity: harness imports resolve offline now (via the compat shim, on Python 3.13).
PYTHONPATH="$PYRUN" "$PY" -c 'import _compat; import atheris, dawg; from chemdataextractor import Document; print("imports OK: chemdataextractor Document + dawg", dawg.CompletionDAWG)'

# 3) Compile the ELF launcher target + standalone reproducer (DWARF < 4 via $DEBUG_FLAGS).
HARNESS="$SRC/mayhem/fuzz_chem.py"
echo ">> compiling chemdataextractor_fuzzer (+ standalone) with DEBUG_FLAGS=$DEBUG_FLAGS"
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" -DHARNESS="\"$HARNESS\"" \
    "$SRC/mayhem/launcher.c" -o "$SRC/chemdataextractor_fuzzer"
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" -DHARNESS="\"$HARNESS\"" \
    "$SRC/mayhem/launcher.c" -o "$SRC/chemdataextractor_fuzzer-standalone"

# 4) pytest ELF wrapper (NON-system binary so the sabotage check bites).
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" "$SRC/mayhem/run_tests.c" -o "$SRC/chemdataextractor_run_tests"

echo ">> build.sh complete"
ls -la "$SRC/chemdataextractor_fuzzer" "$SRC/chemdataextractor_fuzzer-standalone" "$SRC/chemdataextractor_run_tests"
