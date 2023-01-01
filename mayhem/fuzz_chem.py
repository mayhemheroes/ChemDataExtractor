#!/usr/bin/env python3

import atheris
import sys


import fuzz_helpers

with atheris.instrument_imports(include=['chemdataextractor']):
    from chemdataextractor import Document

from lxml.etree import XMLSyntaxError

from chemdataextractor.errors import ReaderError


def TestOneInput(data):
    fdp = fuzz_helpers.EnhancedFuzzedDataProvider(data)
    try:
        with fdp.ConsumeMemoryFile(as_bytes=True, all_data=True) as f:
            Document.from_file(f)
    except (XMLSyntaxError, LookupError, UnicodeDecodeError, ReaderError):
        return -1

def main():
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()
