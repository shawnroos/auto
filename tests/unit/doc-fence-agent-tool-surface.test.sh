#!/usr/bin/env bash
# auto unit test: doc-fence for the agent-tool-surface contract (rename plan, U7/F12).
#
# WHY THIS TEST EXISTS:
# `tests/unit/run-record.test.sh` asserts set-equality between the CLI's `_VERBS`
# registry and what `describe` emits — so DISPATCH and the MACHINE-READABLE mirror
# can never drift. But nothing bound the third copy: the human-facing verb table in
# `docs/contracts/agent-tool-surface.md`. Grepping `agent-tool-surface` across
# `tests/` returned ZERO hits before this file — the prose contract was enforced by
# nothing.
#
# That gap was not hypothetical. U7 renamed the work-node CLI verbs
# (`set-enumerated-steps`, `add-step`) with NO aliases (KTD-4), and the rename had to
# land in the registry, the `describe` payload, and this doc IN LOCKSTEP or a driving
# agent would read a contract naming verbs that exit 2. The audit
# (`vocabulary-audit.test.sh`, which scans `docs/contracts/`) catches a STALE OLD term
# in the doc — but it cannot catch a verb that is simply MISSING, or one renamed to a
# spelling the doc never learned. This fence closes that.
#
# It also immediately caught a REAL pre-existing drift: `transition` has always been
# in `_VERBS` but was never named in agent-tool-surface.md.
#
# HOW IT WORKS: the required set is DERIVED from `python3 lib/run_record.py describe`
# (hence from `_VERBS`), never hand-maintained here — so adding a verb wires its doc
# requirement automatically. Same deterministic-defense shape as
# tests/unit/doc-fence-run-record-schema.test.sh and tests/unit/wikilink-check.test.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DOC="${AUTO_ROOT}/docs/contracts/agent-tool-surface.md"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() {
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m %s\n" "$CURRENT"
  [ -n "${1:-}" ] && printf "      %s\n" "$1"
  return 0
}

# ─── Scenario 0: the doc exists (anti-vacuity — every grep below would pass) ──
it "docs/contracts/agent-tool-surface.md exists (the fenced doc)"
if [ -f "$DOC" ]; then
  pass
else
  fail "agent-tool-surface.md is missing — every check below would pass vacuously"
  echo ""
  echo "doc-fence-agent-tool-surface.test.sh: ${PASS} passed, ${FAIL} failed"
  exit 1
fi

# ─── Derive the verb set from the CLI's own self-description ────────────────
VERBS="$("$PY" - "$AUTO_ROOT" <<'PYEOF'
import json, subprocess, sys
root = sys.argv[1]
out = subprocess.run(
    [sys.executable, f"{root}/lib/run_record.py", "describe"],
    capture_output=True, text=True, check=True,
).stdout
print("\n".join(sorted(json.loads(out)["verbs"])))
PYEOF
)"

it "describe yields a non-empty verb set (anti-vacuity)"
if [ -n "$VERBS" ] && [ "$(printf '%s\n' "$VERBS" | wc -l | tr -d ' ')" -ge 10 ]; then
  pass
else
  fail "describe returned ${VERBS:-<empty>} — the fence below would check nothing"
fi

# The fence's actual check, factored into a function so the deliberate-fail control
# below can re-point it at a PLANTED-BROKEN copy of the doc and prove it fires. (An
# inlined loop cannot be re-run against a different file, which is how a DF control
# ends up merely re-proving that `grep -v X | grep X` finds nothing.)
# missing_verbs <doc> → prints the verbs that dispatch but are not named in <doc>.
missing_verbs() {
  local doc="$1" verb out=""
  while IFS= read -r verb; do
    [ -z "$verb" ] && continue
    grep -q -F -- "\`${verb}\`" "$doc" || out+="${verb} "
  done <<< "$VERBS"
  printf '%s' "$out"
}

# ─── Scenario 1: every verb `describe` documents is NAMED in the doc ─────────
# Matched as `\`<verb>\`` (a markdown code span), so the prose must name the verb
# as a literal identifier, not merely contain the substring in running text.
it "every verb in describe/_VERBS is named in agent-tool-surface.md"
missing="$(missing_verbs "$DOC")"
if [ -z "$missing" ]; then
  pass
else
  fail "these verbs dispatch but are NOT named in agent-tool-surface.md: ${missing}
      the contract an agent orients by is stale — add them (or rename them) there."
fi

# ─── Scenario 2: the doc names NO verb that does not dispatch ────────────────
# The converse leak: a verb REMOVED or RENAMED in `_VERBS` while the doc keeps
# advertising the old spelling. U7 hard-cut the work-node verbs with no aliases, so a
# doc naming a retired verb sends an agent straight into an exit-2. Only code spans
# that look like a CLI verb (kebab-case, in the Verbs section's bullet list) are
# considered — prose identifiers like `_VERBS` or `ALLOWED_TRANSITIONS` are not verbs.
it "agent-tool-surface.md advertises no verb that _VERBS does not dispatch"
stale=""
doc_verbs="$(sed -n '/^## Verbs$/,/^## /p' "$DOC" \
             | grep -oE '`[a-z][a-z-]*`' | tr -d '`' | sort -u)"
while IFS= read -r cand; do
  [ -z "$cand" ] && continue
  if ! printf '%s\n' "$VERBS" | grep -qx -- "$cand"; then
    stale+="${cand} "
  fi
done <<< "$doc_verbs"
if [ -z "$stale" ]; then
  pass
else
  fail "agent-tool-surface.md names these as verbs, but they do NOT dispatch: ${stale}
      an agent following the contract would get exit 2."
fi

# ─── Scenario 3: deliberate-fail — proves the fence is not vacuous ───────────
# Plant a BROKEN copy of the doc (a verb's name stripped) and run the fence's OWN
# checker against it. It must name the missing verb. This exercises the real check,
# not a tautology: asserting that `grep -v X` produced a file without X proves
# nothing about the fence.
it "deliberate-fail: the fence's checker flags a verb stripped from a planted doc"
tmpdir="$(mktemp -d -t doc-fence-ats.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT
sed 's/`add-step`/`REMOVED-BY-DF-PROBE`/g' "$DOC" > "$tmpdir/doc.md"
df_missing="$(missing_verbs "$tmpdir/doc.md")"
case "$df_missing" in
  *add-step*) pass ;;
  *) fail "deliberate-fail: the fence did NOT flag \`add-step\` as missing from the planted doc (got: '${df_missing}') — the fence is vacuous" ;;
esac

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "doc-fence-agent-tool-surface.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
