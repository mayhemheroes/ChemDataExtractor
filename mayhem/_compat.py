# -*- coding: utf-8 -*-
"""Python 3.10+ compatibility shim for ChemDataExtractor 1.3.0 (additive; upstream untouched).

ChemDataExtractor 1.3.0 (2017) is Python-2 / early-Python-3 era code that imports the ABCs
(MutableSequence / MutableMapping / Sequence / ...) straight from ``collections``. Those aliases
were removed from ``collections`` in Python 3.10 and now live only in ``collections.abc``. The base
image ships CPython 3.13, so a bare ``from chemdataextractor import Document`` raises
``ImportError: cannot import name 'MutableSequence' from 'collections'``.

Rather than edit upstream files (the port must stay purely additive), we re-establish the old
aliases on the ``collections`` module *before* ChemDataExtractor is imported. Importing this module
first (the harness imports it; the pytest interpreter picks it up via the site-dir sitecustomize.py
that build.sh writes) makes the whole package importable unchanged.
"""
from __future__ import absolute_import

import collections
import collections.abc as _abc

_ALIASES = (
    "MutableSequence", "MutableMapping", "Sequence", "Mapping", "Set", "MutableSet",
    "Iterable", "Iterator", "Callable", "Hashable", "Container", "Sized",
    "KeysView", "ItemsView", "ValuesView",
)

for _name in _ALIASES:
    if not hasattr(collections, _name) and hasattr(_abc, _name):
        setattr(collections, _name, getattr(_abc, _name))
