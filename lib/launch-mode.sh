#!/usr/bin/env bash
# auto launch-chooser: thin bash shim around launch-mode.py.
#
# Prints `headless` / `interactive` — the deterministic interactive-vs-headless
# handoff the launch chooser (skills/auto-launch §0) keys silent-apply on (R11/AE6).
#
# Pins the interpreter to /usr/bin/python3 (overridable via CLAUDE_AUTO_PYTHON3)
# — never bare `python3`, which on macOS may resolve to a Homebrew Python lacking
# modules (rationale parity: lib/ledger.sh / lib/auto-resume.sh). No arguments:
# the session id comes from CLAUDE_CODE_SESSION_ID and the repo from the shared
# _bootstrap.resolve_repo (CLAUDE_AUTO_REPO, else the git-worktree-bounded home).

set -uo pipefail

CLAUDE_AUTO_PYTHON3="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

auto::launch_mode() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  "$CLAUDE_AUTO_PYTHON3" "${script_dir}/launch-mode.py" "$@"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  auto::launch_mode "$@"
fi
