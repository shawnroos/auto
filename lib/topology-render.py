#!/usr/bin/env python3
"""auto U7 (v0.2.0): the ONE ASCII topology renderer (KTD-10).

`render(recipe, width_hint)` turns any recipe dict into a compact ASCII card.
Called from THREE surfaces — the picker (U8, in the AskUserQuestion preview),
the authoring skill (U9, showing a draft back), and auto-status (the run's
topology). One renderer = the three surfaces can't drift (the same "two
validators" anti-pattern KTD-2 guards against, applied to rendering).

It derives the card from recipe STRUCTURE (phase_order spine, units grouped by
phase, depends_on edges, phase_transitions emit-boundaries) — so a user-authored
recipe renders just like a built-in. No hardcoded per-recipe art.

Loaded via `_bootstrap.load_lib_module("topology-render")` (hyphenated file).
Pure stdlib; deterministic (stable ordering) so tests can assert exact output.
"""

from __future__ import annotations

_DEFAULT_WIDTH = 60


def _phase_units(recipe: dict, phase: str) -> list:
    """Unit ids declared for `phase`, in declaration order (stable)."""
    return [u["id"] for u in recipe.get("steps", []) if u.get("phase") == phase]


def _producer_for_arrival(recipe: dict, to_phase: str):
    """The producer that fires when the run ARRIVES at `to_phase`.

    Recipes declare producers by their `to` phase (the phase whose units the
    producer produces) — e.g. A1's `{from: plan, to: work}` fires when the run
    reaches the work phase, even though phase_order routes plan → handoff → work.
    Keying on `to` (not the exact adjacent pair) is what makes the handoff a
    pass-through: the producer is attached to the arrow ENTERING its target phase.
    U5b's handoff-handler consumes it the same way (advance INTO X → run X's producer).
    """
    for pt in recipe.get("phase_transitions", []):
        if pt.get("to") == to_phase:
            return pt.get("producer")
    return None


def render(recipe: dict, width_hint: int = _DEFAULT_WIDTH) -> str:
    """Return a multi-line ASCII card for `recipe`. Deterministic.

    Layout: name + description header, then each phase in `phase_order` as a
    boxed row listing its declared units (or "(emitted at runtime)" when a phase
    has no declared units but is an emit target), with the producer named on the
    transition arrow between phases. The terminal phase is marked.
    """
    width = max(24, int(width_hint or _DEFAULT_WIDTH))
    name = recipe.get("name", "?")
    desc = recipe.get("description", "")
    phase_order = recipe.get("phase_order", ["plan", "handoff", "work"])
    terminal = recipe.get("terminal_phase", "work")

    lines = []
    lines.append(f"recipe: {name}")
    if desc:
        # Wrap the description to width on word boundaries (cheap, stdlib).
        words, cur = desc.split(), ""
        for w in words:
            if cur and len(cur) + 1 + len(w) > width:
                lines.append(f"  {cur}")
                cur = w
            else:
                cur = f"{cur} {w}".strip()
        if cur:
            lines.append(f"  {cur}")
    lines.append("")

    for i, phase in enumerate(phase_order):
        units = _phase_units(recipe, phase)
        is_terminal = phase == terminal
        label = phase.upper() + ("  (terminal)" if is_terminal else "")
        lines.append(f"  ┌─ {label}")
        if units:
            for uid in units:
                deps = next(
                    (u.get("depends_on", []) for u in recipe.get("steps", []) if u["id"] == uid),
                    [],
                )
                dep_note = f"  ← {', '.join(deps)}" if deps else ""
                lines.append(f"  │   • {uid}{dep_note}")
        else:
            lines.append("  │   • (units emitted at runtime)")
        lines.append("  └─")
        # Inter-phase arrow + the producer that fires arriving at the NEXT phase.
        if i + 1 < len(phase_order):
            nxt = phase_order[i + 1]
            producer = _producer_for_arrival(recipe, nxt)
            arrow = "      ▼"
            if producer:
                arrow += f"  emit: {producer}"
            lines.append(arrow)

    return "\n".join(lines)


# Marker line prefixed onto the highlighted card in a comparison block.
_RECOMMENDED_MARKER = "► recommended"


def render_comparison(recipes: list, *, highlight=None, width: int = _DEFAULT_WIDTH) -> str:
    """Stack N candidate cards for the launch chooser's contrast block (KTD-2/3).

    A thin COMPOSING wrapper: it calls the one `render` once per candidate and
    joins the cards — it does NOT re-implement any per-card art. So the KTD-10
    "one renderer = the surfaces can't drift" invariant holds: a comparison is
    just N invocations of `render` (a separate parallel renderer would reintroduce
    exactly the drift KTD-10 guards against).

    Cards are stacked in input order (preserved, so tests assert exact output),
    separated by a blank-line + horizontal rule. The card whose recipe `name`
    equals `highlight` is prefixed with a `► recommended` marker line; when
    `highlight` is None or names no candidate, no marker is emitted. Pure stdlib,
    deterministic.
    """
    w = max(24, int(width or _DEFAULT_WIDTH))
    rule = "─" * w
    blocks = []
    for recipe in recipes:
        card = render(recipe, w)
        if highlight is not None and recipe.get("name") == highlight:
            card = f"{_RECOMMENDED_MARKER}\n{card}"
        blocks.append(card)
    separator = f"\n\n{rule}\n\n"
    return separator.join(blocks)
