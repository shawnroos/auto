#!/usr/bin/env bash
# auto U8: list resolvable workflows for the picker (READ-ONLY).
#
# Prints one line per workflow: "<name>\t<tier>\t<description>" — the picker prose
# in commands/auto.md consumes this to build the AskUserQuestion options. Tier is
# one of workspace|global|built-in (the badge); first-wins dedup is done by
# workflows.list_available. With --render <name> it prints the full ASCII topology
# card for one workflow (the picker's preview surface, KTD-10).
#
# READ-ONLY: resolves + reads workflow files; never writes. Repo root is resolved
# by the shared _bootstrap.resolve_repo (CLAUDE_AUTO_REPO, else a git-worktree-
# bounded walk-up), parity with the other shims — NOT an inlined copy, so it
# can't drift from the 2026-06 mis-root fix the way an inlined walk-up did.
#
# $ARGUMENTS-safe: all arg logic lives HERE; the .md body never string-interpolates.

set -uo pipefail

CLAUDE_AUTO_PYTHON3="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

auto::workflows_list() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ "$#" -eq 1 ]; then
    # shellcheck disable=SC2086 — deliberate word-split of the packed arg string.
    set -- $1
  fi
  "$CLAUDE_AUTO_PYTHON3" - "$script_dir" "$@" <<'PYEOF'
import sys
script_dir = sys.argv[1]
args = sys.argv[2:]
sys.path.insert(0, script_dir)
# Use the canonical bounded resolver — `_bootstrap` is already imported here, so
# (unlike auto-detect.sh's pre-import single-quoted heredoc) there is no
# dependency-free-core reason to inline a copy. An inlined walk-up here silently
# escaped to $HOME/.claude/auto from a fresh worktree, mislabeling the user's
# global workflows as tier `workspace` (the 2026-06 mis-root bug, third copy).
from _bootstrap import load_lib_module, resolve_repo
workflows = load_lib_module("workflows")

repo = resolve_repo()

if args and args[0] == "--render" and len(args) > 1:
    tr = load_lib_module("topology-render")
    workflow, _tier = workflows.resolve(args[1], repo)
    print(tr.render(workflow, 60))
elif args and args[0] == "--compare":
    # --compare <name>... [--highlight <name>] — resolve each candidate and
    # stack its card via topology-render.render_comparison (the chooser's
    # contrast surface, KTD-2/3). Same first-wins resolve() as --render; the
    # comparison is just N single-sourced cards, so the one-renderer rule holds.
    tr = load_lib_module("topology-render")
    rest, names, highlight, i = args[1:], [], None, 0
    while i < len(rest):
        if rest[i] == "--highlight" and i + 1 < len(rest):
            highlight = rest[i + 1]
            i += 2
        else:
            names.append(rest[i])
            i += 1
    cards = [workflows.resolve(n, repo)[0] for n in names]
    print(tr.render_comparison(cards, highlight=highlight, width=60))
else:
    for name, tier in workflows.list_available(repo):
        try:
            workflow, _ = workflows.resolve(name, repo)
            desc = (workflow.get("description") or "").replace("\t", " ").replace("\n", " ")
        except workflows.WorkflowError:
            desc = "(unreadable)"
        print("%s\t%s\t%s" % (name, tier, desc))
PYEOF
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  auto::workflows_list "$@"
fi
