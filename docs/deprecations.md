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
| retired CLI verbs (`add-unit`, `set-enumerated-units`) | `add-step`, `set-enumerated-steps` | An agent mid-run **across** the upgrade. These were originally a hard cut, on the reasoning that "verbs are never persisted". That was wrong: the pre-rename guidance module handed the driving agent a literal `… set-enumerated-units <args>` line to *run*, and that instruction persists (agent context, rearm prompt) even though the verb doesn't. Now a deprecated alias — `_DEPRECATED_VERBS` in `lib/run_record.py`, same rewrite-and-fall-through as the flags, one stderr notice, stdout byte-clean. Deliberately **not** in `_VERBS`/`describe`, so no new agent learns it | v0.15.0 | <!--legacy--> |
| the `.seam-default-acknowledged` marker file | `.handoff-default-acknowledged` | **USER STATE, not a code identifier.** The rename swept the filename; `lib/auto.py` still *reads* the old one (it only ever writes the new one). Removing the read re-fires the one-time v0.4.0 handoff-flip notice at every user who dismissed it a version ago. Harmless, but it is the kind of paper-cut that makes an upgrade feel broken | v0.15.0 | <!--legacy--> |

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

## What the read-shim does NOT buy you: a mixed fleet

**Running two plugin versions against one `.claude/auto/` state dir is not supported.**
The shim makes a mixed fleet *survivable* — nothing crashes, no record is structurally
misread — but it does not make it *correct*, and the failure is silent.

Here is the whole of it. When the shim maps an old key to its new one it drops the old
twin, and where **both** twins are present the **new key wins**. Every format-v2
run-record carries `handoff_paused` from the moment it is created. So if an older
plugin's hook writes `seam_paused: true` into that record, the record briefly holds both
keys, new-wins discards the old one, and **the pause the old plugin just set is gone** on
the very next read. Same for every twinned key.

That is a deliberate trade. Old-wins would make an upgraded record revert to whatever a
stale hook last wrote — it would break the upgrade path itself. Resolving twins by
timestamp or heuristic would be an unauditable guess about which plugin version "meant
it". New-wins is the only rule that is total, order-independent and explainable, so it is
the rule — and the cost is that the older plugin's write is lost.

**Before any smoke run or `/auto-resume` on a repo whose `.claude/auto/` is shared with an
installed older plugin: update the plugin, or run against an isolated state dir.** This is
most likely exactly where you'd least expect it — dogfooding auto on the auto repo itself.

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
5. Delete the `_DEPRECATED_VERBS` map in `lib/run_record.py` (row 17). Removable only
   under the same condition as the alias command: no run armed by ≤ v0.14.x can still
   be in flight, because such a run's guidance may still be telling its agent to call
   the retired verb.
6. Drop the legacy-marker read in `lib/auto.py::_handoff_default_notice` (row 18). This
   one is genuinely silent, because the notice **migrates the marker on read**: the first
   post-upgrade run of a legacy-ack user writes `.handoff-default-acknowledged` alongside
   the old file, so by the time the read goes there is nothing left to re-fire at. (It was
   not always so. The read used to return early without writing anything, which meant a
   legacy-ack user never grew the new marker and deleting the read re-fired the notice at
   **every one of them** — the exact paper-cut the shim exists to prevent, deferred a
   minor. If you are reading this because you are about to drop the read: confirm
   `_handoff_default_notice` still writes the new marker on the legacy path first.)
7. Delete the matching entries in `tests/unit/vocabulary-audit.test.sh` — the global
   path whitelist, and the `SCRUBS` rows that exempt those surfaces. The audit is what
   holds the line afterwards, so this step is what makes the removal stick. (Every row
   in that table names the surface it exempts in its rationale field; delete the row,
   and if the surface is really gone the audit stays green.)
8. **Delete** the one test whose whole job was to pin a deprecated surface:
   `tests/unit/flag-aliases.test.sh`. Every one of its assertions exists only because the
   retired flags do — with the flags gone there is nothing left in it to keep.

   ⚠ **Only that one.** Three other tests read like they belong here and do not:
   `run-record-stub.test.sh`, `rearm-command-exists.test.sh` and
   `pulse-alias-inflight.test.sh` each pin the deprecated surface with a minority of
   their assertions and the **canonical** surface with the rest. They are step-9 edits.
   Deleting them would drop live regression coverage **and nothing would go red** — the
   suite would stay green, the coverage would just be gone. That is the same shape as
   every other defect this branch has chased: a change that removes a guard without
   anything noticing. See step 9 for what each one actually holds.
9. **Edit** — do not delete — the tests that pin a deprecated surface as part of a
   larger job, or they go red. Drop only the alias assertions:
   - `tests/unit/rearm-command-exists.test.sh` — **one** of its nine assertions pins the
     alias command of row 8 (and one more asserts both command files dispatch
     `lib/pulse.sh` — keep the canonical half). The rest guard the canonical rearm path:
     the loop fires namespaced
     `/auto:auto-pulse`, no bare un-namespaced emissions, every fired command maps to a
     command file, `commands/auto-pulse.md` exists, plus two deliberate-fail controls.
     Those pin **two bugs that actually shipped** — v0.6.2 ("Unknown command" → the pulse
     never ran) and v0.6.5 (bare un-namespaced command).
   - `tests/unit/run-record-stub.test.sh` — its last two assertions pin that cmux-socket's
     pulse-lock path and runaway-spawn sentinel still **resolve post-rename**. Those guard
     the fail-open class the row-7 re-export shim's own docstring calls severe: an empty path
     means "lock free" / "un-spawnable", so both guards fail open and spawn competing
     drivers. Keep them; drop the six that exercise the retired stub itself.
   - `tests/integration/pulse-alias-inflight.test.sh` — keep the canonical pulse path
     assertions (canonical `lib/pulse.sh` advances + rearms, `commands/auto-pulse.md`
     dispatches `lib/pulse.sh`) and the deliberate-fail control (a broken dispatch path
     does NOT advance the run). Drop the alias/stub ones.
   - `tests/integration/workflow-picker.test.sh` (asserts the retired picker stub still
     forwards), `tests/smoke/scaffold.test.sh` (asserts the alias command file exists and
     dispatches), `tests/unit/run-record-cli-feedback.test.sh` (pins the retired verbs
     still dispatch — restore the exit-2 assertion), and
     `tests/unit/handoff-default.test.sh` (pins the legacy ack marker is honoured, and
     that a legacy-only ack migrates forward — see step 6).

Leave `lib/format_compat.py`, its tests, its fixtures, and the legacy tier dirs alone.
