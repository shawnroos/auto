#!/usr/bin/env bash
# DEPRECATED forwarding stub (concept-vocabulary rename U4): adapter → backend.
# Kept one minor version for agents/scripts with the memorized lib/adapter-ce.sh
# path; removed next minor. Execs lib/backend-ce.sh verbatim; exit code passes through.
echo "lib/adapter-ce.sh is deprecated; use lib/backend-ce.sh (adapter→backend rename)" >&2
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/backend-ce.sh" "$@"
