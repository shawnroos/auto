#!/usr/bin/env python3
"""The closed set of adapter ops — the single source of truth (KTD-2).

A unit declares the operation it runs via ``invokes.adapter_op``; the engine's
``orchestrator.dispatch_batch`` rejects any value OUTSIDE this set instead of
launching an agent against a misspelled/unknown op. Historically this frozenset
lived inline in ``lib/orchestrator.py``. v0.14.0 (U1, addressable-step-contents)
lifted it HERE so a second validator — ``lib/presets.py::validate_preset`` —
can check a preset's op against the SAME set without importing the orchestrator
(which pulls in the ledger and the whole dispatch surface).

This module is a pure-stdlib DAG LEAF: it imports NO sibling lib module (exactly
like ``recipe_validate`` and ``ledger_core`` are DAG roots). Both
``orchestrator.py`` and ``presets.py`` import THIS, so there is ONE definition;
``tests/unit/presets.test.sh`` asserts ``adapter_ops.VALID_ADAPTER_OPS ==
orchestrator.VALID_ADAPTER_OPS`` (the symmetry test that proves the lift did not
drift the dispatch guard).
"""

from __future__ import annotations

# The four ops a V1 recipe/preset unit may declare. Kept as a frozenset so
# membership is O(1) and the set is immutable (a consumer can't mutate the shared
# source of truth). Every shipped recipe's op is one of these four.
VALID_ADAPTER_OPS = frozenset({"brainstorm", "do_unit", "next_plan_step", "review"})
