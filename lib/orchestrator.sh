#!/usr/bin/env bash
# DEPRECATED forwarding stub (concept-vocabulary rename U2): orchestrator → dispatcher.
# Kept one minor version for agents/scripts with the memorized lib/orchestrator.sh
# path; removed next minor. Execs lib/dispatcher.sh verbatim; exit code passes through.
echo "lib/orchestrator.sh is deprecated; use lib/dispatcher.sh (orchestrator→dispatcher rename)" >&2
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dispatcher.sh" "$@"
