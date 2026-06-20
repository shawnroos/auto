#!/usr/bin/env bash
# auto U8: list resolvable recipes for the picker (READ-ONLY).
#
# Prints one line per recipe: "<name>\t<tier>\t<description>" — the picker prose
# in commands/auto.md consumes this to build the AskUserQuestion options. Tier is
# one of workspace|global|built-in (the badge); first-wins dedup is done by
# recipes.list_available. With --render <name> it prints the full ASCII topology
# card for one recipe (the picker's preview surface, KTD-10).
#
# READ-ONLY: resolves + reads recipe files; never writes. Repo root is resolved
# by the shared _bootstrap.resolve_repo (CLAUDE_AUTO_REPO, else a git-worktree-
# bounded walk-up), parity with the other shims — NOT an inlined copy, so it
# can't drift from the 2026-06 mis-root fix the way an inlined walk-up did.
#
# $ARGUMENTS-safe: all arg logic lives HERE; the .md body never string-interpolates.

set -uo pipefail

CLAUDE_AUTO_PYTHON3="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

auto::recipes_list() {
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
# global recipes as tier `workspace` (the 2026-06 mis-root bug, third copy).
from _bootstrap import load_lib_module, resolve_repo
recipes = load_lib_module("recipes")

repo = resolve_repo()

if args and args[0] == "--render" and len(args) > 1:
    tr = load_lib_module("topology-render")
    recipe, _tier = recipes.resolve(args[1], repo)
    print(tr.render(recipe, 60))
else:
    for name, tier in recipes.list_available(repo):
        try:
            recipe, _ = recipes.resolve(name, repo)
            desc = (recipe.get("description") or "").replace("\t", " ").replace("\n", " ")
        except recipes.RecipeError:
            desc = "(unreadable)"
        print("%s\t%s\t%s" % (name, tier, desc))
PYEOF
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  auto::recipes_list "$@"
fi
