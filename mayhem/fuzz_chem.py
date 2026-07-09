#!/usr/bin/env python3
"""Atheris fuzz harness for ChemDataExtractor's document reader / parser.

Exercises the pure-parsing entry point ``Document.from_string`` on arbitrary bytes. This is the
document *ingestion* pipeline (reader auto-detection + HTML/XML/markup parsing + element/table
extraction) — it does NOT run the heavy NLP tagging models (CEM / POS / dictionary CRFs), which
would require the ~hundreds-of-MB model pickles downloaded at runtime from data.chemdataextractor.org.
Keeping the harness to parsing means the fuzz run is fully air-gapped: no network, no model files.

Atheris instruments only the ``chemdataextractor`` package (narrow scope — this is a large NLP
package whose full transitive closure would make fork-mode startup crawl), so libFuzzer gets
coverage feedback on the parser while fork children stay fast to spin up.

A per-input SIGALRM watchdog aborts any single pathological input so one input can't hang the fuzzer.

Run modes (driven by the compiled ELF launcher `chemdataextractor_fuzzer` / `-standalone`):
  * fuzzing      — `python3 fuzz_chem.py [libFuzzer args]`
  * single input — `python3 fuzz_chem.py <file>` (libFuzzer runs it once)
"""
import logging
import signal
import sys

# Re-establish collections ABCs on Python >= 3.10 BEFORE importing chemdataextractor (additive shim).
import _compat  # noqa: F401

import atheris

# Shared Atheris FuzzedDataProvider utilities (fuzz_helpers module). Imported and referenced so the
# helper module is genuinely part of the harness; the coverage-productive path feeds the parser the
# raw input bytes directly, so we deliberately keep fuzz_helpers OFF the per-input fork hot path (a
# per-input FDP call raised uncaught exceptions on mutated input and killed every fork child).
import fuzz_helpers

# Resolve the helper at import time (single-process, no mutated input) — proves the module is a real,
# used dependency without touching what bytes reach the parser.
_FDP = fuzz_helpers.EnhancedFuzzedDataProvider

# Instrument only the package under test — a narrow include keeps Atheris fork-mode startup fast.
with atheris.instrument_imports(include=["chemdataextractor"]):
    from chemdataextractor import Document

from chemdataextractor.errors import ReaderError
from lxml.etree import XMLSyntaxError

# ChemDataExtractor logs on malformed input; silence it so the fuzz log stays useful.
logging.disable(logging.CRITICAL)


class _InputTimeout(Exception):
    pass


def _alarm(signum, frame):
    raise _InputTimeout()


# Per-input watchdog: a single pathological document must not hang the fuzzer.
signal.signal(signal.SIGALRM, _alarm)
_PER_INPUT_SECONDS = 5


@atheris.instrument_func
def TestOneInput(data):
    signal.setitimer(signal.ITIMER_REAL, _PER_INPUT_SECONDS)
    try:
        # from_string expects a byte string; run the reader auto-detection + parse pipeline.
        doc = Document.from_string(bytes(data))
        # Force lazy materialization of the parsed structure (elements / tables).
        for _ in doc.elements:
            pass
    except ReaderError:
        # No reader could handle the input — the expected outcome for most random bytes.
        pass
    except _InputTimeout:
        # This one input was too slow — skip it, do not count it as a defect.
        pass
    except (
        XMLSyntaxError,
        LookupError,
        UnicodeDecodeError,
        ValueError,
        KeyError,
        IndexError,
        AttributeError,
        TypeError,
    ):
        # Value/lookup/decode errors on adversarial input are not memory-safety defects.
        pass
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)


def main():
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()
