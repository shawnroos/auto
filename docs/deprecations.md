# Deprecated surfaces — what's kept, what breaks if you remove it

The concept-vocabulary rename (v0.14.0) renamed eight identifiers as code — a ninth,
`content` → `preset`, had already been renamed before it — and kept a compatibility
layer behind them. This file is the **single list** of every surface in that layer:
what it forwards to, what removing it would break, and when it can go.

There is deliberately no TODO scattered through the code for these — the stubs and
aliases each carry a one-line "removed next minor" comment, and this table is the
place that tracks them together.

**Two different lifetimes here, and the difference matters:**

- **The read-shim is PERMANENT.** auto never rewrites a file you authored, so it must
  keep accepting the old on-disk vocabulary forever. Removing it would break user data
  that auto itself has no way to migrate. It is not on any removal schedule.
- **The code aliases are TEMPORARY.** Stubs, flag spellings, and the old command name
  exist so that a run armed under the previous version — and an agent whose memorized
  paths came from it — does not break mid-flight. They go in the **next minor**
  (v0.15.0).

---

## Every deprecated surface

| deprecated surface | replaces / forwards to | what removing it breaks | remove in | <!--legacy--> |
|---|---|---|---|---|
| `lib/orchestrator.sh` | `lib/dispatcher.sh` | Any agent or script invoking the memorized path. Exec-forwards verbatim; exit code passes through; notice on stderr only | v0.15.0 | <!--legacy--> |
| `lib/adapter-ce.sh` | `lib/backend-ce.sh` | Same — memorized path only | v0.15.0 | <!--legacy--> |
| `lib/adapter-native.sh` | `lib/backend-native.sh` | Same — memorized path only | v0.15.0 | <!--legacy--> |
| `lib/tick.sh` | `lib/pulse.sh` | Memorized path, **and** an in-flight run whose persisted rearm prompt still names the old engine entry | v0.15.0 | <!--legacy--> |
| `lib/recipes-list.sh` | `lib/workflows-list.sh` | The picker's data layer as older skill prose named it | v0.15.0 | <!--legacy--> |
| `lib/ledger.sh` | `lib/run_record.sh` | Memorized path. Stdout stays byte-clean (notice on stderr) so `… read \| jq` keeps working | v0.15.0 | <!--legacy--> |
| `lib/ledger.py` | `lib/run_record.py` | **Not a 2-line forwarder — a module-importable re-export shim.** By-path loaders (`spec_from_file_location("ledger", …)`) reach for SYMBOLS on it (`.ledger_path`, `.LedgerError`) inside an `except: sys.exit(0)`, where a missing name fails **silently open**. Deleting it turns a loud ImportError into a silent no-op hook | v0.15.0 | <!--legacy--> |
| `commands/auto-tick.md` | `commands/auto-pulse.md` | **The riskiest one.** In-flight runs have `/auto:auto-tick <run>` persisted inside a `ScheduleWakeup` prompt and in stale rearm-intent JSON. Deleting it wedges those runs mid-flight. Removable only once no run armed by an older version can still be in flight | v0.15.0 | <!--legacy--> |
| `--recipe` flag | `--workflow` | A model composing the flag from older skill prose, and an in-flight run holding the old spelling in a persisted rearm prompt. Alias layer is `_DEPRECATED_FLAGS` in `lib/auto.py` — the token is rewritten and falls through, so the canonical branch stays the only implementation | v0.15.0 | <!--legacy--> |
| `--adapter` flag | `--backend` | Same mechanism, same reason | v0.15.0 | <!--legacy--> |
| `--teardown-recipe-after-init` flag | `--teardown-workflow-after-init` | Same mechanism, same reason | v0.15.0 | <!--legacy--> |
| `auto-adapter` skill name | `auto-backend` | Nothing at runtime. The `(formerly …)` breadcrumb in the skill description keeps MODEL-SIDE triggering matching the old phrasing; drop it when the old name is no longer in anyone's prompts | v0.15.0 | <!--legacy--> |
| `auto-author-recipe` skill name | `auto-author-workflow` | Same — a description breadcrumb, not a code path | v0.15.0 | <!--legacy--> |
| the `--recipe` routing branch in `commands/auto.md` | the `--workflow` branch | The command file must MATCH the retired spelling or the alias never reaches the parser — so this goes **with** the flag entries above, not separately. Easy to miss: it is the one alias surface that is not in `lib/auto.py` | v0.15.0 | <!--legacy--> |
| `.claude/auto/recipes/` tier dirs (workspace + global) | `.claude/auto/workflows/` | **A USER'S OWN FILES.** Read-only legacy tiers in `lib/workflows.py::_tier_dirs`. Never written to. Removing them orphans workflow files the user authored before the rename | **not scheduled** — see below | <!--legacy--> |
| the v1 on-disk keys (`units`, `adapter`, `recipe`, `seam_paused`, `emitter`, `gate_unit`, `do_unit`, …) | their v2 spellings, mapped in memory by `lib/format_compat.py` | **USER DATA.** Every pre-rename run-record, hand-authored workflow file, **and hand-authored preset** — three chokepoints, not two (`presets.load_preset` is the third; without it a pre-rename preset does not degrade, it HARD-FAILS `validate_preset` and aborts `/auto --preset <name>`). The map is applied unconditionally on every read, never gated on the `format` marker | **never** — see below | <!--legacy--> |
| retired CLI verbs (`add-unit`, `set-enumerated-units`) | `add-step`, `set-enumerated-steps` | **Already removed — hard cut, no alias.** Verbs are never persisted, so nothing in flight can hold one; an unknown verb exits 2 and the error names `describe`, the contract's orientation path. Listed here only so a stale transcript is diagnosable | — | <!--legacy--> |

## The two that are not on a schedule

**The read-shim (`lib/format_compat.py`) is permanent by design.** It maps the retired
on-disk keys and values to the current ones **in memory, on every read** — at both
run-record read chokepoints, at workflow resolve, at the authoring write-gate, and at
preset load. The reason it can never be dropped is simple: **auto never rewrites a file
the user authored.** A workflow file you wrote last year is yours; auto reads it and
leaves it alone. So the old spelling must stay acceptable for as long as those files
exist — which is forever. (Run-records are different: they lazily migrate to the current
shape on their first write, because every mutation funnels through one atomic-write
path. But the shim still can't go, because a record that is only ever *read* — a
completed run, an archived one — never migrates.)

Two commands sit on top of it, both **opt-in** and neither a migration the shim's
removal could ever wait on:

- `python3 lib/workflows.py migrate <path>` — modernizes one workflow file in place.
- `python3 lib/run_record.py downgrade <path>` — the **revert** command. Maps a
  format-v2 run-record back to v1 and strips the version marker, so pre-rename code can
  read it. It writes under the run-record flock, and it is **offline/quiesced only**: a
  downgraded record lazy-migrates straight back to v2 on its next write, so stop the
  sessions and hooks that touch `.claude/auto/` before running it, and reinstall the old
  plugin before letting them back. (Deliberately NOT an agent verb — it is absent from
  `describe` and from the agent tool surface.)

**The legacy tier dirs follow the same logic.** They hold user-authored files, so they
stay readable until there is a deliberate decision to strand them — which needs more
than "the rename is old news."

---

## Removing the temporary layer (v0.15.0 checklist)

Rows in the table above whose "remove in" column says v0.15.0 — nothing else.

1. Delete the six forwarding stubs and the module-importable re-export shim (rows 1–7).
2. Delete the alias command file (row 8) — **only** after confirming no run armed by
   ≤ v0.14.x can still be in flight, because its rearm prompt names that command.
3. Delete the `_DEPRECATED_FLAGS` entries in `lib/auto.py` **and the matching routing
   branch in `commands/auto.md`** (rows 9–11 and 14 — the command file is the easy one
   to miss, and leaving it behind leaves a route to a flag the parser no longer knows).
   The canonical branch keeps working untouched — that is why the alias layer is a
   rewrite-and-fall-through rather than a second implementation.
4. Drop the `(formerly …)` breadcrumbs from the two renamed skills' descriptions
   (rows 12–13).
5. Delete the matching entries in `tests/unit/vocabulary-audit.test.sh` — the global
   path whitelist, and the per-term scrub branches that exempt those surfaces. The
   audit is what holds the line afterwards, so this step is what makes the removal
   stick.
6. **Delete** the tests whose whole job was to pin the deprecated surfaces:
   `tests/unit/run-record-stub.test.sh`, `tests/unit/flag-aliases.test.sh`,
   `tests/unit/rearm-command-exists.test.sh`, and
   `tests/integration/pulse-alias-inflight.test.sh`.
7. **Edit** — do not delete — the two tests that pin a deprecated surface as part of a
   larger job, or they go red: `tests/integration/workflow-picker.test.sh` (asserts the
   retired picker stub still forwards) and `tests/smoke/scaffold.test.sh` (asserts the
   alias command file exists and dispatches). Drop only those assertions.

Leave `lib/format_compat.py`, its tests, its fixtures, and the legacy tier dirs alone.
