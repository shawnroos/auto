#!/usr/bin/env python3
"""The closed set of backend ops — the single source of truth (KTD-2).

A step declares the operation it runs via ``invokes.backend_op``; the engine's
``dispatcher.dispatch_batch`` rejects any value OUTSIDE this set instead of
launching an agent against a misspelled/unknown op. Historically this frozenset
lived inline in ``lib/dispatcher.py``. v0.14.0 (U1, addressable-step-contents)
lifted it HERE so a second validator — ``lib/presets.py::validate_preset`` —
can check a preset's op against the SAME set without importing the dispatcher
(which pulls in the run-record and the whole dispatch surface).

This module is a pure-stdlib DAG LEAF: it imports NO sibling lib module (exactly
like ``workflow_validate`` and ``run_record_core`` are DAG roots). Both
``dispatcher.py`` and ``presets.py`` import THIS, so there is ONE definition;
``tests/unit/presets.test.sh`` asserts ``backend_ops.VALID_BACKEND_OPS ==
dispatcher.VALID_BACKEND_OPS`` (the symmetry test that proves the lift did not
drift the dispatch guard).
"""

from __future__ import annotations

# The four ops a V1 workflow/preset step may declare. Kept as a frozenset so
# membership is O(1) and the set is immutable (a consumer can't mutate the shared
# source of truth). Every shipped workflow's op is one of these four.
VALID_BACKEND_OPS = frozenset({"brainstorm", "do_step", "next_plan_step", "review"})
