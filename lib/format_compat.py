"""format-v1 → format-v2 compatibility shim — the ONE module that speaks both
vocabularies (concept-vocabulary rename, U6 / KTD-1).

U6 flips every persisted key and value on disk in a single atomic cutover:
``units``→``steps``, ``adapter``→``backend``, ``recipe``→``workflow``,
``seam``→``handoff``, ``emitter``→``producer``, ``do_unit``→``do_step``, … .
Records and workflow files written by pre-rename code stay v1 on disk **forever**
— a completed or abandoned run never mutates again, and auto never rewrites a
user's workflow file. This module maps v1 → v2 in memory at every read
chokepoint, so every other module in the tree speaks ONLY the new vocabulary.

DAG ROOT. Pure stdlib; imports no sibling. Wired into:
  * ``run_record_core._read_json``        — read_run_record + the locked RMW path
  * ``_bootstrap.load_run_record_safe``   — every hook and scan consumer
  * ``workflows.resolve``             — workflow-file reads, before validate()
  * ``workflow_validate.validate_and_lint`` — the authoring WRITE gate
  * ``presets.load_preset``               — hand-authored preset reads (the THIRD
    user-data chokepoint; without it a pre-rename preset does not degrade, it
    HARD-FAILS ``validate_preset`` and aborts ``/auto --preset <name>``)

The three properties everything else rests on:

  PURE              the caller's dict is never mutated in place; a new dict is
                    returned. (The write gate validates an upgraded COPY of a
                    caller's draft without rewriting the draft.)
  IDEMPOTENT        ``upgrade(upgrade(x)) == upgrade(x)``. Safe to run on every
                    read, however many times.
  ORDER-INDEPENDENT the result never depends on which subset of old keys a record
                    happens to carry, nor on dict insertion order. Every rule is
                    keyed on ``(key-name, value)`` against the INPUT dict, so no
                    rule can ever observe a key another rule already rewrote.

APPLIED UNCONDITIONALLY ON EVERY READ — never gated on ``format``.
The ``format`` marker exists to gate hypothetical FUTURE (v3+) migrations; it must
NEVER be used to *skip* the v1→v2 map.

The reason is NOT that gating would lose a concurrent old-plugin write — read the
next paragraph; it demonstrably does lose it, and that is accepted. The reason is
that **format-gating a READ is a mixed-fleet corruption trap**. A ``format`` marker
tells you what wrote the record LAST, not what vocabulary its keys are in: a v1
record that any old-plugin hook touches after an upgrade, a record hand-edited by an
operator, a record restored from a backup, a v2 record a downgrade stripped the
marker from — each can carry v1 keys under any marker value, or none. A gated shim
reads such a record as if its keys were already v2, so ``steps`` is simply absent and
the step array reads as EMPTY. That is a silent, structural misread of user data.
The ungated map cannot misread anything: it is pure, idempotent and order-independent,
so running it over an already-v2 record is a no-op BY CONSTRUCTION (no old key is
present to map), while running it over anything else fixes it. Ungated, the shim is
total; gated, it is a guess about provenance. Writers may safely lag readers.

STALE-TWIN DROP — AND WHAT IT COSTS. After an old key is mapped to its new key the
old twin is DROPPED, so a mapped record can never carry both ``units`` and ``steps``.
Where BOTH twins are present on input, **the NEW key's value wins**. Genuinely-unknown
keys — anything not in a map below — pass through untouched, at any depth.

Say the consequence plainly, because it is easy to talk yourself out of it:
**a concurrent OLD-plugin write to a v2 record is LOST.** Every v2 record carries
``handoff_paused`` from init. So when an old plugin writes ``seam_paused: true`` into
it, the record now holds BOTH twins, new-wins discards the old one, and the pause the
old plugin just set is gone on the next read. Not "degraded" — gone. The same holds
for every twinned key, and no ordering of the upgrade changes it.

That is a DELIBERATE trade, not an oversight. The alternatives are worse: old-wins
would make an upgraded record revert to whatever a stale hook last wrote, breaking the
upgrade path itself; and resolving the twins by timestamp/heuristic would be exactly
the kind of magic this repo refuses — a silent, unauditable guess about which of two
plugin versions "meant it". New-wins is the only rule that is total, order-independent
and explainable.

The honest conclusion, therefore: **running two plugin versions against one
``.claude/auto/`` state dir is NOT SUPPORTED.** The shim makes a mixed fleet
SURVIVABLE — nothing crashes, nothing is structurally misread — but it does not make
it CORRECT, and a write from the older plugin can be silently dropped. Do the cutover
below.

REVERT SAFETY. ``downgrade_run_record`` is the inverse map (it also strips
the ``format`` marker, so reinstalled pre-rename code never sees an unknown
version field): ``downgrade_run_record(upgrade_run_record(v1)) == v1`` **for every
record v1 code actually writes** — which is the case the revert procedure needs.
The qualifier is load-bearing, not throat-clearing: the inverse is DEPTH-BLIND, so a
record carrying a v2-SPELLED key outside the three opaque containers does not
round-trip. ``{"notes": {"steps": "x", "producer": "y"}}`` comes back as
``{"notes": {"units": "x", "emitter": "y"}}``. Real v1 records cannot contain such a
key (free-form names are confined to the opaque containers below, whose KEYS are
passed through verbatim, never renamed — their values are still walked, but a value
is not what mis-downgrades here), but a HAND-EDITED one can — and hand-edited records
are explicitly in this
module's threat model above. If you are reverting a record you edited by hand, diff
it. The
documented revert procedure is to run it over stranded ``format: 2`` records
BEFORE reinstalling pre-rename code. Downgrade is an OFFLINE / QUIESCED
operation — run-records lazy-migrate back to v2 on their first post-upgrade
mutation, so any new-code hook that fires between the downgrade and the reinstall
silently re-upgrades the record. There is no online-downgrade guarantee.

MIXED-FLEET CUTOVER (required). Before any smoke run or ``/auto-resume`` on a repo
whose ``.claude/auto/`` state dir is SHARED with an installed older (pre-rename)
plugin, update the installed plugin to >= this rename, or run against an isolated
state dir. Otherwise the old plugin's hooks keep writing v1 keys into records the
new code owns. The shim makes that survivable, not correct.

THE REVERT COMMAND LIVES ON ``run_record.py``, NOT HERE (U10). This module is a DAG
ROOT — it imports no sibling — so it cannot reach the run-record **flock**, and KTD-1
requires the downgrade to write under that lock. ``python3 lib/run_record.py downgrade
<path>`` is the operator command; it borrows core's real lock and calls the pure maps
below. See ``run_record.py::downgrade_record_file``.
"""

FORMAT_VERSION = 2


# ── key maps ────────────────────────────────────────────────────────────────
# Renamed at ANY depth. Every token here is unambiguous in this format — nothing
# else in a run-record or a workflow file is spelled this way — so a depth-blind
# rename is safe and catches nesting the schema never spelled out (notably
# ``dispatch_context.enumerated_steps[].invokes.backend_op``, a persisted op
# value two levels inside a step).
_KEY_MAP = {
    "units": "steps",
    "adapter_scale": "backend_scale",
    "adapter_op": "backend_op",
    "enumerated_units": "enumerated_steps",
    "default_adapter": "default_backend",
    "gate_unit": "gate_step",
    "seam_paused": "handoff_paused",
    "all_units_terminal": "all_steps_terminal",
    "winner_unit_id": "winner_step_id",
    "emitter": "producer",
}

# Renamed ONLY at the top level of a run-record. `adapter` and `recipe` are bare,
# generic words — a depth-blind rename could clobber an unrelated key inside an
# opaque payload (a model-emitted finding, a future dispatch_context bag). The
# KTD-1 map scopes both to the run-record's top level, and so do we.
_TOP_KEY_MAP = {
    "adapter": "backend",
    "recipe": "workflow",
}

# Renamed ONLY inside `dropped_depends_on_edges` items — the one place a bare
# `unit` is a persisted key. Same reasoning as above: `unit` is far too generic
# to rename at arbitrary depth.
_EDGE_KEY_MAP = {"unit": "step"}
_EDGE_CONTAINER = "dropped_depends_on_edges"

# OPAQUE KEY NAMESPACES. These containers are maps whose KEYS are chosen by the
# workflow AUTHOR or by an agent at runtime — they are data, not format. Renaming
# a key here would corrupt a legitimate name:
#
#   emit_templates   {"<template_name>": {...}} — a template legally named `units`
#                    would be renamed to `steps` while `iteration.emit_template`
#                    (a VALUE) still said "units", leaving the workflow permanently
#                    unloadable with an error naming a key the author never wrote.
#   judge_verdicts   {"<criterion_id>": <verdict>} — ids come from `verification[].id`;
#                    a renamed id silently never matches, so the criterion reads
#                    PENDING forever and the gate never resolves.
#   decision_payload an agent-supplied bag.
#
# Their KEYS pass through verbatim; their VALUES are still converted, so
# `emit_templates.<name>.invokes.backend_op` and `.phase` still map correctly.
# This is the "genuinely-unknown keys pass through untouched" rule applied at the
# level where the namespace — not just the individual key — is open.
_OPAQUE_KEY_CONTAINERS = frozenset({
    "emit_templates",
    "judge_verdicts",
    "decision_payload",
})


# ── value maps ──────────────────────────────────────────────────────────────
_PHASE_MAP = {"seam": "handoff"}

_PRODUCER_MAP = {
    "plan_output_to_work_units": "plan_output_to_work_steps",
    "judge_winner_to_work_units": "judge_winner_to_work_steps",
    "brainstorm_output_to_plan_unit": "brainstorm_output_to_plan_step",
    # plan_output_to_paired_builders carries neither term — unchanged.
}

_OP_MAP = {"do_unit": "do_step"}
# brainstorm / next_plan_step / review carry neither term — unchanged.

_EXIT_REASON_MAP = {"recipe-bug": "workflow-bug"}
# The exit-reason VALUE flipped here in U6; the SYMBOL that carries it is
# `ExitReason.WORKFLOW_BUG` as of U8 (it was `ExitReason.RECIPE_BUG`). The v1
# spelling `recipe-bug` on the LEFT is a retired on-disk value and must stay —
# a completed pre-rename run keeps it forever.

# Scalar values rewritten by the POST-rename key that holds them.
_VALUE_RULES_UP = {
    "phase": _PHASE_MAP,
    "loop_phase": _PHASE_MAP,
    "terminal_phase": _PHASE_MAP,
    "backend_op": _OP_MAP,
    "producer": _PRODUCER_MAP,
}
# List-of-scalars rewritten element-wise.
_LIST_RULES_UP = {"phase_order": _PHASE_MAP}
# Rules that only fire inside a named container — `from`/`to` and `kind` are
# generic words, so both are double-gated on (container, key) AND on the value
# being a known member of the map.
_CONTEXT_RULES_UP = {
    ("phase_transitions", "from"): _PHASE_MAP,
    ("phase_transitions", "to"): _PHASE_MAP,
    ("exit_reason", "kind"): _EXIT_REASON_MAP,
}


def _invert(m):
    return {v: k for k, v in m.items()}


_KEY_MAP_DOWN = _invert(_KEY_MAP)
_TOP_KEY_MAP_DOWN = _invert(_TOP_KEY_MAP)
_EDGE_KEY_MAP_DOWN = _invert(_EDGE_KEY_MAP)

_VALUE_RULES_DOWN = {
    "phase": _invert(_PHASE_MAP),
    "loop_phase": _invert(_PHASE_MAP),
    "terminal_phase": _invert(_PHASE_MAP),
    "adapter_op": _invert(_OP_MAP),
    "emitter": _invert(_PRODUCER_MAP),
}
_LIST_RULES_DOWN = {"phase_order": _invert(_PHASE_MAP)}
_CONTEXT_RULES_DOWN = {
    ("phase_transitions", "from"): _invert(_PHASE_MAP),
    ("phase_transitions", "to"): _invert(_PHASE_MAP),
    ("exit_reason", "kind"): _invert(_EXIT_REASON_MAP),
}


class _Spec:
    """One direction of the map (upgrade or downgrade)."""

    def __init__(self, key_map, top_key_map, edge_key_map,
                 value_rules, list_rules, context_rules):
        self.key_map = key_map
        self.top_key_map = top_key_map
        self.edge_key_map = edge_key_map
        self.value_rules = value_rules
        self.list_rules = list_rules
        self.context_rules = context_rules

    def new_key(self, key, *, top_level, container):
        if container == _EDGE_CONTAINER and key in self.edge_key_map:
            return self.edge_key_map[key]
        if top_level and key in self.top_key_map:
            return self.top_key_map[key]
        return self.key_map.get(key, key)


_UP = _Spec(_KEY_MAP, _TOP_KEY_MAP, _EDGE_KEY_MAP,
            _VALUE_RULES_UP, _LIST_RULES_UP, _CONTEXT_RULES_UP)
_DOWN = _Spec(_KEY_MAP_DOWN, _TOP_KEY_MAP_DOWN, _EDGE_KEY_MAP_DOWN,
              _VALUE_RULES_DOWN, _LIST_RULES_DOWN, _CONTEXT_RULES_DOWN)


def _convert(node, spec, *, top_level=False, container=None):
    """Recursively map ``node`` under ``spec``. Returns a NEW structure; the
    input is never mutated.

    ``container`` is the (post-rename) key of the dict/list that holds this node
    — it is what lets the context-scoped rules (``phase_transitions[].from``,
    ``exit_reason.kind``, ``dropped_depends_on_edges[].unit``) fire narrowly
    instead of renaming every generic ``from``/``kind``/``unit`` in the tree.
    """
    if isinstance(node, list):
        return [_convert(v, spec, container=container) for v in node]
    if not isinstance(node, dict):
        return node

    # An OPAQUE namespace: the keys at THIS level are author/agent-chosen data, not
    # format. Pass them through verbatim, but keep converting their VALUES (a
    # template's `invokes.backend_op` / `phase` are still format keys).
    if container in _OPAQUE_KEY_CONTAINERS:
        return {k: _convert(v, spec, container=k) for k, v in node.items()}

    # Pass 1 — compute each key's new name from the INPUT dict only. Nothing
    # here reads a key another rule has already rewritten, which is exactly what
    # makes the map order-independent.
    renames = {}
    for key in node:
        nk = spec.new_key(key, top_level=top_level, container=container)
        if nk != key:
            renames[key] = nk

    out = {}
    for key, value in node.items():
        nk = renames.get(key, key)
        # STALE-TWIN DROP: the new key is already present on the input, so this
        # old twin is stale — the new value wins and the old key is dropped. A
        # mapped record can never carry both `units` and `steps`.
        if key in renames and nk in node:
            continue
        out[nk] = _convert_value(nk, value, spec, container=container)
    return out


def _convert_value(key, value, spec, *, container):
    # Every value rule is double-gated: the key must match AND the value must be
    # a known member of the map. An unknown value (a phase named "review", a
    # producer we've never heard of) passes through untouched.
    rule = spec.context_rules.get((container, key))
    if rule is not None and isinstance(value, str):
        return rule.get(value, value)

    rule = spec.value_rules.get(key)
    if rule is not None and isinstance(value, str):
        return rule.get(value, value)

    rule = spec.list_rules.get(key)
    if rule is not None and isinstance(value, list):
        return [rule.get(v, v) if isinstance(v, str) else v for v in value]

    return _convert(value, spec, container=key)


# ── public surface ──────────────────────────────────────────────────────────


def upgrade_run_record(d: dict) -> dict:
    """Map a format-v1 run-record to format-v2. Pure, idempotent,
    order-independent. Applied UNCONDITIONALLY on every read — never gated on
    ``format`` (see the module docstring's write-skip-forever hole).

    Stamps ``format: 2``. Non-dict input is returned untouched (a caller's
    fail-closed guard stays fail-closed).
    """
    if not isinstance(d, dict):
        return d
    out = _convert(d, _UP, top_level=True)
    out["format"] = FORMAT_VERSION
    return out


def downgrade_run_record(d: dict) -> dict:
    """The inverse map: format-v2 run-record → format-v1, for REVERT safety
    (KTD-1). Strips the ``format`` marker so reinstalled pre-rename code never
    sees an unknown version field.

    ``downgrade_run_record(upgrade_run_record(v1)) == v1`` for every record v1 code
    actually writes. NOT unconditionally: the inverse is depth-blind, so a record
    carrying a v2-spelled key outside the opaque containers round-trips to its v1
    spelling (``{"notes": {"steps": …}}`` → ``{"notes": {"units": …}}``). v1 code
    cannot emit that; a hand-edited record can. See the module docstring.

    OFFLINE / QUIESCED ONLY. A downgraded record lazy-migrates straight back to
    v2 on its first read-through-mutation by new code, so the state dir must be
    quiesced (no live sessions, no hooks firing) between the downgrade and the
    reinstall of pre-rename code. There is no online-downgrade guarantee.
    """
    if not isinstance(d, dict):
        return d
    out = _convert(d, _DOWN, top_level=True)
    out.pop("format", None)
    return out


def upgrade_workflow(d: dict) -> dict:
    """Map a format-v1 workflow (recipe) file to format-v2. Pure, idempotent,
    order-independent.

    Acceptance of v1-keyed workflow files is INDEFINITE (KTD-1): auto never
    writes a user's workflow file back, so an old file upgrades in memory every
    time it is resolved.

    Deliberately does NOT stamp ``format``: the workflow schema is
    ``additionalProperties: false``, so a stray top-level key would fail
    validate(). A workflow carries its own ``version`` field instead.
    """
    if not isinstance(d, dict):
        return d
    return _convert(d, _UP, top_level=False)


def downgrade_workflow(d: dict) -> dict:
    """The inverse map for workflow files (revert safety, mirrors
    ``downgrade_run_record``). No ``format`` marker to strip."""
    if not isinstance(d, dict):
        return d
    return _convert(d, _DOWN, top_level=False)


def upgrade_preset(d: dict) -> dict:
    """Map a format-v1 PRESET file to v2. Pure, idempotent, order-independent.

    Presets are the third user-authorable on-disk format (after run-records and
    workflows), and they carry two renamed tokens: the ``invokes.adapter_op`` KEY
    and its ``do_unit`` VALUE. A user's pre-rename workspace/global preset would
    otherwise HARD-FAIL ``validate_preset`` (whose known-key set is now
    ``backend_op`` only) — a preset is not "silently ignored", it aborts
    ``/auto --preset <name>``. Same indefinite read-compat as workflows: auto
    never writes a user's preset file back.

    Shares the workflow map (the flipped keys/values are the same shared op
    surface). Deliberately does NOT stamp ``format``: ``validate_preset`` enforces
    a closed top-level key set, so a stray marker would itself fail validation.
    """
    if not isinstance(d, dict):
        return d
    return _convert(d, _UP, top_level=False)


def downgrade_preset(d: dict) -> dict:
    """The inverse map for preset files (revert safety)."""
    if not isinstance(d, dict):
        return d
    return _convert(d, _DOWN, top_level=False)
